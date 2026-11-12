"""Process-isolated timeout helpers for risky filesystem operations.

Network mounts can block indefinitely inside kernel I/O. Thread-based wrappers
do not help because the worker thread enters the same uninterruptible sleep.

These helpers maintain a single persistent worker process. Startup cost is paid
once (or once per hang-recovery). Normal operations pay only a pipe round-trip
(microseconds). If the worker hangs, it is killed and a fresh one is spawned
for the next call. The killed worker may linger in kernel U-state until the OS
releases the mount — this is expected and unavoidable.

Callers should treat TimeoutError as a stop condition.
"""

from __future__ import annotations

import hashlib
import multiprocessing as mp
import os
import time
from pathlib import Path
from typing import Any

from trove.hashing import hash_file

FILE_OP_TIMEOUT = 60.0
_POLL_INTERVAL_SECONDS = 0.1
_IDLE_TIMEOUT_SECONDS = 300.0  # worker exits after 5 min idle


# ---------------------------------------------------------------------------
# Worker loop — runs in the child process
# ---------------------------------------------------------------------------


def _worker_loop(recv_conn: Any, send_conn: Any) -> None:
    """Receive (fn, args, kwargs) tuples, execute, send back (status, result).

    Exits cleanly after _IDLE_TIMEOUT_SECONDS with no incoming work.
    Must be a top-level function so it is picklable under the spawn context.
    """
    while True:
        if not recv_conn.poll(_IDLE_TIMEOUT_SECONDS):
            break  # idle timeout — exit so the parent can GC us

        try:
            fn, args, kwargs = recv_conn.recv()
        except (EOFError, OSError):
            break

        try:
            result = fn(*args, **kwargs)
            send_conn.send(("ok", result))
        except BaseException as exc:
            try:
                send_conn.send(("err", exc))
            except Exception:
                # Exception is not picklable — send a plain version
                try:
                    send_conn.send(("err", RuntimeError(f"{type(exc).__name__}: {exc}")))
                except Exception:
                    break  # pipe broken, exit

    send_conn.close()
    recv_conn.close()


# ---------------------------------------------------------------------------
# Persistent worker — runs in the parent process
# ---------------------------------------------------------------------------


class _Worker:
    """Single long-lived child process for protected filesystem operations.

    Spawns lazily on first use. If a call times out the child is killed and
    the next call automatically spawns a replacement.
    """

    def __init__(self) -> None:
        self._proc: Any = None
        self._to_child: Any = None  # parent writes work here
        self._from_child: Any = None  # parent reads results here

    def _start(self) -> None:
        ctx = mp.get_context("spawn")
        child_recv, parent_send = ctx.Pipe(duplex=False)  # parent → child
        parent_recv, child_send = ctx.Pipe(duplex=False)  # child → parent
        proc = ctx.Process(
            target=_worker_loop,
            args=(child_recv, child_send),
            daemon=True,
        )
        proc.start()
        child_recv.close()  # parent doesn't read from this end
        child_send.close()  # parent doesn't write to this end
        self._proc = proc
        self._to_child = parent_send
        self._from_child = parent_recv

    def _alive(self) -> bool:
        return self._proc is not None and self._proc.is_alive()

    def _kill(self) -> None:
        """Kill worker and release pipes. Safe to call on a hung process."""
        if self._proc is not None:
            if self._proc.is_alive():
                self._proc.kill()
            self._proc.join(timeout=1.0)  # best-effort; U-state won't die
            # A U-state process (e.g. hung NAS mount) ignores SIGKILL and
            # stays in Python's internal _children set.  Discard it so
            # multiprocessing's atexit handler doesn't block joining it.
            try:
                from multiprocessing.process import _children  # type: ignore[attr-defined]

                _children.discard(self._proc)
            except Exception:
                pass
        for conn in (self._to_child, self._from_child):
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
        self._proc = None
        self._to_child = None
        self._from_child = None

    def run(self, fn: Any, args: tuple, kwargs: dict, timeout: float) -> Any:
        if not self._alive():
            self._start()

        try:
            self._to_child.send((fn, args, kwargs))
        except (BrokenPipeError, OSError):
            # Worker died between alive-check and send — respawn once
            self._kill()
            self._start()
            self._to_child.send((fn, args, kwargs))

        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self._kill()
                raise TimeoutError(f"File operation timed out after {timeout}s — mount may be unavailable")
            if self._from_child.poll(min(_POLL_INTERVAL_SECONDS, remaining)):
                try:
                    status, payload = self._from_child.recv()
                except EOFError:
                    self._kill()
                    raise RuntimeError("Worker process exited unexpectedly") from None
                if status == "ok":
                    return payload
                raise payload  # re-raise original exception from child
            if not self._alive():
                self._kill()
                raise RuntimeError("Worker process exited unexpectedly")


_worker = _Worker()


def run_with_timeout(fn: Any, *args: Any, timeout: float = FILE_OP_TIMEOUT, **kwargs: Any) -> Any:
    """Run fn(*args, **kwargs) in the persistent worker process with a timeout.

    On timeout the worker is killed and a fresh one is spawned for the next
    call. The main process stays responsive throughout (Ctrl-C works).
    """
    return _worker.run(fn, args, kwargs, timeout)


# ---------------------------------------------------------------------------
# Filesystem helpers — top-level so they are picklable
# ---------------------------------------------------------------------------


def ensure_dir(path_str: str) -> None:
    """Create a directory tree if it does not already exist."""
    Path(path_str).mkdir(parents=True, exist_ok=True)


def path_exists(path_str: str) -> bool:
    """Return whether the path exists."""
    return Path(path_str).exists()


def path_size(path_str: str) -> int:
    """Return the file size for a path."""
    return Path(path_str).stat().st_size


def stat_path(path_str: str) -> None:
    """Stat a path to confirm it is responsive."""
    os.stat(path_str)


def rename_path(source_str: str, dest_str: str) -> None:
    """Rename a file."""
    os.rename(source_str, dest_str)


def unlink_path(path_str: str, missing_ok: bool = False) -> None:
    """Delete a file."""
    Path(path_str).unlink(missing_ok=missing_ok)


def remove_empty_dir(path_str: str) -> None:
    """Remove an empty directory."""
    Path(path_str).rmdir()


def hash_path(path_str: str, chunk_size: int = 8192) -> str:
    """Hash a file by path."""
    return hash_file(Path(path_str), chunk_size=chunk_size)


def scan_directory(source_str: str, config_json: str, limit: int | None = None) -> list[str]:
    """Run a full directory scan inside the worker and return paths as strings.

    Running discovery in the worker means all os.scandir / stat calls happen
    in the child process, so a hung NAS cannot wedge the parent.
    """
    from trove.config import LibraryConfig
    from trove.scan import discover_files

    paths = discover_files(Path(source_str), LibraryConfig.from_json(config_json), limit=limit)
    return [str(p) for p in paths]


def copy_file_and_hash(source_str: str, dest_str: str, chunk_size: int = 8192) -> str:
    """Copy a file while computing the destination MD5.

    Preserves the source file's access and modification timestamps on the
    destination so imports do not reset filesystem dates.
    """
    hasher = hashlib.md5()
    src_stat = os.stat(source_str)
    with open(source_str, "rb") as src_f, open(dest_str, "wb") as dst_f:
        while True:
            chunk = src_f.read(chunk_size)
            if not chunk:
                break
            dst_f.write(chunk)
            hasher.update(chunk)
    os.utime(dest_str, ns=(src_stat.st_atime_ns, src_stat.st_mtime_ns))
    return hasher.hexdigest()


def move_and_cleanup(
    source_str: str,
    dest_str: str,
    lib_path_str: str,
    expected_hash: str,
    chunk_size: int = 8192,
) -> tuple[bool, str, bool]:
    """Move a file and cleanup empty parent directories — all in one batch.

    This performs the entire move operation (including cross-device copy fallback
    and cleanup) in a single worker call, avoiding multiple pipe round-trips.

    Args:
        source_str: Source file path
        dest_str: Destination file path
        lib_path_str: Library root path (cleanup stops here)
        expected_hash: MD5 hash expected for the file
        chunk_size: Buffer size for copy operations

    Returns:
        Tuple of (success, hash, was_copy) where:
        - success: True if the file is now at dest with correct hash
        - hash: The computed/verified hash (or expected_hash on simple rename)
        - was_copy: True if we did a copy+delete (cross-device), False for rename
    """
    import errno

    source = Path(source_str)
    dest = Path(dest_str)
    lib_path = Path(lib_path_str)

    # Ensure destination directory exists
    dest.parent.mkdir(parents=True, exist_ok=True)

    # Try rename first (atomic, same filesystem)
    try:
        os.rename(source_str, dest_str)
        # Rename succeeded - cleanup and return
        _cleanup_empty_dirs(source.parent, lib_path)
        return (True, expected_hash, False)
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
        # Cross-device - need to copy+verify+delete

    # Copy with hash verification
    if dest.exists():
        raise FileExistsError(f"Destination already exists: {dest}")

    result_hash = copy_file_and_hash(source_str, dest_str, chunk_size)

    if result_hash != expected_hash:
        # Hash mismatch - clean up partial copy
        try:
            dest.unlink(missing_ok=True)
        except Exception:
            pass
        raise RuntimeError(f"Hash mismatch: expected {expected_hash}, got {result_hash}")

    # Copy verified - remove source
    try:
        source.unlink()
    except Exception:
        # Log but don't fail - the file is correctly at dest
        pass

    # Cleanup empty parent directories
    _cleanup_empty_dirs(source.parent, lib_path)

    return (True, result_hash, True)


def _cleanup_empty_dirs(start: Path, stop_at: Path) -> None:
    """Remove empty parent directories from start up to (but not including) stop_at."""
    parent = start
    while parent != stop_at and parent != parent.parent:
        try:
            parent.rmdir()  # Only succeeds if empty
            parent = parent.parent
        except (OSError, PermissionError):
            # Directory not empty, permission denied, or other error - stop here
            break

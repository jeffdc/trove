# Worker Protocol Contract

## Purpose

Define the cross-project contract for the Go worker protocol before protocol v1
is frozen for both `trove` and future reuse by `reprise`.

This protocol is intentionally:

- hand-rolled
- JSON over stdio
- line-delimited
- local-process only
- easy to inspect and debug without code generation or RPC frameworks

The hard problem here is filesystem isolation around unreliable mounts, not
network RPC. The protocol should stay simple.

## Compatibility Rules

Within protocol version 1:

- existing op names are stable
- existing required request fields remain stable
- existing required response fields remain stable
- new optional request fields may be added
- new optional response fields may be added
- new operations may be added
- incompatible response-shape or op-name changes require a protocol version bump

## Startup Handshake

The worker writes one hello message on startup before processing any requests.

Example:

```json
{
  "protocol_version": 1,
  "worker_version": "0.1.0",
  "capabilities": [
    "check_mount",
    "path_exists",
    "stat_path",
    "stat_paths",
    "walk_tree",
    "quick_signature",
    "hash_path",
    "hash_paths",
    "copy_and_hash",
    "move_file",
    "unlink_path",
    "mkdir_all",
    "remove_empty_dirs"
  ]
}
```

## Request Envelope

Every request is one JSON object on one line:

```json
{
  "id": 42,
  "op": "hash_path",
  "args": {
    "path": "/Volumes/source/file.jpg"
  }
}
```

## Response Envelope

Success:

```json
{
  "id": 42,
  "ok": true,
  "result": {
    "...": "..."
  }
}
```

Failure:

```json
{
  "id": 42,
  "ok": false,
  "error": {
    "kind": "timeout",
    "message": "operation timed out after 60s"
  }
}
```

## Error Kinds

- `timeout`
- `not_found`
- `permission_denied`
- `cross_device`
- `already_exists`
- `io_error`
- `worker_crash`
- `unknown`

## Common Behavioral Rules

- Paths are expected to be host-local filesystem paths.
- `walk_tree` returns relative paths rooted at the request `root`.
- `walk_tree` skips symlinks and zero-byte files.
- `path_exists` treats missing paths as a normal `exists=false` result, not a
  protocol error.
- Batch operations return per-path errors in-band where supported.
- Timeout handling is part of the contract. A timeout means the caller may kill
  and restart the worker process.

## Hash Algorithms

Supported digest algorithms:

- `md5`
- `blake2b-128`
- `blake2b-256`

`hash_path` and `hash_paths` default to `md5` when no algorithm is provided.

For backward compatibility with current `trove` usage:

- digest-bearing results always include `digest`
- `md5` is also included when the selected algorithm is `md5`

## Copy Semantics

`copy_and_hash` and the cross-device path of `move_file` support:

- `preserve_metadata=false`
  - byte copy only
- `preserve_metadata=true`
  - preserve basic metadata
  - current scope means permission bits and modification time
  - ownership, ACLs, xattrs, and platform-specific metadata are not guaranteed

On same-device rename in `move_file`, metadata is preserved by the filesystem.

## Operation Schemas

### `check_mount`

Args:

```json
{
  "path": "/Volumes/library",
  "timeout_seconds": 10
}
```

Result:

```json
{
  "available": true,
  "error": ""
}
```

Notes:

- missing paths return `available=false` as a normal result
- a hung stat may return protocol error `timeout`

### `path_exists`

Args:

```json
{
  "path": "/Volumes/library/file.jpg"
}
```

Result:

```json
{
  "exists": true
}
```

### `stat_path`

Args:

```json
{
  "path": "/Volumes/library/file.jpg"
}
```

Result:

```json
{
  "path": "/Volumes/library/file.jpg",
  "size": 12345,
  "mtime": "2026-04-15T12:00:00Z",
  "mode": "0644",
  "is_dir": false,
  "is_symlink": false
}
```

### `stat_paths`

Args:

```json
{
  "paths": ["/a", "/b", "/c"]
}
```

Result:

```json
{
  "results": [
    {
      "path": "/a",
      "size": 10,
      "mtime": "2026-04-15T12:00:00Z",
      "mode": "0644",
      "is_dir": false,
      "is_symlink": false
    }
  ],
  "errors": [
    {
      "path": "/c",
      "error": {
        "kind": "not_found",
        "message": "..."
      }
    }
  ]
}
```

### `walk_tree`

Args:

```json
{
  "root": "/Volumes/source",
  "extensions": [".jpg", ".heic", ".flac"],
  "exclude_patterns": ["._*", "*.DS_Store"],
  "exclude_paths": ["skip-this-dir", "nested/ignore", "/Volumes/source/also-skip"]
}
```

Result:

```json
{
  "files": [
    {
      "path": "nested/file.jpg",
      "size": 12345,
      "mtime": "2026-04-15T12:00:00Z"
    }
  ]
}
```

Rules:

- `exclude_patterns` apply to filenames
- `exclude_paths` exclude a relative subtree under `root`
- absolute exclude paths under `root` are also accepted
- returned paths are always relative to `root`

### `quick_signature`

Args:

```json
{
  "path": "/Volumes/source/file.flac",
  "chunk_size": 65536
}
```

Result:

```json
{
  "path": "/Volumes/source/file.flac",
  "digest": "abcd1234",
  "algorithm": "blake2b-128",
  "size": 12345,
  "chunk_size": 65536
}
```

Rules:

- this is an explicit quick-signature operation for `reprise`-style scan flows
- current implementation hashes:
  - file size as decimal text
  - first chunk
  - last chunk when file size exceeds chunk size

### `hash_path`

Args:

```json
{
  "path": "/Volumes/source/file.jpg",
  "algorithm": "md5"
}
```

Result:

```json
{
  "path": "/Volumes/source/file.jpg",
  "digest": "abcd1234",
  "algorithm": "md5",
  "md5": "abcd1234"
}
```

### `hash_paths`

Args:

```json
{
  "paths": ["/a", "/b"],
  "algorithm": "blake2b-256"
}
```

Result:

```json
{
  "results": [
    {
      "path": "/a",
      "digest": "abcd1234",
      "algorithm": "blake2b-256"
    }
  ],
  "errors": []
}
```

### `copy_and_hash`

Args:

```json
{
  "source": "/Volumes/source/file.flac",
  "dest": "/Volumes/archive/file.flac",
  "algorithm": "blake2b-256",
  "preserve_metadata": true
}
```

Result:

```json
{
  "digest": "abcd1234",
  "algorithm": "blake2b-256",
  "metadata_preserved": true
}
```

Rules:

- writes to `dest.tmp`, then renames atomically on success
- creates parent directories
- preserves basic metadata only when requested

### `move_file`

Args:

```json
{
  "source": "/Volumes/source/file.flac",
  "dest": "/Volumes/archive/file.flac",
  "expected_hash": "abcd1234",
  "algorithm": "blake2b-256",
  "preserve_metadata": true
}
```

Result:

```json
{
  "digest": "abcd1234",
  "algorithm": "blake2b-256",
  "metadata_preserved": true
}
```

Rules:

- same-device path prefers rename
- cross-device path falls back to copy, verify, then remove source
- `expected_hash` is interpreted according to `algorithm`

### `unlink_path`

Args:

```json
{
  "path": "/Volumes/archive/file.flac"
}
```

Result:

```json
{}
```

### `mkdir_all`

Args:

```json
{
  "path": "/Volumes/archive/a/b/c"
}
```

Result:

```json
{}
```

### `remove_empty_dirs`

Args:

```json
{
  "path": "/Volumes/archive/a/b/c",
  "stop_at": "/Volumes/archive"
}
```

Result:

```json
{
  "removed": ["/Volumes/archive/a/b/c", "/Volumes/archive/a/b"]
}
```

## Explicit Non-Goals

The worker does not own:

- SQLite access
- metadata extraction from media formats
- duplicate business rules
- library placement policy
- archive semantics
- workflow-state transitions

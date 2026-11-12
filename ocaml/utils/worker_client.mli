(** Client for the Go worker child process.

    Spawns the worker binary, communicates via newline-delimited JSON on
    stdin/stdout, and provides typed OCaml wrappers for each operation.

    Includes a watchdog: if the worker does not respond within
    [response_timeout] seconds, it is killed (SIGKILL) and automatically
    restarted on the next call.  This prevents leaked goroutines from
    accumulating when NAS mounts hang. *)

(** Opaque handle to a running worker process. *)
type t

(** Result types returned by worker operations. *)

type stat_result = { size : int; mtime : string; is_dir : bool }
type walk_item = { path : string; size : int; mtime : string }

(** {1 Lifecycle} *)

(** Spawn the worker binary at [worker_path] and read its hello message.
    [response_timeout] is the maximum seconds to wait for any single worker
    response before killing the process (default 120.0, which is 2x the
    worker's internal 60s operation timeout).  Set to 0.0 to disable. *)
val start :
  ?response_timeout:float ->
  worker_path:string ->
  unit ->
  (t, Domain.worker_error) result

(** Shut down the worker: kill the process, close pipes, wait for exit. *)
val stop : t -> unit

(** [true] if the worker process is still running. *)
val is_alive : t -> bool

(** {1 Operations}

    All operations return [(value, worker_error) result].
    They send a JSON request, read a JSON response, and parse the result.
    If the worker does not respond in time, it is killed and restarted;
    the current call returns [Error Timeout]. *)

val check_mount :
  t -> path:string -> timeout_seconds:int -> (bool, Domain.worker_error) result

val path_exists : t -> string -> (bool, Domain.worker_error) result

val stat_path : t -> string -> (stat_result, Domain.worker_error) result

val walk_tree :
  t ->
  root:string ->
  extensions:string list ->
  exclude_patterns:string list ->
  (walk_item list, Domain.worker_error) result

val hash_path : t -> string -> (string, Domain.worker_error) result

val copy_and_hash :
  t -> src:string -> dst:string -> (string, Domain.worker_error) result

val move_file :
  t ->
  src:string ->
  dst:string ->
  expected_hash:string option ->
  (string, Domain.worker_error) result

val unlink_path : t -> string -> (unit, Domain.worker_error) result

val mkdir_all : t -> string -> (unit, Domain.worker_error) result

val remove_empty_dirs :
  t -> path:string -> stop_at:string -> (unit, Domain.worker_error) result

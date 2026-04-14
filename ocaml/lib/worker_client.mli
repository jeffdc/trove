(** Client for the Go worker child process.

    Spawns the worker binary, communicates via newline-delimited JSON on
    stdin/stdout, and provides typed OCaml wrappers for each operation. *)

(** Opaque handle to a running worker process. *)
type t

(** Result types returned by worker operations. *)

type stat_result = { size : int; mtime : string; is_dir : bool }
type walk_item = { path : string; size : int; mtime : string }

(** {1 Lifecycle} *)

(** Spawn the worker binary at [worker_path] and read its hello message.
    Raises [Failure] if the binary cannot be started or the hello handshake
    fails. *)
val start : worker_path:string -> t

(** Shut down the worker: close pipes and wait for the process to exit. *)
val stop : t -> unit

(** [true] if the worker process is still running. *)
val is_alive : t -> bool

(** {1 Operations}

    All operations return [(value, worker_error) result].
    They send a JSON request, read a JSON response, and parse the result. *)

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

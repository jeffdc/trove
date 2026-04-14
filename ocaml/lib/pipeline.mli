(** Composable pipeline stages for file processing.

    Each stage takes a list of file record IDs (except discover which produces
    them) and returns IDs for the next stage. Side effects are DB updates. *)

(** Set of strings, used for tracking claimed paths and skip sets. *)
module StringSet : Set.S with type elt = string

(** {1 Pure functions} *)

(** Normalize a filename for safe, portable use on all platforms.
    See implementation for the full list of normalization rules. *)
val normalize_filename : string -> string

(** Parse an ISO date string, returning [(year, month, day)] or [None]. *)
val parse_iso_date : string -> (int * int * int) option

(** Format a date using a strftime-like structure string.
    Supports [%Y] (4-digit year), [%m] (2-digit month), [%d] (2-digit day). *)
val format_date_structure :
  year:int -> month:int -> day:int -> string -> string

(** Compute relative target path for a file within a library.
    Returns [None] if the capture_date cannot be parsed. *)
val compute_target_path :
  capture_date:string ->
  camera_model:string option ->
  filename:string ->
  Config.library_config ->
  string option

(** Resolve a target path against a mutable set of claimed paths.
    If the path is already claimed, appends [-1], [-2], etc.
    Mutates the set to include the resolved path. *)
val resolve_path : string -> StringSet.t ref -> string

(** {1 Pipeline stages (DB-backed)} *)

(** Process pre-fetched walk items: check for existing records, insert new
    ones, reset changed ones, skip unchanged. Returns [(new_or_reset_ids, skip_count)].

    This is the testable core of discovery that does not require a live worker. *)
val discover_and_persist_from_items :
  Db.t ->
  source_path:string ->
  source_type:string ->
  Worker_client.walk_item list ->
  skip_paths:StringSet.t ->
  int list * int

(** Hash files by ID using [Worker_client.hash_path].
    Files that fail hashing are quarantined. Returns IDs of successfully
    hashed files. *)
val hash_files : Db.t -> Worker_client.t -> int list -> int list

(** Testable version of [hash_files] that takes a hash function instead
    of a worker client. *)
val hash_files_with_fn :
  Db.t ->
  int list ->
  hash_fn:(string -> (string, Domain.worker_error) result) ->
  int list

(** Compute target paths for file records and update the DB.
    Returns the same ID list. *)
val compute_paths : Db.t -> int list -> Config.library_config -> int list

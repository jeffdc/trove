(** Import planning and execution for trove.

    [classify_for_import] builds a pure plan (DB reads only).
    [execute_import] carries out the plan using the Go worker for copies. *)

(** Summary of an import execution. *)
type import_summary = {
  imported : int;
  dup_in_batch : int;
  dup_in_library : int;
  path_conflicts : int;
  errors : int;
}

(** Build an import plan for the given hashed file record IDs.

    Reads file records from DB, classifies them into:
    - [to_import]: unique files with a target path
    - [duplicates_in_batch]: files sharing a hash with another file in this batch
    - [duplicates_in_library]: files whose hash already exists in the library
    - [skipped]: files without a target path
    - [path_conflicts]: count of to_import files whose target path is occupied *)
val classify_for_import :
  Legacy_db_impl.t -> library_id:int -> int list -> Config.library_config -> Legacy_domain.import_plan

(** Resolve a target path against existing library entries.
    Returns the path unchanged if no entry exists there.
    Otherwise appends [-1], [-2], etc. to the stem. *)
val resolve_target_path : Legacy_db_impl.t -> library_id:int -> string -> string

(** Execute an import plan using a live worker for file operations. *)
val execute_import :
  Legacy_db_impl.t ->
  Worker_client.t ->
  Legacy_domain.library ->
  Config.library_config ->
  Legacy_domain.import_plan ->
  import_summary

(** Testable version of [execute_import] that accepts function arguments
    instead of a worker client. *)
val execute_import_with_fns :
  Legacy_db_impl.t ->
  Legacy_domain.library ->
  Config.library_config ->
  Legacy_domain.import_plan ->
  copy_fn:(src:string -> dst:string -> (string, Domain.worker_error) result) ->
  mkdir_fn:(string -> (unit, Domain.worker_error) result) ->
  exists_fn:(string -> (bool, Domain.worker_error) result) ->
  ?hash_fn:(string -> (string, Domain.worker_error) result) ->
  unit ->
  import_summary

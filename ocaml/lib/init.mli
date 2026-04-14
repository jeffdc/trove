(** Library initialization: classify existing files and execute the init plan.

    [classify_for_init] is a pure planning function that reads DB state and
    produces an {!Domain.init_plan}. [execute_init] carries out the plan by
    moving files, creating entries, and cleaning up file records. *)

(** Result of executing an init plan. *)
type init_result = {
  indexed : int;
  moved : int;
  quarantined_count : int;
  errors : int;
}

(** Extract relative path by stripping the library location prefix.
    Given [~lib_location:"/lib/photos"] and ["/lib/photos/2024/photo.jpg"],
    returns ["2024/photo.jpg"]. Returns the original path unchanged if
    the prefix does not match. *)
val relative_path : lib_location:string -> string -> string

(** Build an init plan from hashed and quarantined file IDs.

    Reads existing library entries to detect claimed paths, then classifies
    each file as already-correct, needing a move, or quarantined. Path
    conflicts are resolved with numeric suffixes via {!Pipeline.resolve_path}. *)
val classify_for_init :
  Db.t ->
  library_id:int ->
  hashed_ids:int list ->
  quarantined_ids:int list ->
  Config.library_config ->
  Domain.init_plan

(** Execute an init plan: index correct files, move others, handle quarantined.

    For each category in the plan:
    - {b already_correct}: create entry, delete file record.
    - {b needs_move}: mkdir, move via worker, create entry, clean up empty dirs,
      delete file record. On move failure, log and increment errors.
    - {b quarantined}: mkdir, move to quarantine, create entry, delete file record. *)
val execute_init :
  Db.t -> Worker_client.t -> Domain.library -> Domain.init_plan -> init_result

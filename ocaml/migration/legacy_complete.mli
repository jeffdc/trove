(** Import/init completion: verify all files are accounted for and clean up
    transient file records. *)

(** Plan produced by [plan_complete] classifying file records by terminal state. *)
type complete_plan = {
  imported : Legacy_domain.file_record list;
  duplicate : Legacy_domain.file_record list;
  quarantined : Legacy_domain.file_record list;
  unaccounted : Legacy_domain.file_record list;
}

(** Result of [execute_complete] summarising what happened. *)
type complete_result = {
  imported_count : int;
  duplicate_count : int;
  quarantined_count : int;
  unaccounted_count : int;
  records_cleaned : int;
  can_complete : bool;
}

(** Build a completion plan.

    Queries file records by status and classifies them:
    - [imported]: files at Imported status with a matching library entry (by hash)
    - [duplicate]: files at any Duplicate status
    - [quarantined]: files at any Quarantined status
    - [unaccounted]: discovered + hashed files, plus imported files that lack
      a hash or a matching library entry *)
val plan_complete : Legacy_db_impl.t -> library_id:int -> complete_plan

(** Execute a completion plan.

    If [unaccounted] is non-empty, returns [can_complete = false] and does
    nothing. Otherwise deletes all terminal file records from the database. *)
val execute_complete : Legacy_db_impl.t -> complete_plan -> complete_result

(** Convenience wrapper: [plan_complete] then [execute_complete]. *)
val complete_import : Legacy_db_impl.t -> library_id:int -> complete_result

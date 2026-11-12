type init_summary = {
  source_root_id : int;
  run_id : int;
  observed : int;
  skipped_managed : int;
  indexed_existing : int;
  moved : int;
  duplicate_in_library : int;
  quarantined : int;
  failed : int;
  path_conflicts : int;
}

val initialize_library_by_name :
  Db.t ->
  Worker_client.t ->
  name:string ->
  (init_summary, Domain.app_error) result

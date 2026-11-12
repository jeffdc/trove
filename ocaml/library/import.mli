type import_summary = {
  source_root_id : int;
  run_id : int;
  observed : int;
  admitted : int;
  duplicate_in_library : int;
  quarantined : int;
  failed : int;
  path_conflicts : int;
}

val import_into_library_by_name :
  Db.t ->
  Worker_client.t ->
  name:string ->
  source:string ->
  (import_summary, Domain.app_error) result

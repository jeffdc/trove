(** Read-only schema-runtime helpers for migrated schema databases. *)

type library_item_counts = {
  active : int;
  missing : int;
  broken : int;
  retired : int;
}

type placement_counts = {
  healthy : int;
  misplaced : int;
  missing : int;
  repair_needed : int;
}

type library_status = {
  library : Domain.library;
  total_library_items : int;
  total_placements : int;
  items_without_placement : int;
  library_item_counts : library_item_counts;
  placement_counts : placement_counts;
}

type verify_issue = {
  placement : Domain.library_placement;
  observed_status : Domain.Placement_status.t;
  observed_relative_path : string option;
  detail : string option;
}

type verify_report = {
  library_status : library_status;
  checked_placements : int;
  observed_placement_counts : placement_counts;
  placement_status_mismatches : int;
  issues : verify_issue list;
}

val list_libraries :
  Db.t -> (Domain.library list, Domain.app_error) result

val get_library_status_by_name :
  Db.t -> string -> (library_status, Domain.app_error) result

val verify_library_by_name :
  ?progress:(checked:int -> total:int -> unit) ->
  Db.t ->
  Worker_client.t ->
  string ->
  (verify_report, Domain.app_error) result

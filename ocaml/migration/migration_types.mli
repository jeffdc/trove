(** Shared migration-only types and lookup state. *)

type mapping_state = {
  library_ids_by_legacy_id : (int, int) Hashtbl.t;
  file_object_ids_by_md5 : (string, int) Hashtbl.t;
  library_item_ids_by_entry_id : (int, int) Hashtbl.t;
  source_observation_ids_by_file_id : (int, int) Hashtbl.t;
}

val create_mapping_state : unit -> mapping_state

type anomaly_kind =
  | Imported_file_without_entry
  | Ambiguous_duplicate_kind
  | Missing_without_library_link
  | Entry_without_md5
  | Target_path_conflict
  | Inconsistent_md5_group
  | Unsupported_source_type
  | Legacy_completed_status

type anomaly = {
  kind : anomaly_kind;
  legacy_table : string;
  legacy_id : int option;
  detail : string;
}

val anomaly_kind_to_string : anomaly_kind -> string

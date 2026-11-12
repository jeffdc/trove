type mapping_state = {
  library_ids_by_legacy_id : (int, int) Hashtbl.t;
  file_object_ids_by_md5 : (string, int) Hashtbl.t;
  library_item_ids_by_entry_id : (int, int) Hashtbl.t;
  source_observation_ids_by_file_id : (int, int) Hashtbl.t;
}

let create_mapping_state () =
  {
    library_ids_by_legacy_id = Hashtbl.create 32;
    file_object_ids_by_md5 = Hashtbl.create 128;
    library_item_ids_by_entry_id = Hashtbl.create 128;
    source_observation_ids_by_file_id = Hashtbl.create 128;
  }

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

let anomaly_kind_to_string = function
  | Imported_file_without_entry -> "imported_file_without_entry"
  | Ambiguous_duplicate_kind -> "ambiguous_duplicate_kind"
  | Missing_without_library_link -> "missing_without_library_link"
  | Entry_without_md5 -> "entry_without_md5"
  | Target_path_conflict -> "target_path_conflict"
  | Inconsistent_md5_group -> "inconsistent_md5_group"
  | Unsupported_source_type -> "unsupported_source_type"
  | Legacy_completed_status -> "legacy_completed_status"

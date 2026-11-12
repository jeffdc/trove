(** Core domain types for trove's file processing workflow. *)

type quarantine_reason =
  | Hash_failed
  | No_date
  | Unreadable

type duplicate_kind =
  | In_batch
  | In_library

type file_status =
  | Discovered
  | Hashed
  | Quarantined of quarantine_reason
  | Duplicate of duplicate_kind
  | Imported
  | Unknown_status of string

type file_action =
  | Index
  | Move of { src : string; dst : string }
  | Quarantine of string

type worker_error =
  | Timeout
  | Not_found
  | Permission_denied
  | Cross_device
  | Io_error of string
  | Already_exists
  | Worker_crash
  | Unknown of string

type app_error =
  | Mount_unavailable
  | File_disappeared
  | Db_error of string
  | Worker_protocol_error of string
  | Hash_mismatch of { expected : string; actual : string }

type file_record = {
  id : int;
  source_path : string;
  file_size : int;
  file_modify_date : string;
  md5_hash : string option;
  capture_date : string option;
  camera_model : string option;
  target_path : string option;
  status : file_status;
  error_message : string option;
  discovered_at : string;
  hashed_at : string option;
}

type entry = {
  id : int;
  library_id : int;
  relative_path : string;
  file_size : int;
  md5_hash : string option;
  capture_date : string option;
  camera_model : string option;
  imported_at : string;
  original_path : string option;
}

type library = {
  id : int;
  name : string;
  location : string;
  config_json : string;
  created_at : string;
}

type import_plan = {
  to_import : file_record list;
  duplicates_in_batch : file_record list;
  duplicates_in_library : file_record list;
  path_conflicts : int;
  skipped : file_record list;
}

type init_plan = {
  already_correct : file_record list;
  needs_move : (file_record * string) list;
  duplicates : file_record list;
  quarantined : (file_record * string) list;
}

let file_status_to_string = function
  | Discovered -> "discovered"
  | Hashed -> "hashed"
  | Quarantined _ -> "quarantined"
  | Duplicate _ -> "duplicate"
  | Imported -> "imported"
  | Unknown_status s -> s

let file_status_of_string = function
  | "discovered" -> Discovered
  | "hashed" -> Hashed
  | "quarantined" -> Quarantined Hash_failed
  | "duplicate" -> Duplicate In_batch
  | "imported" -> Imported
  | s -> Unknown_status s

let worker_error_of_string s =
  match s with
  | "timeout" -> Timeout
  | "not_found" -> Not_found
  | "permission_denied" -> Permission_denied
  | "cross_device" -> Cross_device
  | "already_exists" -> Already_exists
  | "worker_crash" -> Worker_crash
  | "io_error" -> Io_error ""
  | _ ->
    let prefix = "io_error:" in
    let plen = String.length prefix in
    if String.length s > plen && String.sub s 0 plen = prefix then
      Io_error (String.sub s plen (String.length s - plen))
    else
      Unknown s

(** Core domain types for trove's file processing workflow. *)

(** File status state machine *)

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

(** Actions that can be taken on a file during init *)
type file_action =
  | Index
  | Move of { src : string; dst : string }
  | Quarantine of string  (** destination path *)

(** Errors from the Go worker *)
type worker_error =
  | Timeout
  | Not_found
  | Permission_denied
  | Cross_device
  | Io_error of string
  | Already_exists
  | Worker_crash
  | Unknown of string

(** Application-level errors *)
type app_error =
  | Mount_unavailable
  | File_disappeared
  | Db_error of string
  | Worker_protocol_error of string
  | Hash_mismatch of { expected : string; actual : string }

(** Core record types *)

type file_record = {
  id : int;
  source_path : string;
  file_size : int;
  file_modify_date : string;  (** ISO 8601 UTC *)
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
  config_json : string;  (** raw JSON — parsed by Config module *)
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
  needs_move : (file_record * string) list;  (** record * target_path *)
  duplicates : file_record list;
  quarantined : (file_record * string) list;  (** record * resolved quarantine path *)
}

(** Convert file_status to/from the string stored in SQLite *)

val file_status_to_string : file_status -> string
val file_status_of_string : string -> file_status

(** Convert worker error kind string from Go worker to OCaml variant *)
val worker_error_of_string : string -> worker_error

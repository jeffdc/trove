(** Target library-centric domain types for the rewrite. *)

type timestamp = string

module Hash_algorithm : sig
  type t =
    | Md5

  val to_string : t -> string
  val of_string : string -> t
end

module Source_kind : sig
  type t =
    | Import
    | Init_root
    | Staging

  val to_string : t -> string
  val of_string : string -> t
end

module Run_mode : sig
  type t =
    | Import
    | Init
    | Verify
    | Rehash
    | Reconcile

  val to_string : t -> string
  val of_string : string -> t
end

module Run_status : sig
  type t =
    | Planned
    | Running
    | Completed
    | Failed
    | Interrupted
    | Abandoned

  val to_string : t -> string
  val of_string : string -> t
end

module Workflow_state : sig
  type t =
    | Observed
    | Identified
    | Planned
    | Executing
    | Completed
    | Failed

  val to_string : t -> string
  val of_string : string -> t
end

module Planned_action : sig
  type t =
    | Admit_copy
    | Admit_move
    | Index_existing
    | Quarantine
    | Skip

  val to_string : t -> string
  val of_string : string -> t
end

module Disposition : sig
  type t =
    | Pending
    | Admitted
    | Duplicate_in_library
    | Quarantined
    | Skipped
    | Failed

  val to_string : t -> string
  val of_string : string -> t
end

module Library_item_status : sig
  type t =
    | Active
    | Missing
    | Broken
    | Retired

  val to_string : t -> string
  val of_string : string -> t
end

module Placement_status : sig
  type t =
    | Healthy
    | Misplaced
    | Missing
    | Repair_needed

  val to_string : t -> string
  val of_string : string -> t
end

module File_op_kind : sig
  type t =
    | Copy
    | Move
    | Unlink
    | Mkdir
    | Quarantine_move

  val to_string : t -> string
  val of_string : string -> t
end

module File_op_status : sig
  type t =
    | Running
    | Completed
    | Failed

  val to_string : t -> string
  val of_string : string -> t
end

type library = {
  id : int;
  name : string;
  root_path : string;
  config_json : string;
  created_at : timestamp;
  updated_at : timestamp;
}

type source_root = {
  id : int;
  library_id : int;
  root_path : string;
  source_kind : Source_kind.t;
  created_at : timestamp;
}

type run = {
  id : int;
  library_id : int;
  source_root_id : int option;
  mode : Run_mode.t;
  status : Run_status.t;
  options_json : string option;
  summary_json : string option;
  error_text : string option;
  started_at : timestamp;
  completed_at : timestamp option;
}

type source_observation = {
  id : int;
  run_id : int;
  source_root_id : int;
  observed_path : string;
  relative_path : string option;
  size_bytes : int option;
  mtime : timestamp option;
  observed_at : timestamp;
  file_object_id : int option;
}

type file_object = {
  id : int;
  content_hash : string;
  hash_algorithm : Hash_algorithm.t;
  blake2b_256_hash : string option;
  size_bytes : int;
  quick_signature : string option;
  capture_date : timestamp option;
  camera_model : string option;
  original_filename : string option;
  extension : string option;
  mime_type : string option;
  metadata_json : string option;
  metadata_extracted_at : timestamp option;
  metadata_tool : string option;
  created_at : timestamp;
  updated_at : timestamp;
}

type run_item = {
  id : int;
  run_id : int;
  source_observation_id : int option;
  file_object_id : int option;
  workflow_state : Workflow_state.t;
  planned_action : Planned_action.t option;
  disposition : Disposition.t option;
  planned_relative_path : string option;
  failure_reason : string option;
  created_at : timestamp;
  updated_at : timestamp;
}

type library_item = {
  id : int;
  library_id : int;
  file_object_id : int;
  admitted_from_run_item_id : int option;
  status : Library_item_status.t;
  created_at : timestamp;
  updated_at : timestamp;
}

type library_placement = {
  id : int;
  library_item_id : int;
  library_id : int;
  intended_relative_path : string;
  actual_relative_path : string option;
  placement_status : Placement_status.t;
  last_verified_at : timestamp option;
  error_text : string option;
  created_at : timestamp;
  updated_at : timestamp;
}

type file_op = {
  id : int;
  run_id : int;
  run_item_id : int option;
  library_item_id : int option;
  op_kind : File_op_kind.t;
  src_path : string option;
  dst_path : string option;
  status : File_op_status.t;
  error_text : string option;
  started_at : timestamp;
  completed_at : timestamp option;
}

type worker_error =
  | Timeout
  | Not_found
  | Permission_denied
  | Cross_device
  | Io_error of string
  | Already_exists
  | Worker_crash
  | Unknown of string

type error_code =
  | Worker_timeout
  | Filesystem_not_found
  | Filesystem_permission_denied
  | Filesystem_cross_device
  | Filesystem_already_exists
  | Filesystem_io_error
  | Worker_io_error
  | Worker_crash_error
  | Worker_unknown
  | Mount_unavailable
  | Library_not_found
  | Db_error
  | Invalid_state
  | Unsupported_operation

type app_error = {
  code : error_code;
  message : string;
  retryable : bool;
  context : (string * string) list;
}

val worker_error_of_string : string -> worker_error

(** Target library-centric domain types for the rewrite. *)

type timestamp = string

exception Invalid_enum of string

let invalid_enum kind value =
  raise (Invalid_enum (Printf.sprintf "Unknown %s: %s" kind value))

module Hash_algorithm = struct
  type t =
    | Md5

  let to_string = function
    | Md5 -> "md5"

  let of_string = function
    | "md5" -> Md5
    | value -> invalid_enum "hash algorithm" value
end

module Source_kind = struct
  type t =
    | Import
    | Init_root
    | Staging

  let to_string = function
    | Import -> "import"
    | Init_root -> "init_root"
    | Staging -> "staging"

  let of_string = function
    | "import" -> Import
    | "init_root" -> Init_root
    | "staging" -> Staging
    | value -> invalid_enum "source kind" value
end

module Run_mode = struct
  type t =
    | Import
    | Init
    | Verify
    | Rehash
    | Reconcile

  let to_string = function
    | Import -> "import"
    | Init -> "init"
    | Verify -> "verify"
    | Rehash -> "rehash"
    | Reconcile -> "reconcile"

  let of_string = function
    | "import" -> Import
    | "init" -> Init
    | "verify" -> Verify
    | "rehash" -> Rehash
    | "reconcile" -> Reconcile
    | value -> invalid_enum "run mode" value
end

module Run_status = struct
  type t =
    | Planned
    | Running
    | Completed
    | Failed
    | Interrupted
    | Abandoned

  let to_string = function
    | Planned -> "planned"
    | Running -> "running"
    | Completed -> "completed"
    | Failed -> "failed"
    | Interrupted -> "interrupted"
    | Abandoned -> "abandoned"

  let of_string = function
    | "planned" -> Planned
    | "running" -> Running
    | "completed" -> Completed
    | "failed" -> Failed
    | "interrupted" -> Interrupted
    | "abandoned" -> Abandoned
    | value -> invalid_enum "run status" value
end

module Workflow_state = struct
  type t =
    | Observed
    | Identified
    | Planned
    | Executing
    | Completed
    | Failed

  let to_string = function
    | Observed -> "observed"
    | Identified -> "identified"
    | Planned -> "planned"
    | Executing -> "executing"
    | Completed -> "completed"
    | Failed -> "failed"

  let of_string = function
    | "observed" -> Observed
    | "identified" -> Identified
    | "planned" -> Planned
    | "executing" -> Executing
    | "completed" -> Completed
    | "failed" -> Failed
    | value -> invalid_enum "workflow state" value
end

module Planned_action = struct
  type t =
    | Admit_copy
    | Admit_move
    | Index_existing
    | Quarantine
    | Skip

  let to_string = function
    | Admit_copy -> "admit_copy"
    | Admit_move -> "admit_move"
    | Index_existing -> "index_existing"
    | Quarantine -> "quarantine"
    | Skip -> "skip"

  let of_string = function
    | "admit_copy" -> Admit_copy
    | "admit_move" -> Admit_move
    | "index_existing" -> Index_existing
    | "quarantine" -> Quarantine
    | "skip" -> Skip
    | value -> invalid_enum "planned action" value
end

module Disposition = struct
  type t =
    | Pending
    | Admitted
    | Duplicate_in_library
    | Quarantined
    | Skipped
    | Failed

  let to_string = function
    | Pending -> "pending"
    | Admitted -> "admitted"
    | Duplicate_in_library -> "duplicate_in_library"
    | Quarantined -> "quarantined"
    | Skipped -> "skipped"
    | Failed -> "failed"

  let of_string = function
    | "pending" -> Pending
    | "admitted" -> Admitted
    | "duplicate_in_library" -> Duplicate_in_library
    | "quarantined" -> Quarantined
    | "skipped" -> Skipped
    | "failed" -> Failed
    | value -> invalid_enum "disposition" value
end

module Library_item_status = struct
  type t =
    | Active
    | Missing
    | Broken
    | Retired

  let to_string = function
    | Active -> "active"
    | Missing -> "missing"
    | Broken -> "broken"
    | Retired -> "retired"

  let of_string = function
    | "active" -> Active
    | "missing" -> Missing
    | "broken" -> Broken
    | "retired" -> Retired
    | value -> invalid_enum "library item status" value
end

module Placement_status = struct
  type t =
    | Healthy
    | Misplaced
    | Missing
    | Repair_needed

  let to_string = function
    | Healthy -> "healthy"
    | Misplaced -> "misplaced"
    | Missing -> "missing"
    | Repair_needed -> "repair_needed"

  let of_string = function
    | "healthy" -> Healthy
    | "misplaced" -> Misplaced
    | "missing" -> Missing
    | "repair_needed" -> Repair_needed
    | value -> invalid_enum "placement status" value
end

module File_op_kind = struct
  type t =
    | Copy
    | Move
    | Unlink
    | Mkdir
    | Quarantine_move

  let to_string = function
    | Copy -> "copy"
    | Move -> "move"
    | Unlink -> "unlink"
    | Mkdir -> "mkdir"
    | Quarantine_move -> "quarantine_move"

  let of_string = function
    | "copy" -> Copy
    | "move" -> Move
    | "unlink" -> Unlink
    | "mkdir" -> Mkdir
    | "quarantine_move" -> Quarantine_move
    | value -> invalid_enum "file op kind" value
end

module File_op_status = struct
  type t =
    | Running
    | Completed
    | Failed

  let to_string = function
    | Running -> "running"
    | Completed -> "completed"
    | Failed -> "failed"

  let of_string = function
    | "running" -> Running
    | "completed" -> Completed
    | "failed" -> Failed
    | value -> invalid_enum "file op status" value
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

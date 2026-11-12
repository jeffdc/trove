(** Record types mirroring the Python/main schema for read-only migration. *)

type library = {
  id : int;
  name : string;
  location : string;
  config_json : string;
  created_at : string;
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

type file_row = {
  id : int;
  source_path : string;
  source_type : string;
  file_size : int;
  file_modify_date : string;
  md5_hash : string option;
  capture_date : string option;
  camera_model : string option;
  target_path : string option;
  status : string;
  error_message : string option;
  discovered_at : string;
  hashed_at : string option;
}

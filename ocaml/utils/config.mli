(** Library configuration parsed from JSON.

    Mirrors the Python LibraryConfig dataclass for compatibility.
    Missing keys in JSON are filled with defaults. *)

type organization_config = {
  structure : string;
  include_camera_model : bool;
  unknown_model_label : string;
}

type file_types_config = {
  photos : string list;
  videos : string list;
  raw : string list;
}

type quarantine_config = {
  path : string;
  reasons : string list;
}

type library_config = {
  organization : organization_config;
  file_types : file_types_config;
  exclude_patterns : string list;
  quarantine : quarantine_config;
}

(** Default configuration matching Python defaults. *)
val default : library_config

(** Parse a JSON string into a library config, filling missing keys
    with defaults. *)
val of_json_string : string -> library_config

(** Serialize a library config to a JSON string. *)
val to_json_string : library_config -> string

(** Return all configured file extensions (photos ++ videos ++ raw),
    lowercased, with leading dots (e.g., ".jpg"). *)
val all_extensions : library_config -> string list

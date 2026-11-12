(** Library configuration parsed from JSON. *)

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

let default_organization =
  {
    structure = "%Y/%m";
    include_camera_model = true;
    unknown_model_label = "Unknown_Model";
  }

let default_file_types =
  {
    photos =
      [ "jpg"; "jpeg"; "heic"; "png"; "tiff"; "tif"; "psd"; "gif"; "dng";
        "bmp"; "webp" ];
    videos = [ "mov"; "mp4"; "mpg"; "mpeg"; "avi"; "m4v"; "mts" ];
    raw =
      [ "cr2"; "cr3"; "nef"; "arw"; "orf"; "raf"; "rw2"; "dng"; "srw";
        "pef" ];
  }

let default_exclude_patterns =
  [ "*.DS_Store"; "._*"; "Thumbs.db"; "*.ini"; "*.db"; "thumb_*" ]

let default_quarantine =
  {
    path = "quarantine/";
    reasons = [ "no_exif_date"; "corrupt_file"; "unreadable_file" ];
  }

let default =
  {
    organization = default_organization;
    file_types = default_file_types;
    exclude_patterns = default_exclude_patterns;
    quarantine = default_quarantine;
  }

(* --- JSON parsing helpers --- *)

let string_list_of_json json =
  Yojson.Safe.Util.(json |> to_list |> filter_string)

let organization_of_json json =
  let open Yojson.Safe.Util in
  let d = default_organization in
  {
    structure =
      (try member "structure" json |> to_string with _ -> d.structure);
    include_camera_model =
      (try member "include_camera_model" json |> to_bool
       with _ -> d.include_camera_model);
    unknown_model_label =
      (try member "unknown_model_label" json |> to_string
       with _ -> d.unknown_model_label);
  }

let file_types_of_json json =
  let open Yojson.Safe.Util in
  let d = default_file_types in
  {
    photos =
      (try member "photos" json |> string_list_of_json with _ -> d.photos);
    videos =
      (try member "videos" json |> string_list_of_json with _ -> d.videos);
    raw = (try member "raw" json |> string_list_of_json with _ -> d.raw);
  }

let quarantine_of_json json =
  let open Yojson.Safe.Util in
  let d = default_quarantine in
  {
    path = (try member "path" json |> to_string with _ -> d.path);
    reasons =
      (try member "reasons" json |> string_list_of_json with _ -> d.reasons);
  }

let of_json_string s =
  let json = Yojson.Safe.from_string s in
  let open Yojson.Safe.Util in
  let d = default in
  {
    organization =
      (try member "organization" json |> organization_of_json
       with _ -> d.organization);
    file_types =
      (try member "file_types" json |> file_types_of_json
       with _ -> d.file_types);
    exclude_patterns =
      (try member "exclude_patterns" json |> string_list_of_json
       with _ -> d.exclude_patterns);
    quarantine =
      (try member "quarantine" json |> quarantine_of_json
       with _ -> d.quarantine);
  }

(* --- JSON serialization --- *)

let json_of_string_list ss =
  `List (List.map (fun s -> `String s) ss)

let organization_to_json org =
  `Assoc
    [
      ("structure", `String org.structure);
      ("include_camera_model", `Bool org.include_camera_model);
      ("unknown_model_label", `String org.unknown_model_label);
    ]

let file_types_to_json ft =
  `Assoc
    [
      ("photos", json_of_string_list ft.photos);
      ("videos", json_of_string_list ft.videos);
      ("raw", json_of_string_list ft.raw);
    ]

let quarantine_to_json q =
  `Assoc
    [
      ("path", `String q.path);
      ("reasons", json_of_string_list q.reasons);
    ]

let to_json_string c =
  let json =
    `Assoc
      [
        ("organization", organization_to_json c.organization);
        ("file_types", file_types_to_json c.file_types);
        ("exclude_patterns", json_of_string_list c.exclude_patterns);
        ("quarantine", quarantine_to_json c.quarantine);
      ]
  in
  Yojson.Safe.to_string json

(* --- Extensions --- *)

let all_extensions c =
  let exts =
    c.file_types.photos @ c.file_types.videos @ c.file_types.raw
  in
  List.map (fun ext -> "." ^ String.lowercase_ascii ext) exts

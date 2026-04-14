open Config

let library_config_testable =
  Alcotest.testable
    (fun fmt c -> Format.pp_print_string fmt (to_json_string c))
    ( = )

let string_list_testable =
  Alcotest.(list string)

(* --- Test: default config matches expected Python defaults --- *)

let test_default_values () =
  let c = default in
  Alcotest.(check string) "structure" "%Y/%m" c.organization.structure;
  Alcotest.(check bool) "include_camera_model" true
    c.organization.include_camera_model;
  Alcotest.(check string) "unknown_model_label" "Unknown_Model"
    c.organization.unknown_model_label;
  (* file_types: photos *)
  Alcotest.(check (list string)) "photos"
    [ "jpg"; "jpeg"; "heic"; "png"; "tiff"; "tif"; "psd"; "gif"; "dng";
      "bmp"; "webp" ]
    c.file_types.photos;
  (* file_types: videos *)
  Alcotest.(check (list string)) "videos"
    [ "mov"; "mp4"; "mpg"; "mpeg"; "avi"; "m4v"; "mts" ]
    c.file_types.videos;
  (* file_types: raw *)
  Alcotest.(check (list string)) "raw"
    [ "cr2"; "cr3"; "nef"; "arw"; "orf"; "raf"; "rw2"; "dng"; "srw"; "pef" ]
    c.file_types.raw;
  (* exclude_patterns *)
  Alcotest.(check (list string)) "exclude_patterns"
    [ "*.DS_Store"; "._*"; "Thumbs.db"; "*.ini"; "*.db"; "thumb_*" ]
    c.exclude_patterns;
  (* quarantine *)
  Alcotest.(check string) "quarantine path" "quarantine/"
    c.quarantine.path;
  Alcotest.(check (list string)) "quarantine reasons"
    [ "no_exif_date"; "corrupt_file"; "unreadable_file" ]
    c.quarantine.reasons

(* --- Test: round-trip serialization --- *)

let test_round_trip () =
  let c = default in
  let json_str = to_json_string c in
  let c' = of_json_string json_str in
  Alcotest.(check library_config_testable) "round-trip" c c'

(* --- Test: empty JSON produces default config --- *)

let test_empty_json () =
  let c = of_json_string "{}" in
  Alcotest.(check library_config_testable) "empty json = default" default c

(* --- Test: partial JSON fills missing keys with defaults --- *)

let test_partial_json_organization_only () =
  let json =
    {|{"organization": {"structure": "%Y/%m/%d", "include_camera_model": false}}|}
  in
  let c = of_json_string json in
  (* overridden values *)
  Alcotest.(check string) "structure overridden" "%Y/%m/%d"
    c.organization.structure;
  Alcotest.(check bool) "include_camera_model overridden" false
    c.organization.include_camera_model;
  (* defaults filled in for missing key within organization *)
  Alcotest.(check string) "unknown_model_label default" "Unknown_Model"
    c.organization.unknown_model_label;
  (* rest of config is defaults *)
  Alcotest.(check (list string)) "file_types.photos default"
    default.file_types.photos c.file_types.photos;
  Alcotest.(check (list string)) "exclude_patterns default"
    default.exclude_patterns c.exclude_patterns;
  Alcotest.(check string) "quarantine.path default" "quarantine/"
    c.quarantine.path

(* --- Test: all_extensions returns dotted, lowercased list --- *)

let test_all_extensions () =
  let exts = all_extensions default in
  (* Should start with photos, then videos, then raw *)
  let has ext = List.mem ext exts in
  Alcotest.(check bool) ".jpg present" true (has ".jpg");
  Alcotest.(check bool) ".heic present" true (has ".heic");
  Alcotest.(check bool) ".mov present" true (has ".mov");
  Alcotest.(check bool) ".cr2 present" true (has ".cr2");
  Alcotest.(check bool) ".webp present" true (has ".webp");
  Alcotest.(check bool) ".pef present" true (has ".pef");
  (* Verify they all start with dots *)
  List.iter
    (fun ext ->
      Alcotest.(check bool) ("dot prefix: " ^ ext) true
        (String.length ext > 0 && ext.[0] = '.'))
    exts;
  (* Total count = 11 photos + 7 videos + 10 raw = 28 *)
  Alcotest.(check int) "extension count" 28 (List.length exts)

(* --- Test: parse a full Python-generated config JSON --- *)

let test_full_python_json () =
  let json =
    {|{
      "organization": {
        "structure": "%Y/%m",
        "include_camera_model": true,
        "unknown_model_label": "Unknown_Model"
      },
      "file_types": {
        "photos": ["jpg", "jpeg", "heic", "png", "tiff", "tif", "psd", "gif", "dng", "bmp", "webp"],
        "videos": ["mov", "mp4", "mpg", "mpeg", "avi", "m4v", "mts"],
        "raw": ["cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "dng", "srw", "pef"]
      },
      "exclude_patterns": ["*.DS_Store", "._*", "Thumbs.db", "*.ini", "*.db", "thumb_*"],
      "quarantine": {
        "path": "quarantine/",
        "reasons": ["no_exif_date", "corrupt_file", "unreadable_file"]
      }
    }|}
  in
  let c = of_json_string json in
  Alcotest.(check library_config_testable) "full python json = default"
    default c

let () =
  Alcotest.run "config"
    [
      ( "defaults",
        [
          Alcotest.test_case "default values" `Quick test_default_values;
        ] );
      ( "serialization",
        [
          Alcotest.test_case "round-trip" `Quick test_round_trip;
          Alcotest.test_case "empty json" `Quick test_empty_json;
          Alcotest.test_case "partial json" `Quick
            test_partial_json_organization_only;
          Alcotest.test_case "full python json" `Quick test_full_python_json;
        ] );
      ( "extensions",
        [
          Alcotest.test_case "all_extensions" `Quick test_all_extensions;
        ] );
    ]

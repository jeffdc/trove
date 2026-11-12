let fresh_file () =
  Filename.temp_file "trove-legacy" ".sqlite3"

let test_open_and_read_current_schema () =
  let path = fresh_file () in
  let src = Legacy_db_impl.open_db path in
  let lib =
    Legacy_db_impl.create_library src ~name:"photos" ~location:"/mnt/photos"
      ~config_json:{|{"copy":"preserve"}|}
  in
  let _entry =
    Legacy_db_impl.create_entry src ~library_id:lib.id ~relative_path:"2024/01/a.jpg"
      ~file_size:1000 ~md5_hash:(Some "hash-a")
      ~capture_date:(Some "2024-01-01T00:00:00Z")
      ~camera_model:(Some "Canon")
      ~original_path:(Some "/src/a.jpg")
  in
  let _file =
    Legacy_db_impl.insert_file src ~source_path:"/src/a.jpg" ~source_type:"local"
      ~file_size:1000 ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  Legacy_db_impl.close src;
  match Legacy_db.open_readonly ~path with
  | Error err ->
    Sys.remove path;
    Alcotest.failf "open_readonly failed: %s" (Utils.string_of_app_error err)
  | Ok legacy ->
    let schema_version =
      match Legacy_db.schema_version legacy with
      | Ok version -> version
      | Error err ->
        Legacy_db.close legacy;
        Sys.remove path;
        Alcotest.failf "schema_version failed: %s"
          (Utils.string_of_app_error err)
    in
    let libraries =
      match Legacy_db.list_libraries legacy with
      | Ok rows -> rows
      | Error err ->
        Legacy_db.close legacy;
        Sys.remove path;
        Alcotest.failf "list_libraries failed: %s"
          (Utils.string_of_app_error err)
    in
    let entries =
      match Legacy_db.list_entries legacy with
      | Ok rows -> rows
      | Error err ->
        Legacy_db.close legacy;
        Sys.remove path;
        Alcotest.failf "list_entries failed: %s"
          (Utils.string_of_app_error err)
    in
    let files =
      match Legacy_db.list_files legacy with
      | Ok rows -> rows
      | Error err ->
        Legacy_db.close legacy;
        Sys.remove path;
        Alcotest.failf "list_files failed: %s"
          (Utils.string_of_app_error err)
    in
    Alcotest.(check int) "schema version" 2 schema_version;
    Alcotest.(check int) "one library" 1 (List.length libraries);
    Alcotest.(check int) "one entry" 1 (List.length entries);
    Alcotest.(check int) "one file row" 1 (List.length files);
    let file = List.hd files in
    Alcotest.(check string) "source_type preserved" "local" file.source_type;
    Legacy_db.close legacy;
    Sys.remove path

let () =
  Alcotest.run "legacy_db"
    [
      ( "read_only",
        [
          Alcotest.test_case "open and read current schema" `Quick
            test_open_and_read_current_schema;
        ] );
    ]

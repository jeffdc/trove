let fresh_source_file () =
  Filename.temp_file "trove-legacy-migrator" ".sqlite3"

let fresh_schema_file () =
  Filename.temp_file "trove-schema-migrator" ".sqlite3"

let fresh_report_file () =
  Filename.temp_file "trove-migration-report" ".json"

let cleanup path =
  if Sys.file_exists path then Sys.remove path

let test_migrator_end_to_end () =
  let source_path = fresh_source_file () in
  let schema_path = fresh_schema_file () in
  let report_path = fresh_report_file () in
  cleanup schema_path;
  cleanup report_path;
  let source = Legacy_db_impl.open_db source_path in
  let alpha =
    Legacy_db_impl.create_library source ~name:"alpha" ~location:"/mnt/alpha"
      ~config_json:"{}"
  in
  ignore
    (Legacy_db_impl.create_entry source ~library_id:alpha.id ~relative_path:"2024/01/a.jpg"
       ~file_size:1000 ~md5_hash:(Some "hash-a")
       ~capture_date:(Some "2024-01-01T00:00:00Z")
       ~camera_model:(Some "Canon")
       ~original_path:(Some "/imports/a.jpg"));
  let file =
    Legacy_db_impl.insert_file source ~source_path:"/imports/a.jpg" ~source_type:"local"
      ~file_size:1000 ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  Legacy_db_impl.update_file source file.id
    [
      ("status", Some "imported");
      ("md5_hash", Some "hash-a");
      ("target_path", Some "2024/01/a.jpg");
      ("hashed_at", Some "2024-01-01T00:00:05Z");
    ];
  Legacy_db_impl.close source;
  let options : Migrator.options =
    {
      source_db_path = source_path;
      schema_db_path = schema_path;
      report_path;
    }
  in
  (match Migrator.run options with
  | Ok () -> ()
  | Error err ->
    cleanup source_path;
    cleanup schema_path;
    cleanup report_path;
    Alcotest.failf "Migrator.run failed: %s" (Utils.string_of_app_error err));
  let schema_db = Db.open_db schema_path in
  let libraries =
    match Db.list_libraries schema_db with
    | Ok rows -> rows
    | Error err ->
      Db.close schema_db;
      cleanup source_path;
      cleanup schema_path;
      cleanup report_path;
      Alcotest.failf "list_libraries failed: %s"
        (Utils.string_of_app_error err)
  in
  let run_items =
    match Db.list_run_items schema_db with
    | Ok rows -> rows
    | Error err ->
      Db.close schema_db;
      cleanup source_path;
      cleanup schema_path;
      cleanup report_path;
      Alcotest.failf "list_run_items failed: %s"
        (Utils.string_of_app_error err)
  in
  Alcotest.(check int) "one library" 1 (List.length libraries);
  Alcotest.(check int) "one run item" 1 (List.length run_items);
  Alcotest.(check bool) "report exists" true (Sys.file_exists report_path);
  let report_json = Yojson.Safe.from_file report_path in
  let has_counts =
    match report_json with
    | `Assoc fields -> List.mem_assoc "counts" fields
    | _ -> false
  in
  Alcotest.(check bool) "report has counts" true has_counts;
  Db.close schema_db;
  cleanup source_path;
  cleanup schema_path;
  cleanup report_path

let () =
  Alcotest.run "migrator"
    [
      ( "migrator",
        [
          Alcotest.test_case "runs migration end-to-end" `Quick
            test_migrator_end_to_end;
        ] );
    ]

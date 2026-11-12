let fresh_source_file () =
  Filename.temp_file "trove-legacy-entries" ".sqlite3"

let fail_with_cleanup source_path legacy target fmt =
  Printf.ksprintf
    (fun msg ->
      Legacy_db.close legacy;
      Db.close target;
      Sys.remove source_path;
      Alcotest.fail msg)
    fmt

let test_migrate_entries () =
  let source_path = fresh_source_file () in
  let source = Legacy_db_impl.open_db source_path in
  let alpha =
    Legacy_db_impl.create_library source ~name:"alpha" ~location:"/mnt/alpha"
      ~config_json:"{}"
  in
  let beta =
    Legacy_db_impl.create_library source ~name:"beta" ~location:"/mnt/beta"
      ~config_json:"{}"
  in
  let _alpha_entry =
    Legacy_db_impl.create_entry source ~library_id:alpha.id ~relative_path:"2024/01/a.jpg"
      ~file_size:1000 ~md5_hash:(Some "shared-hash")
      ~capture_date:(Some "2024-01-01T00:00:00Z")
      ~camera_model:(Some "Canon")
      ~original_path:(Some "/imports/a.jpg")
  in
  let _beta_entry =
    Legacy_db_impl.create_entry source ~library_id:beta.id ~relative_path:"2024/02/b.jpg"
      ~file_size:1000 ~md5_hash:(Some "shared-hash")
      ~capture_date:(Some "2024-01-01T00:00:00Z")
      ~camera_model:(Some "Canon")
      ~original_path:(Some "/imports/b.jpg")
  in
  let _missing_hash =
    Legacy_db_impl.create_entry source ~library_id:alpha.id
      ~relative_path:"2024/03/nohash.jpg" ~file_size:999 ~md5_hash:None
      ~capture_date:None ~camera_model:None
      ~original_path:(Some "/imports/nohash.jpg")
  in
  Legacy_db_impl.close source;
  let legacy =
    match Legacy_db.open_readonly ~path:source_path with
    | Ok db -> db
    | Error err ->
      Sys.remove source_path;
      Alcotest.failf "open_readonly failed: %s"
        (Utils.string_of_app_error err)
  in
  let target = Db.open_db ":memory:" in
  let state = Migration_types.create_mapping_state () in
  let report =
    Migration_report.create ~source_db_path:source_path ~source_schema_version:2
  in
  let run_or_fail_db result label =
    match result with
    | Ok value -> value
    | Error err ->
      fail_with_cleanup source_path legacy target "%s: %s" label
        (Utils.string_of_app_error err)
  in
  run_or_fail_db
    (Migrate_libraries.run ~legacy ~target ~state ~report)
    "Migrate_libraries.run";
  run_or_fail_db
    (Migrate_entries.run ~legacy ~target ~state ~report)
    "Migrate_entries.run";
  let file_objects =
    run_or_fail_db (Db.list_file_objects target) "list_file_objects"
  in
  let library_items =
    run_or_fail_db (Db.list_library_items target) "list_library_items"
  in
  let placements =
    run_or_fail_db
      (Db.list_library_placements target)
      "list_library_placements"
  in
  Alcotest.(check int) "one shared file object" 1 (List.length file_objects);
  Alcotest.(check int) "two library items" 2 (List.length library_items);
  Alcotest.(check int) "two placements" 2 (List.length placements);
  Alcotest.(check int) "entries migrated count" 2
    (Migration_report.get_count report ~counter:"entries_migrated");
  Alcotest.(check int) "file objects created count" 1
    (Migration_report.get_count report ~counter:"file_objects_created");
  Alcotest.(check int) "legacy rows preserved count" 1
    (Migration_report.get_count report ~counter:"legacy_rows_preserved");
  Alcotest.(check int) "one anomaly" 1
    (List.length (Migration_report.anomalies report));
  let file_object = List.hd file_objects in
  Alcotest.(check string) "content hash" "shared-hash" file_object.content_hash;
  Alcotest.(check (option string)) "original filename from original path"
    (Some "a.jpg") file_object.original_filename;
  Legacy_db.close legacy;
  Db.close target;
  Sys.remove source_path

let () =
  Alcotest.run "migrate_entries"
    [
      ( "entries",
        [ Alcotest.test_case "creates membership and placements" `Quick test_migrate_entries ] );
    ]

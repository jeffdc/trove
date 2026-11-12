open Legacy_domain

let fresh_source_file () =
  Filename.temp_file "trove-legacy-files" ".sqlite3"

let update_legacy_file db file_id updates =
  Legacy_db_impl.update_file db file_id updates

let insert_legacy_file db ~source_path ~file_size ~file_modify_date ~status
    ?md5_hash ?capture_date ?camera_model ?target_path ?error_message
    ?hashed_at () =
  let file =
    Legacy_db_impl.insert_file db ~source_path ~source_type:"local" ~file_size
      ~file_modify_date
  in
  let updates =
    [
      ("status", Some status);
      ("md5_hash", md5_hash);
      ("capture_date", capture_date);
      ("camera_model", camera_model);
      ("target_path", target_path);
      ("error_message", error_message);
      ("hashed_at", hashed_at);
    ]
  in
  update_legacy_file db file.id updates;
  file.id

let fail_with_cleanup source_path legacy target fmt =
  Printf.ksprintf
    (fun msg ->
      Legacy_db.close legacy;
      Db.close target;
      Sys.remove source_path;
      Alcotest.fail msg)
    fmt

let test_migrate_files () =
  let source_path = fresh_source_file () in
  let source = Legacy_db_impl.open_db source_path in
  let alpha =
    Legacy_db_impl.create_library source ~name:"alpha" ~location:"/mnt/alpha"
      ~config_json:"{}"
  in
  let _entry =
    Legacy_db_impl.create_entry source ~library_id:alpha.id ~relative_path:"2024/01/imp.jpg"
      ~file_size:1000 ~md5_hash:(Some "imp-hash")
      ~capture_date:(Some "2024-01-01T00:00:00Z")
      ~camera_model:(Some "Canon")
      ~original_path:(Some "/imports/imp.jpg")
  in
  ignore
    (insert_legacy_file source ~source_path:"/imports/imp.jpg" ~file_size:1000
       ~file_modify_date:"2024-01-01T00:00:00Z" ~status:"imported"
       ~md5_hash:"imp-hash"
       ~capture_date:"2024-01-01T00:00:00Z"
       ~camera_model:"Canon"
       ~target_path:"2024/01/imp.jpg"
       ~hashed_at:"2024-01-01T00:00:05Z" ());
  ignore
    (insert_legacy_file source
       ~source_path:"/mnt/alpha/loose/new.jpg" ~file_size:2000
       ~file_modify_date:"2024-02-01T00:00:00Z" ~status:"hashed"
       ~md5_hash:"new-hash"
       ~capture_date:"2024-02-01T00:00:00Z"
       ~camera_model:"Nikon"
       ~target_path:"2024/02/new.jpg"
       ~hashed_at:"2024-02-01T00:00:05Z" ());
  ignore
    (insert_legacy_file source
       ~source_path:"/mnt/alpha/missing/old.jpg" ~file_size:3000
       ~file_modify_date:"2023-12-01T00:00:00Z" ~status:"missing"
       ~md5_hash:"old-hash"
       ~error_message:"not found on disk"
       ~hashed_at:"2023-12-01T00:00:05Z" ());
  ignore
    (insert_legacy_file source ~source_path:"/imports/orphan.jpg"
       ~file_size:4000 ~file_modify_date:"2024-03-01T00:00:00Z"
       ~status:"imported" ~md5_hash:"orphan-hash"
       ~target_path:"2024/03/orphan.jpg"
       ~hashed_at:"2024-03-01T00:00:05Z" ());
  ignore
    (insert_legacy_file source ~source_path:"/imports/dup.jpg"
       ~file_size:5000 ~file_modify_date:"2024-03-02T00:00:00Z"
       ~status:"duplicate" ~md5_hash:"dup-hash"
       ~hashed_at:"2024-03-02T00:00:05Z" ());
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
  run_or_fail_db
    (Migrate_files.run ~legacy ~target ~state ~report)
    "Migrate_files.run";
  let source_roots =
    run_or_fail_db (Db.list_source_roots target) "list_source_roots"
  in
  let runs = run_or_fail_db (Db.list_runs target) "list_runs" in
  let observations =
    run_or_fail_db
      (Db.list_source_observations target)
      "list_source_observations"
  in
  let run_items =
    run_or_fail_db (Db.list_run_items target) "list_run_items"
  in
  let file_objects =
    run_or_fail_db (Db.list_file_objects target) "list_file_objects"
  in
  Alcotest.(check int) "two source roots" 2 (List.length source_roots);
  Alcotest.(check int) "three runs" 3 (List.length runs);
  Alcotest.(check int) "three observations" 3 (List.length observations);
  Alcotest.(check int) "three run items" 3 (List.length run_items);
  Alcotest.(check int) "four file objects" 4 (List.length file_objects);
  Alcotest.(check int) "source observations count" 3
    (Migration_report.get_count report ~counter:"source_observations_created");
  Alcotest.(check int) "run items count" 3
    (Migration_report.get_count report ~counter:"run_items_created");
  Alcotest.(check int) "file objects created count" 4
    (Migration_report.get_count report ~counter:"file_objects_created");
  Alcotest.(check int) "legacy rows preserved count" 2
    (Migration_report.get_count report ~counter:"legacy_rows_preserved");
  Alcotest.(check int) "two anomalies" 2
    (List.length (Migration_report.anomalies report));
  let import_run_items =
    List.filter
      (fun (item : Domain.run_item) ->
        item.disposition = Some Domain.Disposition.Admitted)
      run_items
  in
  Alcotest.(check int) "one admitted run item" 1 (List.length import_run_items);
  let failed_run_items =
    List.filter
      (fun (item : Domain.run_item) ->
        item.workflow_state = Domain.Workflow_state.Failed)
      run_items
  in
  Alcotest.(check int) "one failed run item" 1 (List.length failed_run_items);
  Legacy_db.close legacy;
  Db.close target;
  Sys.remove source_path

let () =
  Alcotest.run "migrate_files"
    [
      ( "files",
        [ Alcotest.test_case "creates observations and run items" `Quick test_migrate_files ] );
    ]

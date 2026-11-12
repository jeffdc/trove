let fresh_source_file () =
  Filename.temp_file "trove-legacy-reconcile" ".sqlite3"

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

let test_reconcile_links_and_missing_state () =
  let source_path = fresh_source_file () in
  let source = Legacy_db_impl.open_db source_path in
  let alpha =
    Legacy_db_impl.create_library source ~name:"alpha" ~location:"/mnt/alpha"
      ~config_json:"{}"
  in
  ignore
    (Legacy_db_impl.create_entry source ~library_id:alpha.id
       ~relative_path:"2024/01/imported.jpg" ~file_size:1000
       ~md5_hash:(Some "imported-hash")
       ~capture_date:(Some "2024-01-01T00:00:00Z")
       ~camera_model:(Some "Canon")
       ~original_path:(Some "/imports/imported.jpg"));
  ignore
     (Legacy_db_impl.create_entry source ~library_id:alpha.id
       ~relative_path:"2024/02/missing.jpg" ~file_size:2000
       ~md5_hash:(Some "missing-hash")
       ~capture_date:(Some "2024-02-01T00:00:00Z")
       ~camera_model:(Some "Sony")
       ~original_path:(Some "/imports/missing.jpg"));
  ignore
    (insert_legacy_file source ~source_path:"/imports/imported.jpg"
       ~file_size:1000 ~file_modify_date:"2024-01-01T00:00:00Z"
       ~status:"imported" ~md5_hash:"imported-hash"
       ~target_path:"2024/01/imported.jpg"
       ~hashed_at:"2024-01-01T00:00:05Z" ());
  ignore
    (insert_legacy_file source
       ~source_path:"/mnt/alpha/2024/02/missing.jpg" ~file_size:2000
       ~file_modify_date:"2024-02-01T00:00:00Z" ~status:"missing"
       ~md5_hash:"missing-hash" ~error_message:"gone from disk"
       ~hashed_at:"2024-02-01T00:00:05Z" ());
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
  run_or_fail_db
    (Migrate_reconcile.run ~target ~state ~report)
    "Migrate_reconcile.run";
  let library_items =
    run_or_fail_db (Db.list_library_items target) "list_library_items"
  in
  let placements =
    run_or_fail_db
      (Db.list_library_placements target)
      "list_library_placements"
  in
  let imported_item =
    List.find
      (fun (item : Domain.library_item) ->
        item.status = Domain.Library_item_status.Active)
      library_items
  in
  let missing_item =
    List.find
      (fun (item : Domain.library_item) ->
        item.status = Domain.Library_item_status.Missing)
      library_items
  in
  Alcotest.(check bool) "imported item linked to admitted run"
    true (Option.is_some imported_item.admitted_from_run_item_id);
  let missing_placement =
    List.find
      (fun (placement : Domain.library_placement) ->
        placement.library_item_id = missing_item.id)
      placements
  in
  Alcotest.(check bool) "missing placement status"
    true
    (missing_placement.placement_status
     = Domain.Placement_status.Missing);
  Alcotest.(check int) "linked items counter" 1
    (Migration_report.get_count report ~counter:"library_items_linked_to_runs");
  Alcotest.(check int) "missing items counter" 1
    (Migration_report.get_count report ~counter:"library_items_marked_missing");
  Legacy_db.close legacy;
  Db.close target;
  Sys.remove source_path

let () =
  Alcotest.run "migrate_reconcile"
    [
      ( "reconcile",
        [
          Alcotest.test_case "links imported runs and marks missing state"
            `Quick test_reconcile_links_and_missing_state;
        ] );
    ]

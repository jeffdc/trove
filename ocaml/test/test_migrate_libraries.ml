let fresh_source_file () =
  Filename.temp_file "trove-legacy-source" ".sqlite3"

let test_migrate_libraries () =
  let source_path = fresh_source_file () in
  let source = Legacy_db_impl.open_db source_path in
  let _a =
    Legacy_db_impl.create_library source ~name:"alpha" ~location:"/mnt/alpha"
      ~config_json:"{}"
  in
  let _b =
    Legacy_db_impl.create_library source ~name:"beta" ~location:"/mnt/beta"
      ~config_json:{|{"layout":"yyyy/mm"}|}
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
  match Migrate_libraries.run ~legacy ~target ~state ~report with
  | Error err ->
    Legacy_db.close legacy;
    Db.close target;
    Sys.remove source_path;
    Alcotest.failf "migration failed: %s" (Utils.string_of_app_error err)
  | Ok () ->
    let libraries =
      match Db.list_libraries target with
      | Ok rows -> rows
      | Error err ->
        Legacy_db.close legacy;
        Db.close target;
        Sys.remove source_path;
        Alcotest.failf "target list_libraries failed: %s"
          (Utils.string_of_app_error err)
    in
    Alcotest.(check int) "two libraries migrated" 2 (List.length libraries);
    Alcotest.(check int) "mapping count" 2
      (Hashtbl.length state.Migration_types.library_ids_by_legacy_id);
    Alcotest.(check int) "report count" 2
      (Migration_report.get_count report ~counter:"libraries_migrated");
    Legacy_db.close legacy;
    Db.close target;
    Sys.remove source_path

let () =
  Alcotest.run "migrate_libraries"
    [
      ( "libraries",
        [ Alcotest.test_case "copies legacy libraries" `Quick test_migrate_libraries ] );
    ]

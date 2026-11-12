type options = {
  source_db_path : string;
  schema_db_path : string;
  report_path : string;
}

let run (options : options) =
  match Legacy_db.open_readonly ~path:options.source_db_path with
  | Error _ as error -> error
  | Ok legacy ->
    let db = Db.open_db options.schema_db_path in
    Fun.protect
      ~finally:(fun () ->
        Legacy_db.close legacy;
        Db.close db)
      (fun () ->
        match Legacy_db.schema_version legacy with
        | Error _ as error -> error
        | Ok schema_version ->
          let state = Migration_types.create_mapping_state () in
          let report =
            Migration_report.create ~source_db_path:options.source_db_path
              ~source_schema_version:schema_version
          in
          match Migrate_libraries.run ~legacy ~target:db ~state ~report with
          | Error _ as error -> error
          | Ok () -> (
              match Migrate_entries.run ~legacy ~target:db ~state ~report with
              | Error _ as error -> error
              | Ok () -> (
                  match Migrate_files.run ~legacy ~target:db ~state ~report with
                  | Error _ as error -> error
                  | Ok () -> (
                      match Migrate_reconcile.run ~target:db ~state ~report with
                      | Error _ as error -> error
                      | Ok () ->
                        Migration_report.write_json report
                          ~path:options.report_path))))

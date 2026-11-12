let test_counts_and_anomalies () =
  let report =
    Migration_report.create ~source_db_path:"/tmp/source.sqlite3"
      ~source_schema_version:2
  in
  Migration_report.incr report ~counter:"libraries_migrated";
  Migration_report.add_count report ~counter:"libraries_migrated" 2;
  Migration_report.add_warning report "copied fixture";
  Migration_report.add_anomaly report
    {
      Migration_types.kind = Entry_without_md5;
      legacy_table = "entries";
      legacy_id = Some 42;
      detail = "missing md5 hash";
    };
  Alcotest.(check int) "count value" 3
    (Migration_report.get_count report ~counter:"libraries_migrated");
  Alcotest.(check int) "warning count" 1
    (List.length (Migration_report.warnings report));
  Alcotest.(check int) "anomaly count" 1
    (List.length (Migration_report.anomalies report));
  match Migration_report.to_yojson report with
  | `Assoc fields ->
    Alcotest.(check bool) "has counts"
      true (List.mem_assoc "counts" fields);
    Alcotest.(check bool) "has anomalies"
      true (List.mem_assoc "anomalies" fields)
  | _ -> Alcotest.fail "report json should be an object"

let () =
  Alcotest.run "migration_report"
    [
      ( "report",
        [ Alcotest.test_case "counts and anomalies" `Quick test_counts_and_anomalies ] );
    ]

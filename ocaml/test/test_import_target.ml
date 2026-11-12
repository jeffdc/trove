let fresh_target_file () =
  Filename.temp_file "trove-target-import" ".sqlite3"

let cleanup path =
  if Sys.file_exists path then Sys.remove path

let worker_path () =
  match Sys.getenv_opt "GROVE_WORKER_PATH" with
  | Some p when Sys.file_exists p -> p
  | Some p ->
    Alcotest.failf
      "GROVE_WORKER_PATH is set but does not point to an existing file: %s" p
  | None ->
    Alcotest.fail
      "GROVE_WORKER_PATH must point to a built worker binary for OCaml tests"

let run_or_fail_db result context =
  match result with
  | Ok value -> value
  | Error err ->
    Alcotest.failf "%s failed: %s" context (Utils.string_of_app_error err)

let run_or_fail_app result context =
  match result with
  | Ok value -> value
  | Error err ->
    Alcotest.failf "%s failed: %s" context (Utils.string_of_app_error err)

let with_target_db f =
  let path = fresh_target_file () in
  cleanup path;
  let db = Db.open_db path in
  Fun.protect
    ~finally:(fun () ->
      Db.close db;
      cleanup path)
    (fun () -> f db)

let with_worker f =
  let worker =
    match Worker_client.start ~worker_path:(worker_path ()) () with
    | Ok worker -> worker
    | Error err ->
      Alcotest.failf "Worker_client.start failed: %s"
        (Utils.string_of_worker_error err)
  in
  Fun.protect ~finally:(fun () -> Worker_client.stop worker) (fun () -> f worker)

let with_tmp_dir f =
  let dir = Filename.temp_dir "trove_target_import_" "" in
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let rec mkdir_p path =
  if path <> "/" && path <> "." && not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let read_file path =
  let ic = open_in path in
  let len = in_channel_length ic in
  let contents = really_input_string ic len in
  close_in ic;
  contents

let timestamp_utc ~year ~month ~day ~hour ~minute ~second =
  let tm =
    {
      Unix.tm_sec = second;
      tm_min = minute;
      tm_hour = hour;
      tm_mday = day;
      tm_mon = month - 1;
      tm_year = year - 1900;
      tm_wday = 0;
      tm_yday = 0;
      tm_isdst = false;
    }
  in
  fst (Unix.mktime tm)

let set_mtime path timestamp =
  Unix.utimes path timestamp timestamp

let test_target_import_end_to_end () =
  with_tmp_dir (fun source_dir ->
    with_tmp_dir (fun library_root ->
      with_target_db (fun db ->
        with_worker (fun worker ->
          let config =
            {
              Config.default with
              organization =
                {
                  Config.default.organization with
                  include_camera_model = false;
                };
            }
          in
          ignore
            (run_or_fail_db
               (Db.create_library db ~name:"alpha" ~root_path:library_root
                  ~config_json:(Config.to_json_string config))
               "create_library");
          let source_a = Filename.concat source_dir "a.jpg" in
          let source_dup = Filename.concat source_dir "dup.jpg" in
          write_file source_a "same-bytes";
          write_file source_dup "same-bytes";
          let fixed_time =
            timestamp_utc ~year:2024 ~month:1 ~day:15 ~hour:12 ~minute:0
              ~second:0
          in
          set_mtime source_a fixed_time;
          set_mtime source_dup fixed_time;
          let occupied_target =
            Filename.concat library_root "2024/01/a.jpg"
          in
          write_file occupied_target "already-here";
          let summary =
            run_or_fail_app
              (Import.import_into_library_by_name db worker ~name:"alpha"
                 ~source:source_dir)
              "target_import"
          in
          Alcotest.(check int) "observed" 2 summary.observed;
          Alcotest.(check int) "admitted" 1 summary.admitted;
          Alcotest.(check int) "duplicate_in_library" 1
            summary.duplicate_in_library;
          Alcotest.(check int) "quarantined" 0 summary.quarantined;
          Alcotest.(check int) "failed" 0 summary.failed;
          Alcotest.(check int) "path_conflicts" 1 summary.path_conflicts;
          let runs = run_or_fail_db (Db.list_runs db) "list_runs" in
          let run_items =
            run_or_fail_db (Db.list_run_items db) "list_run_items"
          in
          let file_objects =
            run_or_fail_db (Db.list_file_objects db) "list_file_objects"
          in
          let library_items =
            run_or_fail_db (Db.list_library_items db) "list_library_items"
          in
          let placements =
            run_or_fail_db
              (Db.list_library_placements db)
              "list_library_placements"
          in
          let file_ops = run_or_fail_db (Db.list_file_ops db) "list_file_ops" in
          Alcotest.(check int) "one run" 1 (List.length runs);
          Alcotest.(check int) "two run items" 2 (List.length run_items);
          Alcotest.(check int) "one file object reused" 1
            (List.length file_objects);
          Alcotest.(check int) "one library item" 1 (List.length library_items);
          Alcotest.(check int) "one placement" 1 (List.length placements);
          Alcotest.(check int) "one file op" 1 (List.length file_ops);
          Alcotest.(check string) "run completed" "completed"
            (Domain.Run_status.to_string (List.hd runs).status);
          Alcotest.(check string) "placement path resolved with suffix"
            "2024/01/a-1.jpg" (List.hd placements).intended_relative_path;
          Alcotest.(check string) "occupied file preserved" "already-here"
            (read_file occupied_target);
          Alcotest.(check string) "imported file copied to suffixed path"
            "same-bytes"
            (read_file (Filename.concat library_root "2024/01/a-1.jpg"))))))

let () =
  Alcotest.run "target_import"
    [
      ( "target_import",
        [
          Alcotest.test_case "imports into target schema safely" `Quick
            test_target_import_end_to_end;
        ] );
    ]

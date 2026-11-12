let fresh_target_file () =
  Filename.temp_file "trove-target-init" ".sqlite3"

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
  let dir = Filename.temp_dir "trove_target_init_" "" in
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

let md5 text = Digest.to_hex (Digest.string text)

let test_target_init_end_to_end () =
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
        let library =
          run_or_fail_db
            (Db.create_library db ~name:"alpha" ~root_path:library_root
               ~config_json:(Config.to_json_string config))
            "create_library"
        in
        let jan_time =
          timestamp_utc ~year:2024 ~month:1 ~day:20 ~hour:12 ~minute:0
            ~second:0
        in
        let old_time =
          timestamp_utc ~year:1980 ~month:1 ~day:1 ~hour:12 ~minute:0
            ~second:0
        in

        let managed_path = Filename.concat library_root "2024/01/managed.jpg" in
        write_file managed_path "managed";
        set_mtime managed_path jan_time;
        let managed_file_object =
          run_or_fail_db
            (Db.create_file_object db ~content_hash:(md5 "managed")
               ~hash_algorithm:Domain.Hash_algorithm.Md5
               ~size_bytes:(String.length "managed")
               ~capture_date:"2024-01-20T12:00:00Z"
               ~original_filename:"managed.jpg" ~extension:"jpg" ())
            "create_managed_file_object"
        in
        let managed_item =
          run_or_fail_db
            (Db.create_library_item db ~library_id:library.id
               ~file_object_id:managed_file_object.id
               ~status:Domain.Library_item_status.Active ())
            "create_managed_item"
        in
        ignore
          (run_or_fail_db
             (Db.create_library_placement db
                ~library_item_id:managed_item.id ~library_id:library.id
                ~intended_relative_path:"2024/01/managed.jpg"
                ~actual_relative_path:"2024/01/managed.jpg"
                ~placement_status:Domain.Placement_status.Healthy ())
             "create_managed_placement");

        let indexed_path = Filename.concat library_root "2024/01/index.jpg" in
        write_file indexed_path "index";
        set_mtime indexed_path jan_time;

        let move_src = Filename.concat library_root "incoming/move.jpg" in
        write_file move_src "move";
        set_mtime move_src jan_time;
        mkdir_p (Filename.concat library_root "2024/01/move.jpg");

        let bad_path = Filename.concat library_root "incoming/unknown.jpg" in
        write_file bad_path "bad";
        set_mtime bad_path old_time;

        let summary =
          run_or_fail_app
            (Init.initialize_library_by_name db worker ~name:"alpha")
            "target_init"
        in
        Alcotest.(check int) "observed" 4 summary.observed;
        Alcotest.(check int) "skipped managed" 1 summary.skipped_managed;
        Alcotest.(check int) "indexed existing" 1 summary.indexed_existing;
        Alcotest.(check int) "moved" 1 summary.moved;
        Alcotest.(check int) "duplicate_in_library" 0
          summary.duplicate_in_library;
        Alcotest.(check int) "quarantined" 1 summary.quarantined;
        Alcotest.(check int) "failed" 0 summary.failed;
        Alcotest.(check int) "path conflicts" 1 summary.path_conflicts;

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
        Alcotest.(check int) "four run items" 4 (List.length run_items);
        Alcotest.(check int) "four file objects total" 4 (List.length file_objects);
        Alcotest.(check int) "three library items total" 3 (List.length library_items);
        Alcotest.(check int) "three placements total" 3 (List.length placements);
        Alcotest.(check int) "two file ops total" 2 (List.length file_ops);
        Alcotest.(check string) "run completed" "completed"
          (Domain.Run_status.to_string (List.hd runs).status);

        let intended_paths =
          List.map (fun (p : Domain.library_placement) -> p.intended_relative_path) placements
          |> List.sort String.compare
        in
        Alcotest.(check (list string)) "placements"
          [ "2024/01/index.jpg"; "2024/01/managed.jpg"; "2024/01/move-1.jpg" ]
          intended_paths;

        Alcotest.(check string) "indexed file preserved" "index"
          (read_file indexed_path);
        Alcotest.(check string) "moved file relocated" "move"
          (read_file (Filename.concat library_root "2024/01/move-1.jpg"));
        Alcotest.(check bool) "move source removed" false
          (Sys.file_exists move_src);
        Alcotest.(check string) "quarantined file moved" "bad"
          (read_file (Filename.concat library_root "quarantine/unknown.jpg"));
        Alcotest.(check bool) "quarantine source removed" false
          (Sys.file_exists bad_path))))

let () =
  Alcotest.run "target_init"
    [
      ( "target_init",
        [
          Alcotest.test_case "initializes target schema safely" `Quick
            test_target_init_end_to_end;
        ] );
    ]

let fresh_target_file () =
  Filename.temp_file "trove-target-runtime" ".sqlite3"

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
  let dir = Filename.temp_dir "trove_target_runtime_" "" in
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

let test_list_libraries () =
  with_target_db (fun db ->
    ignore
      (run_or_fail_db
         (Db.create_library db ~name:"alpha" ~root_path:"/mnt/alpha"
            ~config_json:"{}")
         "create_library alpha");
    ignore
      (run_or_fail_db
         (Db.create_library db ~name:"beta" ~root_path:"/mnt/beta"
            ~config_json:"{}")
         "create_library beta");
    let libs = run_or_fail_app (Runtime.list_libraries db) "target list" in
    Alcotest.(check int) "two libraries" 2 (List.length libs);
    Alcotest.(check string) "sorted first name" "alpha" (List.hd libs).name)

let test_get_library_status_by_name () =
  with_target_db (fun db ->
    let library =
      run_or_fail_db
         (Db.create_library db ~name:"alpha" ~root_path:"/mnt/alpha"
           ~config_json:"{}")
        "create_library"
    in
    let file_object_a =
      run_or_fail_db
        (Db.create_file_object db ~content_hash:"hash-a"
           ~hash_algorithm:Domain.Hash_algorithm.Md5 ~size_bytes:1000
           ())
        "create_file_object_a"
    in
    let file_object_b =
      run_or_fail_db
        (Db.create_file_object db ~content_hash:"hash-b"
           ~hash_algorithm:Domain.Hash_algorithm.Md5 ~size_bytes:2000
           ())
        "create_file_object_b"
    in
    let file_object_c =
      run_or_fail_db
        (Db.create_file_object db ~content_hash:"hash-c"
           ~hash_algorithm:Domain.Hash_algorithm.Md5 ~size_bytes:3000
           ())
        "create_file_object_c"
    in
    let active_item =
      run_or_fail_db
        (Db.create_library_item db ~library_id:library.id
           ~file_object_id:file_object_a.id
           ~status:Domain.Library_item_status.Active ())
        "create_active_item"
    in
    let missing_item =
      run_or_fail_db
        (Db.create_library_item db ~library_id:library.id
           ~file_object_id:file_object_b.id
           ~status:Domain.Library_item_status.Missing ())
        "create_missing_item"
    in
    ignore
      (run_or_fail_db
         (Db.create_library_item db ~library_id:library.id
            ~file_object_id:file_object_c.id
            ~status:Domain.Library_item_status.Broken ())
         "create_broken_item");
    ignore
      (run_or_fail_db
         (Db.create_library_placement db
            ~library_item_id:active_item.id ~library_id:library.id
            ~intended_relative_path:"2024/01/a.jpg"
            ~actual_relative_path:"2024/01/a.jpg"
            ~placement_status:Domain.Placement_status.Healthy ())
         "create_healthy_placement");
    ignore
      (run_or_fail_db
         (Db.create_library_placement db
            ~library_item_id:missing_item.id ~library_id:library.id
            ~intended_relative_path:"2024/01/b.jpg"
            ~placement_status:Domain.Placement_status.Missing ())
         "create_missing_placement");
    let status =
      run_or_fail_app
        (Runtime.get_library_status_by_name db "alpha")
        "get_library_status_by_name"
    in
    Alcotest.(check int) "total items" 3 status.total_library_items;
    Alcotest.(check int) "total placements" 2 status.total_placements;
    Alcotest.(check int) "items without placement" 1
      status.items_without_placement;
    Alcotest.(check int) "active items" 1 status.library_item_counts.active;
    Alcotest.(check int) "missing items" 1 status.library_item_counts.missing;
    Alcotest.(check int) "broken items" 1 status.library_item_counts.broken;
    Alcotest.(check int) "retired items" 0 status.library_item_counts.retired;
    Alcotest.(check int) "healthy placements" 1
      status.placement_counts.healthy;
    Alcotest.(check int) "missing placements" 1
      status.placement_counts.missing;
    Alcotest.(check int) "misplaced placements" 0
      status.placement_counts.misplaced;
    Alcotest.(check int) "repair-needed placements" 0
      status.placement_counts.repair_needed)

let test_get_library_status_missing_library () =
  with_target_db (fun db ->
    match Runtime.get_library_status_by_name db "does-not-exist" with
    | Ok _ -> Alcotest.fail "expected missing library error"
    | Error err ->
      Alcotest.(check string) "error code" "library_not_found"
        (Utils.string_of_error_code err.code))

let test_verify_library_by_name () =
  with_tmp_dir (fun root_path ->
    with_target_db (fun db ->
      with_worker (fun worker ->
        let library =
          run_or_fail_db
            (Db.create_library db ~name:"alpha" ~root_path
               ~config_json:"{}")
            "create_library"
        in
        let create_item content_hash status =
          let file_object =
            run_or_fail_db
              (Db.create_file_object db ~content_hash
                 ~hash_algorithm:Domain.Hash_algorithm.Md5
                 ~size_bytes:1000 ())
              ("create_file_object " ^ content_hash)
          in
          run_or_fail_db
            (Db.create_library_item db ~library_id:library.id
               ~file_object_id:file_object.id ~status ())
            ("create_library_item " ^ content_hash)
        in
        let healthy_item =
          create_item "hash-healthy" Domain.Library_item_status.Active
        in
        let missing_item =
          create_item "hash-missing" Domain.Library_item_status.Missing
        in
        let misplaced_item =
          create_item "hash-misplaced" Domain.Library_item_status.Active
        in
        let repair_item =
          create_item "hash-repair" Domain.Library_item_status.Active
        in
        write_file (Filename.concat root_path "2024/01/healthy.jpg") "healthy";
        write_file (Filename.concat root_path "elsewhere/moved.jpg") "misplaced";
        write_file (Filename.concat root_path "2024/01/conflict.jpg") "repair-a";
        write_file
          (Filename.concat root_path "elsewhere/conflict.jpg")
          "repair-b";
        ignore
          (run_or_fail_db
             (Db.create_library_placement db
                ~library_item_id:healthy_item.id ~library_id:library.id
                ~intended_relative_path:"2024/01/healthy.jpg"
                ~actual_relative_path:"2024/01/healthy.jpg"
                ~placement_status:Domain.Placement_status.Healthy ())
             "create_healthy_placement");
        ignore
          (run_or_fail_db
             (Db.create_library_placement db
                ~library_item_id:missing_item.id ~library_id:library.id
                ~intended_relative_path:"2024/01/missing.jpg"
                ~placement_status:Domain.Placement_status.Missing ())
             "create_missing_placement");
        ignore
          (run_or_fail_db
             (Db.create_library_placement db
                ~library_item_id:misplaced_item.id ~library_id:library.id
                ~intended_relative_path:"2024/01/moved.jpg"
                ~actual_relative_path:"elsewhere/moved.jpg"
                ~placement_status:Domain.Placement_status.Healthy ())
             "create_misplaced_placement");
        ignore
          (run_or_fail_db
             (Db.create_library_placement db
                ~library_item_id:repair_item.id ~library_id:library.id
                ~intended_relative_path:"2024/01/conflict.jpg"
                ~actual_relative_path:"elsewhere/conflict.jpg"
                ~placement_status:Domain.Placement_status.Repair_needed
                ())
             "create_repair_placement");
        let report =
              run_or_fail_app
                (Runtime.verify_library_by_name db worker "alpha")
                "verify_library_by_name"
        in
        Alcotest.(check int) "checked placements" 4 report.checked_placements;
        Alcotest.(check int) "observed healthy placements" 1
          report.observed_placement_counts.healthy;
        Alcotest.(check int) "observed missing placements" 1
          report.observed_placement_counts.missing;
        Alcotest.(check int) "observed misplaced placements" 1
          report.observed_placement_counts.misplaced;
        Alcotest.(check int) "observed repair-needed placements" 1
          report.observed_placement_counts.repair_needed;
        Alcotest.(check int) "placement status mismatches" 1
          report.placement_status_mismatches;
        Alcotest.(check int) "issues count" 3 (List.length report.issues))))

let () =
  Alcotest.run "target_runtime"
    [
      ( "target_runtime",
        [
          Alcotest.test_case "list_libraries" `Quick test_list_libraries;
          Alcotest.test_case "get_library_status_by_name" `Quick
            test_get_library_status_by_name;
          Alcotest.test_case "missing library" `Quick
            test_get_library_status_missing_library;
          Alcotest.test_case "verify_library_by_name" `Quick
            test_verify_library_by_name;
        ] );
    ]

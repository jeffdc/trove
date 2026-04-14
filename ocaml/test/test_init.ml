(* Tests for the Init module — classify_for_init, execute_init, relative_path.
   Following TDD: these tests are written before the implementation. *)

(* Helper: make a file_record with sensible defaults *)
let make_file_record ?(id = 1) ?(source_path = "/lib/photos/test.jpg")
    ?(file_size = 1000) ?(file_modify_date = "2024-01-15T10:00:00Z")
    ?(md5_hash = Some "abc123") ?(capture_date = Some "2024-01-15T10:30:00")
    ?(camera_model = Some "Canon") ?(target_path = Some "2024/01/Canon/test.jpg")
    ?(status = Domain.Hashed) ?(error_message = None)
    ?(discovered_at = "2024-01-15T10:00:00Z") ?(hashed_at = Some "2024-01-15T10:01:00Z")
    () : Domain.file_record =
  {
    id;
    source_path;
    file_size;
    file_modify_date;
    md5_hash;
    capture_date;
    camera_model;
    target_path;
    status;
    error_message;
    discovered_at;
    hashed_at;
  }

(* Helper: insert a file into DB and set it up as hashed with target_path *)
let insert_hashed_file db ~source_path ~target_path ~md5_hash
    ?(capture_date = "2024-01-15T10:30:00") ?(camera_model = "Canon")
    ?(file_size = 1000) () =
  let r =
    Db.insert_file db ~source_path ~source_type:"local" ~file_size
      ~file_modify_date:"2024-01-15T10:00:00Z"
  in
  let updates =
    [
      ("status", Some "hashed");
      ("md5_hash", Some md5_hash);
      ("capture_date", Some capture_date);
      ("camera_model", Some camera_model);
    ]
    @
    (match target_path with
     | Some tp -> [ ("target_path", Some tp) ]
     | None -> [])
  in
  Db.update_file db r.id updates;
  r.id

(* Helper: insert a quarantined file into DB *)
let insert_quarantined_file db ~source_path ?(file_size = 500) () =
  let r =
    Db.insert_file db ~source_path ~source_type:"local" ~file_size
      ~file_modify_date:"2024-01-15T10:00:00Z"
  in
  Db.update_file db r.id
    [
      ("status", Some "quarantined");
      ("error_message", Some "no_date");
    ];
  r.id

(* Helper: create library for testing *)
let create_test_library db ?(name = "photos") ?(location = "/lib/photos") () =
  Db.create_library db ~name ~location
    ~config_json:(Config.to_json_string Config.default)

(* Locate worker binary — same approach as test_worker_client.ml *)
let worker_path () =
  let env_path =
    Sys.getenv_opt "GROVE_WORKER_PATH" |> Option.value ~default:""
  in
  let candidates =
    List.filter (fun s -> s <> "")
      [ env_path; "../worker/worker";
        "/path/to/trove/.worktrees/go-ocaml-rewrite/worker/worker" ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some p -> p
  | None -> failwith "Cannot find worker binary"

(* Custom Alcotest testable for init_result *)
let init_result_testable =
  Alcotest.testable
    (fun fmt (r : Init.init_result) ->
      Format.fprintf fmt
        "{indexed=%d; moved=%d; quarantined_count=%d; errors=%d}"
        r.indexed r.moved r.quarantined_count r.errors)
    (fun (a : Init.init_result) (b : Init.init_result) ->
      a.indexed = b.indexed && a.moved = b.moved
      && a.quarantined_count = b.quarantined_count
      && a.errors = b.errors)

let () =
  Alcotest.run "init"
    [
      (* ---- relative_path helper ---- *)
      ( "relative_path",
        [
          Alcotest.test_case "strips prefix correctly" `Quick (fun () ->
              let result =
                Init.relative_path ~lib_location:"/lib/photos"
                  "/lib/photos/2024/photo.jpg"
              in
              Alcotest.(check string) "stripped" "2024/photo.jpg" result);
          Alcotest.test_case "returns original if no match" `Quick (fun () ->
              let result =
                Init.relative_path ~lib_location:"/other/path"
                  "/lib/photos/2024/photo.jpg"
              in
              Alcotest.(check string)
                "unchanged" "/lib/photos/2024/photo.jpg" result);
          Alcotest.test_case "exact match returns empty" `Quick (fun () ->
              let result =
                Init.relative_path ~lib_location:"/lib/photos" "/lib/photos"
              in
              Alcotest.(check string) "no match returns original" "/lib/photos"
                result);
        ] );
      (* ---- classify_for_init: planning ---- *)
      ( "classify_for_init",
        [
          Alcotest.test_case "empty IDs returns empty plan" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let _lib = create_test_library db () in
              let plan =
                Init.classify_for_init db ~library_id:1 ~hashed_ids:[]
                  ~quarantined_ids:[] Config.default
              in
              Alcotest.(check int) "no already_correct" 0
                (List.length plan.already_correct);
              Alcotest.(check int) "no needs_move" 0
                (List.length plan.needs_move);
              Alcotest.(check int) "no duplicates" 0
                (List.length plan.duplicates);
              Alcotest.(check int) "no quarantined" 0
                (List.length plan.quarantined);
              Db.close db);
          Alcotest.test_case "file at correct path -> already_correct" `Quick
            (fun () ->
              let db = Db.open_db ":memory:" in
              let _lib = create_test_library db () in
              (* File whose relative path matches its target *)
              let file_id =
                insert_hashed_file db
                  ~source_path:"/lib/photos/2024/01/Canon/test.jpg"
                  ~target_path:(Some "2024/01/Canon/test.jpg")
                  ~md5_hash:"abc123" ()
              in
              let plan =
                Init.classify_for_init db ~library_id:1
                  ~hashed_ids:[ file_id ] ~quarantined_ids:[] Config.default
              in
              Alcotest.(check int) "one already_correct" 1
                (List.length plan.already_correct);
              Alcotest.(check int) "no needs_move" 0
                (List.length plan.needs_move);
              Db.close db);
          Alcotest.test_case "file needing move -> needs_move with target"
            `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let _lib = create_test_library db () in
              (* File at wrong location *)
              let file_id =
                insert_hashed_file db
                  ~source_path:"/lib/photos/unsorted/test.jpg"
                  ~target_path:(Some "2024/01/Canon/test.jpg")
                  ~md5_hash:"abc123" ()
              in
              let plan =
                Init.classify_for_init db ~library_id:1
                  ~hashed_ids:[ file_id ] ~quarantined_ids:[] Config.default
              in
              Alcotest.(check int) "no already_correct" 0
                (List.length plan.already_correct);
              Alcotest.(check int) "one needs_move" 1
                (List.length plan.needs_move);
              let _fr, target = List.hd plan.needs_move in
              Alcotest.(check string)
                "target path" "2024/01/Canon/test.jpg" target;
              Db.close db);
          Alcotest.test_case "quarantined file -> quarantined list" `Quick
            (fun () ->
              let db = Db.open_db ":memory:" in
              let _lib = create_test_library db () in
              let qid =
                insert_quarantined_file db
                  ~source_path:"/lib/photos/bad file.jpg" ()
              in
              let plan =
                Init.classify_for_init db ~library_id:1 ~hashed_ids:[]
                  ~quarantined_ids:[ qid ] Config.default
              in
              Alcotest.(check int) "one quarantined" 1
                (List.length plan.quarantined);
              Db.close db);
          Alcotest.test_case "path conflict resolved with suffix" `Quick
            (fun () ->
              let db = Db.open_db ":memory:" in
              let lib = create_test_library db () in
              (* Create an existing entry that claims the target path *)
              let _entry =
                Db.create_entry db ~library_id:lib.id
                  ~relative_path:"2024/01/Canon/test.jpg" ~file_size:999
                  ~md5_hash:(Some "other") ~capture_date:None ~camera_model:None
                  ~original_path:None
              in
              (* File that wants the same target *)
              let file_id =
                insert_hashed_file db
                  ~source_path:"/lib/photos/unsorted/test.jpg"
                  ~target_path:(Some "2024/01/Canon/test.jpg")
                  ~md5_hash:"abc123" ()
              in
              let plan =
                Init.classify_for_init db ~library_id:1
                  ~hashed_ids:[ file_id ] ~quarantined_ids:[] Config.default
              in
              Alcotest.(check int) "one needs_move" 1
                (List.length plan.needs_move);
              let _fr, target = List.hd plan.needs_move in
              Alcotest.(check string)
                "suffixed target" "2024/01/Canon/test-1.jpg" target;
              Db.close db);
          Alcotest.test_case "file with no target_path skipped" `Quick
            (fun () ->
              let db = Db.open_db ":memory:" in
              let _lib = create_test_library db () in
              let file_id =
                insert_hashed_file db
                  ~source_path:"/lib/photos/2024/01/Canon/test.jpg"
                  ~target_path:None ~md5_hash:"abc123" ()
              in
              let plan =
                Init.classify_for_init db ~library_id:1
                  ~hashed_ids:[ file_id ] ~quarantined_ids:[] Config.default
              in
              Alcotest.(check int) "no already_correct" 0
                (List.length plan.already_correct);
              Alcotest.(check int) "no needs_move" 0
                (List.length plan.needs_move);
              Db.close db);
          Alcotest.test_case "file with no md5_hash skipped" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let _lib = create_test_library db () in
              (* Insert file with no hash *)
              let r =
                Db.insert_file db
                  ~source_path:"/lib/photos/2024/01/Canon/test.jpg"
                  ~source_type:"local" ~file_size:1000
                  ~file_modify_date:"2024-01-15T10:00:00Z"
              in
              Db.update_file db r.id
                [
                  ("status", Some "hashed");
                  ("target_path", Some "2024/01/Canon/test.jpg");
                  ("capture_date", Some "2024-01-15T10:30:00");
                ];
              let plan =
                Init.classify_for_init db ~library_id:1
                  ~hashed_ids:[ r.id ] ~quarantined_ids:[] Config.default
              in
              Alcotest.(check int) "no already_correct" 0
                (List.length plan.already_correct);
              Alcotest.(check int) "no needs_move" 0
                (List.length plan.needs_move);
              Db.close db);
          Alcotest.test_case "mixed: correct, needs-move, and quarantined"
            `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let _lib = create_test_library db () in
              (* File at correct path *)
              let correct_id =
                insert_hashed_file db
                  ~source_path:"/lib/photos/2024/01/Canon/correct.jpg"
                  ~target_path:(Some "2024/01/Canon/correct.jpg")
                  ~md5_hash:"hash1" ()
              in
              (* File needing move *)
              let move_id =
                insert_hashed_file db
                  ~source_path:"/lib/photos/unsorted/move_me.jpg"
                  ~target_path:(Some "2024/02/Nikon/move_me.jpg")
                  ~md5_hash:"hash2" ()
              in
              (* Quarantined file *)
              let q_id =
                insert_quarantined_file db ~source_path:"/lib/photos/broken.jpg"
                  ()
              in
              let plan =
                Init.classify_for_init db ~library_id:1
                  ~hashed_ids:[ correct_id; move_id ]
                  ~quarantined_ids:[ q_id ] Config.default
              in
              Alcotest.(check int) "one already_correct" 1
                (List.length plan.already_correct);
              Alcotest.(check int) "one needs_move" 1
                (List.length plan.needs_move);
              Alcotest.(check int) "one quarantined" 1
                (List.length plan.quarantined);
              Db.close db);
        ] );
      (* ---- execute_init: execution with real worker ---- *)
      ( "execute_init",
        [
          Alcotest.test_case "indexes correct file" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let lib = create_test_library db () in
              let worker =
                Worker_client.start ~worker_path:(worker_path ())
              in
              (* Create a hashed file that's already at the right place *)
              let file_id =
                insert_hashed_file db
                  ~source_path:"/lib/photos/2024/01/Canon/indexed.jpg"
                  ~target_path:(Some "2024/01/Canon/indexed.jpg")
                  ~md5_hash:"hash_a" ()
              in
              let records = Db.query_files_by_ids db [ file_id ] in
              let plan : Domain.init_plan =
                {
                  already_correct = records;
                  needs_move = [];
                  duplicates = [];
                  quarantined = [];
                }
              in
              let result = Init.execute_init db worker lib plan in
              Alcotest.(check int) "indexed 1" 1 result.indexed;
              Alcotest.(check int) "moved 0" 0 result.moved;
              Alcotest.(check int) "errors 0" 0 result.errors;
              (* Verify entry was created *)
              let entry =
                Db.get_entry_by_path db ~library_id:lib.id
                  ~relative_path:"2024/01/Canon/indexed.jpg"
              in
              Alcotest.(check bool) "entry exists" true (Option.is_some entry);
              (* Verify file record was deleted *)
              let remaining = Db.query_files_by_ids db [ file_id ] in
              Alcotest.(check int) "file record deleted" 0
                (List.length remaining);
              Worker_client.stop worker;
              Db.close db);
          Alcotest.test_case "moves file to new location" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let tmp_dir = Filename.temp_dir "init_test" "" in
              let lib =
                Db.create_library db ~name:"photos" ~location:tmp_dir
                  ~config_json:(Config.to_json_string Config.default)
              in
              let worker =
                Worker_client.start ~worker_path:(worker_path ())
              in
              (* Create source file on disk *)
              let src_dir = tmp_dir ^ "/unsorted" in
              let _ = Worker_client.mkdir_all worker src_dir in
              let src_path = src_dir ^ "/moveme.jpg" in
              let oc = open_out src_path in
              output_string oc "fake image data";
              close_out oc;
              (* Insert file record *)
              let file_id =
                insert_hashed_file db ~source_path:src_path
                  ~target_path:(Some "2024/01/Canon/moveme.jpg")
                  ~md5_hash:"c72d040ee1fdcd8bce09fc8b6e6c4794" ~file_size:15 ()
              in
              let records = Db.query_files_by_ids db [ file_id ] in
              let fr = List.hd records in
              let plan : Domain.init_plan =
                {
                  already_correct = [];
                  needs_move = [ (fr, "2024/01/Canon/moveme.jpg") ];
                  duplicates = [];
                  quarantined = [];
                }
              in
              let result = Init.execute_init db worker lib plan in
              Alcotest.(check int) "moved 1" 1 result.moved;
              Alcotest.(check int) "errors 0" 0 result.errors;
              (* Verify entry was created *)
              let entry =
                Db.get_entry_by_path db ~library_id:lib.id
                  ~relative_path:"2024/01/Canon/moveme.jpg"
              in
              Alcotest.(check bool) "entry exists" true (Option.is_some entry);
              (* Verify file actually moved *)
              let dst_path = tmp_dir ^ "/2024/01/Canon/moveme.jpg" in
              let exists = Sys.file_exists dst_path in
              Alcotest.(check bool) "dest file exists" true exists;
              (* Verify source file removed *)
              let src_exists = Sys.file_exists src_path in
              Alcotest.(check bool) "source gone" false src_exists;
              (* Verify file record deleted *)
              let remaining = Db.query_files_by_ids db [ file_id ] in
              Alcotest.(check int) "file record deleted" 0
                (List.length remaining);
              Worker_client.stop worker;
              Db.close db);
          Alcotest.test_case "move failure increments errors" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let tmp_dir = Filename.temp_dir "init_test_err" "" in
              let lib =
                Db.create_library db ~name:"photos" ~location:tmp_dir
                  ~config_json:(Config.to_json_string Config.default)
              in
              let worker =
                Worker_client.start ~worker_path:(worker_path ())
              in
              (* File record pointing to non-existent source *)
              let file_id =
                insert_hashed_file db
                  ~source_path:(tmp_dir ^ "/nonexistent/ghost.jpg")
                  ~target_path:(Some "2024/01/Canon/ghost.jpg")
                  ~md5_hash:"abc123" ()
              in
              let records = Db.query_files_by_ids db [ file_id ] in
              let fr = List.hd records in
              let plan : Domain.init_plan =
                {
                  already_correct = [];
                  needs_move = [ (fr, "2024/01/Canon/ghost.jpg") ];
                  duplicates = [];
                  quarantined = [];
                }
              in
              let result = Init.execute_init db worker lib plan in
              Alcotest.(check int) "moved 0" 0 result.moved;
              Alcotest.(check int) "errors 1" 1 result.errors;
              Worker_client.stop worker;
              Db.close db);
        ] );
    ]

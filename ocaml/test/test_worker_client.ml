open Worker_client

(** Locate the Go worker binary. Tries several candidate paths to handle
    both direct execution and dune sandbox environments. *)
let worker_path () =
  let env_path =
    Sys.getenv_opt "GROVE_WORKER_PATH" |> Option.value ~default:""
  in
  (* Absolute path that works regardless of cwd *)
  let abs_path =
    let ocaml_dir = Filename.dirname (Filename.dirname (Sys.executable_name)) in
    Filename.concat (Filename.dirname ocaml_dir) "worker/worker"
  in
  let candidates =
    List.filter (fun s -> s <> "")
      [ env_path; "../worker/worker"; abs_path;
        "/path/to/trove/.worktrees/go-ocaml-rewrite/worker/worker" ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some p -> p
  | None ->
      failwith
        (Printf.sprintf "worker binary not found (tried: %s, cwd=%s)"
           (String.concat ", " candidates) (Sys.getcwd ()))

(** Create a temp directory that is cleaned up after [f] runs. *)
let with_tmp_dir f =
  let dir = Filename.temp_dir "trove_test_" "" in
  Fun.protect
    ~finally:(fun () ->
      (* best-effort cleanup *)
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

(** Write [contents] to [path], creating the file. *)
let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc

let show_worker_error = function
  | Domain.Timeout -> "Timeout"
  | Domain.Not_found -> "Not_found"
  | Domain.Permission_denied -> "Permission_denied"
  | Domain.Cross_device -> "Cross_device"
  | Domain.Io_error s -> "Io_error(" ^ s ^ ")"
  | Domain.Already_exists -> "Already_exists"
  | Domain.Worker_crash -> "Worker_crash"
  | Domain.Unknown s -> "Unknown(" ^ s ^ ")"

let fail_error e = Alcotest.fail ("expected Ok, got Error: " ^ show_worker_error e)

(* ---- lifecycle ---- *)

let test_start_and_stop () =
  let w = start ~worker_path:(worker_path ()) in
  Alcotest.(check bool) "worker is alive after start" true (is_alive w);
  stop w;
  Alcotest.(check bool) "worker is dead after stop" false (is_alive w)

let test_worker_stays_alive () =
  with_tmp_dir (fun dir ->
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          (* issue two operations in a row *)
          let r1 = path_exists w (Filename.concat dir "nope1") in
          let r2 = path_exists w (Filename.concat dir "nope2") in
          Alcotest.(check bool) "first call ok" true (Result.is_ok r1);
          Alcotest.(check bool) "second call ok" true (Result.is_ok r2);
          Alcotest.(check bool) "still alive" true (is_alive w)))

(* ---- check_mount ---- *)

let test_check_mount_real_dir () =
  with_tmp_dir (fun dir ->
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match check_mount w ~path:dir ~timeout_seconds:5 with
          | Ok avail ->
              Alcotest.(check bool) "mount is available" true avail
          | Error e -> fail_error e))

let test_check_mount_nonexistent () =
  let w = start ~worker_path:(worker_path ()) in
  Fun.protect ~finally:(fun () -> stop w) (fun () ->
      match check_mount w ~path:"/no/such/path/at/all" ~timeout_seconds:5 with
      | Ok avail ->
          (* Worker returns ok with available=false for non-existent paths *)
          Alcotest.(check bool) "mount not available" false avail
      | Error _ ->
          (* Also acceptable: the worker might return an error *)
          ())

(* ---- path_exists ---- *)

let test_path_exists_real_file () =
  with_tmp_dir (fun dir ->
      let path = Filename.concat dir "exists.txt" in
      write_file path "hello";
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match path_exists w path with
          | Ok b -> Alcotest.(check bool) "file exists" true b
          | Error e -> fail_error e))

let test_path_exists_missing () =
  with_tmp_dir (fun dir ->
      let path = Filename.concat dir "missing.txt" in
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match path_exists w path with
          | Ok b -> Alcotest.(check bool) "file does not exist" false b
          | Error e -> fail_error e))

(* ---- stat_path ---- *)

let test_stat_path () =
  with_tmp_dir (fun dir ->
      let path = Filename.concat dir "stat_me.txt" in
      write_file path "12345";
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match stat_path w path with
          | Ok sr ->
              Alcotest.(check int) "size is 5" 5 sr.size;
              Alcotest.(check bool) "is not dir" false sr.is_dir
          | Error e -> fail_error e))

(* ---- walk_tree ---- *)

let test_walk_tree () =
  with_tmp_dir (fun dir ->
      write_file (Filename.concat dir "a.jpg") "photo1";
      write_file (Filename.concat dir "b.txt") "readme";
      let sub = Filename.concat dir "sub" in
      Unix.mkdir sub 0o755;
      write_file (Filename.concat sub "c.jpg") "photo2";
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match
            walk_tree w ~root:dir ~extensions:[ ".jpg" ] ~exclude_patterns:[]
          with
          | Ok items ->
              Alcotest.(check int) "found 2 jpgs" 2 (List.length items);
              let paths =
                List.map (fun (i : walk_item) -> i.path) items
                |> List.sort String.compare
              in
              Alcotest.(check (list string))
                "correct paths" [ "a.jpg"; "sub/c.jpg" ] paths
          | Error e -> fail_error e))

(* ---- hash_path ---- *)

let test_hash_path () =
  with_tmp_dir (fun dir ->
      let path = Filename.concat dir "hash_me.txt" in
      write_file path "hello";
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match hash_path w path with
          | Ok md5 ->
              (* MD5("hello") = 5d41402abc4b2a76b9719d911017c592 *)
              Alcotest.(check string) "correct md5"
                "5d41402abc4b2a76b9719d911017c592" md5
          | Error e -> fail_error e))

(* ---- copy_and_hash ---- *)

let test_copy_and_hash () =
  with_tmp_dir (fun dir ->
      let src = Filename.concat dir "original.txt" in
      let dst = Filename.concat dir "copied.txt" in
      write_file src "copy me";
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match copy_and_hash w ~src ~dst with
          | Ok md5 ->
              Alcotest.(check bool) "md5 non-empty" true (String.length md5 > 0);
              Alcotest.(check bool) "dest exists" true (Sys.file_exists dst);
              Alcotest.(check bool) "source still exists" true
                (Sys.file_exists src)
          | Error e -> fail_error e))

(* ---- move_file ---- *)

let test_move_file () =
  with_tmp_dir (fun dir ->
      let src = Filename.concat dir "to_move.txt" in
      let dst = Filename.concat dir "moved.txt" in
      write_file src "move me";
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match move_file w ~src ~dst ~expected_hash:None with
          | Ok _md5 ->
              Alcotest.(check bool) "dest exists" true (Sys.file_exists dst);
              Alcotest.(check bool) "source gone" false (Sys.file_exists src)
          | Error e -> fail_error e))

(* ---- mkdir_all ---- *)

let test_mkdir_all () =
  with_tmp_dir (fun dir ->
      let target = Filename.concat dir "a/b/c" in
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match mkdir_all w target with
          | Ok () ->
              Alcotest.(check bool) "dir created" true (Sys.is_directory target)
          | Error e -> fail_error e))

(* ---- unlink_path ---- *)

let test_unlink_path () =
  with_tmp_dir (fun dir ->
      let path = Filename.concat dir "delete_me.txt" in
      write_file path "bye";
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match unlink_path w path with
          | Ok () ->
              Alcotest.(check bool) "file deleted" false (Sys.file_exists path)
          | Error e -> fail_error e))

(* ---- remove_empty_dirs ---- *)

let test_remove_empty_dirs () =
  with_tmp_dir (fun dir ->
      let nested = Filename.concat dir "a/b/c" in
      ignore
        (Sys.command
           (Printf.sprintf "mkdir -p %s" (Filename.quote nested)));
      let w = start ~worker_path:(worker_path ()) in
      Fun.protect ~finally:(fun () -> stop w) (fun () ->
          match remove_empty_dirs w ~path:nested ~stop_at:dir with
          | Ok () ->
              Alcotest.(check bool) "nested dir removed" false
                (Sys.file_exists nested);
              Alcotest.(check bool) "stop_at dir still exists" true
                (Sys.file_exists dir)
          | Error e -> fail_error e))

(* ---- test runner ---- *)

let () =
  Alcotest.run "worker_client"
    [
      ( "lifecycle",
        [
          Alcotest.test_case "start and stop" `Quick test_start_and_stop;
          Alcotest.test_case "stays alive across calls" `Quick
            test_worker_stays_alive;
        ] );
      ( "check_mount",
        [
          Alcotest.test_case "real dir" `Quick test_check_mount_real_dir;
          Alcotest.test_case "nonexistent" `Quick test_check_mount_nonexistent;
        ] );
      ( "path_exists",
        [
          Alcotest.test_case "real file" `Quick test_path_exists_real_file;
          Alcotest.test_case "missing file" `Quick test_path_exists_missing;
        ] );
      ( "stat_path",
        [ Alcotest.test_case "real file" `Quick test_stat_path ] );
      ( "walk_tree",
        [ Alcotest.test_case "filtered walk" `Quick test_walk_tree ] );
      ( "hash_path",
        [ Alcotest.test_case "known content" `Quick test_hash_path ] );
      ( "copy_and_hash",
        [ Alcotest.test_case "basic copy" `Quick test_copy_and_hash ] );
      ( "move_file",
        [ Alcotest.test_case "basic move" `Quick test_move_file ] );
      ( "mkdir_all",
        [ Alcotest.test_case "nested dirs" `Quick test_mkdir_all ] );
      ( "unlink_path",
        [ Alcotest.test_case "delete file" `Quick test_unlink_path ] );
      ( "remove_empty_dirs",
        [
          Alcotest.test_case "remove nested empties" `Quick
            test_remove_empty_dirs;
        ] );
    ]

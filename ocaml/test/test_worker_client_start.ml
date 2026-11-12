open Worker_client

let with_tmp_dir f =
  let dir = Filename.temp_dir "trove_worker_start_" "" in
  Fun.protect
    ~finally:(fun () ->
      ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
    (fun () -> f dir)

let write_executable path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  Unix.chmod path 0o755

let test_start_missing_binary () =
  match start ~worker_path:"/definitely/not/a/real/worker" () with
  | Ok worker ->
    stop worker;
    Alcotest.fail "expected missing worker path to return Error"
  | Error Domain.Not_found -> ()
  | Error err ->
    Alcotest.failf "expected Not_found, got %s"
      (Utils.string_of_worker_error err)

let test_start_bad_json_hello () =
  with_tmp_dir (fun dir ->
    let script = Filename.concat dir "bad-json-worker.sh" in
    write_executable script "#!/bin/sh\nprintf 'not-json\\n'\n";
    match start ~worker_path:script () with
    | Ok worker ->
      stop worker;
      Alcotest.fail "expected invalid hello json to return Error"
    | Error (Domain.Unknown detail) ->
      Alcotest.(check bool) "mentions invalid json" true
        (String.contains detail 'j' || String.contains detail 'J')
    | Error err ->
      Alcotest.failf "expected Unknown, got %s"
        (Utils.string_of_worker_error err))

let test_start_unsupported_protocol_version () =
  with_tmp_dir (fun dir ->
    let script = Filename.concat dir "wrong-version-worker.sh" in
    write_executable script
      "#!/bin/sh\nprintf '{\"protocol_version\":2}\\n'\n";
    match start ~worker_path:script () with
    | Ok worker ->
      stop worker;
      Alcotest.fail "expected unsupported protocol version to return Error"
    | Error (Domain.Unknown detail) ->
      Alcotest.(check bool) "mentions protocol version" true
        (String.length detail > 0)
    | Error err ->
      Alcotest.failf "expected Unknown, got %s"
        (Utils.string_of_worker_error err))

let () =
  Alcotest.run "worker_client_start"
    [
      ( "start",
        [
          Alcotest.test_case "missing binary returns Not_found" `Quick
            test_start_missing_binary;
          Alcotest.test_case "invalid hello json returns Unknown" `Quick
            test_start_bad_json_hello;
          Alcotest.test_case "unsupported protocol returns Unknown" `Quick
            test_start_unsupported_protocol_version;
        ] );
    ]

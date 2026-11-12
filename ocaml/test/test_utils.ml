let () =
  Alcotest.run "utils"
    [
      ( "now_iso",
        [
          Alcotest.test_case "returns non-empty string" `Quick (fun () ->
              let result = Utils.now_iso () in
              Alcotest.(check bool) "non-empty" true (String.length result > 0));
          Alcotest.test_case "matches ISO 8601 format" `Quick (fun () ->
              let result = Utils.now_iso () in
              let re = Str.regexp
                "^\\([0-9][0-9][0-9][0-9]\\)-\\([0-9][0-9]\\)-\\([0-9][0-9]\\)T\\([0-9][0-9]\\):\\([0-9][0-9]\\):\\([0-9][0-9]\\)Z$"
              in
              Alcotest.(check bool) "format" true (Str.string_match re result 0));
          Alcotest.test_case "returns UTC (ends with Z)" `Quick (fun () ->
              let result = Utils.now_iso () in
              Alcotest.(check bool) "ends with Z" true
                (String.ends_with ~suffix:"Z" result));
          Alcotest.test_case "two calls produce different values" `Quick
            (fun () ->
              let a = Utils.now_iso () in
              Unix.sleepf 1.1;
              let b = Utils.now_iso () in
              Alcotest.(check bool) "different" true (a <> b));
        ] );
      ( "string_of_worker_error",
        [
          Alcotest.test_case "Timeout" `Quick (fun () ->
              Alcotest.(check string) "" "timeout"
                (Utils.string_of_worker_error Domain.Timeout));
          Alcotest.test_case "Not_found" `Quick (fun () ->
              Alcotest.(check string) "" "not_found"
                (Utils.string_of_worker_error Domain.Not_found));
          Alcotest.test_case "Permission_denied" `Quick (fun () ->
              Alcotest.(check string) "" "permission_denied"
                (Utils.string_of_worker_error Domain.Permission_denied));
          Alcotest.test_case "Cross_device" `Quick (fun () ->
              Alcotest.(check string) "" "cross_device"
                (Utils.string_of_worker_error Domain.Cross_device));
          Alcotest.test_case "Already_exists" `Quick (fun () ->
              Alcotest.(check string) "" "already_exists"
                (Utils.string_of_worker_error Domain.Already_exists));
          Alcotest.test_case "Worker_crash" `Quick (fun () ->
              Alcotest.(check string) "" "worker_crash"
                (Utils.string_of_worker_error Domain.Worker_crash));
          Alcotest.test_case "Io_error empty" `Quick (fun () ->
              Alcotest.(check string) "" "io_error"
                (Utils.string_of_worker_error (Domain.Io_error "")));
          Alcotest.test_case "Io_error with message" `Quick (fun () ->
              Alcotest.(check string) "" "io_error: disk full"
                (Utils.string_of_worker_error (Domain.Io_error "disk full")));
          Alcotest.test_case "Unknown" `Quick (fun () ->
              Alcotest.(check string) "" "unknown: something weird"
                (Utils.string_of_worker_error (Domain.Unknown "something weird")));
        ] );
      ( "app_error",
        [
          Alcotest.test_case "string_of_error_code" `Quick (fun () ->
              Alcotest.(check string) "" "library_not_found"
                (Utils.string_of_error_code Domain.Library_not_found));
          Alcotest.test_case "string_of_app_error without context" `Quick
            (fun () ->
              let err =
                Utils.app_error ~code:Domain.Library_not_found
                  "library was not found"
              in
              Alcotest.(check string) "" "[library_not_found] library was not found"
                (Utils.string_of_app_error err));
          Alcotest.test_case "string_of_app_error with context" `Quick
            (fun () ->
              let err =
                Utils.app_error ~code:Domain.Mount_unavailable
                  ~context:[ ("path", "/mnt/photos") ]
                  "path is not mounted"
              in
              Alcotest.(check string) "" "[mount_unavailable] path is not mounted (path=/mnt/photos)"
                (Utils.string_of_app_error err));
          Alcotest.test_case "app_error_of_worker_error timeout" `Quick
            (fun () ->
              let err =
                Utils.app_error_of_worker_error ~op:"hash_path"
                  ~path:"/tmp/a.jpg" Domain.Timeout
              in
              Alcotest.(check string) "code" "worker_timeout"
                (Utils.string_of_error_code err.code);
              Alcotest.(check bool) "retryable" true err.retryable);
          Alcotest.test_case "app_error_of_db_message" `Quick (fun () ->
              let err =
                Utils.app_error_of_db_message
                  ~context:[ ("run_id", "42") ]
                  "step error: BUSY"
              in
              Alcotest.(check string) "code" "db_error"
                (Utils.string_of_error_code err.code);
              Alcotest.(check bool) "has detail" true
                (List.mem ("detail", "step error: BUSY") err.context));
        ] );
      ( "relative_to_root",
        [
          Alcotest.test_case "path equals root returns empty string" `Quick
            (fun () ->
              Alcotest.(check (option string)) "" (Some "")
                (Utils.relative_to_root ~root_path:"/a/b" "/a/b"));
          Alcotest.test_case "path directly under root" `Quick (fun () ->
              Alcotest.(check (option string)) "" (Some "file.txt")
                (Utils.relative_to_root ~root_path:"/a/b" "/a/b/file.txt"));
          Alcotest.test_case "path nested under root" `Quick (fun () ->
              Alcotest.(check (option string)) "" (Some "c/d/file.txt")
                (Utils.relative_to_root ~root_path:"/a/b" "/a/b/c/d/file.txt"));
          Alcotest.test_case "path not under root returns None" `Quick (fun () ->
              Alcotest.(check (option string)) "" None
                (Utils.relative_to_root ~root_path:"/a/b" "/x/y/file.txt"));
          Alcotest.test_case "partial prefix match returns None" `Quick
            (fun () ->
              Alcotest.(check (option string)) "" None
                (Utils.relative_to_root ~root_path:"/a/b" "/a/bc/file.txt"));
          Alcotest.test_case "root with trailing slash mismatch" `Quick
            (fun () ->
              Alcotest.(check (option string)) "" None
                (Utils.relative_to_root ~root_path:"/a/b" "/a/b-file.txt"));
          Alcotest.test_case "empty relative path for exact match" `Quick
            (fun () ->
              Alcotest.(check (option string)) "" (Some "")
                (Utils.relative_to_root ~root_path:"/photos" "/photos"));
        ] );
      ( "path_within_root",
        [
          Alcotest.test_case "path equals root" `Quick (fun () ->
              Alcotest.(check bool) "" true
                (Utils.path_within_root ~root_path:"/a/b" "/a/b"));
          Alcotest.test_case "path under root" `Quick (fun () ->
              Alcotest.(check bool) "" true
                (Utils.path_within_root ~root_path:"/a/b" "/a/b/file.txt"));
          Alcotest.test_case "path not under root" `Quick (fun () ->
              Alcotest.(check bool) "" false
                (Utils.path_within_root ~root_path:"/a/b" "/x/y/file.txt"));
          Alcotest.test_case "partial prefix not under root" `Quick (fun () ->
              Alcotest.(check bool) "" false
                (Utils.path_within_root ~root_path:"/a/b" "/a/bc/file.txt"));
          Alcotest.test_case "root is prefix of different path" `Quick
            (fun () ->
              Alcotest.(check bool) "" false
                (Utils.path_within_root ~root_path:"/a/b" "/a/b-file.txt"));
        ] );
      ( "extension_of_filename",
        [
          Alcotest.test_case "simple extension" `Quick (fun () ->
              Alcotest.(check (option string)) "" (Some "jpg")
                (Utils.extension_of_filename "photo.jpg"));
          Alcotest.test_case "no extension" `Quick (fun () ->
              Alcotest.(check (option string)) "" None
                (Utils.extension_of_filename "README"));
          Alcotest.test_case "hidden file no extension" `Quick (fun () ->
              Alcotest.(check (option string)) "" None
                (Utils.extension_of_filename ".gitignore"));
          Alcotest.test_case "double extension" `Quick (fun () ->
              Alcotest.(check (option string)) "" (Some "gz")
                (Utils.extension_of_filename "archive.tar.gz"));
          Alcotest.test_case "dot at end" `Quick (fun () ->
              Alcotest.(check (option string)) "" None
                (Utils.extension_of_filename "file."));
          Alcotest.test_case "dot at start only" `Quick (fun () ->
              Alcotest.(check (option string)) "" None
                (Utils.extension_of_filename "."));
          Alcotest.test_case "empty string" `Quick (fun () ->
              Alcotest.(check (option string)) "" None
                (Utils.extension_of_filename ""));
          Alcotest.test_case "uppercase extension" `Quick (fun () ->
              Alcotest.(check (option string)) "" (Some "JPG")
                (Utils.extension_of_filename "photo.JPG"));
        ] );
      ( "StringSet",
        [
          Alcotest.test_case "empty set" `Quick (fun () ->
              Alcotest.(check bool) "" true
                (Utils.StringSet.is_empty Utils.StringSet.empty));
          Alcotest.test_case "add and mem" `Quick (fun () ->
              let s = Utils.StringSet.add "hello" Utils.StringSet.empty in
              Alcotest.(check bool) "" true (Utils.StringSet.mem "hello" s));
          Alcotest.test_case "mem returns false for missing element" `Quick
            (fun () ->
              let s = Utils.StringSet.add "hello" Utils.StringSet.empty in
              Alcotest.(check bool) "" false (Utils.StringSet.mem "world" s));
          Alcotest.test_case "add multiple elements" `Quick (fun () ->
              let s =
                Utils.StringSet.add "a"
                  (Utils.StringSet.add "b"
                     (Utils.StringSet.add "c" Utils.StringSet.empty))
              in
              Alcotest.(check int) "size" 3 (Utils.StringSet.cardinal s));
          Alcotest.test_case "duplicate add is idempotent" `Quick (fun () ->
              let s =
                Utils.StringSet.add "a" (Utils.StringSet.add "a" Utils.StringSet.empty)
              in
              Alcotest.(check int) "size" 1 (Utils.StringSet.cardinal s));
        ] );
    ]

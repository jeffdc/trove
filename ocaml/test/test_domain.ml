open Domain

let status_testable =
  Alcotest.testable
    (fun fmt s -> Format.pp_print_string fmt (file_status_to_string s))
    ( = )

let test_status_to_string () =
  Alcotest.(check string) "discovered" "discovered"
    (file_status_to_string Discovered);
  Alcotest.(check string) "hashed" "hashed"
    (file_status_to_string Hashed);
  Alcotest.(check string) "quarantined (hash_failed)" "quarantined"
    (file_status_to_string (Quarantined Hash_failed));
  Alcotest.(check string) "quarantined (no_date)" "quarantined"
    (file_status_to_string (Quarantined No_date));
  Alcotest.(check string) "quarantined (unreadable)" "quarantined"
    (file_status_to_string (Quarantined Unreadable));
  Alcotest.(check string) "duplicate (in_batch)" "duplicate"
    (file_status_to_string (Duplicate In_batch));
  Alcotest.(check string) "duplicate (in_library)" "duplicate"
    (file_status_to_string (Duplicate In_library));
  Alcotest.(check string) "imported" "imported"
    (file_status_to_string Imported)

let test_status_round_trip () =
  (* Simple variants round-trip exactly *)
  let check s =
    Alcotest.(check status_testable) "round_trip" s
      (file_status_of_string (file_status_to_string s))
  in
  check Discovered;
  check Hashed;
  check Imported;
  (* Quarantined and Duplicate round-trip to their defaults *)
  Alcotest.(check status_testable) "quarantined default"
    (Quarantined Hash_failed)
    (file_status_of_string (file_status_to_string (Quarantined No_date)));
  Alcotest.(check status_testable) "duplicate default"
    (Duplicate In_batch)
    (file_status_of_string (file_status_to_string (Duplicate In_library)))

let worker_error_testable =
  Alcotest.testable
    (fun fmt e ->
      Format.pp_print_string fmt
        (match e with
        | Timeout -> "Timeout"
        | Not_found -> "Not_found"
        | Permission_denied -> "Permission_denied"
        | Cross_device -> "Cross_device"
        | Io_error s -> "Io_error(" ^ s ^ ")"
        | Already_exists -> "Already_exists"
        | Worker_crash -> "Worker_crash"
        | Unknown s -> "Unknown(" ^ s ^ ")"))
    ( = )

let test_worker_error_of_string () =
  Alcotest.(check worker_error_testable) "timeout" Timeout
    (worker_error_of_string "timeout");
  Alcotest.(check worker_error_testable) "not_found" Not_found
    (worker_error_of_string "not_found");
  Alcotest.(check worker_error_testable) "permission_denied" Permission_denied
    (worker_error_of_string "permission_denied");
  Alcotest.(check worker_error_testable) "cross_device" Cross_device
    (worker_error_of_string "cross_device");
  Alcotest.(check worker_error_testable) "already_exists" Already_exists
    (worker_error_of_string "already_exists");
  Alcotest.(check worker_error_testable) "worker_crash" Worker_crash
    (worker_error_of_string "worker_crash")

let test_worker_error_unknown () =
  Alcotest.(check worker_error_testable) "unknown maps correctly"
    (Unknown "whatever")
    (worker_error_of_string "whatever");
  Alcotest.(check worker_error_testable) "io_error prefix"
    (Io_error "disk full")
    (worker_error_of_string "io_error:disk full");
  Alcotest.(check worker_error_testable) "io_error bare"
    (Io_error "")
    (worker_error_of_string "io_error")

let () =
  Alcotest.run "domain"
    [
      ( "file_status",
        [
          Alcotest.test_case "to_string" `Quick test_status_to_string;
          Alcotest.test_case "round_trip" `Quick test_status_round_trip;
        ] );
      ( "worker_error",
        [
          Alcotest.test_case "of_string" `Quick test_worker_error_of_string;
          Alcotest.test_case "unknown" `Quick test_worker_error_unknown;
        ] );
    ]

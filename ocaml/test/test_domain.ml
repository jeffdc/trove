open Legacy_domain

let status_testable =
  Alcotest.testable
    (fun fmt s -> Format.pp_print_string fmt (Legacy_domain.file_status_to_string s))
    ( = )

let test_status_to_string () =
  Alcotest.(check string) "discovered" "discovered"
    (Legacy_domain.file_status_to_string Discovered);
  Alcotest.(check string) "hashed" "hashed"
    (Legacy_domain.file_status_to_string Hashed);
  Alcotest.(check string) "quarantined (hash_failed)" "quarantined"
    (Legacy_domain.file_status_to_string (Quarantined Hash_failed));
  Alcotest.(check string) "quarantined (no_date)" "quarantined"
    (Legacy_domain.file_status_to_string (Quarantined No_date));
  Alcotest.(check string) "quarantined (unreadable)" "quarantined"
    (Legacy_domain.file_status_to_string (Quarantined Unreadable));
  Alcotest.(check string) "duplicate (in_batch)" "duplicate"
    (Legacy_domain.file_status_to_string (Duplicate In_batch));
  Alcotest.(check string) "duplicate (in_library)" "duplicate"
    (Legacy_domain.file_status_to_string (Duplicate In_library));
  Alcotest.(check string) "imported" "imported"
    (Legacy_domain.file_status_to_string Imported)

let test_status_round_trip () =
  let check s =
    Alcotest.(check status_testable) "round_trip" s
      (Legacy_domain.file_status_of_string (Legacy_domain.file_status_to_string s))
  in
  check Discovered;
  check Hashed;
  check Imported;
  Alcotest.(check status_testable) "quarantined default"
    (Quarantined Hash_failed)
    (Legacy_domain.file_status_of_string (Legacy_domain.file_status_to_string (Quarantined No_date)));
  Alcotest.(check status_testable) "duplicate default"
    (Duplicate In_batch)
    (Legacy_domain.file_status_of_string (Legacy_domain.file_status_to_string (Duplicate In_library)))

let test_status_unknown () =
  Alcotest.(check status_testable) "unknown status preserved"
    (Unknown_status "mystery")
    (Legacy_domain.file_status_of_string "mystery");
  Alcotest.(check string) "unknown status re-renders raw value" "mystery"
    (Legacy_domain.file_status_to_string (Unknown_status "mystery"))

let worker_error_testable =
  Alcotest.testable
    (fun fmt e ->
      Format.pp_print_string fmt
        (match e with
        | Domain.Timeout -> "Timeout"
        | Domain.Not_found -> "Not_found"
        | Domain.Permission_denied -> "Permission_denied"
        | Domain.Cross_device -> "Cross_device"
        | Domain.Io_error s -> "Io_error(" ^ s ^ ")"
        | Domain.Already_exists -> "Already_exists"
        | Domain.Worker_crash -> "Worker_crash"
        | Domain.Unknown s -> "Unknown(" ^ s ^ ")"))
    ( = )

let test_worker_error_of_string () =
  Alcotest.(check worker_error_testable) "timeout" Domain.Timeout
    (Domain.worker_error_of_string "timeout");
  Alcotest.(check worker_error_testable) "not_found" Domain.Not_found
    (Domain.worker_error_of_string "not_found");
  Alcotest.(check worker_error_testable) "permission_denied" Domain.Permission_denied
    (Domain.worker_error_of_string "permission_denied");
  Alcotest.(check worker_error_testable) "cross_device" Domain.Cross_device
    (Domain.worker_error_of_string "cross_device");
  Alcotest.(check worker_error_testable) "already_exists" Domain.Already_exists
    (Domain.worker_error_of_string "already_exists");
  Alcotest.(check worker_error_testable) "worker_crash" Domain.Worker_crash
    (Domain.worker_error_of_string "worker_crash")

let test_worker_error_unknown () =
  Alcotest.(check worker_error_testable) "unknown maps correctly"
    (Domain.Unknown "whatever")
    (Domain.worker_error_of_string "whatever");
  Alcotest.(check worker_error_testable) "io_error prefix"
    (Domain.Io_error "disk full")
    (Domain.worker_error_of_string "io_error:disk full");
  Alcotest.(check worker_error_testable) "io_error bare"
    (Domain.Io_error "")
    (Domain.worker_error_of_string "io_error")

let () =
  Alcotest.run "domain"
    [
      ( "file_status",
        [
          Alcotest.test_case "to_string" `Quick test_status_to_string;
          Alcotest.test_case "round_trip" `Quick test_status_round_trip;
          Alcotest.test_case "unknown" `Quick test_status_unknown;
        ] );
      ( "worker_error",
        [
          Alcotest.test_case "of_string" `Quick test_worker_error_of_string;
          Alcotest.test_case "unknown" `Quick test_worker_error_unknown;
        ] );
    ]

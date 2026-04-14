let test_version () =
  Alcotest.(check string) "version" "0.1.0" Trove_lib.version

let () =
  Alcotest.run "trove"
    [
      ( "basics",
        [
          Alcotest.test_case "version" `Quick test_version;
        ] );
    ]

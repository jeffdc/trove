let test_domain_loads () =
  let _ = Domain.Hash_algorithm.Md5 in
  ()

let () =
  Alcotest.run "domain"
    [
      ( "basics",
        [
          Alcotest.test_case "domain module loads" `Quick test_domain_loads;
        ] );
    ]

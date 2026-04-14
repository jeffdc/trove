(* Tests for the Pipeline module — pure functions and DB-backed stages.
   Following TDD: these tests are written before the implementation. *)

let () =
  Alcotest.run "pipeline"
    [
      (* ---- normalize_filename ---- *)
      ( "normalize_filename",
        [
          Alcotest.test_case "simple filename unchanged" `Quick (fun () ->
              Alcotest.(check string)
                "simple" "photo.jpg"
                (Pipeline.normalize_filename "photo.jpg"));
          Alcotest.test_case "replaces unsafe chars" `Quick (fun () ->
              Alcotest.(check string)
                "unsafe" "a_b_c.jpg"
                (Pipeline.normalize_filename "a:b*c.jpg"));
          Alcotest.test_case "replaces whitespace" `Quick (fun () ->
              Alcotest.(check string)
                "whitespace" "hello_world.jpg"
                (Pipeline.normalize_filename "hello world.jpg"));
          Alcotest.test_case "collapses underscores" `Quick (fun () ->
              Alcotest.(check string)
                "collapse" "a_b.jpg"
                (Pipeline.normalize_filename "a___b.jpg"));
          Alcotest.test_case "strips leading/trailing dots and underscores"
            `Quick (fun () ->
              Alcotest.(check string)
                "strip" "photo.jpg"
                (Pipeline.normalize_filename "._photo.jpg"));
          Alcotest.test_case "strips trailing underscores" `Quick (fun () ->
              Alcotest.(check string)
                "strip trailing" "photo.jpg"
                (Pipeline.normalize_filename "photo_.jpg"));
          Alcotest.test_case "Windows reserved CON" `Quick (fun () ->
              Alcotest.(check string)
                "con" "_CON.txt"
                (Pipeline.normalize_filename "CON.txt"));
          Alcotest.test_case "Windows reserved PRN" `Quick (fun () ->
              Alcotest.(check string)
                "prn" "_PRN.txt"
                (Pipeline.normalize_filename "PRN.txt"));
          Alcotest.test_case "Windows reserved NUL" `Quick (fun () ->
              Alcotest.(check string)
                "nul" "_NUL.txt"
                (Pipeline.normalize_filename "NUL.txt"));
          Alcotest.test_case "Windows reserved COM1" `Quick (fun () ->
              Alcotest.(check string)
                "com1" "_COM1.txt"
                (Pipeline.normalize_filename "COM1.txt"));
          Alcotest.test_case "Windows reserved LPT9" `Quick (fun () ->
              Alcotest.(check string)
                "lpt9" "_LPT9.txt"
                (Pipeline.normalize_filename "LPT9.txt"));
          Alcotest.test_case "Windows reserved case insensitive" `Quick
            (fun () ->
              Alcotest.(check string)
                "con lower" "_con.txt"
                (Pipeline.normalize_filename "con.txt"));
          Alcotest.test_case "empty basename becomes unnamed" `Quick (fun () ->
              Alcotest.(check string)
                "empty" "unnamed.jpg"
                (Pipeline.normalize_filename ".jpg"));
          Alcotest.test_case "completely empty becomes unnamed" `Quick
            (fun () ->
              Alcotest.(check string)
                "empty no ext" "unnamed"
                (Pipeline.normalize_filename ""));
          Alcotest.test_case "long basename truncated with hash" `Quick
            (fun () ->
              let long_name = String.make 250 'a' ^ ".jpg" in
              let result = Pipeline.normalize_filename long_name in
              let base =
                Filename.chop_extension result
              in
              (* 192 chars + _ + 7 hex = 200 chars *)
              Alcotest.(check bool)
                "truncated" true
                (String.length base = 200);
              Alcotest.(check bool)
                "ends with .jpg" true
                (Filename.check_suffix result ".jpg"));
          Alcotest.test_case "complex: spaces, unsafe, leading dots" `Quick
            (fun () ->
              Alcotest.(check string)
                "complex" "my_photo_file.jpg"
                (Pipeline.normalize_filename "._my photo:file.jpg"));
          Alcotest.test_case "slash replaced" `Quick (fun () ->
              Alcotest.(check string)
                "slash" "a_b.jpg"
                (Pipeline.normalize_filename "a/b.jpg"));
          Alcotest.test_case "pipe and angle brackets" `Quick (fun () ->
              Alcotest.(check string)
                "pipe" "a_b_c.jpg"
                (Pipeline.normalize_filename "a|b<c>.jpg"));
          Alcotest.test_case "tab replaced" `Quick (fun () ->
              Alcotest.(check string)
                "tab" "a_b.jpg"
                (Pipeline.normalize_filename "a\tb.jpg"));
          Alcotest.test_case "no extension" `Quick (fun () ->
              Alcotest.(check string)
                "no ext" "photo"
                (Pipeline.normalize_filename "photo"));
          Alcotest.test_case "AUX reserved" `Quick (fun () ->
              Alcotest.(check string)
                "aux" "_AUX.doc"
                (Pipeline.normalize_filename "AUX.doc"));
          Alcotest.test_case "not-reserved when part of longer name" `Quick
            (fun () ->
              Alcotest.(check string)
                "not reserved" "CONNECT.txt"
                (Pipeline.normalize_filename "CONNECT.txt"));
          Alcotest.test_case "question mark replaced" `Quick (fun () ->
              Alcotest.(check string)
                "question" "what_now.txt"
                (Pipeline.normalize_filename "what?now.txt"));
          Alcotest.test_case "double quote replaced" `Quick (fun () ->
              Alcotest.(check string)
                "dquote" "say_hi.txt"
                (Pipeline.normalize_filename "say\"hi.txt"));
        ] );
      (* ---- compute_target_path ---- *)
      ( "compute_target_path",
        [
          Alcotest.test_case "basic with model" `Quick (fun () ->
              let config = Config.default in
              let result =
                Pipeline.compute_target_path ~capture_date:"2024-01-15T10:30:00"
                  ~camera_model:(Some "Canon EOS R5") ~filename:"photo.jpg"
                  config
              in
              Alcotest.(check (option string))
                "with model" (Some "2024/01/Canon_EOS_R5/photo.jpg") result);
          Alcotest.test_case "basic without model uses unknown label" `Quick
            (fun () ->
              let config = Config.default in
              let result =
                Pipeline.compute_target_path ~capture_date:"2024-01-15T10:30:00"
                  ~camera_model:None ~filename:"photo.jpg" config
              in
              Alcotest.(check (option string))
                "unknown model"
                (Some "2024/01/Unknown_Model/photo.jpg")
                result);
          Alcotest.test_case "include_camera_model false" `Quick (fun () ->
              let config =
                {
                  Config.default with
                  organization =
                    { Config.default.organization with include_camera_model = false };
                }
              in
              let result =
                Pipeline.compute_target_path ~capture_date:"2024-06-30T14:00:00"
                  ~camera_model:(Some "Nikon Z9") ~filename:"sunset.jpg" config
              in
              Alcotest.(check (option string))
                "no model" (Some "2024/06/sunset.jpg") result);
          Alcotest.test_case "custom structure %Y/%m/%d" `Quick (fun () ->
              let config =
                {
                  Config.default with
                  organization =
                    { Config.default.organization with structure = "%Y/%m/%d" };
                }
              in
              let result =
                Pipeline.compute_target_path ~capture_date:"2024-03-05T08:00:00"
                  ~camera_model:None ~filename:"test.jpg" config
              in
              Alcotest.(check (option string))
                "day structure"
                (Some "2024/03/05/Unknown_Model/test.jpg")
                result);
          Alcotest.test_case "normalizes filename in path" `Quick (fun () ->
              let config = Config.default in
              let result =
                Pipeline.compute_target_path ~capture_date:"2024-01-15T10:30:00"
                  ~camera_model:(Some "Canon") ~filename:"my photo.jpg" config
              in
              Alcotest.(check (option string))
                "normalized"
                (Some "2024/01/Canon/my_photo.jpg")
                result);
          Alcotest.test_case "bad date returns None" `Quick (fun () ->
              let config = Config.default in
              let result =
                Pipeline.compute_target_path ~capture_date:"not-a-date"
                  ~camera_model:None ~filename:"test.jpg" config
              in
              Alcotest.(check (option string)) "bad date" None result);
          Alcotest.test_case "date only (no time)" `Quick (fun () ->
              let config = Config.default in
              let result =
                Pipeline.compute_target_path ~capture_date:"2024-07-04"
                  ~camera_model:(Some "Sony") ~filename:"img.jpg" config
              in
              Alcotest.(check (option string))
                "date only"
                (Some "2024/07/Sony/img.jpg")
                result);
        ] );
      (* ---- resolve_path ---- *)
      ( "resolve_path",
        [
          Alcotest.test_case "unclaimed path returned as-is" `Quick (fun () ->
              let claimed = ref (Pipeline.StringSet.empty) in
              let result = Pipeline.resolve_path "2024/01/photo.jpg" claimed in
              Alcotest.(check string) "as-is" "2024/01/photo.jpg" result;
              Alcotest.(check bool)
                "claimed" true
                (Pipeline.StringSet.mem "2024/01/photo.jpg" !claimed));
          Alcotest.test_case "claimed path gets suffix -1" `Quick (fun () ->
              let claimed =
                ref (Pipeline.StringSet.singleton "2024/01/photo.jpg")
              in
              let result = Pipeline.resolve_path "2024/01/photo.jpg" claimed in
              Alcotest.(check string) "suffixed" "2024/01/photo-1.jpg" result;
              Alcotest.(check bool)
                "new claimed" true
                (Pipeline.StringSet.mem "2024/01/photo-1.jpg" !claimed));
          Alcotest.test_case "double collision gets -2" `Quick (fun () ->
              let claimed =
                ref
                  (Pipeline.StringSet.of_list
                     [ "2024/01/photo.jpg"; "2024/01/photo-1.jpg" ])
              in
              let result = Pipeline.resolve_path "2024/01/photo.jpg" claimed in
              Alcotest.(check string) "suffixed -2" "2024/01/photo-2.jpg" result);
          Alcotest.test_case "no directory in path" `Quick (fun () ->
              let claimed = ref (Pipeline.StringSet.singleton "photo.jpg") in
              let result = Pipeline.resolve_path "photo.jpg" claimed in
              Alcotest.(check string) "suffixed" "photo-1.jpg" result);
          Alcotest.test_case "no extension" `Quick (fun () ->
              let claimed =
                ref (Pipeline.StringSet.singleton "2024/01/README")
              in
              let result = Pipeline.resolve_path "2024/01/README" claimed in
              Alcotest.(check string) "suffixed" "2024/01/README-1" result);
          Alcotest.test_case "original path added to claimed" `Quick (fun () ->
              let claimed = ref Pipeline.StringSet.empty in
              let _ = Pipeline.resolve_path "a/b.jpg" claimed in
              let result = Pipeline.resolve_path "a/b.jpg" claimed in
              Alcotest.(check string) "second call" "a/b-1.jpg" result);
        ] );
      (* ---- discover_and_persist (DB tests) ---- *)
      ( "discover_and_persist",
        [
          Alcotest.test_case "inserts walked files into DB" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let walk_items =
                [
                  {
                    Worker_client.path = "/src/photo1.jpg";
                    size = 1000;
                    mtime = "2024-01-15T10:00:00Z";
                  };
                  {
                    Worker_client.path = "/src/photo2.jpg";
                    size = 2000;
                    mtime = "2024-01-15T11:00:00Z";
                  };
                ]
              in
              let ids, skip_count =
                Pipeline.discover_and_persist_from_items db
                  ~source_path:"/src" ~source_type:"local" walk_items
                  ~skip_paths:(Pipeline.StringSet.empty)
              in
              Alcotest.(check int) "two new files" 2 (List.length ids);
              Alcotest.(check int) "no skips" 0 skip_count;
              (* Verify they're in the DB *)
              let records = Db.query_files_by_status db Domain.Discovered in
              Alcotest.(check int) "two records" 2 (List.length records);
              Db.close db);
          Alcotest.test_case "skips files in skip_paths" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let walk_items =
                [
                  {
                    Worker_client.path = "/src/photo1.jpg";
                    size = 1000;
                    mtime = "2024-01-15T10:00:00Z";
                  };
                  {
                    Worker_client.path = "/src/subdir/photo2.jpg";
                    size = 2000;
                    mtime = "2024-01-15T11:00:00Z";
                  };
                ]
              in
              let skip =
                Pipeline.StringSet.singleton "subdir/photo2.jpg"
              in
              let ids, skip_count =
                Pipeline.discover_and_persist_from_items db
                  ~source_path:"/src" ~source_type:"local" walk_items
                  ~skip_paths:skip
              in
              Alcotest.(check int) "one new file" 1 (List.length ids);
              Alcotest.(check int) "one skipped" 1 skip_count;
              Db.close db);
          Alcotest.test_case "unchanged file skipped on re-discovery" `Quick
            (fun () ->
              let db = Db.open_db ":memory:" in
              let walk_items =
                [
                  {
                    Worker_client.path = "/src/photo1.jpg";
                    size = 1000;
                    mtime = "2024-01-15T10:00:00Z";
                  };
                ]
              in
              let skip = Pipeline.StringSet.empty in
              (* First discovery *)
              let ids1, _ =
                Pipeline.discover_and_persist_from_items db
                  ~source_path:"/src" ~source_type:"local" walk_items
                  ~skip_paths:skip
              in
              Alcotest.(check int) "first: one new" 1 (List.length ids1);
              (* Second discovery, same data *)
              let ids2, skip2 =
                Pipeline.discover_and_persist_from_items db
                  ~source_path:"/src" ~source_type:"local" walk_items
                  ~skip_paths:skip
              in
              Alcotest.(check int) "second: none new" 0 (List.length ids2);
              Alcotest.(check int) "second: one skipped" 1 skip2;
              Db.close db);
          Alcotest.test_case "changed file resets to discovered" `Quick
            (fun () ->
              let db = Db.open_db ":memory:" in
              let items1 =
                [
                  {
                    Worker_client.path = "/src/photo1.jpg";
                    size = 1000;
                    mtime = "2024-01-15T10:00:00Z";
                  };
                ]
              in
              let skip = Pipeline.StringSet.empty in
              let _, _ =
                Pipeline.discover_and_persist_from_items db
                  ~source_path:"/src" ~source_type:"local" items1
                  ~skip_paths:skip
              in
              (* Re-discover with different size *)
              let items2 =
                [
                  {
                    Worker_client.path = "/src/photo1.jpg";
                    size = 2000;
                    mtime = "2024-01-15T12:00:00Z";
                  };
                ]
              in
              let ids2, skip2 =
                Pipeline.discover_and_persist_from_items db
                  ~source_path:"/src" ~source_type:"local" items2
                  ~skip_paths:skip
              in
              Alcotest.(check int) "one reset" 1 (List.length ids2);
              Alcotest.(check int) "none skipped" 0 skip2;
              Db.close db);
        ] );
      (* ---- hash_files ---- *)
      ( "hash_files",
        [
          Alcotest.test_case "empty list returns empty" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let result = Pipeline.hash_files_with_fn db [] ~hash_fn:(fun _ -> Ok "abc") in
              Alcotest.(check (list int)) "empty" [] result;
              Db.close db);
          Alcotest.test_case "hashes files and updates DB" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let r1 =
                Db.insert_file db ~source_path:"/src/a.jpg" ~source_type:"local"
                  ~file_size:100 ~file_modify_date:"2024-01-15T10:00:00Z"
              in
              let r2 =
                Db.insert_file db ~source_path:"/src/b.jpg" ~source_type:"local"
                  ~file_size:200 ~file_modify_date:"2024-01-15T11:00:00Z"
              in
              let hash_fn = function
                | "/src/a.jpg" -> Ok "hash_a"
                | "/src/b.jpg" -> Ok "hash_b"
                | p -> Error (Domain.Io_error ("unexpected: " ^ p))
              in
              let result =
                Pipeline.hash_files_with_fn db [ r1.id; r2.id ] ~hash_fn
              in
              Alcotest.(check int) "two hashed" 2 (List.length result);
              (* Verify DB updated *)
              let records = Db.query_files_by_status db Domain.Hashed in
              Alcotest.(check int) "two hashed in DB" 2 (List.length records);
              let a_rec = List.find (fun r -> r.Domain.source_path = "/src/a.jpg") records in
              Alcotest.(check (option string)) "hash_a" (Some "hash_a") a_rec.md5_hash;
              Db.close db);
          Alcotest.test_case "hash failure quarantines file" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let r1 =
                Db.insert_file db ~source_path:"/src/bad.jpg" ~source_type:"local"
                  ~file_size:100 ~file_modify_date:"2024-01-15T10:00:00Z"
              in
              let hash_fn _ = Error Domain.Not_found in
              let result =
                Pipeline.hash_files_with_fn db [ r1.id ] ~hash_fn
              in
              Alcotest.(check (list int)) "none hashed" [] result;
              let quarantined =
                Db.query_files_by_status db (Domain.Quarantined Domain.Hash_failed)
              in
              Alcotest.(check int)
                "one quarantined" 1 (List.length quarantined);
              Db.close db);
        ] );
      (* ---- compute_paths ---- *)
      ( "compute_paths",
        [
          Alcotest.test_case "sets target_path on records" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let r =
                Db.insert_file db ~source_path:"/src/photo.jpg"
                  ~source_type:"local" ~file_size:100
                  ~file_modify_date:"2024-01-15T10:00:00Z"
              in
              Db.update_file db r.id
                [
                  ("capture_date", Some "2024-01-15T10:30:00");
                  ("camera_model", Some "Canon");
                  ("status", Some "hashed");
                ];
              let config = Config.default in
              let result = Pipeline.compute_paths db [ r.id ] config in
              Alcotest.(check int) "one id returned" 1 (List.length result);
              let records = Db.query_files_by_ids db [ r.id ] in
              let rec_ = List.hd records in
              Alcotest.(check (option string))
                "target set"
                (Some "2024/01/Canon/photo.jpg")
                rec_.target_path;
              Db.close db);
          Alcotest.test_case "no capture_date skips target_path" `Quick
            (fun () ->
              let db = Db.open_db ":memory:" in
              let r =
                Db.insert_file db ~source_path:"/src/nodateimg.jpg"
                  ~source_type:"local" ~file_size:100
                  ~file_modify_date:"2024-01-15T10:00:00Z"
              in
              let config = Config.default in
              let result = Pipeline.compute_paths db [ r.id ] config in
              Alcotest.(check int) "one id" 1 (List.length result);
              let records = Db.query_files_by_ids db [ r.id ] in
              let rec_ = List.hd records in
              Alcotest.(check (option string))
                "no target" None rec_.target_path;
              Db.close db);
          Alcotest.test_case "empty list returns empty" `Quick (fun () ->
              let db = Db.open_db ":memory:" in
              let result = Pipeline.compute_paths db [] Config.default in
              Alcotest.(check (list int)) "empty" [] result;
              Db.close db);
        ] );
      (* ---- format_date_structure ---- *)
      ( "format_date_structure",
        [
          Alcotest.test_case "%Y/%m" `Quick (fun () ->
              let result =
                Pipeline.format_date_structure ~year:2024 ~month:1 ~day:15
                  "%Y/%m"
              in
              Alcotest.(check string) "year/month" "2024/01" result);
          Alcotest.test_case "%Y/%m/%d" `Quick (fun () ->
              let result =
                Pipeline.format_date_structure ~year:2024 ~month:3 ~day:5
                  "%Y/%m/%d"
              in
              Alcotest.(check string) "year/month/day" "2024/03/05" result);
          Alcotest.test_case "%Y only" `Quick (fun () ->
              let result =
                Pipeline.format_date_structure ~year:2024 ~month:12 ~day:25
                  "%Y"
              in
              Alcotest.(check string) "year only" "2024" result);
          Alcotest.test_case "%d-%m-%Y" `Quick (fun () ->
              let result =
                Pipeline.format_date_structure ~year:2024 ~month:6 ~day:1
                  "%d-%m-%Y"
              in
              Alcotest.(check string) "reversed" "01-06-2024" result);
        ] );
      (* ---- parse_iso_date ---- *)
      ( "parse_iso_date",
        [
          Alcotest.test_case "full ISO datetime" `Quick (fun () ->
              let result = Pipeline.parse_iso_date "2024-01-15T10:30:00" in
              Alcotest.(check (option (triple int int int)))
                "parsed" (Some (2024, 1, 15)) result);
          Alcotest.test_case "date only" `Quick (fun () ->
              let result = Pipeline.parse_iso_date "2024-07-04" in
              Alcotest.(check (option (triple int int int)))
                "parsed" (Some (2024, 7, 4)) result);
          Alcotest.test_case "with timezone" `Quick (fun () ->
              let result = Pipeline.parse_iso_date "2024-01-15T10:30:00Z" in
              Alcotest.(check (option (triple int int int)))
                "parsed" (Some (2024, 1, 15)) result);
          Alcotest.test_case "with +offset" `Quick (fun () ->
              let result =
                Pipeline.parse_iso_date "2024-01-15T10:30:00+05:00"
              in
              Alcotest.(check (option (triple int int int)))
                "parsed" (Some (2024, 1, 15)) result);
          Alcotest.test_case "garbage returns None" `Quick (fun () ->
              let result = Pipeline.parse_iso_date "not-a-date" in
              Alcotest.(check (option (triple int int int)))
                "none" None result);
          Alcotest.test_case "empty returns None" `Quick (fun () ->
              let result = Pipeline.parse_iso_date "" in
              Alcotest.(check (option (triple int int int)))
                "none" None result);
        ] );
    ]

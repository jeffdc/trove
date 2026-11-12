open Domain

(* ---------- Helpers ---------- *)

let fresh_db () = Legacy_db_impl.open_db ":memory:"

let make_library db =
  Legacy_db_impl.create_library db ~name:"photos" ~location:"/mnt/photos" ~config_json:"{}"

(** Insert a file record at the given status with an optional md5_hash.
    Returns the file_record (re-fetched so fields reflect updates). *)
let insert_file_with_status db ~source_path ~status ~md5_hash =
  let fr =
    Legacy_db_impl.insert_file db ~source_path ~source_type:"add" ~file_size:1000
      ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  let updates = [("status", Some (Legacy_domain.file_status_to_string status))] in
  let updates = match md5_hash with
    | Some h -> ("md5_hash", Some h) :: updates
    | None -> updates
  in
  Legacy_db_impl.update_file db fr.id updates;
  let records = Legacy_db_impl.query_files_by_ids db [ fr.id ] in
  List.hd records

(* ================================================================== *)
(* 1. Empty DB: plan has all empty lists, can_complete = true          *)
(* ================================================================== *)

let test_empty_db () =
  let db = fresh_db () in
  let lib = make_library db in
  let plan = Legacy_complete.plan_complete db ~library_id:lib.id in
  Alcotest.(check int) "imported" 0 (List.length plan.imported);
  Alcotest.(check int) "duplicate" 0 (List.length plan.duplicate);
  Alcotest.(check int) "quarantined" 0 (List.length plan.quarantined);
  Alcotest.(check int) "unaccounted" 0 (List.length plan.unaccounted);
  let result = Legacy_complete.execute_complete db plan in
  Alcotest.(check bool) "can_complete" true result.can_complete;
  Alcotest.(check int) "records_cleaned" 0 result.records_cleaned;
  Legacy_db_impl.close db

(* ================================================================== *)
(* 2. All files imported with matching entries: can_complete = true     *)
(* ================================================================== *)

let test_all_imported_with_entries () =
  let db = fresh_db () in
  let lib = make_library db in
  let _fr1 =
    insert_file_with_status db ~source_path:"/src/a.jpg"
      ~status:Imported ~md5_hash:(Some "hash_a")
  in
  let _fr2 =
    insert_file_with_status db ~source_path:"/src/b.jpg"
      ~status:Imported ~md5_hash:(Some "hash_b")
  in
  (* Create matching entries in the library *)
  let _e1 =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/a.jpg"
      ~file_size:1000 ~md5_hash:(Some "hash_a") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let _e2 =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/b.jpg"
      ~file_size:1000 ~md5_hash:(Some "hash_b") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let plan = Legacy_complete.plan_complete db ~library_id:lib.id in
  Alcotest.(check int) "imported" 2 (List.length plan.imported);
  Alcotest.(check int) "unaccounted" 0 (List.length plan.unaccounted);
  let result = Legacy_complete.execute_complete db plan in
  Alcotest.(check bool) "can_complete" true result.can_complete;
  Alcotest.(check int) "imported_count" 2 result.imported_count;
  Legacy_db_impl.close db

(* ================================================================== *)
(* 3. Files at discovered/hashed: unaccounted, can_complete = false     *)
(* ================================================================== *)

let test_discovered_and_hashed_are_unaccounted () =
  let db = fresh_db () in
  let lib = make_library db in
  let _fr1 =
    insert_file_with_status db ~source_path:"/src/disc.jpg"
      ~status:Discovered ~md5_hash:None
  in
  let _fr2 =
    insert_file_with_status db ~source_path:"/src/hash.jpg"
      ~status:Hashed ~md5_hash:(Some "some_hash")
  in
  let plan = Legacy_complete.plan_complete db ~library_id:lib.id in
  Alcotest.(check int) "unaccounted" 2 (List.length plan.unaccounted);
  Alcotest.(check int) "imported" 0 (List.length plan.imported);
  let result = Legacy_complete.execute_complete db plan in
  Alcotest.(check bool) "can_complete" false result.can_complete;
  Alcotest.(check int) "unaccounted_count" 2 result.unaccounted_count;
  Alcotest.(check int) "records_cleaned" 0 result.records_cleaned;
  Legacy_db_impl.close db

(* ================================================================== *)
(* 4. Imported file with no matching entry: goes to unaccounted        *)
(* ================================================================== *)

let test_imported_no_matching_entry () =
  let db = fresh_db () in
  let lib = make_library db in
  let _fr =
    insert_file_with_status db ~source_path:"/src/orphan.jpg"
      ~status:Imported ~md5_hash:(Some "orphan_hash")
  in
  (* No entry created for this hash *)
  let plan = Legacy_complete.plan_complete db ~library_id:lib.id in
  Alcotest.(check int) "imported" 0 (List.length plan.imported);
  Alcotest.(check int) "unaccounted" 1 (List.length plan.unaccounted);
  Alcotest.(check string) "correct file" "/src/orphan.jpg"
    (List.hd plan.unaccounted).source_path;
  Legacy_db_impl.close db

(* ================================================================== *)
(* 5. Imported file with no hash: goes to unaccounted                  *)
(* ================================================================== *)

let test_imported_no_hash () =
  let db = fresh_db () in
  let lib = make_library db in
  let _fr =
    insert_file_with_status db ~source_path:"/src/nohash.jpg"
      ~status:Imported ~md5_hash:None
  in
  let plan = Legacy_complete.plan_complete db ~library_id:lib.id in
  Alcotest.(check int) "imported" 0 (List.length plan.imported);
  Alcotest.(check int) "unaccounted" 1 (List.length plan.unaccounted);
  Alcotest.(check string) "correct file" "/src/nohash.jpg"
    (List.hd plan.unaccounted).source_path;
  Legacy_db_impl.close db

(* ================================================================== *)
(* 6. execute_complete deletes terminal records                        *)
(* ================================================================== *)

let test_execute_deletes_terminal_records () =
  let db = fresh_db () in
  let lib = make_library db in
  let fr1 =
    insert_file_with_status db ~source_path:"/src/imp.jpg"
      ~status:Imported ~md5_hash:(Some "h1")
  in
  let fr2 =
    insert_file_with_status db ~source_path:"/src/dup.jpg"
      ~status:(Duplicate In_batch) ~md5_hash:(Some "h2")
  in
  let fr3 =
    insert_file_with_status db ~source_path:"/src/quar.jpg"
      ~status:(Quarantined No_date) ~md5_hash:None
  in
  (* Create a matching entry for the imported file *)
  let _e =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/imp.jpg"
      ~file_size:1000 ~md5_hash:(Some "h1") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let plan = Legacy_complete.plan_complete db ~library_id:lib.id in
  Alcotest.(check int) "imported" 1 (List.length plan.imported);
  Alcotest.(check int) "duplicate" 1 (List.length plan.duplicate);
  Alcotest.(check int) "quarantined" 1 (List.length plan.quarantined);
  Alcotest.(check int) "unaccounted" 0 (List.length plan.unaccounted);
  let result = Legacy_complete.execute_complete db plan in
  Alcotest.(check bool) "can_complete" true result.can_complete;
  (* Verify all terminal records are deleted *)
  let remaining_imp = Legacy_db_impl.query_files_by_ids db [ fr1.id ] in
  let remaining_dup = Legacy_db_impl.query_files_by_ids db [ fr2.id ] in
  let remaining_qua = Legacy_db_impl.query_files_by_ids db [ fr3.id ] in
  Alcotest.(check int) "imp gone" 0 (List.length remaining_imp);
  Alcotest.(check int) "dup gone" 0 (List.length remaining_dup);
  Alcotest.(check int) "qua gone" 0 (List.length remaining_qua);
  Legacy_db_impl.close db

(* ================================================================== *)
(* 7. execute_complete refuses when unaccounted > 0                    *)
(* ================================================================== *)

let test_execute_refuses_with_unaccounted () =
  let db = fresh_db () in
  let _lib = make_library db in
  let _fr =
    insert_file_with_status db ~source_path:"/src/stuck.jpg"
      ~status:Discovered ~md5_hash:None
  in
  let plan = Legacy_complete.plan_complete db ~library_id:_lib.id in
  Alcotest.(check int) "unaccounted" 1 (List.length plan.unaccounted);
  let result = Legacy_complete.execute_complete db plan in
  Alcotest.(check bool) "can_complete" false result.can_complete;
  Alcotest.(check int) "records_cleaned" 0 result.records_cleaned;
  (* Verify file still exists *)
  let remaining = Legacy_db_impl.query_files_by_status db Discovered in
  Alcotest.(check int) "still there" 1 (List.length remaining);
  Legacy_db_impl.close db

(* ================================================================== *)
(* 8. complete_import end-to-end: all imported -> cleans up            *)
(* ================================================================== *)

let test_complete_import_end_to_end () =
  let db = fresh_db () in
  let lib = make_library db in
  let _fr =
    insert_file_with_status db ~source_path:"/src/done.jpg"
      ~status:Imported ~md5_hash:(Some "done_hash")
  in
  let _e =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/done.jpg"
      ~file_size:1000 ~md5_hash:(Some "done_hash") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let result = Legacy_complete.complete_import db ~library_id:lib.id in
  Alcotest.(check bool) "can_complete" true result.can_complete;
  Alcotest.(check int) "imported_count" 1 result.imported_count;
  Alcotest.(check int) "unaccounted_count" 0 result.unaccounted_count;
  (* Records should be cleaned *)
  let remaining = Legacy_db_impl.query_files_by_status db Imported in
  Alcotest.(check int) "cleaned up" 0 (List.length remaining);
  Legacy_db_impl.close db

(* ================================================================== *)
(* 9. Mixed statuses: imported + duplicate + quarantined + hashed      *)
(* ================================================================== *)

let test_mixed_statuses () =
  let db = fresh_db () in
  let lib = make_library db in
  (* Imported with matching entry *)
  let _fr_imp =
    insert_file_with_status db ~source_path:"/src/imp.jpg"
      ~status:Imported ~md5_hash:(Some "imp_h")
  in
  let _e =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/imp.jpg"
      ~file_size:1000 ~md5_hash:(Some "imp_h") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  (* Duplicate *)
  let _fr_dup =
    insert_file_with_status db ~source_path:"/src/dup.jpg"
      ~status:(Duplicate In_library) ~md5_hash:(Some "dup_h")
  in
  (* Quarantined *)
  let _fr_qua =
    insert_file_with_status db ~source_path:"/src/qua.jpg"
      ~status:(Quarantined Hash_failed) ~md5_hash:None
  in
  (* Still hashed (not done) *)
  let _fr_hashed =
    insert_file_with_status db ~source_path:"/src/hashed.jpg"
      ~status:Hashed ~md5_hash:(Some "hashed_h")
  in
  let plan = Legacy_complete.plan_complete db ~library_id:lib.id in
  Alcotest.(check int) "imported" 1 (List.length plan.imported);
  Alcotest.(check int) "duplicate" 1 (List.length plan.duplicate);
  Alcotest.(check int) "quarantined" 1 (List.length plan.quarantined);
  Alcotest.(check int) "unaccounted" 1 (List.length plan.unaccounted);
  (* Should not be completable because of the hashed file *)
  let result = Legacy_complete.execute_complete db plan in
  Alcotest.(check bool) "can_complete" false result.can_complete;
  Alcotest.(check int) "records_cleaned" 0 result.records_cleaned;
  Alcotest.(check int) "imported_count" 1 result.imported_count;
  Alcotest.(check int) "duplicate_count" 1 result.duplicate_count;
  Alcotest.(check int) "quarantined_count" 1 result.quarantined_count;
  Alcotest.(check int) "unaccounted_count" 1 result.unaccounted_count;
  Legacy_db_impl.close db

(* ================================================================== *)
(* Test registration                                                   *)
(* ================================================================== *)

let () =
  Alcotest.run "complete"
    [
      ( "plan_complete",
        [
          Alcotest.test_case "empty DB" `Quick test_empty_db;
          Alcotest.test_case "all imported with entries" `Quick
            test_all_imported_with_entries;
          Alcotest.test_case "discovered/hashed are unaccounted" `Quick
            test_discovered_and_hashed_are_unaccounted;
          Alcotest.test_case "imported no matching entry" `Quick
            test_imported_no_matching_entry;
          Alcotest.test_case "imported no hash" `Quick
            test_imported_no_hash;
          Alcotest.test_case "mixed statuses" `Quick test_mixed_statuses;
        ] );
      ( "execute_complete",
        [
          Alcotest.test_case "deletes terminal records" `Quick
            test_execute_deletes_terminal_records;
          Alcotest.test_case "refuses with unaccounted" `Quick
            test_execute_refuses_with_unaccounted;
        ] );
      ( "complete_import",
        [
          Alcotest.test_case "end-to-end" `Quick
            test_complete_import_end_to_end;
        ] );
    ]

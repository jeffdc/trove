open Domain

(* ---------- Helpers ---------- *)

let fresh_db () = Legacy_db_impl.open_db ":memory:"

let make_library db =
  Legacy_db_impl.create_library db ~name:"photos" ~location:"/mnt/photos" ~config_json:"{}"

(** Insert a file record in "hashed" state with the given properties.
    Returns the file_record. *)
let insert_hashed_file db ~source_path ~file_size ~md5_hash ~target_path
    ~capture_date ~camera_model =
  let fr =
    Legacy_db_impl.insert_file db ~source_path ~source_type:"directory"
      ~file_size ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  let updates =
    [ ("status", Some "hashed");
      ("md5_hash", Some md5_hash);
      ("target_path", target_path);
      ("capture_date", capture_date);
      ("camera_model", camera_model);
    ]
  in
  Legacy_db_impl.update_file db fr.id updates;
  (* Re-fetch to get updated record *)
  let records = Legacy_db_impl.query_files_by_ids db [ fr.id ] in
  List.hd records

(* ================================================================== *)
(* Planning tests: classify_for_import                                 *)
(* ================================================================== *)

(* 1. Empty ID list returns empty plan *)
let test_classify_empty_ids () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  let plan = Legacy_import.classify_for_import db ~library_id:lib.id [] config in
  Alcotest.(check int) "to_import" 0 (List.length plan.to_import);
  Alcotest.(check int) "dup batch" 0 (List.length plan.duplicates_in_batch);
  Alcotest.(check int) "dup lib" 0 (List.length plan.duplicates_in_library);
  Alcotest.(check int) "path_conflicts" 0 plan.path_conflicts;
  Alcotest.(check int) "skipped" 0 (List.length plan.skipped);
  Legacy_db_impl.close db

(* 2. Single file with target_path goes to to_import *)
let test_classify_single_importable () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  let fr =
    insert_hashed_file db ~source_path:"/src/photo.jpg" ~file_size:1000
      ~md5_hash:"aaa111" ~target_path:(Some "2024/01/photo.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  Alcotest.(check int) "to_import" 1 (List.length plan.to_import);
  Alcotest.(check int) "skipped" 0 (List.length plan.skipped);
  Alcotest.(check string) "correct file"
    "/src/photo.jpg" (List.hd plan.to_import).source_path;
  Legacy_db_impl.close db

(* 3. File without target_path goes to skipped *)
let test_classify_no_target_path () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  let fr =
    insert_hashed_file db ~source_path:"/src/mystery.dat" ~file_size:500
      ~md5_hash:"bbb222" ~target_path:None
      ~capture_date:None ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  Alcotest.(check int) "to_import" 0 (List.length plan.to_import);
  Alcotest.(check int) "skipped" 1 (List.length plan.skipped);
  Alcotest.(check string) "correct file"
    "/src/mystery.dat" (List.hd plan.skipped).source_path;
  Legacy_db_impl.close db

(* 4. Two files with same hash: one imports, one is batch duplicate *)
let test_classify_batch_dedup () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  let fr1 =
    insert_hashed_file db ~source_path:"/src/a.jpg" ~file_size:1000
      ~md5_hash:"same_hash" ~target_path:(Some "2024/01/a.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let fr2 =
    insert_hashed_file db ~source_path:"/src/b.jpg" ~file_size:1000
      ~md5_hash:"same_hash" ~target_path:(Some "2024/01/b.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr1.id; fr2.id ] config
  in
  Alcotest.(check int) "to_import" 1 (List.length plan.to_import);
  Alcotest.(check int) "dup batch" 1 (List.length plan.duplicates_in_batch);
  (* The one with the lower ID should be the keeper *)
  Alcotest.(check int) "keeper id" fr1.id (List.hd plan.to_import).id;
  Alcotest.(check int) "dup id" fr2.id (List.hd plan.duplicates_in_batch).id;
  Legacy_db_impl.close db

(* 5. File matching existing entry by size+hash is a library duplicate *)
let test_classify_library_dedup () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  (* Create an existing entry in the library *)
  let _entry =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/existing.jpg"
      ~file_size:2000 ~md5_hash:(Some "lib_hash") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  (* File with same size and hash *)
  let fr =
    insert_hashed_file db ~source_path:"/src/dupe.jpg" ~file_size:2000
      ~md5_hash:"lib_hash" ~target_path:(Some "2024/01/dupe.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  Alcotest.(check int) "to_import" 0 (List.length plan.to_import);
  Alcotest.(check int) "dup lib" 1 (List.length plan.duplicates_in_library);
  Alcotest.(check int) "dup id" fr.id (List.hd plan.duplicates_in_library).id;
  Legacy_db_impl.close db

(* 6. File matching entry by size but different hash is NOT a duplicate *)
let test_classify_same_size_different_hash () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  (* Existing entry with size 3000, different hash *)
  let _entry =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/other.jpg"
      ~file_size:3000 ~md5_hash:(Some "hash_X") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let fr =
    insert_hashed_file db ~source_path:"/src/new.jpg" ~file_size:3000
      ~md5_hash:"hash_Y" ~target_path:(Some "2024/01/new.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  Alcotest.(check int) "to_import" 1 (List.length plan.to_import);
  Alcotest.(check int) "dup lib" 0 (List.length plan.duplicates_in_library);
  Legacy_db_impl.close db

(* 7. Path conflicts counted correctly *)
let test_classify_path_conflicts () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  (* Create an entry occupying target path *)
  let _entry =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/conflict.jpg"
      ~file_size:999 ~md5_hash:(Some "whatever") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  (* File targeting the same path *)
  let fr =
    insert_hashed_file db ~source_path:"/src/conflict.jpg" ~file_size:4000
      ~md5_hash:"unique_hash" ~target_path:(Some "2024/01/conflict.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  Alcotest.(check int) "to_import" 1 (List.length plan.to_import);
  Alcotest.(check int) "path_conflicts" 1 plan.path_conflicts;
  Legacy_db_impl.close db

(* ================================================================== *)
(* Helper tests: resolve_target_path                                   *)
(* ================================================================== *)

(* 12. No conflict: returns path unchanged *)
let test_resolve_target_path_no_conflict () =
  let db = fresh_db () in
  let lib = make_library db in
  let resolved =
    Legacy_import.resolve_target_path db ~library_id:lib.id "2024/01/photo.jpg"
  in
  Alcotest.(check string) "unchanged" "2024/01/photo.jpg" resolved;
  Legacy_db_impl.close db

(* 13. First conflict: returns stem-1.ext *)
let test_resolve_target_path_first_conflict () =
  let db = fresh_db () in
  let lib = make_library db in
  let _entry =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/photo.jpg"
      ~file_size:100 ~md5_hash:None ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let resolved =
    Legacy_import.resolve_target_path db ~library_id:lib.id "2024/01/photo.jpg"
  in
  Alcotest.(check string) "suffixed" "2024/01/photo-1.jpg" resolved;
  Legacy_db_impl.close db

(* Additional: second conflict returns stem-2.ext *)
let test_resolve_target_path_second_conflict () =
  let db = fresh_db () in
  let lib = make_library db in
  let _entry1 =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/photo.jpg"
      ~file_size:100 ~md5_hash:None ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let _entry2 =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/photo-1.jpg"
      ~file_size:100 ~md5_hash:None ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let resolved =
    Legacy_import.resolve_target_path db ~library_id:lib.id "2024/01/photo.jpg"
  in
  Alcotest.(check string) "suffixed" "2024/01/photo-2.jpg" resolved;
  Legacy_db_impl.close db

(* ================================================================== *)
(* Execution tests: execute_import (DB-level, no real worker)          *)
(* ================================================================== *)

(* 8. Marks batch duplicates in DB *)
let test_execute_marks_batch_duplicates () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  let fr1 =
    insert_hashed_file db ~source_path:"/src/a.jpg" ~file_size:1000
      ~md5_hash:"dup_hash" ~target_path:(Some "2024/01/a.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let fr2 =
    insert_hashed_file db ~source_path:"/src/b.jpg" ~file_size:1000
      ~md5_hash:"dup_hash" ~target_path:(Some "2024/01/b.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr1.id; fr2.id ] config
  in
  (* We need a mock worker for execute_import. Use the testable version. *)
  let copy_fn ~src:_ ~dst:_ = Ok "dup_hash" in
  let mkdir_fn _path = Ok () in
  let exists_fn _path = Ok false in
  let _summary =
    Legacy_import.execute_import_with_fns db lib config plan
      ~copy_fn ~mkdir_fn ~exists_fn ()
  in
  (* Check that the batch duplicate file is now marked as duplicate *)
  let records = Legacy_db_impl.query_files_by_ids db [ fr2.id ] in
  Alcotest.(check int) "one record" 1 (List.length records);
  let status_str =
    Legacy_domain.file_status_to_string (List.hd records).status
  in
  Alcotest.(check string) "marked duplicate" "duplicate" status_str;
  Legacy_db_impl.close db

(* 9. Marks library duplicates in DB *)
let test_execute_marks_library_duplicates () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  (* Existing entry in library *)
  let _entry =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/existing.jpg"
      ~file_size:2000 ~md5_hash:(Some "lib_dup") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let fr =
    insert_hashed_file db ~source_path:"/src/dupe.jpg" ~file_size:2000
      ~md5_hash:"lib_dup" ~target_path:(Some "2024/01/dupe.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  let copy_fn ~src:_ ~dst:_ = Ok "lib_dup" in
  let mkdir_fn _path = Ok () in
  let exists_fn _path = Ok false in
  let _summary =
    Legacy_import.execute_import_with_fns db lib config plan
      ~copy_fn ~mkdir_fn ~exists_fn ()
  in
  let records = Legacy_db_impl.query_files_by_ids db [ fr.id ] in
  Alcotest.(check int) "one record" 1 (List.length records);
  let status_str =
    Legacy_domain.file_status_to_string (List.hd records).status
  in
  Alcotest.(check string) "marked duplicate" "duplicate" status_str;
  Legacy_db_impl.close db

(* 10. Copies file and creates entry *)
let test_execute_copies_and_creates_entry () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  let fr =
    insert_hashed_file db ~source_path:"/src/new.jpg" ~file_size:5000
      ~md5_hash:"new_hash" ~target_path:(Some "2024/01/new.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  (* Track calls *)
  let copy_calls = ref [] in
  let mkdir_calls = ref [] in
  let copy_fn ~src ~dst =
    copy_calls := (src, dst) :: !copy_calls;
    Ok "new_hash"
  in
  let mkdir_fn path =
    mkdir_calls := path :: !mkdir_calls;
    Ok ()
  in
  let exists_fn _path = Ok false in
  let summary =
    Legacy_import.execute_import_with_fns db lib config plan
      ~copy_fn ~mkdir_fn ~exists_fn ()
  in
  Alcotest.(check int) "imported" 1 summary.imported;
  Alcotest.(check int) "errors" 0 summary.errors;
  (* Verify copy was called with correct paths *)
  Alcotest.(check int) "one copy" 1 (List.length !copy_calls);
  let src, dst = List.hd !copy_calls in
  Alcotest.(check string) "copy src" "/src/new.jpg" src;
  Alcotest.(check string) "copy dst" "/mnt/photos/2024/01/new.jpg" dst;
  (* Verify entry was created *)
  let entry =
    Legacy_db_impl.get_entry_by_path db ~library_id:lib.id ~relative_path:"2024/01/new.jpg"
  in
  Alcotest.(check bool) "entry exists" true (Option.is_some entry);
  let entry = Option.get entry in
  Alcotest.(check int) "entry size" 5000 entry.file_size;
  Alcotest.(check string) "entry hash" "new_hash" (Option.get entry.md5_hash);
  (* Verify file record marked as imported *)
  let records = Legacy_db_impl.query_files_by_ids db [ fr.id ] in
  let status_str =
    Legacy_domain.file_status_to_string (List.hd records).status
  in
  Alcotest.(check string) "marked imported" "imported" status_str;
  Legacy_db_impl.close db

(* 11. resolve_target_path suffixes on conflict during execution *)
let test_execute_resolves_path_conflict () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  (* Existing entry occupying the target path *)
  let _entry =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/photo.jpg"
      ~file_size:999 ~md5_hash:(Some "old_hash") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let fr =
    insert_hashed_file db ~source_path:"/src/photo.jpg" ~file_size:6000
      ~md5_hash:"new_hash_2" ~target_path:(Some "2024/01/photo.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  let copy_calls = ref [] in
  let copy_fn ~src ~dst =
    copy_calls := (src, dst) :: !copy_calls;
    Ok "new_hash_2"
  in
  let mkdir_fn _path = Ok () in
  let exists_fn _path = Ok false in
  let summary =
    Legacy_import.execute_import_with_fns db lib config plan
      ~copy_fn ~mkdir_fn ~exists_fn ()
  in
  Alcotest.(check int) "imported" 1 summary.imported;
  (* Should have used the suffixed path *)
  let _, dst = List.hd !copy_calls in
  Alcotest.(check string) "suffixed dst" "/mnt/photos/2024/01/photo-1.jpg" dst;
  (* Entry should be at the suffixed path *)
  let entry =
    Legacy_db_impl.get_entry_by_path db ~library_id:lib.id
      ~relative_path:"2024/01/photo-1.jpg"
  in
  Alcotest.(check bool) "entry at suffixed path" true (Option.is_some entry);
  Legacy_db_impl.close db

(* Copy failure increments errors and continues *)
let test_execute_copy_failure () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  let fr =
    insert_hashed_file db ~source_path:"/src/fail.jpg" ~file_size:1000
      ~md5_hash:"fail_hash" ~target_path:(Some "2024/01/fail.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  let copy_fn ~src:_ ~dst:_ = Error (Domain.Io_error "disk full") in
  let mkdir_fn _path = Ok () in
  let exists_fn _path = Ok false in
  let summary =
    Legacy_import.execute_import_with_fns db lib config plan
      ~copy_fn ~mkdir_fn ~exists_fn ()
  in
  Alcotest.(check int) "imported" 0 summary.imported;
  Alcotest.(check int) "errors" 1 summary.errors;
  Legacy_db_impl.close db

(* Hash mismatch after copy increments errors *)
let test_execute_hash_mismatch () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  let fr =
    insert_hashed_file db ~source_path:"/src/mismatch.jpg" ~file_size:1000
      ~md5_hash:"expected_hash" ~target_path:(Some "2024/01/mismatch.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  (* copy_and_hash returns a different hash *)
  let copy_fn ~src:_ ~dst:_ = Ok "wrong_hash" in
  let mkdir_fn _path = Ok () in
  let exists_fn _path = Ok false in
  let summary =
    Legacy_import.execute_import_with_fns db lib config plan
      ~copy_fn ~mkdir_fn ~exists_fn ()
  in
  Alcotest.(check int) "imported" 0 summary.imported;
  Alcotest.(check int) "errors" 1 summary.errors;
  Legacy_db_impl.close db

(* Orphan recovery: file exists at dest with matching hash, skip copy *)
let test_execute_orphan_recovery () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  let fr =
    insert_hashed_file db ~source_path:"/src/orphan.jpg" ~file_size:7000
      ~md5_hash:"orphan_hash" ~target_path:(Some "2024/01/orphan.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id [ fr.id ] config
  in
  let copy_called = ref false in
  let copy_fn ~src:_ ~dst:_ =
    copy_called := true;
    Ok "orphan_hash"
  in
  let mkdir_fn _path = Ok () in
  (* File already exists at destination *)
  let exists_fn _path = Ok true in
  (* We need a hash function for the existing file at dest *)
  let hash_fn _path = Ok "orphan_hash" in
  let summary =
    Legacy_import.execute_import_with_fns db lib config plan
      ~copy_fn ~mkdir_fn ~exists_fn ~hash_fn ()
  in
  Alcotest.(check int) "imported" 1 summary.imported;
  Alcotest.(check bool) "copy not called" false !copy_called;
  Legacy_db_impl.close db

(* Summary counts are correct for mixed plan *)
let test_execute_summary_counts () =
  let db = fresh_db () in
  let lib = make_library db in
  let config = Config.default in
  (* Existing entry for library dedup *)
  let _entry =
    Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:"2024/01/old.jpg"
      ~file_size:2000 ~md5_hash:(Some "lib_h") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  (* File 1: will import *)
  let fr1 =
    insert_hashed_file db ~source_path:"/src/new1.jpg" ~file_size:1000
      ~md5_hash:"h1" ~target_path:(Some "2024/01/new1.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  (* File 2: batch dup of fr3 *)
  let fr2 =
    insert_hashed_file db ~source_path:"/src/dup_a.jpg" ~file_size:3000
      ~md5_hash:"h_batch" ~target_path:(Some "2024/01/dup_a.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  (* File 3: kept from batch dup pair *)
  let fr3 =
    insert_hashed_file db ~source_path:"/src/dup_b.jpg" ~file_size:3000
      ~md5_hash:"h_batch" ~target_path:(Some "2024/01/dup_b.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  (* File 4: library dup *)
  let fr4 =
    insert_hashed_file db ~source_path:"/src/lib_dup.jpg" ~file_size:2000
      ~md5_hash:"lib_h" ~target_path:(Some "2024/01/lib_dup.jpg")
      ~capture_date:(Some "2024-01-15") ~camera_model:None
  in
  let plan =
    Legacy_import.classify_for_import db ~library_id:lib.id
      [ fr1.id; fr2.id; fr3.id; fr4.id ] config
  in
  let mkdir_fn _path = Ok () in
  let exists_fn _path = Ok false in
  let copy_fn ~src ~dst:_ =
    if src = "/src/new1.jpg" then Ok "h1"
    else if src = "/src/dup_a.jpg" then Ok "h_batch"
    else Ok "unknown"
  in
  let summary =
    Legacy_import.execute_import_with_fns db lib config plan
      ~copy_fn ~mkdir_fn ~exists_fn ()
  in
  Alcotest.(check int) "dup_in_batch" 1 summary.dup_in_batch;
  Alcotest.(check int) "dup_in_library" 1 summary.dup_in_library;
  (* fr2 is the batch dup (higher id), fr1 and the keeper of fr2/fr3 import *)
  Alcotest.(check int) "imported" 2 summary.imported;
  Legacy_db_impl.close db

(* ================================================================== *)
(* Test registration                                                   *)
(* ================================================================== *)

let () =
  Alcotest.run "import"
    [
      ( "classify_for_import",
        [
          Alcotest.test_case "empty IDs" `Quick test_classify_empty_ids;
          Alcotest.test_case "single importable" `Quick
            test_classify_single_importable;
          Alcotest.test_case "no target_path" `Quick
            test_classify_no_target_path;
          Alcotest.test_case "batch dedup" `Quick test_classify_batch_dedup;
          Alcotest.test_case "library dedup" `Quick test_classify_library_dedup;
          Alcotest.test_case "same size different hash" `Quick
            test_classify_same_size_different_hash;
          Alcotest.test_case "path conflicts" `Quick
            test_classify_path_conflicts;
        ] );
      ( "resolve_target_path",
        [
          Alcotest.test_case "no conflict" `Quick
            test_resolve_target_path_no_conflict;
          Alcotest.test_case "first conflict" `Quick
            test_resolve_target_path_first_conflict;
          Alcotest.test_case "second conflict" `Quick
            test_resolve_target_path_second_conflict;
        ] );
      ( "execute_import",
        [
          Alcotest.test_case "marks batch duplicates" `Quick
            test_execute_marks_batch_duplicates;
          Alcotest.test_case "marks library duplicates" `Quick
            test_execute_marks_library_duplicates;
          Alcotest.test_case "copies and creates entry" `Quick
            test_execute_copies_and_creates_entry;
          Alcotest.test_case "resolves path conflict" `Quick
            test_execute_resolves_path_conflict;
          Alcotest.test_case "copy failure" `Quick test_execute_copy_failure;
          Alcotest.test_case "hash mismatch" `Quick test_execute_hash_mismatch;
          Alcotest.test_case "orphan recovery" `Quick
            test_execute_orphan_recovery;
          Alcotest.test_case "summary counts" `Quick
            test_execute_summary_counts;
        ] );
    ]

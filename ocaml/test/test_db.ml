open Domain

(* Helper: open an in-memory DB for testing *)
let fresh_db () = Db.open_db ":memory:"

(* --- 1. Create DB, verify tables exist --- *)

let test_tables_exist () =
  let db = fresh_db () in
  let tables = ref [] in
  let raw = Db.raw_db db in
  let _rc =
    Sqlite3.exec raw
      ~cb:(fun row _headers ->
        match row.(0) with Some name -> tables := name :: !tables | None -> ())
      "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
  in
  let has t = List.mem t !tables in
  Alcotest.(check bool) "libraries table" true (has "libraries");
  Alcotest.(check bool) "entries table" true (has "entries");
  Alcotest.(check bool) "files table" true (has "files");
  Alcotest.(check bool) "schema_version table" true (has "schema_version");
  Db.close db

(* --- 2. Create library, get by name, get by id --- *)

let test_create_and_get_library () =
  let db = fresh_db () in
  let lib =
    Db.create_library db ~name:"photos" ~location:"/mnt/photos"
      ~config_json:"{}"
  in
  Alcotest.(check string) "name" "photos" lib.name;
  Alcotest.(check string) "location" "/mnt/photos" lib.location;
  Alcotest.(check string) "config" "{}" lib.config_json;
  Alcotest.(check bool) "id > 0" true (lib.id > 0);
  (* get by name *)
  let found = Db.get_library db "photos" in
  Alcotest.(check bool) "found by name" true (Option.is_some found);
  let found = Option.get found in
  Alcotest.(check int) "same id" lib.id found.id;
  Alcotest.(check string) "same name" "photos" found.name;
  (* get by id *)
  let found2 = Db.get_library_by_id db lib.id in
  Alcotest.(check bool) "found by id" true (Option.is_some found2);
  let found2 = Option.get found2 in
  Alcotest.(check string) "same name by id" "photos" found2.name;
  (* not found *)
  let missing = Db.get_library db "nonexistent" in
  Alcotest.(check bool) "not found" true (Option.is_none missing);
  Db.close db

(* --- 3. List libraries --- *)

let test_list_libraries () =
  let db = fresh_db () in
  let empty = Db.list_libraries db in
  Alcotest.(check int) "empty list" 0 (List.length empty);
  let _lib1 =
    Db.create_library db ~name:"a" ~location:"/a" ~config_json:"{}"
  in
  let _lib2 =
    Db.create_library db ~name:"b" ~location:"/b" ~config_json:"{}"
  in
  let libs = Db.list_libraries db in
  Alcotest.(check int) "two libraries" 2 (List.length libs);
  Db.close db

(* --- 4. Delete library cascades to entries --- *)

let test_delete_library_cascades () =
  let db = fresh_db () in
  let lib =
    Db.create_library db ~name:"photos" ~location:"/photos" ~config_json:"{}"
  in
  let _entry =
    Db.create_entry db ~library_id:lib.id ~relative_path:"2024/01/img.jpg"
      ~file_size:1000 ~md5_hash:(Some "abc123") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let entries_before = Db.list_entries db lib.id in
  Alcotest.(check int) "one entry before" 1 (List.length entries_before);
  Db.delete_library db lib.id;
  let gone = Db.get_library_by_id db lib.id in
  Alcotest.(check bool) "library deleted" true (Option.is_none gone);
  let entries_after = Db.list_entries db lib.id in
  Alcotest.(check int) "entries cascaded" 0 (List.length entries_after);
  Db.close db

(* --- 5. Create entry, get by path --- *)

let test_create_entry_get_by_path () =
  let db = fresh_db () in
  let lib =
    Db.create_library db ~name:"photos" ~location:"/photos" ~config_json:"{}"
  in
  let entry =
    Db.create_entry db ~library_id:lib.id ~relative_path:"2024/01/img.jpg"
      ~file_size:2048 ~md5_hash:(Some "deadbeef")
      ~capture_date:(Some "2024-01-15T12:00:00Z")
      ~camera_model:(Some "Canon R5")
      ~original_path:(Some "/src/img.jpg")
  in
  Alcotest.(check bool) "id > 0" true (entry.id > 0);
  Alcotest.(check int) "library_id" lib.id entry.library_id;
  Alcotest.(check string) "relative_path" "2024/01/img.jpg" entry.relative_path;
  Alcotest.(check int) "file_size" 2048 entry.file_size;
  Alcotest.(check (option string)) "md5_hash" (Some "deadbeef") entry.md5_hash;
  Alcotest.(check (option string)) "capture_date"
    (Some "2024-01-15T12:00:00Z") entry.capture_date;
  Alcotest.(check (option string)) "camera_model" (Some "Canon R5")
    entry.camera_model;
  Alcotest.(check (option string)) "original_path" (Some "/src/img.jpg")
    entry.original_path;
  (* get by path *)
  let found =
    Db.get_entry_by_path db ~library_id:lib.id
      ~relative_path:"2024/01/img.jpg"
  in
  Alcotest.(check bool) "found" true (Option.is_some found);
  let found = Option.get found in
  Alcotest.(check int) "same id" entry.id found.id;
  (* not found *)
  let missing =
    Db.get_entry_by_path db ~library_id:lib.id ~relative_path:"nope.jpg"
  in
  Alcotest.(check bool) "not found" true (Option.is_none missing);
  Db.close db

(* --- 6. Get entries by hash, by size --- *)

let test_get_entries_by_hash_and_size () =
  let db = fresh_db () in
  let lib =
    Db.create_library db ~name:"photos" ~location:"/photos" ~config_json:"{}"
  in
  let _e1 =
    Db.create_entry db ~library_id:lib.id ~relative_path:"a.jpg"
      ~file_size:1000 ~md5_hash:(Some "hash1") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let _e2 =
    Db.create_entry db ~library_id:lib.id ~relative_path:"b.jpg"
      ~file_size:1000 ~md5_hash:(Some "hash1") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  let _e3 =
    Db.create_entry db ~library_id:lib.id ~relative_path:"c.jpg"
      ~file_size:2000 ~md5_hash:(Some "hash2") ~capture_date:None
      ~camera_model:None ~original_path:None
  in
  (* by hash *)
  let by_hash =
    Db.get_entries_by_hash db ~library_id:lib.id ~md5_hash:"hash1"
  in
  Alcotest.(check int) "two with hash1" 2 (List.length by_hash);
  let by_hash2 =
    Db.get_entries_by_hash db ~library_id:lib.id ~md5_hash:"hash2"
  in
  Alcotest.(check int) "one with hash2" 1 (List.length by_hash2);
  let by_hash3 =
    Db.get_entries_by_hash db ~library_id:lib.id ~md5_hash:"nope"
  in
  Alcotest.(check int) "none with nope" 0 (List.length by_hash3);
  (* by size *)
  let by_size =
    Db.get_entries_by_size db ~library_id:lib.id ~file_size:1000
  in
  Alcotest.(check int) "two with size 1000" 2 (List.length by_size);
  let by_size2 =
    Db.get_entries_by_size db ~library_id:lib.id ~file_size:2000
  in
  Alcotest.(check int) "one with size 2000" 1 (List.length by_size2);
  Db.close db

(* --- 7. Insert file with status=discovered --- *)

let test_insert_file () =
  let db = fresh_db () in
  let file =
    Db.insert_file db ~source_path:"/tmp/img.jpg" ~source_type:"add"
      ~file_size:4096 ~file_modify_date:"2024-01-15T10:00:00Z"
  in
  Alcotest.(check bool) "id > 0" true (file.id > 0);
  Alcotest.(check string) "source_path" "/tmp/img.jpg" file.source_path;
  Alcotest.(check int) "file_size" 4096 file.file_size;
  Alcotest.(check string) "file_modify_date" "2024-01-15T10:00:00Z"
    file.file_modify_date;
  Alcotest.(check string) "status is discovered" "discovered"
    (file_status_to_string file.status);
  Alcotest.(check (option string)) "md5_hash is none" None file.md5_hash;
  Alcotest.(check (option string)) "capture_date is none" None
    file.capture_date;
  Alcotest.(check (option string)) "camera_model is none" None
    file.camera_model;
  Alcotest.(check (option string)) "target_path is none" None file.target_path;
  Alcotest.(check (option string)) "error_message is none" None
    file.error_message;
  Alcotest.(check (option string)) "hashed_at is none" None file.hashed_at;
  Db.close db

(* --- 8. Update file fields (hash, status) --- *)

let test_update_file () =
  let db = fresh_db () in
  let file =
    Db.insert_file db ~source_path:"/tmp/img.jpg" ~source_type:"add"
      ~file_size:4096 ~file_modify_date:"2024-01-15T10:00:00Z"
  in
  Db.update_file db file.id
    [
      ("md5_hash", Some "abc123");
      ("status", Some "hashed");
      ("hashed_at", Some "2024-01-15T10:01:00Z");
    ];
  let files = Db.query_files_by_status db Hashed in
  Alcotest.(check int) "one hashed" 1 (List.length files);
  let updated = List.hd files in
  Alcotest.(check (option string)) "hash set" (Some "abc123") updated.md5_hash;
  Alcotest.(check (option string)) "hashed_at set"
    (Some "2024-01-15T10:01:00Z") updated.hashed_at;
  (* Update with NULL value *)
  Db.update_file db file.id [ ("error_message", None) ];
  Db.close db

(* --- 9. Query files by status --- *)

let test_query_files_by_status () =
  let db = fresh_db () in
  let _f1 =
    Db.insert_file db ~source_path:"/a.jpg" ~source_type:"add" ~file_size:100
      ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  let _f2 =
    Db.insert_file db ~source_path:"/b.jpg" ~source_type:"add" ~file_size:200
      ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  let f3 =
    Db.insert_file db ~source_path:"/c.jpg" ~source_type:"init" ~file_size:300
      ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  let discovered = Db.query_files_by_status db Discovered in
  Alcotest.(check int) "three discovered" 3 (List.length discovered);
  Db.update_file db f3.id [ ("status", Some "hashed") ];
  let discovered2 = Db.query_files_by_status db Discovered in
  Alcotest.(check int) "two discovered" 2 (List.length discovered2);
  let hashed = Db.query_files_by_status db Hashed in
  Alcotest.(check int) "one hashed" 1 (List.length hashed);
  Db.close db

(* --- 10. Delete files by status --- *)

let test_delete_files_by_status () =
  let db = fresh_db () in
  let _f1 =
    Db.insert_file db ~source_path:"/a.jpg" ~source_type:"add" ~file_size:100
      ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  let f2 =
    Db.insert_file db ~source_path:"/b.jpg" ~source_type:"add" ~file_size:200
      ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  let f3 =
    Db.insert_file db ~source_path:"/c.jpg" ~source_type:"init" ~file_size:300
      ~file_modify_date:"2024-01-01T00:00:00Z"
  in
  Db.update_file db f2.id [ ("status", Some "imported") ];
  Db.update_file db f3.id [ ("status", Some "hashed") ];
  Db.delete_files_by_status db [ Discovered; Hashed ];
  let remaining = Db.query_files_by_status db Imported in
  Alcotest.(check int) "one imported remains" 1 (List.length remaining);
  let discovered = Db.query_files_by_status db Discovered in
  Alcotest.(check int) "no discovered" 0 (List.length discovered);
  let hashed = Db.query_files_by_status db Hashed in
  Alcotest.(check int) "no hashed" 0 (List.length hashed);
  Db.close db

(* --- 11. import_file atomicity --- *)

let test_import_file () =
  let db = fresh_db () in
  let lib =
    Db.create_library db ~name:"photos" ~location:"/photos" ~config_json:"{}"
  in
  let file =
    Db.insert_file db ~source_path:"/tmp/img.jpg" ~source_type:"add"
      ~file_size:4096 ~file_modify_date:"2024-01-15T10:00:00Z"
  in
  Db.update_file db file.id
    [ ("md5_hash", Some "deadbeef"); ("status", Some "hashed") ];
  let entry =
    Db.import_file db ~file_id:file.id ~library_id:lib.id
      ~relative_path:"2024/01/img.jpg" ~file_size:4096 ~md5_hash:"deadbeef"
      ~capture_date:(Some "2024-01-15T12:00:00Z")
      ~camera_model:(Some "Canon R5")
      ~original_path:(Some "/tmp/img.jpg")
  in
  Alcotest.(check bool) "entry id > 0" true (entry.id > 0);
  Alcotest.(check int) "library_id" lib.id entry.library_id;
  Alcotest.(check string) "relative_path" "2024/01/img.jpg"
    entry.relative_path;
  Alcotest.(check int) "file_size" 4096 entry.file_size;
  Alcotest.(check (option string)) "md5_hash" (Some "deadbeef") entry.md5_hash;
  let imported = Db.query_files_by_status db Imported in
  Alcotest.(check int) "one imported" 1 (List.length imported);
  Alcotest.(check int) "same file id" file.id (List.hd imported).id;
  Db.close db

(* --- 12. update_file rejects invalid column names --- *)

let test_update_file_rejects_invalid_columns () =
  let db = fresh_db () in
  let file =
    Db.insert_file db ~source_path:"/tmp/img.jpg" ~source_type:"add"
      ~file_size:4096 ~file_modify_date:"2024-01-15T10:00:00Z"
  in
  let raised = ref false in
  (try
     Db.update_file db file.id
       [ ("robert_tables; DROP TABLE files;--", Some "x") ]
   with Invalid_argument _ -> raised := true);
  Alcotest.(check bool) "invalid column rejected" true !raised;
  Db.close db

(* --- Additional: update_library_config and update_library_location --- *)

let test_update_library () =
  let db = fresh_db () in
  let lib =
    Db.create_library db ~name:"photos" ~location:"/photos" ~config_json:"{}"
  in
  Db.update_library_config db lib.id "{\"key\":\"value\"}";
  let updated = Db.get_library_by_id db lib.id in
  Alcotest.(check string) "config updated" "{\"key\":\"value\"}"
    (Option.get updated).config_json;
  Db.update_library_location db lib.id "/new/photos";
  let updated2 = Db.get_library_by_id db lib.id in
  Alcotest.(check string) "location updated" "/new/photos"
    (Option.get updated2).location;
  Db.close db

(* --- Additional: update_entry_hash --- *)

let test_update_entry_hash () =
  let db = fresh_db () in
  let lib =
    Db.create_library db ~name:"photos" ~location:"/photos" ~config_json:"{}"
  in
  let entry =
    Db.create_entry db ~library_id:lib.id ~relative_path:"a.jpg"
      ~file_size:1000 ~md5_hash:None ~capture_date:None ~camera_model:None
      ~original_path:None
  in
  Alcotest.(check (option string)) "initially none" None entry.md5_hash;
  Db.update_entry_hash db entry.id "newhash";
  let found =
    Db.get_entry_by_path db ~library_id:lib.id ~relative_path:"a.jpg"
  in
  Alcotest.(check (option string)) "hash updated" (Some "newhash")
    (Option.get found).md5_hash;
  Db.close db

(* --- Additional: delete_file --- *)

let test_delete_file () =
  let db = fresh_db () in
  let file =
    Db.insert_file db ~source_path:"/tmp/img.jpg" ~source_type:"add"
      ~file_size:4096 ~file_modify_date:"2024-01-15T10:00:00Z"
  in
  let before = Db.query_files_by_status db Discovered in
  Alcotest.(check int) "one before" 1 (List.length before);
  Db.delete_file db file.id;
  let after = Db.query_files_by_status db Discovered in
  Alcotest.(check int) "none after" 0 (List.length after);
  Db.close db

(* --- Additional: schema version and migrations --- *)

let test_schema_version () =
  let db = fresh_db () in
  let raw = Db.raw_db db in
  let version = ref 0 in
  let _rc =
    Sqlite3.exec raw
      ~cb:(fun row _headers ->
        match row.(0) with
        | Some v -> version := int_of_string v
        | None -> ())
      "SELECT version FROM schema_version"
  in
  Alcotest.(check int) "schema version is 2" 2 !version;
  Db.close db

let () =
  Alcotest.run "db"
    [
      ( "schema",
        [
          Alcotest.test_case "tables exist" `Quick test_tables_exist;
          Alcotest.test_case "schema version" `Quick test_schema_version;
        ] );
      ( "libraries",
        [
          Alcotest.test_case "create and get" `Quick
            test_create_and_get_library;
          Alcotest.test_case "list" `Quick test_list_libraries;
          Alcotest.test_case "delete cascades" `Quick
            test_delete_library_cascades;
          Alcotest.test_case "update config/location" `Quick
            test_update_library;
        ] );
      ( "entries",
        [
          Alcotest.test_case "create and get by path" `Quick
            test_create_entry_get_by_path;
          Alcotest.test_case "get by hash and size" `Quick
            test_get_entries_by_hash_and_size;
          Alcotest.test_case "update entry hash" `Quick test_update_entry_hash;
        ] );
      ( "files",
        [
          Alcotest.test_case "insert file" `Quick test_insert_file;
          Alcotest.test_case "update file" `Quick test_update_file;
          Alcotest.test_case "query by status" `Quick
            test_query_files_by_status;
          Alcotest.test_case "delete by status" `Quick
            test_delete_files_by_status;
          Alcotest.test_case "delete file" `Quick test_delete_file;
          Alcotest.test_case "reject invalid columns" `Quick
            test_update_file_rejects_invalid_columns;
        ] );
      ( "import",
        [
          Alcotest.test_case "import_file atomicity" `Quick test_import_file;
        ] );
    ]

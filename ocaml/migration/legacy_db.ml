open Legacy_types

type t = { db : Sqlite3.db }

let finalize_ignore stmt =
  ignore (Sqlite3.finalize stmt)

let db_error ?(context = []) message =
  Utils.app_error ~code:Domain.Db_error ~context message

let invalid_state ?(context = []) message =
  Utils.app_error ~code:Domain.Invalid_state ~context message

let filesystem_error ?(context = []) message =
  Utils.app_error ~code:Domain.Filesystem_io_error ~context message

let sqlite_error ?(context = []) ~message rc =
  Error
    (db_error
       ~context:(("rc", Sqlite3.Rc.to_string rc) :: context)
       message)

let opt_text stmt col =
  if Sqlite3.column_is_null stmt col then None
  else Some (Sqlite3.column_text stmt col)

let map_exn ?(context = []) ~message exn =
  match exn with
  | Sys_error detail ->
    filesystem_error ~context:(("detail", detail) :: context) message
  | Invalid_argument detail ->
    invalid_state ~context:(("detail", detail) :: context) message
  | Failure detail ->
    db_error ~context:(("detail", detail) :: context) message
  | exn ->
    db_error
      ~context:(("detail", Printexc.to_string exn) :: context)
      message

let with_exn_result ?(context = []) ~message f =
  try f () with
  | exn -> Error (map_exn ~context ~message exn)

let open_readonly ~path =
  if String.equal path "" then
    Error
      (invalid_state
         ~context:[ ("path", path) ]
         "legacy database path is empty")
  else if not (Sys.file_exists path) then
    Error
      (Utils.app_error ~code:Domain.Filesystem_not_found
         ~context:[ ("path", path) ]
         "legacy database path does not exist")
  else
    with_exn_result
      ~message:"failed to open legacy database"
      ~context:[ ("path", path) ]
      (fun () ->
        let db = Sqlite3.db_open path in
        match Sqlite3.exec db "PRAGMA query_only=ON" with
        | Sqlite3.Rc.OK -> Ok { db }
        | rc ->
          ignore (Sqlite3.db_close db);
          sqlite_error ~context:[ ("path", path) ]
            ~message:"failed to enable sqlite query_only mode" rc)

let close t =
  ignore (Sqlite3.db_close t.db)

let raw_db t = t.db

let schema_version t =
  with_exn_result ~message:"failed to read legacy schema version" (fun () ->
      let stmt =
        Sqlite3.prepare t.db "SELECT version FROM schema_version LIMIT 1"
      in
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW ->
        let result = Sqlite3.column_int stmt 0 in
        finalize_ignore stmt;
        Ok result
      | Sqlite3.Rc.DONE ->
        finalize_ignore stmt;
        Error
          (invalid_state
             "legacy schema_version table is missing its version row")
      | rc ->
        finalize_ignore stmt;
        sqlite_error ~message:"failed to step legacy schema_version query" rc)

let read_library stmt =
  {
    id = Sqlite3.column_int stmt 0;
    name = Sqlite3.column_text stmt 1;
    location = Sqlite3.column_text stmt 2;
    config_json = Sqlite3.column_text stmt 3;
    created_at = Sqlite3.column_text stmt 4;
  }

let read_entry stmt =
  {
    id = Sqlite3.column_int stmt 0;
    library_id = Sqlite3.column_int stmt 1;
    relative_path = Sqlite3.column_text stmt 2;
    file_size = Sqlite3.column_int stmt 3;
    md5_hash = opt_text stmt 4;
    capture_date = opt_text stmt 5;
    camera_model = opt_text stmt 6;
    imported_at = Sqlite3.column_text stmt 7;
    original_path = opt_text stmt 8;
  }

let read_file_row stmt =
  {
    id = Sqlite3.column_int stmt 0;
    source_path = Sqlite3.column_text stmt 1;
    source_type = Sqlite3.column_text stmt 2;
    file_size = Sqlite3.column_int stmt 3;
    file_modify_date = Sqlite3.column_text stmt 4;
    md5_hash = opt_text stmt 5;
    capture_date = opt_text stmt 6;
    camera_model = opt_text stmt 7;
    target_path = opt_text stmt 8;
    status = Sqlite3.column_text stmt 9;
    error_message = opt_text stmt 10;
    discovered_at = Sqlite3.column_text stmt 11;
    hashed_at = opt_text stmt 12;
  }

let collect_rows stmt read_row =
  let acc = ref [] in
  let rec loop () =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      acc := read_row stmt :: !acc;
      loop ()
    | Sqlite3.Rc.DONE ->
      finalize_ignore stmt;
      Ok (List.rev !acc)
    | rc ->
      finalize_ignore stmt;
      sqlite_error ~message:"failed to step legacy query" rc
  in
  loop ()

let list_libraries t =
  with_exn_result ~message:"failed to list legacy libraries" (fun () ->
      let stmt =
        Sqlite3.prepare t.db
          "SELECT id, name, location, config, created_at FROM libraries ORDER \
           BY id"
      in
      collect_rows stmt read_library)

let list_entries t =
  with_exn_result ~message:"failed to list legacy entries" (fun () ->
      let stmt =
        Sqlite3.prepare t.db
          "SELECT id, library_id, relative_path, file_size, md5_hash, \
           capture_date, camera_model, imported_at, original_path FROM entries \
           ORDER BY id"
      in
      collect_rows stmt read_entry)

let list_files t =
  with_exn_result ~message:"failed to list legacy files" (fun () ->
      let stmt =
        Sqlite3.prepare t.db
          "SELECT id, source_path, source_type, file_size, file_modify_date, \
           md5_hash, capture_date, camera_model, target_path, status, \
           error_message, discovered_at, hashed_at FROM files ORDER BY id"
      in
      collect_rows stmt read_file_row)

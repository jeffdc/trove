open Legacy_domain

type t = { db : Sqlite3.db }

exception Legacy_db_error of Domain.app_error

(* ---------- Helpers ---------- *)

let raise_db_error ?(context = []) message =
  raise (Legacy_db_error (Utils.app_error ~code:Domain.Db_error ~context message))

let raise_invalid_state ?(context = []) message =
  raise
    (Legacy_db_error
       (Utils.app_error ~code:Domain.Invalid_state ~context message))

let exec_exn db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> ()
  | rc ->
    raise_db_error
      ~context:[ ("rc", Sqlite3.Rc.to_string rc); ("sql", sql) ]
      "sqlite exec failed"

let bind_text stmt pos s =
  match Sqlite3.bind_text stmt pos s with
  | Sqlite3.Rc.OK -> ()
  | rc ->
    raise_db_error
      ~context:
        [
          ("op", "bind_text");
          ("position", string_of_int pos);
          ("rc", Sqlite3.Rc.to_string rc);
        ]
      "sqlite bind_text failed"

let bind_int stmt pos n =
  match Sqlite3.bind_int stmt pos n with
  | Sqlite3.Rc.OK -> ()
  | rc ->
    raise_db_error
      ~context:
        [
          ("op", "bind_int");
          ("position", string_of_int pos);
          ("rc", Sqlite3.Rc.to_string rc);
        ]
      "sqlite bind_int failed"

let bind_opt_text stmt pos = function
  | Some s -> bind_text stmt pos s
  | None ->
    match Sqlite3.bind stmt pos Sqlite3.Data.NULL with
    | Sqlite3.Rc.OK -> ()
    | rc ->
      raise_db_error
        ~context:
          [
            ("op", "bind_null");
            ("position", string_of_int pos);
            ("rc", Sqlite3.Rc.to_string rc);
          ]
        "sqlite bind NULL failed"

let step_exn stmt =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> ()
  | Sqlite3.Rc.ROW -> ()
  | rc ->
    raise_db_error ~context:[ ("rc", Sqlite3.Rc.to_string rc) ]
      "sqlite step failed"

let step_done stmt =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> ()
  | rc ->
    raise_db_error ~context:[ ("rc", Sqlite3.Rc.to_string rc) ]
      "sqlite step_done failed"

let opt_text stmt col =
  if Sqlite3.column_is_null stmt col then None
  else Some (Sqlite3.column_text stmt col)

let finalize_exn stmt =
  match Sqlite3.finalize stmt with
  | Sqlite3.Rc.OK -> ()
  | rc ->
    raise_db_error ~context:[ ("rc", Sqlite3.Rc.to_string rc) ]
      "sqlite finalize failed"

(* ---------- Schema ---------- *)

let create_tables_sql =
  {|
  CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER NOT NULL
  );

  CREATE TABLE IF NOT EXISTS libraries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    location TEXT NOT NULL,
    config TEXT NOT NULL DEFAULT '{}',
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
    relative_path TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    md5_hash TEXT,
    capture_date TEXT,
    camera_model TEXT,
    imported_at TEXT NOT NULL,
    original_path TEXT,
    UNIQUE(library_id, relative_path)
  );

  CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_path TEXT NOT NULL,
    source_type TEXT NOT NULL,
    file_size INTEGER NOT NULL,
    file_modify_date TEXT NOT NULL,
    md5_hash TEXT,
    capture_date TEXT,
    camera_model TEXT,
    target_path TEXT,
    status TEXT NOT NULL,
    error_message TEXT,
    discovered_at TEXT NOT NULL,
    hashed_at TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_entries_library_hash
    ON entries(library_id, md5_hash);
  CREATE INDEX IF NOT EXISTS idx_entries_library_path
    ON entries(library_id, relative_path);
  CREATE INDEX IF NOT EXISTS idx_entries_library_size
    ON entries(library_id, file_size);
  CREATE INDEX IF NOT EXISTS idx_files_source_path
    ON files(source_path);
  CREATE INDEX IF NOT EXISTS idx_files_md5_hash
    ON files(md5_hash);
  CREATE INDEX IF NOT EXISTS idx_files_status
    ON files(status);
|}

let get_schema_version db =
  (* Check if schema_version table has any rows *)
  let stmt = Sqlite3.prepare db "SELECT version FROM schema_version LIMIT 1" in
  let result =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Sqlite3.column_int stmt 0
    | _ -> 0
  in
  finalize_exn stmt;
  result

let set_schema_version db v =
  exec_exn db "DELETE FROM schema_version";
  let stmt =
    Sqlite3.prepare db "INSERT INTO schema_version (version) VALUES (?)"
  in
  bind_int stmt 1 v;
  step_done stmt;
  finalize_exn stmt

let run_migrations db =
  let version = get_schema_version db in
  (* Migration v1: add config column to libraries.
     Since we CREATE TABLE with config already, this is a no-op for fresh DBs.
     For existing DBs without config, we add it. *)
  if version < 1 then begin
    (* The column already exists from CREATE TABLE IF NOT EXISTS, so we
       only run ALTER TABLE if the column doesn't exist yet.
       SQLite doesn't have IF NOT EXISTS for ALTER TABLE, so we catch the error. *)
    (match Sqlite3.exec db
             "ALTER TABLE libraries ADD COLUMN config TEXT NOT NULL DEFAULT '{}'"
     with
     | Sqlite3.Rc.OK -> ()
     | _ -> () (* column already exists from CREATE TABLE *))
  end;
  (* Migration v2: add original_path column to entries *)
  if version < 2 then begin
    (match Sqlite3.exec db
             "ALTER TABLE entries ADD COLUMN original_path TEXT"
     with
     | Sqlite3.Rc.OK -> ()
     | _ -> () (* column already exists *))
  end;
  if version < 2 then set_schema_version db 2

(* ---------- open / close ---------- *)

let open_db path =
  (* Create parent directories for file-based databases *)
  if path <> ":memory:" && path <> "" then begin
    let dir = Filename.dirname path in
    (* Recursive mkdir *)
    let rec mkdir_p d =
      if d <> "/" && d <> "." && not (Sys.file_exists d) then begin
        mkdir_p (Filename.dirname d);
        Unix.mkdir d 0o755
      end
    in
    mkdir_p dir
  end;
  let db = Sqlite3.db_open path in
  exec_exn db "PRAGMA journal_mode=WAL";
  exec_exn db "PRAGMA foreign_keys=ON";
  exec_exn db create_tables_sql;
  run_migrations db;
  { db }

let close t =
  ignore (Sqlite3.db_close t.db)

let raw_db t = t.db

(* ---------- Libraries ---------- *)

let read_library stmt =
  {
    id = Sqlite3.column_int stmt 0;
    name = Sqlite3.column_text stmt 1;
    location = Sqlite3.column_text stmt 2;
    config_json = Sqlite3.column_text stmt 3;
    created_at = Sqlite3.column_text stmt 4;
  }

let create_library t ~name ~location ~config_json =
  let now = Utils.now_iso () in
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO libraries (name, location, config, created_at) \
       VALUES (?, ?, ?, ?)"
  in
  bind_text stmt 1 name;
  bind_text stmt 2 location;
  bind_text stmt 3 config_json;
  bind_text stmt 4 now;
  step_done stmt;
  finalize_exn stmt;
  let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
  { id; name; location; config_json; created_at = now }

let get_library t name =
  let stmt =
    Sqlite3.prepare t.db
      "SELECT id, name, location, config, created_at \
       FROM libraries WHERE name = ?"
  in
  bind_text stmt 1 name;
  let result =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (read_library stmt)
    | _ -> None
  in
  finalize_exn stmt;
  result

let get_library_by_id t id =
  let stmt =
    Sqlite3.prepare t.db
      "SELECT id, name, location, config, created_at \
       FROM libraries WHERE id = ?"
  in
  bind_int stmt 1 id;
  let result =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (read_library stmt)
    | _ -> None
  in
  finalize_exn stmt;
  result

let list_libraries t =
  let stmt =
    Sqlite3.prepare t.db
      "SELECT id, name, location, config, created_at FROM libraries"
  in
  let acc = ref [] in
  let rec loop () =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      acc := read_library stmt :: !acc;
      loop ()
    | _ -> ()
  in
  loop ();
  finalize_exn stmt;
  List.rev !acc

let update_library_config t id config_json =
  let stmt =
    Sqlite3.prepare t.db "UPDATE libraries SET config = ? WHERE id = ?"
  in
  bind_text stmt 1 config_json;
  bind_int stmt 2 id;
  step_done stmt;
  finalize_exn stmt

let update_library_location t id location =
  let stmt =
    Sqlite3.prepare t.db "UPDATE libraries SET location = ? WHERE id = ?"
  in
  bind_text stmt 1 location;
  bind_int stmt 2 id;
  step_done stmt;
  finalize_exn stmt

let delete_library t id =
  let stmt = Sqlite3.prepare t.db "DELETE FROM libraries WHERE id = ?" in
  bind_int stmt 1 id;
  step_done stmt;
  finalize_exn stmt

(* ---------- Entries ---------- *)

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

let entry_columns =
  "id, library_id, relative_path, file_size, md5_hash, capture_date, \
   camera_model, imported_at, original_path"

let create_entry t ~library_id ~relative_path ~file_size ~md5_hash
    ~capture_date ~camera_model ~original_path =
  let now = Utils.now_iso () in
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO entries (library_id, relative_path, file_size, md5_hash, \
       capture_date, camera_model, imported_at, original_path) \
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
  in
  bind_int stmt 1 library_id;
  bind_text stmt 2 relative_path;
  bind_int stmt 3 file_size;
  bind_opt_text stmt 4 md5_hash;
  bind_opt_text stmt 5 capture_date;
  bind_opt_text stmt 6 camera_model;
  bind_text stmt 7 now;
  bind_opt_text stmt 8 original_path;
  step_done stmt;
  finalize_exn stmt;
  let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
  {
    id;
    library_id;
    relative_path;
    file_size;
    md5_hash;
    capture_date;
    camera_model;
    imported_at = now;
    original_path;
  }

let get_entry_by_path t ~library_id ~relative_path =
  let stmt =
    Sqlite3.prepare t.db
      (Printf.sprintf
         "SELECT %s FROM entries WHERE library_id = ? AND relative_path = ?"
         entry_columns)
  in
  bind_int stmt 1 library_id;
  bind_text stmt 2 relative_path;
  let result =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (read_entry stmt)
    | _ -> None
  in
  finalize_exn stmt;
  result

let collect_entries stmt =
  let acc = ref [] in
  let rec loop () =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      acc := read_entry stmt :: !acc;
      loop ()
    | _ -> ()
  in
  loop ();
  finalize_exn stmt;
  List.rev !acc

let get_entries_by_hash t ~library_id ~md5_hash =
  let stmt =
    Sqlite3.prepare t.db
      (Printf.sprintf
         "SELECT %s FROM entries WHERE library_id = ? AND md5_hash = ?"
         entry_columns)
  in
  bind_int stmt 1 library_id;
  bind_text stmt 2 md5_hash;
  collect_entries stmt

let get_entries_by_size t ~library_id ~file_size =
  let stmt =
    Sqlite3.prepare t.db
      (Printf.sprintf
         "SELECT %s FROM entries WHERE library_id = ? AND file_size = ?"
         entry_columns)
  in
  bind_int stmt 1 library_id;
  bind_int stmt 2 file_size;
  collect_entries stmt

let list_entries t library_id =
  let stmt =
    Sqlite3.prepare t.db
      (Printf.sprintf
         "SELECT %s FROM entries WHERE library_id = ?" entry_columns)
  in
  bind_int stmt 1 library_id;
  collect_entries stmt

let update_entry_hash t entry_id hash =
  let stmt =
    Sqlite3.prepare t.db "UPDATE entries SET md5_hash = ? WHERE id = ?"
  in
  bind_text stmt 1 hash;
  bind_int stmt 2 entry_id;
  step_done stmt;
  finalize_exn stmt

(* ---------- Files ---------- *)

let file_columns =
  "id, source_path, file_size, file_modify_date, md5_hash, capture_date, \
   camera_model, target_path, status, error_message, discovered_at, hashed_at"

let read_file_record stmt =
  {
    id = Sqlite3.column_int stmt 0;
    source_path = Sqlite3.column_text stmt 1;
    file_size = Sqlite3.column_int stmt 2;
    file_modify_date = Sqlite3.column_text stmt 3;
    md5_hash = opt_text stmt 4;
    capture_date = opt_text stmt 5;
    camera_model = opt_text stmt 6;
    target_path = opt_text stmt 7;
    status = file_status_of_string (Sqlite3.column_text stmt 8);
    error_message = opt_text stmt 9;
    discovered_at = Sqlite3.column_text stmt 10;
    hashed_at = opt_text stmt 11;
  }

let allowed_file_columns =
  [
    "source_path";
    "source_type";
    "file_size";
    "file_modify_date";
    "md5_hash";
    "capture_date";
    "camera_model";
    "target_path";
    "status";
    "error_message";
    "discovered_at";
    "hashed_at";
  ]

let insert_file t ~source_path ~source_type ~file_size ~file_modify_date =
  let now = Utils.now_iso () in
  let status_str = file_status_to_string Discovered in
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO files (source_path, source_type, file_size, \
       file_modify_date, status, discovered_at) \
       VALUES (?, ?, ?, ?, ?, ?)"
  in
  bind_text stmt 1 source_path;
  bind_text stmt 2 source_type;
  bind_int stmt 3 file_size;
  bind_text stmt 4 file_modify_date;
  bind_text stmt 5 status_str;
  bind_text stmt 6 now;
  step_done stmt;
  finalize_exn stmt;
  let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
  {
    id;
    source_path;
    file_size;
    file_modify_date;
    md5_hash = None;
    capture_date = None;
    camera_model = None;
    target_path = None;
    status = Discovered;
    error_message = None;
    discovered_at = now;
    hashed_at = None;
  }

let update_file t id updates =
  if updates = [] then ()
  else begin
    (* Validate column names *)
    List.iter
      (fun (col, _) ->
        if not (List.mem col allowed_file_columns) then
          raise_invalid_state ~context:[ ("column", col) ]
            "update_file received an invalid column")
      updates;
    (* Build SET clause *)
    let set_parts =
      List.mapi (fun _i (col, _) -> Printf.sprintf "%s = ?" col) updates
    in
    let sql =
      Printf.sprintf "UPDATE files SET %s WHERE id = ?"
        (String.concat ", " set_parts)
    in
    let stmt = Sqlite3.prepare t.db sql in
    List.iteri
      (fun i (_, v) -> bind_opt_text stmt (i + 1) v)
      updates;
    bind_int stmt (List.length updates + 1) id;
    step_done stmt;
    finalize_exn stmt
  end

let collect_file_records stmt =
  let acc = ref [] in
  let rec loop () =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW ->
      acc := read_file_record stmt :: !acc;
      loop ()
    | _ -> ()
  in
  loop ();
  finalize_exn stmt;
  List.rev !acc

let get_file_by_path t source_path =
  let stmt =
    Sqlite3.prepare t.db
      (Printf.sprintf "SELECT %s FROM files WHERE source_path = ?" file_columns)
  in
  bind_text stmt 1 source_path;
  let result =
    match Sqlite3.step stmt with
    | Sqlite3.Rc.ROW -> Some (read_file_record stmt)
    | _ -> None
  in
  finalize_exn stmt;
  result

let query_files_by_ids t ids =
  match ids with
  | [] -> []
  | _ ->
    let placeholders =
      String.concat ", " (List.map (fun _ -> "?") ids)
    in
    let sql =
      Printf.sprintf "SELECT %s FROM files WHERE id IN (%s)"
        file_columns placeholders
    in
    let stmt = Sqlite3.prepare t.db sql in
    List.iteri (fun i id -> bind_int stmt (i + 1) id) ids;
    collect_file_records stmt

let query_files_by_status t status =
  let stmt =
    Sqlite3.prepare t.db
      (Printf.sprintf "SELECT %s FROM files WHERE status = ?" file_columns)
  in
  bind_text stmt 1 (file_status_to_string status);
  collect_file_records stmt

let delete_files_by_status t statuses =
  match statuses with
  | [] -> ()
  | _ ->
    let placeholders =
      String.concat ", " (List.map (fun _ -> "?") statuses)
    in
    let sql =
      Printf.sprintf "DELETE FROM files WHERE status IN (%s)" placeholders
    in
    let stmt = Sqlite3.prepare t.db sql in
    List.iteri
      (fun i s -> bind_text stmt (i + 1) (file_status_to_string s))
      statuses;
    step_done stmt;
    finalize_exn stmt

let delete_file t id =
  let stmt = Sqlite3.prepare t.db "DELETE FROM files WHERE id = ?" in
  bind_int stmt 1 id;
  step_done stmt;
  finalize_exn stmt

(* ---------- Atomic import ---------- *)

let import_file t ~file_id ~library_id ~relative_path ~file_size ~md5_hash
    ~capture_date ~camera_model ~original_path =
  exec_exn t.db "BEGIN IMMEDIATE";
  try
    let now = Utils.now_iso () in
    (* Insert entry *)
    let stmt =
      Sqlite3.prepare t.db
        "INSERT INTO entries (library_id, relative_path, file_size, md5_hash, \
         capture_date, camera_model, imported_at, original_path) \
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    in
    bind_int stmt 1 library_id;
    bind_text stmt 2 relative_path;
    bind_int stmt 3 file_size;
    bind_text stmt 4 md5_hash;
    bind_opt_text stmt 5 capture_date;
    bind_opt_text stmt 6 camera_model;
    bind_text stmt 7 now;
    bind_opt_text stmt 8 original_path;
    step_done stmt;
    finalize_exn stmt;
    let entry_id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
    (* Update file status to imported *)
    let stmt2 =
      Sqlite3.prepare t.db "UPDATE files SET status = ? WHERE id = ?"
    in
    bind_text stmt2 1 (file_status_to_string Imported);
    bind_int stmt2 2 file_id;
    step_done stmt2;
    finalize_exn stmt2;
    exec_exn t.db "COMMIT";
    {
      id = entry_id;
      library_id;
      relative_path;
      file_size;
      md5_hash = Some md5_hash;
      capture_date;
      camera_model;
      imported_at = now;
      original_path;
    }
  with exn ->
    (try exec_exn t.db "ROLLBACK" with _ -> ());
    raise exn

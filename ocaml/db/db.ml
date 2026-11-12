open Domain

type t = { db : Sqlite3.db }

let ( let* ) = Result.bind

let db_error ?(context = []) message =
  Utils.app_error ~code:Db_error ~context message

let sqlite_error ?(context = []) ~message rc =
  Error
    (db_error
       ~context:(("rc", Sqlite3.Rc.to_string rc) :: context)
       message)

let exec_result db sql =
  match Sqlite3.exec db sql with
  | Sqlite3.Rc.OK -> Ok ()
  | rc -> sqlite_error ~message:"sqlite exec failed" ~context:[ ("sql", sql) ] rc

let bind_text_result stmt pos s =
  match Sqlite3.bind_text stmt pos s with
  | Sqlite3.Rc.OK -> Ok ()
  | rc ->
    sqlite_error ~message:"sqlite bind_text failed"
      ~context:[ ("position", string_of_int pos); ("value", s) ] rc

let bind_int_result stmt pos n =
  match Sqlite3.bind_int stmt pos n with
  | Sqlite3.Rc.OK -> Ok ()
  | rc ->
    sqlite_error ~message:"sqlite bind_int failed"
      ~context:
        [ ("position", string_of_int pos); ("value", string_of_int n) ]
      rc

let bind_null_result stmt pos =
  match Sqlite3.bind stmt pos Sqlite3.Data.NULL with
  | Sqlite3.Rc.OK -> Ok ()
  | rc ->
    sqlite_error ~message:"sqlite bind_null failed"
      ~context:[ ("position", string_of_int pos) ] rc

let bind_opt_text_result stmt pos = function
  | Some s -> bind_text_result stmt pos s
  | None -> bind_null_result stmt pos

let bind_opt_int_result stmt pos = function
  | Some n -> bind_int_result stmt pos n
  | None -> bind_null_result stmt pos

let step_done_result stmt =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.DONE -> Ok ()
  | rc -> sqlite_error ~message:"sqlite step_done failed" rc

let step_row_opt_result stmt read_fn =
  match Sqlite3.step stmt with
  | Sqlite3.Rc.ROW -> Ok (Some (read_fn stmt))
  | Sqlite3.Rc.DONE -> Ok None
  | rc -> sqlite_error ~message:"sqlite step failed" rc

let finalize_ignore stmt =
  ignore (Sqlite3.finalize stmt)

let with_stmt db sql f =
  let stmt = Sqlite3.prepare db sql in
  Fun.protect ~finally:(fun () -> finalize_ignore stmt) (fun () -> f stmt)

let opt_text stmt col =
  if Sqlite3.column_is_null stmt col then None
  else Some (Sqlite3.column_text stmt col)

let opt_int stmt col =
  if Sqlite3.column_is_null stmt col then None
  else Some (Sqlite3.column_int stmt col)

let create_tables_sql =
  {|
  CREATE TABLE IF NOT EXISTS libraries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    root_path TEXT NOT NULL UNIQUE,
    config_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS source_roots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL REFERENCES libraries(id),
    root_path TEXT NOT NULL,
    source_kind TEXT NOT NULL,
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL REFERENCES libraries(id),
    source_root_id INTEGER REFERENCES source_roots(id),
    mode TEXT NOT NULL,
    status TEXT NOT NULL,
    options_json TEXT,
    summary_json TEXT,
    error_text TEXT,
    started_at TEXT NOT NULL,
    completed_at TEXT
  );

  CREATE TABLE IF NOT EXISTS file_objects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_hash TEXT NOT NULL UNIQUE,
    hash_algorithm TEXT NOT NULL,
    blake2b_256_hash TEXT UNIQUE,
    size_bytes INTEGER NOT NULL,
    quick_signature TEXT,
    capture_date TEXT,
    camera_model TEXT,
    original_filename TEXT,
    extension TEXT,
    mime_type TEXT,
    metadata_json TEXT,
    metadata_extracted_at TEXT,
    metadata_tool TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS source_observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER NOT NULL REFERENCES runs(id),
    source_root_id INTEGER NOT NULL REFERENCES source_roots(id),
    observed_path TEXT NOT NULL,
    relative_path TEXT,
    size_bytes INTEGER,
    mtime TEXT,
    observed_at TEXT NOT NULL,
    file_object_id INTEGER REFERENCES file_objects(id),
    UNIQUE(run_id, observed_path)
  );

  CREATE TABLE IF NOT EXISTS run_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER NOT NULL REFERENCES runs(id),
    source_observation_id INTEGER REFERENCES source_observations(id),
    file_object_id INTEGER REFERENCES file_objects(id),
    workflow_state TEXT NOT NULL,
    planned_action TEXT,
    disposition TEXT,
    planned_relative_path TEXT,
    failure_reason TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS library_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_id INTEGER NOT NULL REFERENCES libraries(id),
    file_object_id INTEGER NOT NULL REFERENCES file_objects(id),
    admitted_from_run_item_id INTEGER REFERENCES run_items(id),
    status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(library_id, file_object_id)
  );

  CREATE TABLE IF NOT EXISTS library_placements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    library_item_id INTEGER NOT NULL REFERENCES library_items(id),
    library_id INTEGER NOT NULL REFERENCES libraries(id),
    intended_relative_path TEXT NOT NULL,
    actual_relative_path TEXT,
    placement_status TEXT NOT NULL,
    last_verified_at TEXT,
    error_text TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(library_item_id),
    UNIQUE(library_id, intended_relative_path)
  );

  CREATE TABLE IF NOT EXISTS file_ops (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id INTEGER NOT NULL REFERENCES runs(id),
    run_item_id INTEGER REFERENCES run_items(id),
    library_item_id INTEGER REFERENCES library_items(id),
    op_kind TEXT NOT NULL,
    src_path TEXT,
    dst_path TEXT,
    status TEXT NOT NULL,
    error_text TEXT,
    started_at TEXT NOT NULL,
    completed_at TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_source_roots_library_id
    ON source_roots(library_id);
  CREATE INDEX IF NOT EXISTS idx_runs_library_started
    ON runs(library_id, started_at DESC);
  CREATE INDEX IF NOT EXISTS idx_runs_library_status
    ON runs(library_id, status);
  CREATE INDEX IF NOT EXISTS idx_source_observations_source_root_id
    ON source_observations(source_root_id);
  CREATE INDEX IF NOT EXISTS idx_source_observations_file_object_id
    ON source_observations(file_object_id);
  CREATE INDEX IF NOT EXISTS idx_file_objects_capture_date
    ON file_objects(capture_date);
  CREATE INDEX IF NOT EXISTS idx_file_objects_camera_model
    ON file_objects(camera_model);
  CREATE INDEX IF NOT EXISTS idx_file_objects_size_bytes
    ON file_objects(size_bytes);
  CREATE INDEX IF NOT EXISTS idx_file_objects_original_filename
    ON file_objects(original_filename);
  CREATE INDEX IF NOT EXISTS idx_file_objects_extension
    ON file_objects(extension);
  CREATE INDEX IF NOT EXISTS idx_run_items_run_id
    ON run_items(run_id);
  CREATE INDEX IF NOT EXISTS idx_run_items_run_state
    ON run_items(run_id, workflow_state);
  CREATE INDEX IF NOT EXISTS idx_run_items_run_disposition
    ON run_items(run_id, disposition);
  CREATE INDEX IF NOT EXISTS idx_run_items_file_object_id
    ON run_items(file_object_id);
  CREATE INDEX IF NOT EXISTS idx_library_items_library_id
    ON library_items(library_id);
  CREATE INDEX IF NOT EXISTS idx_library_items_file_object_id
    ON library_items(file_object_id);
  CREATE INDEX IF NOT EXISTS idx_library_placements_status
    ON library_placements(placement_status);
  CREATE INDEX IF NOT EXISTS idx_library_placements_library_status
    ON library_placements(library_id, placement_status);
  CREATE INDEX IF NOT EXISTS idx_file_ops_run_id
    ON file_ops(run_id);
  CREATE INDEX IF NOT EXISTS idx_file_ops_run_item_id
    ON file_ops(run_item_id);
  CREATE INDEX IF NOT EXISTS idx_file_ops_library_item_id
    ON file_ops(library_item_id);
  CREATE INDEX IF NOT EXISTS idx_file_ops_run_status
    ON file_ops(run_id, status);
|}

let open_db path =
  if path <> ":memory:" && path <> "" then begin
    let dir = Filename.dirname path in
    let rec mkdir_p d =
      if d <> "/" && d <> "." && not (Sys.file_exists d) then begin
        mkdir_p (Filename.dirname d);
        Unix.mkdir d 0o755
      end
    in
    mkdir_p dir
  end;
  let db = Sqlite3.db_open path in
  ignore (exec_result db "PRAGMA journal_mode=WAL");
  ignore (exec_result db "PRAGMA busy_timeout=5000");
  ignore (exec_result db "PRAGMA foreign_keys=ON");
  ignore (exec_result db create_tables_sql);
  { db }

let close t =
  ignore (Sqlite3.db_close t.db)

let raw_db t = t.db

let read_library stmt =
  {
    id = Sqlite3.column_int stmt 0;
    name = Sqlite3.column_text stmt 1;
    root_path = Sqlite3.column_text stmt 2;
    config_json = Sqlite3.column_text stmt 3;
    created_at = Sqlite3.column_text stmt 4;
    updated_at = Sqlite3.column_text stmt 5;
  }

let create_library t ~name ~root_path ~config_json =
  let now = Utils.now_iso () in
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO libraries (name, root_path, config_json, created_at, \
       updated_at) VALUES (?, ?, ?, ?, ?)"
  in
  let result =
    let* () = bind_text_result stmt 1 name in
    let* () = bind_text_result stmt 2 root_path in
    let* () = bind_text_result stmt 3 config_json in
    let* () = bind_text_result stmt 4 now in
    let* () = bind_text_result stmt 5 now in
    let* () = step_done_result stmt in
    let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
    Ok
      {
        id;
        name;
        root_path;
        config_json;
        created_at = now;
        updated_at = now;
      }
  in
  finalize_ignore stmt;
  result

let get_library_by_name t name =
  with_stmt t.db
    "SELECT id, name, root_path, config_json, created_at, updated_at \
     FROM libraries WHERE name = ?"
    (fun stmt ->
      let* () = bind_text_result stmt 1 name in
      step_row_opt_result stmt read_library)

let get_library_by_id t id =
  with_stmt t.db
    "SELECT id, name, root_path, config_json, created_at, updated_at \
     FROM libraries WHERE id = ?"
    (fun stmt ->
      let* () = bind_int_result stmt 1 id in
      step_row_opt_result stmt read_library)

let list_libraries t =
  with_stmt t.db
    "SELECT id, name, root_path, config_json, created_at, updated_at \
     FROM libraries ORDER BY id"
    (fun stmt ->
      let acc = ref [] in
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          acc := read_library stmt :: !acc;
          loop ()
        | Sqlite3.Rc.DONE -> Ok (List.rev !acc)
        | rc -> sqlite_error ~message:"sqlite step failed" rc
      in
      loop ())

let read_file_object stmt =
  {
    id = Sqlite3.column_int stmt 0;
    content_hash = Sqlite3.column_text stmt 1;
    hash_algorithm =
      Hash_algorithm.of_string (Sqlite3.column_text stmt 2);
    blake2b_256_hash = opt_text stmt 3;
    size_bytes = Sqlite3.column_int stmt 4;
    quick_signature = opt_text stmt 5;
    capture_date = opt_text stmt 6;
    camera_model = opt_text stmt 7;
    original_filename = opt_text stmt 8;
    extension = opt_text stmt 9;
    mime_type = opt_text stmt 10;
    metadata_json = opt_text stmt 11;
    metadata_extracted_at = opt_text stmt 12;
    metadata_tool = opt_text stmt 13;
    created_at = Sqlite3.column_text stmt 14;
    updated_at = Sqlite3.column_text stmt 15;
  }

let create_file_object t ~content_hash ~hash_algorithm ~size_bytes
    ?blake2b_256_hash ?quick_signature ?capture_date ?camera_model
    ?original_filename ?extension ?mime_type ?metadata_json
    ?metadata_extracted_at ?metadata_tool ?created_at ?updated_at () =
  let created_at = Option.value created_at ~default:(Utils.now_iso ()) in
  let updated_at = Option.value updated_at ~default:created_at in
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO file_objects (content_hash, hash_algorithm, \
       blake2b_256_hash, size_bytes, quick_signature, capture_date, \
       camera_model, original_filename, extension, mime_type, metadata_json, \
       metadata_extracted_at, metadata_tool, created_at, updated_at) VALUES \
       (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  in
  let result =
    let* () = bind_text_result stmt 1 content_hash in
    let* () = bind_text_result stmt 2 (Hash_algorithm.to_string hash_algorithm) in
    let* () = bind_opt_text_result stmt 3 blake2b_256_hash in
    let* () = bind_int_result stmt 4 size_bytes in
    let* () = bind_opt_text_result stmt 5 quick_signature in
    let* () = bind_opt_text_result stmt 6 capture_date in
    let* () = bind_text_result stmt 1 content_hash in
    let* () = bind_text_result stmt 2 (Hash_algorithm.to_string hash_algorithm) in
    let* () = bind_opt_text_result stmt 3 blake2b_256_hash in
    let* () = bind_int_result stmt 4 size_bytes in
    let* () = bind_opt_text_result stmt 5 quick_signature in
    let* () = bind_opt_text_result stmt 6 capture_date in
    let* () = bind_opt_text_result stmt 7 camera_model in
    let* () = bind_opt_text_result stmt 8 original_filename in
    let* () = bind_opt_text_result stmt 9 extension in
    let* () = bind_opt_text_result stmt 10 mime_type in
    let* () = bind_opt_text_result stmt 11 metadata_json in
    let* () = bind_opt_text_result stmt 12 metadata_extracted_at in
    let* () = bind_opt_text_result stmt 13 metadata_tool in
    let* () = bind_text_result stmt 14 created_at in
    let* () = bind_text_result stmt 15 updated_at in
    let* () = step_done_result stmt in
    let id =
      Int64.to_int
        (Sqlite3.last_insert_rowid t.db)
    in
    Ok
      {
        id;
        content_hash;
        hash_algorithm;
        blake2b_256_hash;
        size_bytes;
        quick_signature;
        capture_date;
        camera_model;
        original_filename;
        extension;
        mime_type;
        metadata_json;
        metadata_extracted_at;
        metadata_tool;
        created_at;
        updated_at;
      }
  in
  finalize_ignore stmt;
  result

let get_file_object_by_content_hash t content_hash =
  with_stmt t.db
    "SELECT id, content_hash, hash_algorithm, blake2b_256_hash, size_bytes, \
     quick_signature, capture_date, camera_model, original_filename, \
     extension, mime_type, metadata_json, metadata_extracted_at, \
     metadata_tool, created_at, updated_at FROM file_objects \
     WHERE content_hash = ?"
    (fun stmt ->
      let* () = bind_text_result stmt 1 content_hash in
      step_row_opt_result stmt read_file_object)

let list_file_objects t =
  with_stmt t.db
    "SELECT id, content_hash, hash_algorithm, blake2b_256_hash, size_bytes, \
     quick_signature, capture_date, camera_model, original_filename, \
     extension, mime_type, metadata_json, metadata_extracted_at, \
     metadata_tool, created_at, updated_at FROM file_objects ORDER BY id"
    (fun stmt ->
      let acc = ref [] in
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          acc := read_file_object stmt :: !acc;
          loop ()
        | Sqlite3.Rc.DONE -> Ok (List.rev !acc)
        | rc -> sqlite_error ~message:"sqlite step failed" rc
      in
      loop ())

let read_library_item stmt =
  {
    id = Sqlite3.column_int stmt 0;
    library_id = Sqlite3.column_int stmt 1;
    file_object_id = Sqlite3.column_int stmt 2;
    admitted_from_run_item_id = opt_int stmt 3;
    status =
      Library_item_status.of_string (Sqlite3.column_text stmt 4);
    created_at = Sqlite3.column_text stmt 5;
    updated_at = Sqlite3.column_text stmt 6;
  }

let create_library_item t ~library_id ~file_object_id
    ?admitted_from_run_item_id ~status ?created_at ?updated_at () =
  let created_at = Option.value created_at ~default:(Utils.now_iso ()) in
  let updated_at = Option.value updated_at ~default:created_at in
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO library_items (library_id, file_object_id, \
       admitted_from_run_item_id, status, created_at, updated_at) VALUES \
       (?, ?, ?, ?, ?, ?)"
  in
  let result =
    let* () = bind_int_result stmt 1 library_id in
    let* () = bind_int_result stmt 2 file_object_id in
    let* () = bind_opt_int_result stmt 3 admitted_from_run_item_id in
    let* () = bind_text_result stmt 4 (Library_item_status.to_string status) in
    let* () = bind_text_result stmt 5 created_at in
    let* () = bind_text_result stmt 6 updated_at in
    let* () = step_done_result stmt in
    let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
    Ok
      {
        id;
        library_id;
        file_object_id;
        admitted_from_run_item_id;
        status;
        created_at;
        updated_at;
      }
  in
  finalize_ignore stmt;
  result

let get_library_item_by_library_and_file_object t ~library_id ~file_object_id =
  with_stmt t.db
    "SELECT id, library_id, file_object_id, admitted_from_run_item_id, \
     status, created_at, updated_at FROM library_items WHERE library_id = ? \
     AND file_object_id = ?"
    (fun stmt ->
      let* () = bind_int_result stmt 1 library_id in
      let* () = bind_int_result stmt 2 file_object_id in
      step_row_opt_result stmt read_library_item)

let list_library_items t =
  with_stmt t.db
    "SELECT id, library_id, file_object_id, admitted_from_run_item_id, \
     status, created_at, updated_at FROM library_items ORDER BY id"
    (fun stmt ->
      let acc = ref [] in
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          acc := read_library_item stmt :: !acc;
          loop ()
        | Sqlite3.Rc.DONE -> Ok (List.rev !acc)
        | rc -> sqlite_error ~message:"sqlite step failed" rc
      in
      loop ())

let update_library_item_status t ~id ~status ~updated_at =
  let stmt =
    Sqlite3.prepare t.db
      "UPDATE library_items SET status = ?, updated_at = ? WHERE id = ?"
  in
  let result =
    let* () = bind_text_result stmt 1 (Library_item_status.to_string status) in
    let* () = bind_text_result stmt 2 updated_at in
    let* () = bind_int_result stmt 3 id in
    step_done_result stmt
  in
  finalize_ignore stmt;
  result

let set_library_item_admitted_from_run_item t ~id ~run_item_id ~updated_at =
  let stmt =
    Sqlite3.prepare t.db
      "UPDATE library_items SET admitted_from_run_item_id = ?, updated_at = ? \
       WHERE id = ?"
  in
  let result =
    let* () = bind_int_result stmt 1 run_item_id in
    let* () = bind_text_result stmt 2 updated_at in
    let* () = bind_int_result stmt 3 id in
    step_done_result stmt
  in
  finalize_ignore stmt;
  result

let read_library_placement stmt =
  {
    id = Sqlite3.column_int stmt 0;
    library_item_id = Sqlite3.column_int stmt 1;
    library_id = Sqlite3.column_int stmt 2;
    intended_relative_path = Sqlite3.column_text stmt 3;
    actual_relative_path = opt_text stmt 4;
    placement_status =
      Placement_status.of_string (Sqlite3.column_text stmt 5);
    last_verified_at = opt_text stmt 6;
    error_text = opt_text stmt 7;
    created_at = Sqlite3.column_text stmt 8;
    updated_at = Sqlite3.column_text stmt 9;
  }

let create_library_placement t ~library_item_id ~library_id
    ~intended_relative_path ?actual_relative_path ~placement_status
    ?last_verified_at ?error_text ?created_at ?updated_at () =
  let created_at = Option.value created_at ~default:(Utils.now_iso ()) in
  let updated_at = Option.value updated_at ~default:created_at in
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO library_placements (library_item_id, library_id, \
       intended_relative_path, actual_relative_path, placement_status, \
       last_verified_at, error_text, created_at, updated_at) VALUES \
       (?, ?, ?, ?, ?, ?, ?, ?, ?)"
  in
  let result =
    let* () = bind_int_result stmt 1 library_item_id in
    let* () = bind_int_result stmt 2 library_id in
    let* () = bind_text_result stmt 3 intended_relative_path in
    let* () = bind_opt_text_result stmt 4 actual_relative_path in
    let* () = bind_text_result stmt 5 (Placement_status.to_string placement_status) in
    let* () = bind_opt_text_result stmt 6 last_verified_at in
    let* () = bind_opt_text_result stmt 7 error_text in
    let* () = bind_text_result stmt 8 created_at in
    let* () = bind_text_result stmt 9 updated_at in
    let* () = step_done_result stmt in
    let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
    Ok
      {
        id;
        library_item_id;
        library_id;
        intended_relative_path;
        actual_relative_path;
        placement_status;
        last_verified_at;
        error_text;
        created_at;
        updated_at;
      }
  in
  finalize_ignore stmt;
  result

let list_library_placements t =
  with_stmt t.db
    "SELECT id, library_item_id, library_id, intended_relative_path, \
     actual_relative_path, placement_status, last_verified_at, error_text, \
     created_at, updated_at FROM library_placements ORDER BY id"
    (fun stmt ->
      let acc = ref [] in
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          acc := read_library_placement stmt :: !acc;
          loop ()
        | Sqlite3.Rc.DONE -> Ok (List.rev !acc)
        | rc -> sqlite_error ~message:"sqlite step failed" rc
      in
      loop ())

let get_library_placement_by_library_item_id t library_item_id =
  let stmt =
    Sqlite3.prepare t.db
      "SELECT id, library_item_id, library_id, intended_relative_path, \
       actual_relative_path, placement_status, last_verified_at, error_text, \
       created_at, updated_at FROM library_placements \
       WHERE library_item_id = ?"
  in
  match bind_int_result stmt 1 library_item_id with
  | Error _ as error ->
    finalize_ignore stmt;
    error
  | Ok () ->
    let result =
      match Sqlite3.step stmt with
      | Sqlite3.Rc.ROW -> Ok (Some (read_library_placement stmt))
      | Sqlite3.Rc.DONE -> Ok None
      | rc -> sqlite_error ~message:"sqlite step failed" rc
    in
    finalize_ignore stmt;
    result

let update_library_placement_state t ~id ~placement_status ?last_verified_at
    ?error_text ~updated_at () =
  let stmt =
    Sqlite3.prepare t.db
      "UPDATE library_placements SET placement_status = ?, last_verified_at = \
       ?, error_text = ?, updated_at = ? WHERE id = ?"
  in
  let result =
    let* () = bind_text_result stmt 1 (Placement_status.to_string placement_status) in
    let* () = bind_opt_text_result stmt 2 last_verified_at in
    let* () = bind_opt_text_result stmt 3 error_text in
    let* () = bind_text_result stmt 4 updated_at in
    let* () = bind_int_result stmt 5 id in
    step_done_result stmt
  in
  finalize_ignore stmt;
  result

let read_source_root stmt =
  {
    id = Sqlite3.column_int stmt 0;
    library_id = Sqlite3.column_int stmt 1;
    root_path = Sqlite3.column_text stmt 2;
    source_kind = Source_kind.of_string (Sqlite3.column_text stmt 3);
    created_at = Sqlite3.column_text stmt 4;
  }

let create_source_root t ~library_id ~root_path ~source_kind ?created_at () =
  let created_at = Option.value created_at ~default:(Utils.now_iso ()) in
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO source_roots (library_id, root_path, source_kind, \
       created_at) VALUES (?, ?, ?, ?)"
  in
  let result =
    let* () = bind_int_result stmt 1 library_id in
    let* () = bind_text_result stmt 2 root_path in
    let* () = bind_text_result stmt 3 (Source_kind.to_string source_kind) in
    let* () = bind_text_result stmt 4 created_at in
    step_done_result stmt
  in
  finalize_ignore stmt;
  match result with
  | Ok () ->
    let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
    Ok { id; library_id; root_path; source_kind; created_at }
  | Error _ as e -> e

let list_source_roots t =
  with_stmt t.db
    "SELECT id, library_id, root_path, source_kind, created_at \
     FROM source_roots ORDER BY id"
    (fun stmt ->
      let acc = ref [] in
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          acc := read_source_root stmt :: !acc;
          loop ()
        | Sqlite3.Rc.DONE -> Ok (List.rev !acc)
        | rc -> sqlite_error ~message:"sqlite step failed" rc
      in
      loop ())

let read_run stmt =
  {
    id = Sqlite3.column_int stmt 0;
    library_id = Sqlite3.column_int stmt 1;
    source_root_id = opt_int stmt 2;
    mode = Run_mode.of_string (Sqlite3.column_text stmt 3);
    status = Run_status.of_string (Sqlite3.column_text stmt 4);
    options_json = opt_text stmt 5;
    summary_json = opt_text stmt 6;
    error_text = opt_text stmt 7;
    started_at = Sqlite3.column_text stmt 8;
    completed_at = opt_text stmt 9;
  }

let create_run t ~library_id ?source_root_id ~mode ~status ?options_json
    ?summary_json ?error_text ~started_at ?completed_at () =
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO runs (library_id, source_root_id, mode, status, \
       options_json, summary_json, error_text, started_at, completed_at) \
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
  in
  let result =
    let* () = bind_int_result stmt 1 library_id in
    let* () = bind_opt_int_result stmt 2 source_root_id in
    let* () = bind_text_result stmt 3 (Run_mode.to_string mode) in
    let* () = bind_text_result stmt 4 (Run_status.to_string status) in
    let* () = bind_opt_text_result stmt 5 options_json in
    let* () = bind_opt_text_result stmt 6 summary_json in
    let* () = bind_opt_text_result stmt 7 error_text in
    let* () = bind_text_result stmt 8 started_at in
    let* () = bind_opt_text_result stmt 9 completed_at in
    step_done_result stmt
  in
  finalize_ignore stmt;
  match result with
  | Ok () ->
    let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
    let srid = (source_root_id : int option) in
    let comp = (completed_at : string option) in
    Ok { id; library_id; source_root_id = srid; mode; status; options_json;
         summary_json; error_text; started_at; completed_at = comp }
  | Error _ as e -> e

let update_run_completion t ~id ~status ?summary_json ?error_text ~completed_at () =
  let stmt =
    Sqlite3.prepare t.db
      "UPDATE runs SET status = ?, summary_json = ?, error_text = ?, \
       completed_at = ? WHERE id = ?"
  in
  let result =
    let* () = bind_text_result stmt 1 (Run_status.to_string status) in
    let* () = bind_opt_text_result stmt 2 summary_json in
    let* () = bind_opt_text_result stmt 3 error_text in
    let* () = bind_text_result stmt 4 completed_at in
    let* () = bind_int_result stmt 5 id in
    step_done_result stmt
  in
  finalize_ignore stmt;
  result

let list_runs t =
  with_stmt t.db
    "SELECT id, library_id, source_root_id, mode, status, options_json, \
     summary_json, error_text, started_at, completed_at FROM runs \
     ORDER BY id"
    (fun stmt ->
      let acc = ref [] in
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          acc := read_run stmt :: !acc;
          loop ()
        | Sqlite3.Rc.DONE -> Ok (List.rev !acc)
        | rc -> sqlite_error ~message:"sqlite step failed" rc
      in
      loop ())

let read_source_observation stmt =
  {
    id = Sqlite3.column_int stmt 0;
    run_id = Sqlite3.column_int stmt 1;
    source_root_id = Sqlite3.column_int stmt 2;
    observed_path = Sqlite3.column_text stmt 3;
    relative_path = opt_text stmt 4;
    size_bytes = opt_int stmt 5;
    mtime = opt_text stmt 6;
    observed_at = Sqlite3.column_text stmt 7;
    file_object_id = opt_int stmt 8;
  }

let create_source_observation t ~run_id ~source_root_id ~observed_path
    ?relative_path ?size_bytes ?mtime ~observed_at ?file_object_id () =
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO source_observations (run_id, source_root_id, observed_path, \
       relative_path, size_bytes, mtime, observed_at, file_object_id) VALUES \
       (?, ?, ?, ?, ?, ?, ?, ?)"
  in
  let result =
    let* () = bind_int_result stmt 1 run_id in
    let* () = bind_int_result stmt 2 source_root_id in
    let* () = bind_text_result stmt 3 observed_path in
    let* () = bind_opt_text_result stmt 4 relative_path in
    let* () = bind_opt_int_result stmt 5 size_bytes in
    let* () = bind_opt_text_result stmt 6 mtime in
    let* () = bind_text_result stmt 7 observed_at in
    let* () = bind_opt_int_result stmt 8 file_object_id in
    step_done_result stmt
  in
  finalize_ignore stmt;
  match result with
  | Ok () ->
    let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
    Ok { id; run_id; source_root_id; observed_path; relative_path; size_bytes; mtime; observed_at; file_object_id }
  | Error _ as e -> e

let list_source_observations t =
  with_stmt t.db
    "SELECT id, run_id, source_root_id, observed_path, relative_path, \
     size_bytes, mtime, observed_at, file_object_id FROM source_observations \
     ORDER BY id"
    (fun stmt ->
      let acc = ref [] in
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          acc := read_source_observation stmt :: !acc;
          loop ()
        | Sqlite3.Rc.DONE -> Ok (List.rev !acc)
        | rc -> sqlite_error ~message:"sqlite step failed" rc
      in
      loop ())

let read_run_item stmt =
  {
    id = Sqlite3.column_int stmt 0;
    run_id = Sqlite3.column_int stmt 1;
    source_observation_id = opt_int stmt 2;
    file_object_id = opt_int stmt 3;
    workflow_state = Workflow_state.of_string (Sqlite3.column_text stmt 4);
    planned_action =
      Option.map Planned_action.of_string (opt_text stmt 5);
    disposition = Option.map Disposition.of_string (opt_text stmt 6);
    planned_relative_path = opt_text stmt 7;
    failure_reason = opt_text stmt 8;
    created_at = Sqlite3.column_text stmt 9;
    updated_at = Sqlite3.column_text stmt 10;
  }

let create_run_item t ~run_id ?source_observation_id ?file_object_id
    ~workflow_state ?planned_action ?disposition ?planned_relative_path
    ?failure_reason ~created_at ~updated_at () =
  let planned_action_text =
    Option.map Planned_action.to_string planned_action
  in
  let disposition_text = Option.map Disposition.to_string disposition in
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO run_items (run_id, source_observation_id, file_object_id, \
       workflow_state, planned_action, disposition, planned_relative_path, \
       failure_reason, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, \
       ?, ?, ?)"
  in
  let result =
    let* () = bind_int_result stmt 1 run_id in
    let* () = bind_opt_int_result stmt 2 source_observation_id in
    let* () = bind_opt_int_result stmt 3 file_object_id in
    let* () = bind_text_result stmt 4 (Workflow_state.to_string workflow_state) in
    let* () = bind_opt_text_result stmt 5 planned_action_text in
    let* () = bind_opt_text_result stmt 6 disposition_text in
    let* () = bind_opt_text_result stmt 7 planned_relative_path in
    let* () = bind_opt_text_result stmt 8 failure_reason in
    let* () = bind_text_result stmt 9 created_at in
    let* () = bind_text_result stmt 10 updated_at in
    step_done_result stmt
  in
  finalize_ignore stmt;
  match result with
  | Ok () ->
    let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
    let planned_action_val = planned_action in
    let disposition_val = disposition in
    Ok { id; run_id; source_observation_id; file_object_id; workflow_state; planned_action = planned_action_val; disposition = disposition_val; planned_relative_path; failure_reason; created_at; updated_at }
  | Error _ as e -> e

let list_run_items t =
  with_stmt t.db
    "SELECT id, run_id, source_observation_id, file_object_id, \
     workflow_state, planned_action, disposition, planned_relative_path, \
     failure_reason, created_at, updated_at FROM run_items ORDER BY id"
    (fun stmt ->
      let acc = ref [] in
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          acc := read_run_item stmt :: !acc;
          loop ()
        | Sqlite3.Rc.DONE -> Ok (List.rev !acc)
        | rc -> sqlite_error ~message:"sqlite step failed" rc
      in
      loop ())

let read_file_op stmt =
  {
    id = Sqlite3.column_int stmt 0;
    run_id = Sqlite3.column_int stmt 1;
    run_item_id = opt_int stmt 2;
    library_item_id = opt_int stmt 3;
    op_kind = File_op_kind.of_string (Sqlite3.column_text stmt 4);
    src_path = opt_text stmt 5;
    dst_path = opt_text stmt 6;
    status = File_op_status.of_string (Sqlite3.column_text stmt 7);
    error_text = opt_text stmt 8;
    started_at = Sqlite3.column_text stmt 9;
    completed_at = opt_text stmt 10;
  }

let create_file_op t ~run_id ?run_item_id ?library_item_id ~op_kind ?src_path
    ?dst_path ~status ?error_text ~started_at ?completed_at () =
  let stmt =
    Sqlite3.prepare t.db
      "INSERT INTO file_ops (run_id, run_item_id, library_item_id, op_kind, \
       src_path, dst_path, status, error_text, started_at, completed_at) \
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  in
  let result =
    let* () = bind_int_result stmt 1 run_id in
    let* () = bind_opt_int_result stmt 2 run_item_id in
    let* () = bind_opt_int_result stmt 3 library_item_id in
    let* () = bind_text_result stmt 4 (File_op_kind.to_string op_kind) in
    let* () = bind_opt_text_result stmt 5 src_path in
    let* () = bind_opt_text_result stmt 6 dst_path in
    let* () = bind_text_result stmt 7 (File_op_status.to_string status) in
    let* () = bind_opt_text_result stmt 8 error_text in
    let* () = bind_text_result stmt 9 started_at in
    let* () = bind_opt_text_result stmt 10 completed_at in
    step_done_result stmt
  in
  finalize_ignore stmt;
  match result with
  | Ok () ->
    let id = Int64.to_int (Sqlite3.last_insert_rowid t.db) in
    let completed_at_val = (completed_at : string option) in
    Ok { id; run_id; run_item_id; library_item_id; op_kind; src_path; dst_path; status; error_text; started_at; completed_at = completed_at_val }
  | Error _ as e -> e

let list_file_ops t =
  with_stmt t.db
    "SELECT id, run_id, run_item_id, library_item_id, op_kind, src_path, \
     dst_path, status, error_text, started_at, completed_at FROM file_ops \
     ORDER BY id"
    (fun stmt ->
      let acc = ref [] in
      let rec loop () =
        match Sqlite3.step stmt with
        | Sqlite3.Rc.ROW ->
          acc := read_file_op stmt :: !acc;
          loop ()
        | Sqlite3.Rc.DONE -> Ok (List.rev !acc)
        | rc -> sqlite_error ~message:"sqlite step failed" rc
      in
      loop ())

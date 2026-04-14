(** SQLite database layer for trove.

    Manages libraries, entries (imported files in a library), and files
    (in-progress files being discovered/hashed/imported). Compatible with
    the Python trove schema. *)

open Domain

(** Opaque database handle. *)
type t

(** Open or create a database at [path]. Creates parent directories if
    needed, sets WAL mode, enables foreign keys, creates tables, and
    runs any pending migrations. Use [":memory:"] for in-memory databases. *)
val open_db : string -> t

(** Close the database handle. *)
val close : t -> unit

(** Expose the underlying [Sqlite3.db] for low-level access (e.g. in tests). *)
val raw_db : t -> Sqlite3.db

(** {2 Libraries} *)

val create_library :
  t ->
  name:string ->
  location:string ->
  config_json:string ->
  library

val get_library : t -> string -> library option
val get_library_by_id : t -> int -> library option
val list_libraries : t -> library list
val update_library_config : t -> int -> string -> unit
val update_library_location : t -> int -> string -> unit
val delete_library : t -> int -> unit

(** {2 Entries} *)

val create_entry :
  t ->
  library_id:int ->
  relative_path:string ->
  file_size:int ->
  md5_hash:string option ->
  capture_date:string option ->
  camera_model:string option ->
  original_path:string option ->
  entry

val get_entry_by_path :
  t -> library_id:int -> relative_path:string -> entry option

val get_entries_by_hash :
  t -> library_id:int -> md5_hash:string -> entry list

val get_entries_by_size :
  t -> library_id:int -> file_size:int -> entry list

val list_entries : t -> int -> entry list
val update_entry_hash : t -> int -> string -> unit

(** {2 Files} *)

val insert_file :
  t ->
  source_path:string ->
  source_type:string ->
  file_size:int ->
  file_modify_date:string ->
  file_record

(** Update file columns. Each pair is [(column_name, value_option)] where
    [None] sets the column to NULL. Column names are validated against an
    allowlist; [Invalid_argument] is raised for unknown columns. *)
val update_file : t -> int -> (string * string option) list -> unit

(** Look up a file record by its source_path. Returns [None] if not found. *)
val get_file_by_path : t -> string -> file_record option

(** Fetch file records for the given IDs. Returns records in no guaranteed order. *)
val query_files_by_ids : t -> int list -> file_record list

val query_files_by_status : t -> file_status -> file_record list
val delete_files_by_status : t -> file_status list -> unit
val delete_file : t -> int -> unit

(** {2 Atomic import}

    Insert an entry and update the corresponding file's status to
    [Imported] in a single transaction. *)
val import_file :
  t ->
  file_id:int ->
  library_id:int ->
  relative_path:string ->
  file_size:int ->
  md5_hash:string ->
  capture_date:string option ->
  camera_model:string option ->
  original_path:string option ->
  entry

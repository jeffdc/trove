(** Read-only access to the Python/main Trove schema. *)

type t

val open_readonly : path:string -> (t, Domain.app_error) result
val close : t -> unit
val raw_db : t -> Sqlite3.db

val schema_version : t -> (int, Domain.app_error) result
val list_libraries : t -> (Legacy_types.library list, Domain.app_error) result
val list_entries : t -> (Legacy_types.entry list, Domain.app_error) result
val list_files : t -> (Legacy_types.file_row list, Domain.app_error) result

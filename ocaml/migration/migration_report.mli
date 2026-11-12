(** In-memory migration summary and report writer. *)

type t

val create : source_db_path:string -> source_schema_version:int -> t
val add_anomaly : t -> Migration_types.anomaly -> unit
val add_warning : t -> string -> unit
val incr : t -> counter:string -> unit
val add_count : t -> counter:string -> int -> unit
val get_count : t -> counter:string -> int
val anomalies : t -> Migration_types.anomaly list
val warnings : t -> string list
val to_yojson : t -> Yojson.Safe.t
val write_json : t -> path:string -> (unit, Domain.app_error) result

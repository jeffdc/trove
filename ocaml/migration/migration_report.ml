type t = {
  source_db_path : string;
  source_schema_version : int;
  migrated_at : string;
  counts : (string, int) Hashtbl.t;
  mutable anomalies_rev : Migration_types.anomaly list;
  mutable warnings_rev : string list;
}



let create ~source_db_path ~source_schema_version =
  {
    source_db_path;
    source_schema_version;
    migrated_at = Utils.now_iso ();
    counts = Hashtbl.create 32;
    anomalies_rev = [];
    warnings_rev = [];
  }

let add_anomaly t anomaly =
  t.anomalies_rev <- anomaly :: t.anomalies_rev

let add_warning t warning =
  t.warnings_rev <- warning :: t.warnings_rev

let get_count t ~counter =
  Option.value (Hashtbl.find_opt t.counts counter) ~default:0

let incr t ~counter =
  let next = get_count t ~counter + 1 in
  Hashtbl.replace t.counts counter next

let add_count t ~counter amount =
  let next = get_count t ~counter + amount in
  Hashtbl.replace t.counts counter next

let anomalies t =
  List.rev t.anomalies_rev

let warnings t =
  List.rev t.warnings_rev

let counts_assoc t =
  Hashtbl.to_seq t.counts
  |> List.of_seq
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let anomaly_to_yojson (anomaly : Migration_types.anomaly) =
  `Assoc
    [
      ("kind", `String (Migration_types.anomaly_kind_to_string anomaly.kind));
      ("legacy_table", `String anomaly.legacy_table);
      ( "legacy_id",
        match anomaly.legacy_id with Some id -> `Int id | None -> `Null );
      ("detail", `String anomaly.detail);
    ]

let to_yojson t =
  let counts_json =
    counts_assoc t
    |> List.map (fun (key, value) -> (key, `Int value))
  in
  `Assoc
    [
      ("source_db_path", `String t.source_db_path);
      ("source_schema_version", `Int t.source_schema_version);
      ("migrated_at", `String t.migrated_at);
      ("counts", `Assoc counts_json);
      ( "warnings",
        `List (List.map (fun warning -> `String warning) (warnings t)) );
      ( "anomalies",
        `List (List.map anomaly_to_yojson (anomalies t)) );
    ]

let write_json t ~path =
  try
    let oc = open_out path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () ->
        Yojson.Safe.pretty_to_channel oc (to_yojson t);
        output_char oc '\n');
    Ok ()
  with
  | Sys_error detail ->
    Error
      (Utils.app_error ~code:Domain.Filesystem_io_error
         ~context:[ ("path", path); ("detail", detail) ]
         "failed to write migration report")
  | exn ->
    Error
      (Utils.app_error ~code:Domain.Filesystem_io_error
         ~context:[ ("path", path); ("detail", Printexc.to_string exn) ]
         "failed to write migration report")

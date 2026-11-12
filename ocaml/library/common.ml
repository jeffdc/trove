open Domain

let map_db_error ?(context = []) = function
  | Ok value -> Ok value
  | Error err ->
    Error
      {
        err with
        context =
          if context = [] then err.context else err.context @ context;
      }

let fallback_capture_date mtime =
  match Path.parse_iso_date mtime with
  | Some (year, _, _) when year >= 1990 && year <= 2099 -> Some mtime
  | _ -> None

let ensure_mount worker path =
  match Worker_client.check_mount worker ~path ~timeout_seconds:10 with
  | Ok true -> Ok ()
  | Ok false ->
    Error
      (Utils.app_error ~code:Mount_unavailable
         ~context:[ ("path", path) ]
         "path is not mounted")
  | Error err -> Error (Utils.app_error_of_worker_error ~op:"check_mount" ~path err)

let resolve_available_path worker ~library_root ~claimed desired_path =
  let candidate_available candidate =
    if Utils.StringSet.mem candidate !claimed then
      Ok false
    else
      let full_path = Filename.concat library_root candidate in
      match Worker_client.path_exists worker full_path with
      | Error err ->
        Error (Utils.app_error_of_worker_error ~op:"path_exists" ~path:full_path err)
      | Ok exists -> Ok (not exists)
  in
  let dir_part, filename =
    match String.rindex_opt desired_path '/' with
    | Some i ->
      ( String.sub desired_path 0 i,
        String.sub desired_path (i + 1) (String.length desired_path - i - 1) )
    | None -> ("", desired_path)
  in
  let ext = Filename.extension filename in
  let stem =
    if ext = "" then filename
    else String.sub filename 0 (String.length filename - String.length ext)
  in
  let rec loop candidate index had_conflict =
    match candidate_available candidate with
    | Error _ as error -> error
    | Ok true ->
      claimed := Utils.StringSet.add candidate !claimed;
      Ok (candidate, had_conflict)
    | Ok false ->
      let next =
        let basename = Printf.sprintf "%s-%d%s" stem index ext in
        if dir_part = "" then basename else dir_part ^ "/" ^ basename
      in
      loop next (index + 1) true
  in
  loop desired_path 1 false

let ensure_file_object db ~content_hash ~size_bytes ~capture_date
    ~original_filename ~created_at =
  match
    map_db_error
      ~context:[ ("content_hash", content_hash) ]
      (Db.get_file_object_by_content_hash db content_hash)
  with
  | Error _ as error -> error
  | Ok (Some existing) ->
    if existing.size_bytes <> size_bytes then
      Error
        (Utils.app_error ~code:Invalid_state
           ~context:
             [
               ("content_hash", content_hash);
               ("existing_size_bytes", string_of_int existing.size_bytes);
               ("source_size_bytes", string_of_int size_bytes);
             ]
           "content hash already exists with a different file size")
    else Ok existing
  | Ok None ->
    let extension = Utils.extension_of_filename original_filename in
    map_db_error
      ~context:[ ("content_hash", content_hash) ]
      (Db.create_file_object db ~content_hash
         ~hash_algorithm:Hash_algorithm.Md5 ~size_bytes ?capture_date
         ~original_filename ?extension ~created_at ~updated_at:created_at ())

let create_source_observation db ~run_id ~source_root_id ~observed_path
    ~relative_path ~size_bytes ~mtime ~observed_at ?file_object_id () =
  map_db_error
    ~context:[ ("observed_path", observed_path); ("run_id", string_of_int run_id) ]
    (Db.create_source_observation db ~run_id ~source_root_id
       ~observed_path ~relative_path ~size_bytes ~mtime ~observed_at
       ?file_object_id ())

let create_run_item db ~run_id ~source_observation_id ?file_object_id
    ~workflow_state ?planned_action ?disposition ?planned_relative_path
    ?failure_reason ~created_at () =
  map_db_error
    ~context:
      [
        ("run_id", string_of_int run_id);
        ("source_observation_id", string_of_int source_observation_id);
      ]
    (Db.create_run_item db ~run_id ~source_observation_id ?file_object_id
       ~workflow_state ?planned_action ?disposition ?planned_relative_path
       ?failure_reason ~created_at ~updated_at:created_at ())

let actual_managed_path (placement : library_placement) =
  match placement.actual_relative_path with
  | Some path when not (String.equal path "") -> path
  | _ -> placement.intended_relative_path

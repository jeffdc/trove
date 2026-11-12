open Domain

let map_target_error ?(context = []) = function
  | Ok value -> Ok value
  | Error err ->
    Error
      {
        err with
        context =
          if context = [] then err.context else err.context @ context;
      }

type inferred_context = {
  library_id : int;
  mode : Domain.Run_mode.t;
  source_kind : Domain.Source_kind.t;
  source_root_path : string;
}

let longest_matching_library libraries source_path =
  let matches =
    List.filter
      (fun (lib : Domain.library) ->
        Utils.path_within_root ~root_path:lib.root_path source_path)
      libraries
  in
  let compare_root_length
      (a : Domain.library)
      (b : Domain.library) =
    compare (String.length b.root_path) (String.length a.root_path)
  in
  match List.sort compare_root_length matches with
  | [] -> None
  | first :: _ -> Some first

let unique_library_id ids =
  match List.sort_uniq compare ids with
  | [ id ] -> Some id
  | _ -> None

let basename_from_path path =
  Filename.basename path

let ensure_file_object ~target ~(state : Migration_types.mapping_state) ~report
    (file_row : Legacy_types.file_row)
    md5_hash =
  match map_target_error (Db.get_file_object_by_content_hash target md5_hash) with
  | Error _ as error -> error
  | Ok (Some file_object) ->
    Hashtbl.replace state.file_object_ids_by_md5 md5_hash file_object.id;
    if file_object.size_bytes <> file_row.file_size then
      Migration_report.add_anomaly report
        {
          Migration_types.kind = Inconsistent_md5_group;
          legacy_table = "files";
          legacy_id = Some file_row.id;
          detail =
            Printf.sprintf
              "file row md5 %s maps to existing file_object %d with size %d but \
               file row reports size %d" md5_hash file_object.id
              file_object.size_bytes file_row.file_size;
        };
    Ok file_object
  | Ok None ->
    let original_filename = basename_from_path file_row.source_path in
    let extension = Utils.extension_of_filename original_filename in
    let created_at =
      Option.value file_row.hashed_at ~default:file_row.discovered_at
    in
    match
      map_target_error
        (Db.create_file_object target ~content_hash:md5_hash
           ~hash_algorithm:Domain.Hash_algorithm.Md5
           ~size_bytes:file_row.file_size ?capture_date:file_row.capture_date
           ?camera_model:file_row.camera_model ~original_filename ?extension
           ~created_at ~updated_at:created_at ())
    with
    | Error _ as error -> error
    | Ok file_object ->
      Hashtbl.replace state.file_object_ids_by_md5 md5_hash file_object.id;
      Migration_report.incr report ~counter:"file_objects_created";
      Ok file_object

let source_kind_for_file_row report (file_row : Legacy_types.file_row) mode =
  match String.lowercase_ascii file_row.source_type with
  | "" | "local" ->
    (match mode with
    | Domain.Run_mode.Init -> Domain.Source_kind.Init_root
    | _ -> Domain.Source_kind.Import)
  | _other ->
    Migration_report.add_anomaly report
      {
        Migration_types.kind = Unsupported_source_type;
        legacy_table = "files";
        legacy_id = Some file_row.id;
        detail =
          Printf.sprintf "unsupported legacy source_type %S; defaulting source_kind"
            file_row.source_type;
      };
    Migration_report.incr report ~counter:"legacy_rows_preserved";
    (match mode with
    | Domain.Run_mode.Init -> Domain.Source_kind.Init_root
    | _ -> Domain.Source_kind.Import)

let infer_library_from_file_object file_object_to_library_ids file_object_id =
  match Hashtbl.find_opt file_object_to_library_ids file_object_id with
  | None -> None
  | Some ids -> unique_library_id ids

let infer_library_from_target_path placement_path_to_library_ids target_path =
  match Hashtbl.find_opt placement_path_to_library_ids target_path with
  | None -> None
  | Some ids -> unique_library_id ids

let infer_context report libraries file_object_to_library_ids
    placement_path_to_library_ids
    (file_row : Legacy_types.file_row)
    (file_object_opt : Domain.file_object option) =
  match longest_matching_library libraries file_row.source_path with
  | Some lib ->
    Ok
      (Some
         {
           library_id = lib.id;
           mode = Domain.Run_mode.Init;
           source_kind = Domain.Source_kind.Init_root;
           source_root_path = lib.root_path;
         })
  | None ->
    let library_from_file_object =
      match file_object_opt with
      | Some file_object ->
        infer_library_from_file_object file_object_to_library_ids
          file_object.id
      | None -> None
    in
    let library_from_target_path =
      match file_row.target_path with
      | Some target_path ->
        infer_library_from_target_path placement_path_to_library_ids target_path
      | None -> None
    in
    match (library_from_file_object, library_from_target_path) with
    | Some library_id, Some other_library_id when library_id <> other_library_id ->
      Migration_report.add_anomaly report
        {
          Migration_types.kind = Target_path_conflict;
          legacy_table = "files";
          legacy_id = Some file_row.id;
          detail =
            Printf.sprintf
              "file row implies library %d via content identity but library %d \
               via target_path %s" library_id other_library_id
              (Option.value file_row.target_path ~default:"");
        };
      Migration_report.incr report ~counter:"legacy_rows_preserved";
      Ok None
    | Some library_id, _ | _, Some library_id ->
      let mode = Domain.Run_mode.Import in
      let source_kind = source_kind_for_file_row report file_row mode in
      Ok
        (Some
           {
             library_id;
             mode;
             source_kind;
             source_root_path = Filename.dirname file_row.source_path;
           })
    | None, None -> Ok None

let run_status_for_file_status status =
  match status with
  | "discovered" | "hashed" -> Domain.Run_status.Interrupted
  | "imported" | "quarantined" -> Domain.Run_status.Completed
  | "missing" -> Domain.Run_status.Failed
  | "duplicate" -> Domain.Run_status.Completed
  | "completed" -> Domain.Run_status.Completed
  | _ -> Domain.Run_status.Interrupted

let workflow_for_file_status (file_row : Legacy_types.file_row) =
  match String.lowercase_ascii file_row.status with
  | "discovered" ->
    Ok (Domain.Workflow_state.Observed, Some Domain.Disposition.Pending)
  | "hashed" ->
    Ok (Domain.Workflow_state.Identified, Some Domain.Disposition.Pending)
  | "quarantined" ->
    Ok
      (Domain.Workflow_state.Completed, Some Domain.Disposition.Quarantined)
  | "imported" ->
    Ok
      (Domain.Workflow_state.Completed, Some Domain.Disposition.Admitted)
  | "missing" ->
    Ok (Domain.Workflow_state.Failed, Some Domain.Disposition.Failed)
  | "duplicate" -> Error `ambiguous_duplicate
  | "completed" -> Error `legacy_completed
  | _ -> Error `unknown

let get_or_create_source_root target report source_root_cache context created_at =
  let key =
    Printf.sprintf "%d|%s|%s" context.library_id
      (Domain.Source_kind.to_string context.source_kind)
      context.source_root_path
  in
  match Hashtbl.find_opt source_root_cache key with
  | Some source_root -> Ok source_root
  | None -> (
      match
        map_target_error
          (Db.create_source_root target ~library_id:context.library_id
             ~root_path:context.source_root_path
             ~source_kind:context.source_kind ~created_at ())
      with
      | Error _ as error -> error
      | Ok source_root ->
        Hashtbl.add source_root_cache key source_root;
        Migration_report.incr report ~counter:"source_roots_created";
        Ok source_root)

let get_or_create_run target report run_cache context
    (source_root : Domain.source_root) status
    started_at =
  let key =
    Printf.sprintf "%d|%d|%s|%s" context.library_id source_root.id
      (Domain.Run_mode.to_string context.mode)
      (Domain.Run_status.to_string status)
  in
  match Hashtbl.find_opt run_cache key with
  | Some run -> Ok run
  | None -> (
      match
        map_target_error
          (Db.create_run target ~library_id:context.library_id
             ~source_root_id:source_root.id ~mode:context.mode ~status
             ~started_at
             ?completed_at:
               (match status with
               | Domain.Run_status.Interrupted -> None
               | _ -> Some started_at)
             ())
      with
      | Error _ as error -> error
      | Ok run ->
        Hashtbl.add run_cache key run;
        Migration_report.incr report ~counter:"runs_created";
        Ok run)

let run_item_created_at (file_row : Legacy_types.file_row) =
  Option.value file_row.hashed_at ~default:file_row.discovered_at

let maybe_planned_action (context : inferred_context)
    (file_row : Legacy_types.file_row) =
  match context.mode with
  | Domain.Run_mode.Init ->
    if file_row.status = "missing" then None else Some Domain.Planned_action.Index_existing
  | Domain.Run_mode.Import ->
    if file_row.status = "quarantined" then Some Domain.Planned_action.Quarantine
    else if Option.is_some file_row.target_path then Some Domain.Planned_action.Admit_copy
    else None
  | _ -> None

let run ~legacy ~target ~(state : Migration_types.mapping_state) ~report =
  let libraries =
    match map_target_error (Db.list_libraries target) with
    | Error _ as error -> error
    | Ok libraries -> Ok libraries
  in
  match libraries with
  | Error _ as error -> error
  | Ok libraries -> (
      match map_target_error (Db.list_library_items target) with
      | Error _ as error -> error
      | Ok library_items -> (
          match map_target_error (Db.list_library_placements target) with
          | Error _ as error -> error
          | Ok placements -> (
              match Legacy_db.list_files legacy with
              | Error _ as error -> error
              | Ok files ->
                let file_object_to_library_ids = Hashtbl.create 32 in
                List.iter
                  (fun (item : Domain.library_item) ->
                    let current =
                      Option.value
                        (Hashtbl.find_opt file_object_to_library_ids item.file_object_id)
                        ~default:[]
                    in
                    Hashtbl.replace file_object_to_library_ids item.file_object_id
                      (item.library_id :: current))
                  library_items;
                let placement_path_to_library_ids = Hashtbl.create 64 in
                List.iter
                  (fun (placement : Domain.library_placement) ->
                    let current =
                      Option.value
                        (Hashtbl.find_opt placement_path_to_library_ids
                           placement.intended_relative_path)
                        ~default:[]
                    in
                    Hashtbl.replace placement_path_to_library_ids
                      placement.intended_relative_path
                      (placement.library_id :: current))
                  placements;
                let source_root_cache = Hashtbl.create 16 in
                let run_cache = Hashtbl.create 16 in
                let rec loop = function
                  | [] -> Ok ()
                  | (file_row : Legacy_types.file_row) :: rest ->
                    let status = String.lowercase_ascii file_row.status in
                    match workflow_for_file_status file_row with
                    | Error `ambiguous_duplicate ->
                      Migration_report.add_anomaly report
                        {
                          Migration_types.kind = Ambiguous_duplicate_kind;
                          legacy_table = "files";
                          legacy_id = Some file_row.id;
                          detail =
                            "legacy duplicate row preserved because duplicate kind is ambiguous";
                        };
                      Migration_report.incr report ~counter:"legacy_rows_preserved";
                      loop rest
                    | Error `legacy_completed ->
                      Migration_report.add_anomaly report
                        {
                          Migration_types.kind = Legacy_completed_status;
                          legacy_table = "files";
                          legacy_id = Some file_row.id;
                          detail =
                            "legacy completed row preserved because ownership is ambiguous";
                        };
                      Migration_report.incr report ~counter:"legacy_rows_preserved";
                      loop rest
                    | Error `unknown ->
                      Migration_report.incr report ~counter:"legacy_rows_preserved";
                      loop rest
                    | Ok (workflow_state, disposition) ->
                      let file_object_result =
                        match file_row.md5_hash with
                        | None -> Ok None
                        | Some md5_hash ->
                          match ensure_file_object ~target ~state ~report file_row md5_hash with
                          | Error _ as error -> error
                          | Ok file_object -> Ok (Some file_object)
                      in
                      match file_object_result with
                      | Error _ as error -> error
                      | Ok file_object_opt ->
                        match
                          infer_context report libraries file_object_to_library_ids
                            placement_path_to_library_ids file_row file_object_opt
                        with
                        | Error _ as error -> error
                        | Ok None ->
                          if status = "imported" then begin
                            Migration_report.add_anomaly report
                              {
                                Migration_types.kind = Imported_file_without_entry;
                                legacy_table = "files";
                                legacy_id = Some file_row.id;
                                detail =
                                  "imported file row could not be linked to a durable library member";
                              };
                            Migration_report.incr report
                              ~counter:"legacy_rows_preserved";
                            loop rest
                          end else if status = "missing" then begin
                            Migration_report.add_anomaly report
                              {
                                Migration_types.kind = Missing_without_library_link;
                                legacy_table = "files";
                                legacy_id = Some file_row.id;
                                detail =
                                  "missing file row could not be linked to a library context";
                              };
                            Migration_report.incr report
                              ~counter:"legacy_rows_preserved";
                            loop rest
                          end else begin
                            Migration_report.incr report
                              ~counter:"legacy_rows_preserved";
                            loop rest
                          end
                        | Ok (Some context) ->
                          let created_at = run_item_created_at file_row in
                          match
                            get_or_create_source_root target report
                              source_root_cache context file_row.discovered_at
                          with
                          | Error _ as error -> error
                          | Ok source_root ->
                            match
                              get_or_create_run target report run_cache context
                                source_root (run_status_for_file_status status)
                                file_row.discovered_at
                            with
                            | Error _ as error -> error
                            | Ok run ->
                              let relative_path =
                                Utils.relative_to_root ~root_path:source_root.root_path
                                  file_row.source_path
                              in
                              match
                                map_target_error
                                  (Db.create_source_observation target
                                     ~run_id:run.id
                                     ~source_root_id:source_root.id
                                     ~observed_path:file_row.source_path
                                     ?relative_path
                                     ~size_bytes:file_row.file_size
                                     ~mtime:file_row.file_modify_date
                                     ~observed_at:file_row.discovered_at
                                     ?file_object_id:
                                       (Option.map
                                          (fun (f : Domain.file_object) ->
                                            f.id)
                                          file_object_opt)
                                     ())
                              with
                              | Error _ as error -> error
                              | Ok source_observation ->
                                Hashtbl.replace
                                  state.source_observation_ids_by_file_id
                                  file_row.id source_observation.id;
                                Migration_report.incr report
                                  ~counter:"source_observations_created";
                                match
                                  map_target_error
                                    (Db.create_run_item target ~run_id:run.id
                                       ~source_observation_id:source_observation.id
                                       ?file_object_id:
                                         (Option.map
                                            (fun (f : Domain.file_object) ->
                                              f.id)
                                            file_object_opt)
                                       ~workflow_state
                                       ?planned_action:
                                         (maybe_planned_action context file_row)
                                       ?disposition
                                       ?planned_relative_path:file_row.target_path
                                       ?failure_reason:file_row.error_message
                                       ~created_at ~updated_at:created_at ())
                                with
                                | Error _ as error -> error
                                | Ok _run_item ->
                                  Migration_report.incr report
                                    ~counter:"run_items_created";
                                  loop rest
                in
                loop files)))

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

type import_summary = {
  source_root_id : int;
  run_id : int;
  observed : int;
  admitted : int;
  duplicate_in_library : int;
  quarantined : int;
  failed : int;
  path_conflicts : int;
}

type counters = {
  mutable observed : int;
  mutable admitted : int;
  mutable duplicate_in_library : int;
  mutable quarantined : int;
  mutable failed : int;
  mutable path_conflicts : int;
}

let empty_counters () =
  {
    observed = 0;
    admitted = 0;
    duplicate_in_library = 0;
    quarantined = 0;
    failed = 0;
    path_conflicts = 0;
  }

let counters_to_json counts =
  Yojson.Safe.to_string
    (`Assoc
      [
        ("observed", `Int counts.observed);
        ("admitted", `Int counts.admitted);
        ("duplicate_in_library", `Int counts.duplicate_in_library);
        ("quarantined", `Int counts.quarantined);
        ("failed", `Int counts.failed);
        ("path_conflicts", `Int counts.path_conflicts);
      ])

let complete_run db (run : run) counts status ?error_text () =
  map_db_error
    ~context:[ ("run_id", string_of_int run.id) ]
    (Db.update_run_completion db ~id:run.id ~status
       ~summary_json:(counters_to_json counts) ?error_text
       ~completed_at:(Utils.now_iso ()) ())

let record_copy_failure db ~run_id ~source_observation_id ?file_object_id
    ~source_path ?destination_path ?planned_relative_path ~failure_reason ~at
    () =
  match
    Common.create_run_item db ~run_id ~source_observation_id ?file_object_id
      ~workflow_state:Workflow_state.Failed
      ~planned_action:Planned_action.Admit_copy
      ~disposition:Disposition.Failed ?planned_relative_path
      ~failure_reason ~created_at:at ()
  with
  | Error _ as error -> error
  | Ok run_item ->
    map_db_error
      ~context:[ ("run_id", string_of_int run_id); ("source_path", source_path) ]
      (Db.create_file_op db ~run_id ~run_item_id:run_item.id
         ~op_kind:File_op_kind.Copy ~src_path:source_path
         ?dst_path:destination_path ~status:File_op_status.Failed
         ~error_text:failure_reason ~started_at:at ~completed_at:at ())
    |> Result.map (fun _ -> ())

let process_item db worker (library : library) config source
    (source_root : source_root) (run : run) claimed counts
    (item : Worker_client.walk_item) =
  counts.observed <- counts.observed + 1;
  let observed_path =
    if Filename.is_relative item.path then Filename.concat source item.path
    else item.path
  in
  let relative_path =
    match
      if Filename.is_relative item.path then Some item.path
      else Utils.relative_to_root ~root_path:source item.path
    with
    | Some path -> path
    | None -> item.path
  in
  let observed_at = Utils.now_iso () in
  let original_filename = Filename.basename observed_path in
  let create_observation ?file_object_id () =
    Common.create_source_observation db ~run_id:run.id
      ~source_root_id:source_root.id ~observed_path ~relative_path
      ~size_bytes:item.size ~mtime:item.mtime ~observed_at ?file_object_id ()
  in
  let create_failure_without_hash failure_reason =
    match create_observation () with
    | Error _ as error -> error
    | Ok source_observation ->
      Common.create_run_item db ~run_id:run.id
        ~source_observation_id:source_observation.id
        ~workflow_state:Workflow_state.Failed
        ~planned_action:Planned_action.Admit_copy
        ~disposition:Disposition.Failed ~failure_reason
        ~created_at:observed_at ()
      |> Result.map (fun _ -> counts.failed <- counts.failed + 1)
  in
  let create_quarantine (source_observation : source_observation) file_object_id
      failure_reason =
    Common.create_run_item db ~run_id:run.id
      ~source_observation_id:source_observation.id ~file_object_id
      ~workflow_state:Workflow_state.Completed
      ~planned_action:Planned_action.Quarantine
      ~disposition:Disposition.Quarantined ~failure_reason
      ~created_at:observed_at ()
    |> Result.map (fun _ -> counts.quarantined <- counts.quarantined + 1)
  in
  match Worker_client.hash_path worker observed_path with
  | Error err ->
    let failure_reason =
      Printf.sprintf "hash failed: %s" (Utils.string_of_worker_error err)
    in
    create_failure_without_hash failure_reason
  | Ok content_hash ->
    let capture_date = Common.fallback_capture_date item.mtime in
    match
      Common.ensure_file_object db ~content_hash ~size_bytes:item.size
        ~capture_date ~original_filename ~created_at:observed_at
    with
    | Error err -> create_failure_without_hash (Utils.string_of_app_error err)
    | Ok file_object -> (
        match create_observation ~file_object_id:file_object.id () with
        | Error _ as error -> error
        | Ok source_observation -> (
            match capture_date with
            | None ->
              create_quarantine source_observation file_object.id "no_usable_date"
            | Some capture_date -> (
                match
                  Path.compute_library_path ~capture_date ~camera_model:None
                    ~filename:original_filename
                    ~structure:config.Config.organization.structure
                    ~include_camera_model:config.Config.organization.include_camera_model
                    ~unknown_model_label:config.Config.organization.unknown_model_label
                with
                | None ->
                  create_quarantine source_observation file_object.id
                    "unable_to_compute_library_path"
                | Some planned_relative_path -> (
                    match
                      map_db_error
                        ~context:
                          [
                            ("library_id", string_of_int library.id);
                            ("file_object_id", string_of_int file_object.id);
                          ]
                        (Db.get_library_item_by_library_and_file_object
                           db ~library_id:library.id
                           ~file_object_id:file_object.id)
                    with
                    | Error _ as error -> error
                    | Ok (Some _) ->
                      Common.create_run_item db ~run_id:run.id
                        ~source_observation_id:source_observation.id
                        ~file_object_id:file_object.id
                        ~workflow_state:Workflow_state.Completed
                        ~planned_action:Planned_action.Skip
                        ~disposition:Disposition.Duplicate_in_library
                        ~planned_relative_path ~created_at:observed_at ()
                      |> Result.map (fun _ ->
                             counts.duplicate_in_library <-
                               counts.duplicate_in_library + 1)
                    | Ok None ->
                      let admit_success resolved_relative_path destination_path
                          op_started_at =
                        match
                          Common.create_run_item db ~run_id:run.id
                            ~source_observation_id:source_observation.id
                            ~file_object_id:file_object.id
                            ~workflow_state:Workflow_state.Completed
                            ~planned_action:Planned_action.Admit_copy
                            ~disposition:Disposition.Admitted
                            ~planned_relative_path:resolved_relative_path
                            ~created_at:(Utils.now_iso ()) ()
                        with
                        | Error _ as error -> error
                        | Ok run_item -> (
                            match
                              map_db_error
                                ~context:
                                  [
                                    ("library_id", string_of_int library.id);
                                    ("file_object_id", string_of_int file_object.id);
                                  ]
                                (Db.create_library_item db
                                   ~library_id:library.id
                                   ~file_object_id:file_object.id
                                   ~admitted_from_run_item_id:run_item.id
                                   ~status:Library_item_status.Active ())
                            with
                            | Error _ as error -> error
                            | Ok library_item -> (
                                match
                                  map_db_error
                                    ~context:
                                      [
                                        ("library_id", string_of_int library.id);
                                        ( "library_item_id",
                                          string_of_int library_item.id );
                                      ]
                                    (Db.create_library_placement db
                                       ~library_item_id:library_item.id
                                       ~library_id:library.id
                                       ~intended_relative_path:
                                         resolved_relative_path
                                       ~actual_relative_path:
                                         resolved_relative_path
                                       ~placement_status:
                                         Placement_status.Healthy
                                       ~last_verified_at:op_started_at ())
                                with
                                | Error _ as error -> error
                                | Ok _ ->
                                  map_db_error
                                    ~context:
                                      [
                                        ("run_id", string_of_int run.id);
                                        ("source_path", observed_path);
                                      ]
                                    (Db.create_file_op db
                                       ~run_id:run.id
                                       ~run_item_id:run_item.id
                                       ~library_item_id:library_item.id
                                       ~op_kind:File_op_kind.Copy
                                       ~src_path:observed_path
                                       ~dst_path:destination_path
                                       ~status:File_op_status.Completed
                                       ~started_at:op_started_at
                                       ~completed_at:(Utils.now_iso ()) ())
                                  |> Result.map (fun _ ->
                                         counts.admitted <-
                                           counts.admitted + 1)))
                      in
                      match
                        Common.resolve_available_path worker
                          ~library_root:library.root_path ~claimed
                          planned_relative_path
                      with
                      | Error _ as error -> error
                      | Ok (resolved_relative_path, had_conflict) ->
                        if had_conflict then
                          counts.path_conflicts <- counts.path_conflicts + 1;
                        let destination_path =
                          Filename.concat library.root_path
                            resolved_relative_path
                        in
                        let op_started_at = Utils.now_iso () in
                        (match
                           Worker_client.mkdir_all worker
                             (Filename.dirname destination_path)
                         with
                        | Error err ->
                          let failure_reason =
                            Printf.sprintf "mkdir failed: %s"
                              (Utils.string_of_worker_error err)
                          in
                          record_copy_failure db ~run_id:run.id
                            ~source_observation_id:source_observation.id
                            ~file_object_id:file_object.id
                            ~source_path:observed_path ~destination_path
                            ~planned_relative_path:resolved_relative_path
                            ~failure_reason ~at:op_started_at ()
                          |> Result.map (fun () ->
                                 counts.failed <- counts.failed + 1)
                        | Ok () -> (
                            match
                              Worker_client.copy_and_hash worker
                                ~src:observed_path ~dst:destination_path
                            with
                            | Error err ->
                              let failure_reason =
                                Printf.sprintf "copy failed: %s"
                                  (Utils.string_of_worker_error err)
                              in
                              record_copy_failure db ~run_id:run.id
                                ~source_observation_id:source_observation.id
                                ~file_object_id:file_object.id
                                ~source_path:observed_path ~destination_path
                                ~planned_relative_path:resolved_relative_path
                                ~failure_reason ~at:op_started_at ()
                              |> Result.map (fun () ->
                                     counts.failed <- counts.failed + 1)
                            | Ok copied_hash ->
                              if copied_hash <> content_hash then begin
                                ignore
                                  (Worker_client.unlink_path worker
                                     destination_path);
                                let failure_reason =
                                  Printf.sprintf
                                    "copy hash mismatch: expected %s got %s"
                                    content_hash copied_hash
                                in
                                record_copy_failure db ~run_id:run.id
                                  ~source_observation_id:
                                    source_observation.id
                                  ~file_object_id:file_object.id
                                  ~source_path:observed_path ~destination_path
                                  ~planned_relative_path:resolved_relative_path
                                  ~failure_reason ~at:op_started_at ()
                                |> Result.map (fun () ->
                                       counts.failed <- counts.failed + 1)
                              end
                              else
                                admit_success resolved_relative_path
                                  destination_path op_started_at))))))

let import_into_library_by_name db worker ~name ~source =
  match
    map_db_error ~context:[ ("library_name", name) ]
      (Db.get_library_by_name db name)
  with
  | Error _ as error -> error
  | Ok None ->
    Error
      (Utils.app_error ~code:Library_not_found
         ~context:[ ("library_name", name) ]
         "library was not found")
  | Ok (Some library) ->
    if Utils.path_within_root ~root_path:library.root_path source then
      Error
        (Utils.app_error ~code:Unsupported_operation
           ~context:[ ("source", source); ("library_root", library.root_path) ]
           "add does not support importing from inside the library root")
    else
      match Common.ensure_mount worker source with
      | Error _ as error -> error
      | Ok () -> (
          match Common.ensure_mount worker library.root_path with
          | Error _ as error -> error
          | Ok () ->
            let config = Config.of_json_string library.config_json in
            let started_at = Utils.now_iso () in
            match
              map_db_error
                ~context:[ ("library_id", string_of_int library.id); ("source", source) ]
                (Db.create_source_root db ~library_id:library.id
                   ~root_path:source ~source_kind:Source_kind.Import
                   ~created_at:started_at ())
            with
            | Error _ as error -> error
            | Ok source_root -> (
                match
                  map_db_error
                    ~context:[ ("library_id", string_of_int library.id) ]
                    (Db.create_run db ~library_id:library.id
                       ~source_root_id:source_root.id ~mode:Run_mode.Import
                       ~status:Run_status.Running
                       ~options_json:
                         (Yojson.Safe.to_string
                            (`Assoc [ ("source_path", `String source) ]))
                       ~started_at ())
                with
                | Error _ as error -> error
                | Ok run ->
                  let finish_error err counts =
                    let _ =
                      complete_run db run counts Run_status.Failed
                        ~error_text:(Utils.string_of_app_error err) ()
                    in
                    Error err
                  in
                  match
                    Worker_client.walk_tree worker ~root:source
                      ~extensions:(Config.all_extensions config)
                      ~exclude_patterns:config.exclude_patterns
                  with
                  | Error err ->
                    finish_error
                      (Utils.app_error_of_worker_error ~op:"walk_tree" ~path:source err)
                      (empty_counters ())
                  | Ok items -> (
                      match map_db_error (Db.list_library_placements db) with
                      | Error _ as error -> error
                      | Ok all_placements ->
                        let claimed =
                          List.fold_left
                            (fun acc (placement : library_placement) ->
                              if placement.library_id = library.id then
                                Utils.StringSet.add placement.intended_relative_path acc
                              else acc)
                            Utils.StringSet.empty all_placements
                          |> ref
                        in
                        let sorted_items =
                          List.sort
                            (fun (a : Worker_client.walk_item)
                                 (b : Worker_client.walk_item) ->
                              String.compare a.path b.path)
                            items
                        in
                        let counts = empty_counters () in
                        let rec loop = function
                          | [] -> Ok ()
                          | item :: rest -> (
                              match
                                process_item db worker library config source
                                  source_root run claimed counts item
                              with
                              | Error _ as error -> error
                              | Ok () -> loop rest)
                        in
                        match loop sorted_items with
                        | Error err -> finish_error err counts
                        | Ok () ->
                          let run_status =
                            if counts.failed > 0 then Run_status.Failed
                            else Run_status.Completed
                          in
                          match complete_run db run counts run_status () with
                          | Error _ as error -> error
                          | Ok () ->
                            Ok
                              {
                                source_root_id = source_root.id;
                                run_id = run.id;
                                observed = counts.observed;
                                admitted = counts.admitted;
                                duplicate_in_library = counts.duplicate_in_library;
                                quarantined = counts.quarantined;
                                failed = counts.failed;
                                path_conflicts = counts.path_conflicts;
                              })))

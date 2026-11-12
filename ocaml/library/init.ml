open Domain

let ( let* ) = Result.bind

let map_db_error ?(context = []) = function
  | Ok value -> Ok value
  | Error err ->
    Error
      {
        err with
        context =
          if context = [] then err.context else err.context @ context;
      }

type init_summary = {
  source_root_id : int;
  run_id : int;
  observed : int;
  skipped_managed : int;
  indexed_existing : int;
  moved : int;
  duplicate_in_library : int;
  quarantined : int;
  failed : int;
  path_conflicts : int;
}

type counters = {
  mutable observed : int;
  mutable skipped_managed : int;
  mutable indexed_existing : int;
  mutable moved : int;
  mutable duplicate_in_library : int;
  mutable quarantined : int;
  mutable failed : int;
  mutable path_conflicts : int;
}

type process_context = {
  db : Db.t;
  worker : Worker_client.t;
  library : library;
  config : Config.library_config;
  source_root : source_root;
  run : run;
  claimed : Utils.StringSet.t ref;
  counts : counters;
  observed_path : string;
  relative_path : string;
  original_filename : string;
  observed_at : string;
  item : Worker_client.walk_item;
}

let track_path_conflict counts had_conflict =
  if had_conflict then
    counts.path_conflicts <- counts.path_conflicts + 1

let create_library_item_and_placement ctx ~file_object_id ~run_item_id
    ~resolved_relative_path ~verified_at () =
  let* library_item =
    map_db_error
      ~context:
        [
          ("library_id", string_of_int ctx.library.id);
          ("file_object_id", string_of_int file_object_id);
        ]
      (Db.create_library_item ctx.db ~library_id:ctx.library.id
         ~file_object_id ~admitted_from_run_item_id:run_item_id
         ~status:Library_item_status.Active ())
  in
  map_db_error
    ~context:
      [
        ("library_id", string_of_int ctx.library.id);
        ("library_item_id", string_of_int library_item.id);
      ]
    (Db.create_library_placement ctx.db ~library_item_id:library_item.id
       ~library_id:ctx.library.id ~intended_relative_path:resolved_relative_path
       ~actual_relative_path:resolved_relative_path
       ~placement_status:Placement_status.Healthy ~last_verified_at:verified_at ())

let empty_counters () =
  {
    observed = 0;
    skipped_managed = 0;
    indexed_existing = 0;
    moved = 0;
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
        ("skipped_managed", `Int counts.skipped_managed);
        ("indexed_existing", `Int counts.indexed_existing);
        ("moved", `Int counts.moved);
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

let record_move_failure db ~run_id ~source_observation_id ?file_object_id
    ~op_kind ~source_path ?destination_path ?planned_relative_path
    ~failure_reason ~at () =
  match
    Common.create_run_item db ~run_id ~source_observation_id ?file_object_id
      ~workflow_state:Workflow_state.Failed ?planned_action:None
      ~disposition:Disposition.Failed ?planned_relative_path
      ~failure_reason ~created_at:at ()
  with
  | Error _ as error -> error
  | Ok run_item ->
    map_db_error
      ~context:[ ("run_id", string_of_int run_id); ("source_path", source_path) ]
      (Db.create_file_op db ~run_id ~run_item_id:run_item.id ~op_kind
         ~src_path:source_path ?dst_path:destination_path
         ~status:File_op_status.Failed ~error_text:failure_reason
         ~started_at:at ~completed_at:at ())
    |> Result.map (fun _ -> ())

let process_item db worker (library : library) config
    (source_root : source_root) (run : run) claimed managed_paths counts
    (item : Worker_client.walk_item) =
  counts.observed <- counts.observed + 1;
  let observed_path =
    if Filename.is_relative item.path then
      Filename.concat library.root_path item.path
    else item.path
  in
  let relative_path =
    match
      if Filename.is_relative item.path then Some item.path
      else Utils.relative_to_root ~root_path:library.root_path item.path
    with
    | Some path -> path
    | None -> item.path
  in

  let observed_at = Utils.now_iso () in
  let ctx =
    {
      db;
      worker;
      library;
      config;
      source_root;
      run;
      claimed;
      counts;
      observed_path;
      relative_path;
      original_filename = Filename.basename observed_path;
      observed_at;
      item;
    }
  in

  if Utils.StringSet.mem relative_path managed_paths then
    match
      Common.create_source_observation db ~run_id:run.id
        ~source_root_id:source_root.id ~observed_path ~relative_path
        ~size_bytes:item.size ~mtime:item.mtime ~observed_at ()
    with
    | Error _ as error -> error
    | Ok source_observation ->
      Common.create_run_item db ~run_id:run.id
        ~source_observation_id:source_observation.id
        ~workflow_state:Workflow_state.Completed
        ~planned_action:Planned_action.Skip ~disposition:Disposition.Skipped
        ~created_at:observed_at ()
      |> Result.map (fun _ ->
             counts.skipped_managed <- counts.skipped_managed + 1)
  else
    let original_filename = Filename.basename observed_path in
    let create_failure_without_hash failure_reason =
      match
        Common.create_source_observation db ~run_id:run.id
          ~source_root_id:source_root.id ~observed_path ~relative_path
          ~size_bytes:item.size ~mtime:item.mtime ~observed_at ()
      with
      | Error _ as error -> error
      | Ok source_observation ->
        Common.create_run_item db ~run_id:run.id
          ~source_observation_id:source_observation.id
          ~workflow_state:Workflow_state.Failed
          ~disposition:Disposition.Failed ~failure_reason
          ~created_at:observed_at ()
        |> Result.map (fun _ -> counts.failed <- counts.failed + 1)
    in
    let create_quarantine (source_observation : source_observation)
        file_object_id failure_reason =
      let quarantine_path =
        Config.(config.quarantine.path ^ Path.normalize_filename original_filename)
      in
      match
        Common.resolve_available_path worker ~library_root:library.root_path ~claimed
          quarantine_path
      with
      | Error _ as error -> error
      | Ok (resolved_quarantine_path, had_conflict) ->
        track_path_conflict counts had_conflict;
        let destination_path =
          Filename.concat library.root_path resolved_quarantine_path
        in
        let op_started_at = Utils.now_iso () in
        (match
           Worker_client.mkdir_all worker (Filename.dirname destination_path)
         with
        | Error err ->
          let failure_reason =
            Printf.sprintf "mkdir failed: %s" (Utils.string_of_worker_error err)
          in
          record_move_failure db ~run_id:run.id
            ~source_observation_id:source_observation.id
            ~file_object_id ~op_kind:File_op_kind.Quarantine_move
            ~source_path:observed_path ~destination_path
            ~planned_relative_path:resolved_quarantine_path
            ~failure_reason ~at:op_started_at ()
          |> Result.map (fun () -> counts.failed <- counts.failed + 1)
        | Ok () -> (
            match
              Worker_client.move_file worker ~src:observed_path
                ~dst:destination_path ~expected_hash:None
            with
            | Error err ->
              let failure_reason =
                Printf.sprintf "quarantine move failed: %s"
                  (Utils.string_of_worker_error err)
              in
              record_move_failure db ~run_id:run.id
                ~source_observation_id:source_observation.id
                ~file_object_id ~op_kind:File_op_kind.Quarantine_move
                ~source_path:observed_path ~destination_path
                ~planned_relative_path:resolved_quarantine_path
                ~failure_reason ~at:op_started_at ()
              |> Result.map (fun () -> counts.failed <- counts.failed + 1)
            | Ok _ ->
              (match
                 Common.create_run_item db ~run_id:run.id
                   ~source_observation_id:source_observation.id ~file_object_id
                   ~workflow_state:Workflow_state.Completed
                   ~planned_action:Planned_action.Quarantine
                   ~disposition:Disposition.Quarantined
                   ~planned_relative_path:resolved_quarantine_path
                   ~failure_reason ~created_at:observed_at ()
               with
              | Error _ as error -> error
              | Ok run_item ->
                map_db_error
                  ~context:
                    [ ("run_id", string_of_int run.id); ("source_path", observed_path) ]
                  (Db.create_file_op db ~run_id:run.id
                     ~run_item_id:run_item.id
                     ~op_kind:File_op_kind.Quarantine_move
                     ~src_path:observed_path ~dst_path:destination_path
                     ~status:File_op_status.Completed ~started_at:op_started_at
                     ~completed_at:(Utils.now_iso ()) ())
                |> Result.map (fun _ ->
                       counts.quarantined <- counts.quarantined + 1))))
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
          match
            Common.create_source_observation db ~run_id:run.id
              ~source_root_id:source_root.id ~observed_path ~relative_path
              ~size_bytes:item.size ~mtime:item.mtime ~observed_at
              ~file_object_id:file_object.id ()
          with
          | Error _ as error -> error
          | Ok source_observation -> (
              match capture_date with
              | None ->
                create_quarantine source_observation file_object.id
                  "no_usable_date"
              | Some capture_date -> (
                  match
                    Path.compute_library_path ~capture_date
                      ~camera_model:None ~filename:original_filename
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
                        let index_existing resolved_relative_path =
                          match
                            Common.create_run_item db ~run_id:run.id
                              ~source_observation_id:source_observation.id
                              ~file_object_id:file_object.id
                              ~workflow_state:Workflow_state.Completed
                              ~planned_action:Planned_action.Index_existing
                              ~disposition:Disposition.Admitted
                              ~planned_relative_path:resolved_relative_path
                              ~created_at:(Utils.now_iso ()) ()
                          with
                          | Error _ as error -> error
                          | Ok run_item ->
                            create_library_item_and_placement ctx ~file_object_id:file_object.id
                              ~run_item_id:run_item.id ~resolved_relative_path ~verified_at:observed_at ()
                            |> Result.map (fun _ ->
                                   counts.indexed_existing <- counts.indexed_existing + 1)
                        in
                        let move_into_place resolved_relative_path destination_path
                            had_conflict =
                          track_path_conflict counts had_conflict;
                          let op_started_at = Utils.now_iso () in
                          match
                            Worker_client.mkdir_all worker
                              (Filename.dirname destination_path)
                          with
                          | Error err ->
                            let failure_reason =
                              Printf.sprintf "mkdir failed: %s"
                                (Utils.string_of_worker_error err)
                            in
                            record_move_failure db ~run_id:run.id
                              ~source_observation_id:source_observation.id
                              ~file_object_id:file_object.id
                              ~op_kind:File_op_kind.Move
                              ~source_path:observed_path ~destination_path
                              ~planned_relative_path:resolved_relative_path
                              ~failure_reason ~at:op_started_at ()
                            |> Result.map (fun () ->
                                   counts.failed <- counts.failed + 1)
                          | Ok () -> (
                              match
                                Worker_client.move_file worker ~src:observed_path
                                  ~dst:destination_path
                                  ~expected_hash:(Some content_hash)
                              with
                              | Error err ->
                                let failure_reason =
                                  Printf.sprintf "move failed: %s"
                                    (Utils.string_of_worker_error err)
                                in
                                record_move_failure db ~run_id:run.id
                                  ~source_observation_id:source_observation.id
                                  ~file_object_id:file_object.id
                                  ~op_kind:File_op_kind.Move
                                  ~source_path:observed_path ~destination_path
                                  ~planned_relative_path:
                                    resolved_relative_path
                                  ~failure_reason ~at:op_started_at ()
                                |> Result.map (fun () ->
                                       counts.failed <- counts.failed + 1)
                              | Ok _ -> (
                                  match
                                    Common.create_run_item db ~run_id:run.id
                                      ~source_observation_id:
                                        source_observation.id
                                      ~file_object_id:file_object.id
                                      ~workflow_state:
                                        Workflow_state.Completed
                                      ~planned_action:
                                        Planned_action.Admit_move
                                      ~disposition:Disposition.Admitted
                                      ~planned_relative_path:
                                        resolved_relative_path
                                      ~created_at:(Utils.now_iso ()) ()
                                  with
                                  | Error _ as error -> error
                                  | Ok run_item -> (
                                      match
                                        create_library_item_and_placement ctx
                                          ~file_object_id:file_object.id
                                          ~run_item_id:run_item.id
                                          ~resolved_relative_path
                                          ~verified_at:op_started_at ()
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
                                             ~op_kind:File_op_kind.Move
                                             ~src_path:observed_path
                                             ~dst_path:destination_path
                                             ~status:File_op_status.Completed
                                             ~started_at:op_started_at
                                             ~completed_at:(Utils.now_iso ()) ())
                                        |> Result.map (fun _ ->
                                               ignore
                                                 (Worker_client.remove_empty_dirs worker
                                                    ~path:(Filename.dirname observed_path)
                                                    ~stop_at:library.root_path);
                                               counts.moved <- counts.moved + 1))))
                        in
                        if String.equal relative_path planned_relative_path then
                          index_existing planned_relative_path
                        else
                          match
                            Common.resolve_available_path worker
                              ~library_root:library.root_path ~claimed
                              planned_relative_path
                          with
                          | Error _ as error -> error
                          | Ok (resolved_relative_path, had_conflict) ->
                            let destination_path =
                              Filename.concat library.root_path
                                resolved_relative_path
                            in
                            move_into_place resolved_relative_path
                              destination_path had_conflict))))

let initialize_library_by_name db worker ~name =
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
  | Ok (Some library) -> (
      match Common.ensure_mount worker library.root_path with
      | Error _ as error -> error
      | Ok () ->
        let config = Config.of_json_string library.config_json in
        let started_at = Utils.now_iso () in
        match
          map_db_error
            ~context:
              [ ("library_id", string_of_int library.id); ("library_root", library.root_path) ]
            (Db.create_source_root db ~library_id:library.id
               ~root_path:library.root_path ~source_kind:Source_kind.Init_root
               ~created_at:started_at ())
        with
        | Error _ as error -> error
        | Ok source_root -> (
            match
              map_db_error
                ~context:[ ("library_id", string_of_int library.id) ]
                (Db.create_run db ~library_id:library.id
                   ~source_root_id:source_root.id ~mode:Run_mode.Init
                   ~status:Run_status.Running
                   ~options_json:
                     (Yojson.Safe.to_string
                        (`Assoc
                          [ ("library_root", `String library.root_path) ]))
                   ~started_at ())
            with
            | Error _ as error -> error
            | Ok run -> (
                let finish_error err counts =
                  let _ =
                    complete_run db run counts Run_status.Failed
                      ~error_text:(Utils.string_of_app_error err) ()
                  in
                  Error err
                in
                match
                  Worker_client.walk_tree worker ~root:library.root_path
                    ~extensions:(Config.all_extensions config)
                    ~exclude_patterns:config.exclude_patterns
                with
                | Error err ->
                  finish_error
                    (Utils.app_error_of_worker_error ~op:"walk_tree"
                       ~path:library.root_path err)
                    (empty_counters ())
                | Ok items -> (
                    match map_db_error (Db.list_library_placements db) with
                    | Error _ as error -> error
                    | Ok all_placements ->
                      let library_placements =
                        List.filter
                          (fun (placement : library_placement) ->
                            placement.library_id = library.id)
                          all_placements
                      in
                      let claimed =
                        List.fold_left
                          (fun acc (placement : library_placement) ->
                            Utils.StringSet.add placement.intended_relative_path acc)
                          Utils.StringSet.empty library_placements
                        |> ref
                      in
                      let managed_paths =
                        List.fold_left
                          (fun acc placement ->
                            Utils.StringSet.add (Common.actual_managed_path placement) acc)
                          Utils.StringSet.empty library_placements
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
                              process_item db worker library config
                                source_root run claimed managed_paths counts item
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
                              skipped_managed = counts.skipped_managed;
                              indexed_existing = counts.indexed_existing;
                              moved = counts.moved;
                              duplicate_in_library =
                                counts.duplicate_in_library;
                              quarantined = counts.quarantined;
                              failed = counts.failed;
                              path_conflicts = counts.path_conflicts;
                            }))))

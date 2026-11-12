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

let key library_id file_object_id =
  Printf.sprintf "%d|%d" library_id file_object_id

let run ~target ~state:_ ~report =
  match map_target_error (Db.list_runs target) with
  | Error _ as error -> error
  | Ok runs -> (
      match map_target_error (Db.list_run_items target) with
      | Error _ as error -> error
      | Ok run_items -> (
          match map_target_error (Db.list_library_items target) with
          | Error _ as error -> error
          | Ok library_items ->
            let runs_by_id = Hashtbl.create 32 in
            List.iter
              (fun (run : Domain.run) ->
                Hashtbl.replace runs_by_id run.id run)
              runs;
            let library_items_by_key = Hashtbl.create 64 in
            List.iter
              (fun (item : Domain.library_item) ->
                Hashtbl.replace library_items_by_key
                  (key item.library_id item.file_object_id) item)
              library_items;
            let rec loop = function
              | [] -> Ok ()
              | (run_item : Domain.run_item) :: rest -> (
                  match Hashtbl.find_opt runs_by_id run_item.run_id with
                  | None ->
                    Migration_report.add_warning report
                      (Printf.sprintf "run_item %d references missing run %d"
                         run_item.id run_item.run_id);
                    loop rest
                  | Some run -> (
                      match run_item.file_object_id with
                      | None -> loop rest
                      | Some file_object_id -> (
                          match
                            Hashtbl.find_opt library_items_by_key
                              (key run.library_id file_object_id)
                          with
                          | None ->
                            let anomaly =
                              match run_item.disposition with
                              | Some Domain.Disposition.Admitted ->
                                Some
                                  {
                                    Migration_types.kind =
                                      Imported_file_without_entry;
                                    legacy_table = "files";
                                    legacy_id = None;
                                    detail =
                                      Printf.sprintf
                                        "run_item %d is admitted in library %d \
                                         for file_object %d but no \
                                         library_item exists" run_item.id
                                        run.library_id file_object_id;
                                  }
                              | Some Domain.Disposition.Failed ->
                                Some
                                  {
                                    Migration_types.kind =
                                      Missing_without_library_link;
                                    legacy_table = "files";
                                    legacy_id = None;
                                    detail =
                                      Printf.sprintf
                                        "run_item %d is failed in library %d \
                                         for file_object %d but no \
                                         library_item exists" run_item.id
                                        run.library_id file_object_id;
                                  }
                              | _ -> None
                            in
                            Option.iter
                              (Migration_report.add_anomaly report)
                              anomaly;
                            loop rest
                          | Some library_item ->
                            let continue () = loop rest in
                            (match run_item.disposition with
                            | Some Domain.Disposition.Admitted ->
                              let conflict_result =
                                match
                                  map_target_error
                                    (Db.get_library_placement_by_library_item_id
                                       target library_item.id)
                                with
                                | Error _ as error -> error
                                | Ok placement_opt ->
                                  (match
                                     ( placement_opt,
                                       run_item.planned_relative_path )
                                   with
                                  | Some placement, Some planned_path
                                    when placement.intended_relative_path
                                         <> planned_path ->
                                    Migration_report.add_anomaly report
                                      {
                                        Migration_types.kind =
                                          Target_path_conflict;
                                        legacy_table = "files";
                                        legacy_id = None;
                                        detail =
                                          Printf.sprintf
                                            "run_item %d planned path %s but \
                                             library_item %d is placed at %s"
                                            run_item.id planned_path
                                            library_item.id
                                            placement.intended_relative_path;
                                      };
                                    Ok ()
                                  | _ -> Ok ())
                              in
                              (match conflict_result with
                              | Error _ as error -> error
                              | Ok () ->
                                let link_result =
                                  match
                                    library_item.admitted_from_run_item_id
                                  with
                                  | None ->
                                    Db.set_library_item_admitted_from_run_item
                                      target ~id:library_item.id
                                      ~run_item_id:run_item.id
                                      ~updated_at:run_item.updated_at
                                    |> map_target_error
                                  | Some existing_id when existing_id = run_item.id ->
                                    Ok ()
                                  | Some existing_id ->
                                    Migration_report.add_warning report
                                      (Printf.sprintf
                                         "library_item %d already linked to \
                                          admitted run_item %d; leaving existing \
                                          link in place instead of replacing it \
                                          with run_item %d"
                                         library_item.id existing_id
                                         run_item.id);
                                    Ok ()
                                in
                                (match link_result with
                                | Error _ as error -> error
                                | Ok () ->
                                  if
                                    Option.is_none
                                      library_item.admitted_from_run_item_id
                                  then
                                    Migration_report.incr report
                                      ~counter:"library_items_linked_to_runs";
                                  continue ()))
                            | Some Domain.Disposition.Failed
                              when run_item.workflow_state
                                   = Domain.Workflow_state.Failed ->
                              let status_result =
                                if
                                  library_item.status
                                  = Domain.Library_item_status.Missing
                                then Ok ()
                                else
                                  Db.update_library_item_status target
                                    ~id:library_item.id
                                    ~status:
                                      Domain.Library_item_status.Missing
                                    ~updated_at:run_item.updated_at
                                  |> map_target_error
                              in
                              (match status_result with
                              | Error _ as error -> error
                              | Ok () -> (
                                  match
                                    map_target_error
                                      (Db.get_library_placement_by_library_item_id
                                         target library_item.id)
                                  with
                                  | Error _ as error -> error
                                  | Ok None ->
                                    Migration_report.add_warning report
                                      (Printf.sprintf
                                         "library_item %d has no placement row \
                                          to mark missing during reconcile"
                                         library_item.id);
                                    Migration_report.incr report
                                      ~counter:"library_items_marked_missing";
                                    continue ()
                                  | Ok (Some placement) -> (
                                      match
                                        map_target_error
                                          (Db.update_library_placement_state
                                             target ~id:placement.id
                                             ~placement_status:
                                               Domain.Placement_status.Missing
                                             ~last_verified_at:
                                               run_item.updated_at
                                             ?error_text:run_item.failure_reason
                                             ~updated_at:run_item.updated_at ())
                                      with
                                      | Error _ as error -> error
                                      | Ok () ->
                                        Migration_report.incr report
                                          ~counter:"library_items_marked_missing";
                                        Migration_report.incr report
                                          ~counter:"library_placements_marked_missing";
                                        continue ())))
                            | _ -> continue ()))))
            in
            loop run_items))

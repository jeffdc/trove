open Domain

type library_item_counts = {
  active : int;
  missing : int;
  broken : int;
  retired : int;
}

type placement_counts = {
  healthy : int;
  misplaced : int;
  missing : int;
  repair_needed : int;
}

type library_status = {
  library : library;
  total_library_items : int;
  total_placements : int;
  items_without_placement : int;
  library_item_counts : library_item_counts;
  placement_counts : placement_counts;
}

type verify_issue = {
  placement : library_placement;
  observed_status : Placement_status.t;
  observed_relative_path : string option;
  detail : string option;
}

type verify_report = {
  library_status : library_status;
  checked_placements : int;
  observed_placement_counts : placement_counts;
  placement_status_mismatches : int;
  issues : verify_issue list;
}

let zero_library_item_counts =
  { active = 0; missing = 0; broken = 0; retired = 0 }

let zero_placement_counts =
  { healthy = 0; misplaced = 0; missing = 0; repair_needed = 0 }

let map_db_error ?(context = []) = function
  | Ok value -> Ok value
  | Error err ->
    Error
      {
        err with
        context =
          if context = [] then err.context else err.context @ context;
      }

let list_libraries db = map_db_error (Db.list_libraries db)

type library_snapshot = {
  library : library;
  items : library_item list;
  placements : library_placement list;
}

type path_state =
  | Missing
  | File
  | Directory

let add_library_item_count counts status =
  match status with
  | Library_item_status.Active ->
    { counts with active = counts.active + 1 }
  | Library_item_status.Missing ->
    { counts with missing = counts.missing + 1 }
  | Library_item_status.Broken ->
    { counts with broken = counts.broken + 1 }
  | Library_item_status.Retired ->
    { counts with retired = counts.retired + 1 }

let add_placement_count counts status =
  match status with
  | Placement_status.Healthy ->
    { counts with healthy = counts.healthy + 1 }
  | Placement_status.Misplaced ->
    { counts with misplaced = counts.misplaced + 1 }
  | Placement_status.Missing ->
    { counts with missing = counts.missing + 1 }
  | Placement_status.Repair_needed ->
    { counts with repair_needed = counts.repair_needed + 1 }

let load_library_snapshot_by_name db name =
  match map_db_error ~context:[ ("library_name", name) ] (Db.get_library_by_name db name) with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some library) -> (
      match map_db_error (Db.list_library_items db) with
      | Error _ as error -> error
      | Ok all_items -> (
          match map_db_error (Db.list_library_placements db) with
          | Error _ as error -> error
          | Ok all_placements ->
            let items =
              List.filter
                (fun (item : library_item) -> item.library_id = library.id)
                all_items
            in
            let placements =
              List.filter
                (fun (placement : library_placement) ->
                  placement.library_id = library.id)
                all_placements
            in
            Ok (Some { library; items; placements })))

let summarize_snapshot snapshot =
  let item_ids_with_placement = Hashtbl.create (List.length snapshot.placements) in
  List.iter
    (fun (placement : library_placement) ->
      Hashtbl.replace item_ids_with_placement placement.library_item_id true)
    snapshot.placements;
  let library_item_counts =
    List.fold_left
      (fun counts (item : library_item) ->
        add_library_item_count counts item.status)
      zero_library_item_counts snapshot.items
  in
  let placement_counts =
    List.fold_left
      (fun counts (placement : library_placement) ->
        add_placement_count counts placement.placement_status)
      zero_placement_counts snapshot.placements
  in
  let items_without_placement =
    List.fold_left
      (fun count (item : library_item) ->
        if Hashtbl.mem item_ids_with_placement item.id then count else count + 1)
      0 snapshot.items
  in
  {
    library = snapshot.library;
    total_library_items = List.length snapshot.items;
    total_placements = List.length snapshot.placements;
    items_without_placement;
    library_item_counts;
    placement_counts;
  }

let get_library_status_by_name db name =
  match load_library_snapshot_by_name db name with
  | Error _ as error -> error
  | Ok None ->
    Error
      (Utils.app_error ~code:Domain.Library_not_found
         ~context:[ ("library_name", name) ]
         "library was not found")
  | Ok (Some snapshot) -> Ok (summarize_snapshot snapshot)

let stat_path_state worker full_path =
  match Worker_client.path_exists worker full_path with
  | Error err ->
    Error (Utils.app_error_of_worker_error ~op:"path_exists" ~path:full_path err)
  | Ok false -> Ok Missing
  | Ok true -> (
      match Worker_client.stat_path worker full_path with
      | Error err ->
        Error (Utils.app_error_of_worker_error ~op:"stat_path" ~path:full_path err)
      | Ok stat -> if stat.is_dir then Ok Directory else Ok File)

let resolve_actual_relative_path placement =
  match placement.actual_relative_path with
  | Some path when not (String.equal path "") -> path
  | _ -> placement.intended_relative_path

let verify_placement snapshot worker placement =
  let root_path = snapshot.library.root_path in
  let intended_relative_path = placement.intended_relative_path in
  let actual_relative_path = resolve_actual_relative_path placement in
  let intended_full_path = Filename.concat root_path intended_relative_path in
  let actual_full_path =
    if String.equal actual_relative_path intended_relative_path then
      intended_full_path
    else Filename.concat root_path actual_relative_path
  in
  match stat_path_state worker intended_full_path with
  | Error _ as error -> error
  | Ok intended_state when String.equal actual_relative_path intended_relative_path
    -> (
      match intended_state with
      | File ->
        Ok
          {
            placement;
            observed_status = Placement_status.Healthy;
            observed_relative_path = Some intended_relative_path;
            detail = None;
          }
      | Directory ->
        Ok
          {
            placement;
            observed_status = Placement_status.Repair_needed;
            observed_relative_path = Some intended_relative_path;
            detail = Some "expected file but found directory at intended path";
          }
      | Missing ->
        Ok
          {
            placement;
            observed_status = Placement_status.Missing;
            observed_relative_path = None;
            detail = Some "file missing at intended path";
          })
  | Ok intended_state -> (
      match stat_path_state worker actual_full_path with
      | Error _ as error -> error
      | Ok actual_state -> (
          match (intended_state, actual_state) with
          | Missing, File ->
            Ok
              {
                placement;
                observed_status = Placement_status.Misplaced;
                observed_relative_path = Some actual_relative_path;
                detail =
                  Some "file present at actual path but not at intended path";
              }
          | Missing, Directory ->
            Ok
              {
                placement;
                observed_status = Placement_status.Repair_needed;
                observed_relative_path = Some actual_relative_path;
                detail = Some "expected file but found directory at actual path";
              }
          | Missing, Missing ->
            Ok
              {
                placement;
                observed_status = Placement_status.Missing;
                observed_relative_path = None;
                detail = Some "file missing at both intended and actual paths";
              }
          | File, Missing ->
            Ok
              {
                placement;
                observed_status = Placement_status.Repair_needed;
                observed_relative_path = Some intended_relative_path;
                detail =
                  Some "file present at intended path but actual path differs";
              }
          | File, File ->
            Ok
              {
                placement;
                observed_status = Placement_status.Repair_needed;
                observed_relative_path = Some actual_relative_path;
                detail =
                  Some "file exists at both intended and actual paths";
              }
          | File, Directory ->
            Ok
              {
                placement;
                observed_status = Placement_status.Repair_needed;
                observed_relative_path = Some intended_relative_path;
                detail =
                  Some
                    "file present at intended path but actual path is a \
                     directory";
              }
          | Directory, Missing ->
            Ok
              {
                placement;
                observed_status = Placement_status.Repair_needed;
                observed_relative_path = Some intended_relative_path;
                detail = Some "expected file but found directory at intended path";
              }
          | Directory, File ->
            Ok
              {
                placement;
                observed_status = Placement_status.Repair_needed;
                observed_relative_path = Some actual_relative_path;
                detail =
                  Some
                    "intended path is a directory and actual path holds the file";
              }
          | Directory, Directory ->
            Ok
              {
                placement;
                observed_status = Placement_status.Repair_needed;
                observed_relative_path = Some actual_relative_path;
                detail =
                  Some "expected files but found directories at both paths";
              }))

let verify_library_by_name ?progress db worker name =
  match load_library_snapshot_by_name db name with
  | Error _ as error -> error
  | Ok None ->
    Error
      (Utils.app_error ~code:Domain.Library_not_found
         ~context:[ ("library_name", name) ]
         "library was not found")
  | Ok (Some snapshot) -> (
      match
        Worker_client.check_mount worker ~path:snapshot.library.root_path
          ~timeout_seconds:10
      with
      | Error err ->
        Error
          (Utils.app_error_of_worker_error ~op:"check_mount"
             ~path:snapshot.library.root_path err)
      | Ok false ->
        Error
          (Utils.app_error ~code:Domain.Mount_unavailable
             ~context:[ ("path", snapshot.library.root_path) ]
             "library root path is not mounted")
      | Ok true ->
        let library_status = summarize_snapshot snapshot in
        let total = List.length snapshot.placements in
        let rec loop index observed_placement_counts
            placement_status_mismatches issues = function
          | [] ->
            Ok
              {
                library_status;
                checked_placements = total;
                observed_placement_counts;
                placement_status_mismatches;
                issues = List.rev issues;
              }
          | placement :: rest -> (
              match verify_placement snapshot worker placement with
              | Error _ as error -> error
              | Ok issue ->
                let observed_placement_counts =
                  add_placement_count observed_placement_counts
                    issue.observed_status
                in
                let placement_status_mismatches =
                  if issue.observed_status <> placement.placement_status then
                    placement_status_mismatches + 1
                  else placement_status_mismatches
                in
                let issues =
                  if issue.observed_status <> Placement_status.Healthy then
                    issue :: issues
                  else issues
                in
                Option.iter
                  (fun callback -> callback ~checked:(index + 1) ~total)
                  progress;
                loop (index + 1) observed_placement_counts
                  placement_status_mismatches issues rest)
        in
        match loop 0 zero_placement_counts 0 [] snapshot.placements with
        | Error _ as error -> error
        | Ok report -> Ok report)

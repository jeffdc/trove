open Cmdliner

let find_worker_path () =
  let rec ancestor_dirs dir =
    let parent = Filename.dirname dir in
    if String.equal parent dir then [ dir ] else dir :: ancestor_dirs parent
  in
  let candidate_paths () =
    let dirs = ancestor_dirs (Sys.getcwd ()) in
    let make_path dir a b = Filename.concat (Filename.concat dir a) b in
    List.map (fun dir -> make_path dir "grove" "worker") dirs
  in
  match Sys.getenv_opt "GROVE_WORKER_PATH" with
  | Some p when Sys.file_exists p -> Ok p
  | Some p ->
    Error
      (Utils.app_error ~code:Domain.Filesystem_not_found
         ~context:[ ("path", p); ("env", "GROVE_WORKER_PATH") ]
         "GROVE_WORKER_PATH does not point to an existing file")
  | None -> (
      match List.find_opt Sys.file_exists (candidate_paths ()) with
      | Some p -> Ok p
      | None ->
        Error
          (Utils.app_error ~code:Domain.Filesystem_not_found
             ~context:[ ("env", "GROVE_WORKER_PATH") ]
             "cannot find worker binary; set GROVE_WORKER_PATH to a built grove worker binary"))

let resolve_db_path = function
  | Some p -> p
  | None ->
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"." in
    let dir = Filename.concat home ".trove" in
    Filename.concat dir "state.db"

let with_db db_opt f =
  let path = resolve_db_path db_opt in
  let db = Db.open_db path in
  Fun.protect ~finally:(fun () -> Db.close db) (fun () -> f db)

let with_worker f =
  match find_worker_path () with
  | Error _ as error -> error
  | Ok path -> (
      match Worker_client.start ~worker_path:path () with
      | Error err ->
        Error (Utils.app_error_of_worker_error ~op:"start_worker" ~path err)
      | Ok worker ->
        Ok
          (Fun.protect ~finally:(fun () -> Worker_client.stop worker) (fun () ->
               f worker)))

let report_app_error ?prefix err =
  match prefix with
  | Some p -> Printf.eprintf "%s: %s\n" p (Utils.string_of_app_error err)
  | None -> Printf.eprintf "%s\n" (Utils.string_of_app_error err)

let print_placement_counts label (counts : Runtime.placement_counts) =
  Printf.printf "%s\n" label;
  Printf.printf "  healthy:       %d\n" counts.healthy;
  Printf.printf "  misplaced:     %d\n" counts.misplaced;
  Printf.printf "  missing:       %d\n" counts.missing;
  Printf.printf "  repair_needed: %d\n" counts.repair_needed

let print_import_summary (summary : Import.import_summary) =
  Printf.printf "Import complete:\n";
  Printf.printf "  Source root id:         %d\n" summary.source_root_id;
  Printf.printf "  Run id:                 %d\n" summary.run_id;
  Printf.printf "  Observed:               %d\n" summary.observed;
  Printf.printf "  Admitted:               %d\n" summary.admitted;
  Printf.printf "  Duplicates in library:  %d\n" summary.duplicate_in_library;
  Printf.printf "  Quarantined:            %d\n" summary.quarantined;
  Printf.printf "  Failed:                 %d\n" summary.failed;
  Printf.printf "  Path conflicts:         %d\n" summary.path_conflicts

let print_init_summary (summary : Init.init_summary) =
  Printf.printf "Init complete:\n";
  Printf.printf "  Source root id:         %d\n" summary.source_root_id;
  Printf.printf "  Run id:                 %d\n" summary.run_id;
  Printf.printf "  Observed:               %d\n" summary.observed;
  Printf.printf "  Skipped managed:        %d\n" summary.skipped_managed;
  Printf.printf "  Indexed existing:       %d\n" summary.indexed_existing;
  Printf.printf "  Moved:                  %d\n" summary.moved;
  Printf.printf "  Duplicates in library:  %d\n" summary.duplicate_in_library;
  Printf.printf "  Quarantined:            %d\n" summary.quarantined;
  Printf.printf "  Failed:                 %d\n" summary.failed;
  Printf.printf "  Path conflicts:         %d\n" summary.path_conflicts

let not_implemented command_name =
  Printf.printf "%s is not implemented yet for the new schema.\n" command_name

let db_path =
  let doc = "Path to state database." in
  Arg.(value & opt (some string) None & info [ "db" ] ~doc)

let _verbose =
  let doc = "Verbose output." in
  Arg.(value & flag & info [ "v"; "verbose" ] ~doc)

let _quiet =
  let doc = "Suppress non-essential output." in
  Arg.(value & flag & info [ "q"; "quiet" ] ~doc)

let create_cmd =
  let name_arg =
    let doc = "Name for the new library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let location_arg =
    let doc = "Filesystem path for the library." in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"LOCATION" ~doc)
  in
  let structure =
    let doc =
      "Strftime date structure for organizing files (e.g. %%Y/%%m/%%d)."
    in
    Arg.(value & opt (some string) None & info [ "structure" ] ~doc)
  in
  let no_camera_model =
    let doc = "Disable camera model in directory structure." in
    Arg.(value & flag & info [ "no-camera-model" ] ~doc)
  in
  let run db_opt name location structure no_camera_model =
    with_db db_opt (fun db ->
        let config = Config.default in
        let org = config.organization in
        let org =
          match structure with
          | Some s -> { org with structure = s }
          | None -> org
        in
        let org =
          if no_camera_model then
            { org with include_camera_model = false }
          else org
        in
        let config = { config with organization = org } in
        let config_json = Config.to_json_string config in
        match Db.create_library db ~name ~root_path:location ~config_json with
        | Ok lib ->
          Printf.printf "Created library %S at %s (id=%d)\n" lib.name
            lib.root_path lib.id
        | Error err ->
          report_app_error ~prefix:"Failed to create library" err;
          exit 1)
  in
  let term =
    Term.(
      const run $ db_path $ name_arg $ location_arg $ structure
      $ no_camera_model)
  in
  Cmd.v (Cmd.info "create" ~doc:"Create a new library") term

let list_cmd =
  let run db_opt =
    with_db db_opt (fun db ->
        match Runtime.list_libraries db with
        | Error err ->
          report_app_error ~prefix:"Error listing libraries" err;
          exit 1
        | Ok libs ->
          if libs = [] then
            Printf.printf "No libraries found.\n"
          else begin
            Printf.printf "%-20s %-40s %s\n" "NAME" "ROOT PATH" "CREATED";
            Printf.printf "%s\n" (String.make 90 '-');
            List.iter
              (fun (lib : Domain.library) ->
                Printf.printf "%-20s %-40s %s\n" lib.name lib.root_path
                  lib.created_at)
              libs
          end)
  in
  let term = Term.(const run $ db_path) in
  Cmd.v (Cmd.info "list" ~doc:"List all libraries") term

let add_cmd =
  let name_arg =
    let doc = "Name of the library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let source_arg =
    let doc = "Source directory to import from." in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"SOURCE" ~doc)
  in
  let run db_opt name source =
    with_db db_opt (fun db ->
        match with_worker (fun worker ->
                  Import.import_into_library_by_name db worker ~name ~source)
        with
        | Error err ->
          report_app_error ~prefix:"Error starting worker" err;
          exit 1
        | Ok (Error err) ->
          report_app_error ~prefix:"Error importing into library" err;
          exit 1
        | Ok (Ok summary) -> print_import_summary summary)
  in
  let term = Term.(const run $ db_path $ name_arg $ source_arg) in
  Cmd.v (Cmd.info "add" ~doc:"Import files from a source into a library") term

let init_cmd =
  let name_arg =
    let doc = "Name of the library to initialize." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let run db_opt name =
    with_db db_opt (fun db ->
        match with_worker (fun worker ->
                  Init.initialize_library_by_name db worker ~name)
        with
        | Error err ->
          report_app_error ~prefix:"Error starting worker" err;
          exit 1
        | Ok (Error err) ->
          report_app_error ~prefix:"Error initializing library" err;
          exit 1
        | Ok (Ok summary) -> print_init_summary summary)
  in
  let term = Term.(const run $ db_path $ name_arg) in
  Cmd.v
    (Cmd.info "init"
       ~doc:"Initialize unmanaged files already under a library root")
    term

let status_cmd =
  let name_arg =
    let doc = "Name of the library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let run db_opt name =
    with_db db_opt (fun db ->
        match Runtime.get_library_status_by_name db name with
        | Error err ->
          report_app_error ~prefix:"Error reading library status" err;
          exit 1
        | Ok status ->
          Printf.printf "Library: %s\n" status.library.name;
          Printf.printf "Root path: %s\n" status.library.root_path;
          Printf.printf "Created: %s\n" status.library.created_at;
          Printf.printf "Updated: %s\n" status.library.updated_at;
          Printf.printf "Library items: %d\n" status.total_library_items;
          Printf.printf "Placements: %d\n" status.total_placements;
          Printf.printf "Items without placement: %d\n"
            status.items_without_placement;
          Printf.printf "\nLibrary item status:\n";
          Printf.printf "  active:   %d\n" status.library_item_counts.active;
          Printf.printf "  missing:  %d\n" status.library_item_counts.missing;
          Printf.printf "  broken:   %d\n" status.library_item_counts.broken;
          Printf.printf "  retired:  %d\n" status.library_item_counts.retired;
          Printf.printf "\nPlacement status:\n";
          Printf.printf "  healthy:       %d\n" status.placement_counts.healthy;
          Printf.printf "  misplaced:     %d\n" status.placement_counts.misplaced;
          Printf.printf "  missing:       %d\n" status.placement_counts.missing;
          Printf.printf "  repair_needed: %d\n"
            status.placement_counts.repair_needed)
  in
  let term = Term.(const run $ db_path $ name_arg) in
  Cmd.v (Cmd.info "status" ~doc:"Show library status") term

let verify_cmd =
  let name_arg =
    let doc = "Name of the library to verify." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let max_issues_arg =
    let doc = "Maximum number of non-healthy placements to print." in
    Arg.(value & opt int 50 & info [ "max-issues" ] ~docv:"N" ~doc)
  in
  let run db_opt name max_issues =
    with_db db_opt (fun db ->
        let started_at = Unix.gettimeofday () in
        let last_reported = ref 0 in
        match with_worker (fun worker ->
                  let progress ~checked ~total =
                    if
                      checked = total || checked = 1
                      || checked - !last_reported >= 250
                    then begin
                      last_reported := checked;
                      let percent =
                        if total = 0 then 100.0
                        else
                          (float_of_int checked *. 100.0)
                          /. float_of_int total
                      in
                      let elapsed = Unix.gettimeofday () -. started_at in
                      Printf.printf
                        "\rChecking placements: %d/%d (%.1f%%, %.0fs elapsed)%!"
                        checked total percent elapsed
                    end
                  in
                  Runtime.verify_library_by_name ~progress db worker name)
        with
        | Error err ->
          if !last_reported > 0 then Printf.printf "\n%!";
          report_app_error ~prefix:"Error starting worker" err;
          exit 1
        | Ok (Error err) ->
          if !last_reported > 0 then Printf.printf "\n%!";
          report_app_error ~prefix:"Error verifying library" err;
          exit 1
        | Ok (Ok report) ->
          if report.checked_placements > 0 then Printf.printf "\n%!";
          Printf.printf "Library: %s\n" report.library_status.library.name;
          Printf.printf "Root path: %s\n"
            report.library_status.library.root_path;
          Printf.printf "Library items: %d\n"
            report.library_status.total_library_items;
          Printf.printf "Placements checked: %d\n" report.checked_placements;
          Printf.printf "Items without placement: %d\n"
            report.library_status.items_without_placement;
          Printf.printf "Placement status mismatches: %d\n"
            report.placement_status_mismatches;
          Printf.printf "\n";
          print_placement_counts "Recorded placement status:"
            report.library_status.placement_counts;
          Printf.printf "\n";
          print_placement_counts "Observed placement status:"
            report.observed_placement_counts;
          if report.issues = [] then
            Printf.printf "\nNo placement issues detected.\n"
          else begin
            let shown_issues = min max_issues (List.length report.issues) in
            Printf.printf "\nPlacement issues: %d\n"
              (List.length report.issues);
            List.to_seq report.issues
            |> Seq.take shown_issues
            |> Seq.iter (fun (issue : Runtime.verify_issue) ->
                   Printf.printf "  %s: intended=%s"
                     (Domain.Placement_status.to_string issue.observed_status)
                     issue.placement.intended_relative_path;
                   (match issue.observed_relative_path with
                   | Some path
                     when not
                            (String.equal path
                               issue.placement.intended_relative_path) ->
                     Printf.printf " observed=%s" path
                   | _ -> ());
                   (match issue.detail with
                   | Some detail -> Printf.printf "  (%s)" detail
                   | None -> ());
                   Printf.printf "\n");
            if shown_issues < List.length report.issues then
              Printf.printf "  ... %d more issue(s) not shown\n"
                (List.length report.issues - shown_issues)
          end;
          if report.issues = [] && report.placement_status_mismatches = 0
             && report.library_status.items_without_placement = 0
          then
            Printf.printf "\nStatus: OK\n"
          else Printf.printf "\nStatus: ISSUES FOUND\n")
  in
  let term = Term.(const run $ db_path $ name_arg $ max_issues_arg) in
  Cmd.v
    (Cmd.info "verify"
       ~doc:"Verify managed placements on disk against the schema")
    term

let hash_cmd =
  let name_arg =
    let doc = "Name of the library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let run _db_opt _name = not_implemented "hash" in
  let term = Term.(const run $ db_path $ name_arg) in
  Cmd.v
    (Cmd.info "hash"
       ~doc:"Hash library content (not implemented yet)")
    term

let duplicates_cmd =
  let name_arg =
    let doc = "Name of the library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let run _db_opt _name = not_implemented "duplicates" in
  let term = Term.(const run $ db_path $ name_arg) in
  Cmd.v
    (Cmd.info "duplicates"
       ~doc:"Report duplicates in a library (not implemented yet)")
    term

let relocate_cmd =
  let name_arg =
    let doc = "Name of the library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let path_arg =
    let doc = "New filesystem path for the library." in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"PATH" ~doc)
  in
  let run _db_opt _name _path = not_implemented "relocate" in
  let term = Term.(const run $ db_path $ name_arg $ path_arg) in
  Cmd.v
    (Cmd.info "relocate"
       ~doc:"Update library location (not implemented yet)")
    term

let migrate_db_cmd =
  let source_arg =
    let doc = "Path to the source legacy database copy." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"SOURCE_DB" ~doc)
  in
  let schema_arg =
    let doc = "Path to the migrated schema database to create." in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"SCHEMA_DB" ~doc)
  in
  let report_arg =
    let doc = "Path to the JSON migration report to write." in
    Arg.(required & pos 2 (some string) None & info [] ~docv:"REPORT_JSON" ~doc)
  in
  let run source_db_path schema_db_path report_path =
    let options : Migrator.options =
      { source_db_path; schema_db_path; report_path }
    in
    match Migrator.run options with
    | Ok () ->
      Printf.printf "Migration complete.\n";
      Printf.printf "  Legacy DB:      %s\n" source_db_path;
      Printf.printf "  New schema DB:  %s\n" schema_db_path;
      Printf.printf "  Report:         %s\n" report_path
    | Error err ->
      report_app_error ~prefix:"Migration failed" err;
      exit 1
  in
  let term = Term.(const run $ source_arg $ schema_arg $ report_arg) in
  Cmd.v
    (Cmd.info "migrate-db"
       ~doc:"Migrate a copied legacy database into the new schema")
    term

let info = Cmd.info "trove" ~doc:"Photo organization tool"

let cmd =
  Cmd.group info
    [
      create_cmd;
      list_cmd;
      add_cmd;
      init_cmd;
      status_cmd;
      verify_cmd;
      hash_cmd;
      duplicates_cmd;
      relocate_cmd;
      migrate_db_cmd;
    ]

let () = exit (Cmd.eval cmd)

open Cmdliner

(* -------------------------------------------------------------------------- *)
(* Helpers                                                                    *)
(* -------------------------------------------------------------------------- *)

let find_worker_path () =
  match Sys.getenv_opt "GROVE_WORKER_PATH" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    let candidates = [ "./worker/worker"; "../worker/worker" ] in
    (match List.find_opt Sys.file_exists candidates with
     | Some p -> p
     | None -> failwith "Cannot find worker binary. Set GROVE_WORKER_PATH.")

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
  let path = find_worker_path () in
  let w = Worker_client.start ~worker_path:path in
  Fun.protect ~finally:(fun () -> Worker_client.stop w) (fun () -> f w)

let require_library db name =
  match Db.get_library db name with
  | Some lib -> lib
  | None ->
    Printf.eprintf "Error: library %S not found.\n" name;
    exit 1

(* -------------------------------------------------------------------------- *)
(* Global options                                                             *)
(* -------------------------------------------------------------------------- *)

let db_path =
  let doc = "Path to state database." in
  Arg.(value & opt (some string) None & info [ "db" ] ~doc)

let _verbose =
  let doc = "Verbose output." in
  Arg.(value & flag & info [ "v"; "verbose" ] ~doc)

let _quiet =
  let doc = "Suppress non-essential output." in
  Arg.(value & flag & info [ "q"; "quiet" ] ~doc)

(* -------------------------------------------------------------------------- *)
(* 1. create <name> <location>                                                *)
(* -------------------------------------------------------------------------- *)

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
    let doc = "Strftime date structure for organizing files (e.g. %%Y/%%m/%%d)." in
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
        if no_camera_model then { org with include_camera_model = false }
        else org
      in
      let config = { config with organization = org } in
      let config_json = Config.to_json_string config in
      let lib = Db.create_library db ~name ~location ~config_json in
      Printf.printf "Created library %S at %s (id=%d)\n" lib.name lib.location lib.id)
  in
  let term = Term.(const run $ db_path $ name_arg $ location_arg $ structure $ no_camera_model) in
  Cmd.v (Cmd.info "create" ~doc:"Create a new library") term

(* -------------------------------------------------------------------------- *)
(* 2. list                                                                    *)
(* -------------------------------------------------------------------------- *)

let list_cmd =
  let run db_opt =
    with_db db_opt (fun db ->
      let libs = Db.list_libraries db in
      if libs = [] then
        Printf.printf "No libraries found.\n"
      else begin
        Printf.printf "%-20s %-40s %8s  %s\n" "NAME" "LOCATION" "ENTRIES" "CREATED";
        Printf.printf "%s\n" (String.make 90 '-');
        List.iter (fun (lib : Domain.library) ->
          let entries = Db.list_entries db lib.id in
          Printf.printf "%-20s %-40s %8d  %s\n"
            lib.name lib.location (List.length entries) lib.created_at
        ) libs
      end)
  in
  let term = Term.(const run $ db_path) in
  Cmd.v (Cmd.info "list" ~doc:"List all libraries") term

(* -------------------------------------------------------------------------- *)
(* 3. add <name> <source>                                                     *)
(* -------------------------------------------------------------------------- *)

let add_cmd =
  let name_arg =
    let doc = "Name of the target library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let source_arg =
    let doc = "Source directory to import from." in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"SOURCE" ~doc)
  in
  let run db_opt name source =
    with_db db_opt (fun db ->
      with_worker (fun w ->
        let lib = require_library db name in
        let config = Config.of_json_string lib.config_json in

        (* Check mount *)
        Printf.printf "Checking mount for %s...\n" source;
        (match Worker_client.check_mount w ~path:source ~timeout_seconds:10 with
         | Ok true -> ()
         | Ok false ->
           Printf.eprintf "Error: source path %S is not mounted.\n" source;
           exit 1
         | Error e ->
           Printf.eprintf "Error checking mount: %s\n"
             (match e with
              | Domain.Timeout -> "timeout"
              | Domain.Io_error msg -> msg
              | _ -> "unknown error");
           exit 1);

        Printf.printf "Checking mount for %s...\n" lib.location;
        (match Worker_client.check_mount w ~path:lib.location ~timeout_seconds:10 with
         | Ok true -> ()
         | Ok false ->
           Printf.eprintf "Error: library path %S is not mounted.\n" lib.location;
           exit 1
         | Error e ->
           Printf.eprintf "Error checking mount: %s\n"
             (match e with
              | Domain.Timeout -> "timeout"
              | Domain.Io_error msg -> msg
              | _ -> "unknown error");
           exit 1);

        (* Walk source *)
        Printf.printf "Scanning %s...\n" source;
        let extensions = Config.all_extensions config in
        let items =
          match Worker_client.walk_tree w ~root:source ~extensions ~exclude_patterns:config.exclude_patterns with
          | Ok items -> items
          | Error e ->
            Printf.eprintf "Error walking source: %s\n"
              (match e with
               | Domain.Timeout -> "timeout"
               | Domain.Io_error msg -> msg
               | _ -> "unknown error");
            exit 1
        in
        Printf.printf "Found %d files.\n" (List.length items);

        (* Discover and persist *)
        Printf.printf "Discovering files...\n";
        let new_ids, skip_count =
          Pipeline.discover_and_persist_from_items db
            ~source_path:source ~source_type:"import"
            items ~skip_paths:Pipeline.StringSet.empty
        in
        Printf.printf "Discovered %d new files, skipped %d unchanged.\n"
          (List.length new_ids) skip_count;

        (* Hash *)
        Printf.printf "Hashing files...\n";
        let hashed_ids = Pipeline.hash_files db w new_ids in
        Printf.printf "Hashed %d files.\n" (List.length hashed_ids);

        (* Compute paths (metadata extraction skipped) *)
        Printf.printf "Computing target paths...\n";
        let path_ids = Pipeline.compute_paths db hashed_ids config in

        (* Classify *)
        let plan = Import.classify_for_import db ~library_id:lib.id path_ids config in
        Printf.printf "Import plan: %d to import, %d batch duplicates, %d library duplicates, %d path conflicts, %d skipped.\n"
          (List.length plan.to_import)
          (List.length plan.duplicates_in_batch)
          (List.length plan.duplicates_in_library)
          plan.path_conflicts
          (List.length plan.skipped);

        (* Execute *)
        Printf.printf "Importing...\n";
        let summary = Import.execute_import db w lib config plan in
        Printf.printf "\nImport complete:\n";
        Printf.printf "  Imported:             %d\n" summary.imported;
        Printf.printf "  Duplicates (batch):   %d\n" summary.dup_in_batch;
        Printf.printf "  Duplicates (library): %d\n" summary.dup_in_library;
        Printf.printf "  Path conflicts:       %d\n" summary.path_conflicts;
        Printf.printf "  Errors:               %d\n" summary.errors;

        (* Note: completion step skipped — Complete module not yet available *)
        Printf.printf "\nNote: completion step skipped (module not yet implemented).\n"))
  in
  let term = Term.(const run $ db_path $ name_arg $ source_arg) in
  Cmd.v (Cmd.info "add" ~doc:"Import files from a source into a library") term

(* -------------------------------------------------------------------------- *)
(* 4. init <name>                                                             *)
(* -------------------------------------------------------------------------- *)

let init_cmd =
  let name_arg =
    let doc = "Name of the library to initialize." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let run db_opt name =
    with_db db_opt (fun db ->
      with_worker (fun w ->
        let lib = require_library db name in
        let config = Config.of_json_string lib.config_json in

        (* Check mount *)
        Printf.printf "Checking mount for %s...\n" lib.location;
        (match Worker_client.check_mount w ~path:lib.location ~timeout_seconds:10 with
         | Ok true -> ()
         | Ok false ->
           Printf.eprintf "Error: library path %S is not mounted.\n" lib.location;
           exit 1
         | Error e ->
           Printf.eprintf "Error checking mount: %s\n"
             (match e with
              | Domain.Timeout -> "timeout"
              | Domain.Io_error msg -> msg
              | _ -> "unknown error");
           exit 1);

        (* Walk library *)
        Printf.printf "Scanning %s...\n" lib.location;
        let extensions = Config.all_extensions config in
        let items =
          match Worker_client.walk_tree w ~root:lib.location ~extensions ~exclude_patterns:config.exclude_patterns with
          | Ok items -> items
          | Error e ->
            Printf.eprintf "Error walking library: %s\n"
              (match e with
               | Domain.Timeout -> "timeout"
               | Domain.Io_error msg -> msg
               | _ -> "unknown error");
            exit 1
        in
        Printf.printf "Found %d files.\n" (List.length items);

        (* Discover and persist *)
        Printf.printf "Discovering files...\n";
        let new_ids, skip_count =
          Pipeline.discover_and_persist_from_items db
            ~source_path:lib.location ~source_type:"init"
            items ~skip_paths:Pipeline.StringSet.empty
        in
        Printf.printf "Discovered %d new files, skipped %d unchanged.\n"
          (List.length new_ids) skip_count;

        (* Hash *)
        Printf.printf "Hashing files...\n";
        let hashed_ids = Pipeline.hash_files db w new_ids in
        Printf.printf "Hashed %d files.\n" (List.length hashed_ids);

        (* Metadata extraction skipped — not yet implemented in OCaml *)

        (* Compute paths *)
        Printf.printf "Computing target paths...\n";
        let path_ids = Pipeline.compute_paths db hashed_ids config in

        (* Separate quarantined from hashed *)
        let quarantined_records = Db.query_files_by_status db (Domain.Quarantined Domain.Hash_failed) in
        let quarantined_ids = List.map (fun (r : Domain.file_record) -> r.id) quarantined_records in

        (* Classify *)
        let plan = Init.classify_for_init db ~library_id:lib.id
            ~hashed_ids:path_ids ~quarantined_ids config in
        Printf.printf "Init plan: %d already correct, %d to move, %d duplicates, %d quarantined.\n"
          (List.length plan.already_correct)
          (List.length plan.needs_move)
          (List.length plan.duplicates)
          (List.length plan.quarantined);

        (* Execute *)
        Printf.printf "Initializing...\n";
        let result = Init.execute_init db w lib plan in
        Printf.printf "\nInit complete:\n";
        Printf.printf "  Indexed:     %d\n" result.indexed;
        Printf.printf "  Moved:       %d\n" result.moved;
        Printf.printf "  Quarantined: %d\n" result.quarantined_count;
        Printf.printf "  Errors:      %d\n" result.errors;

        (* Note: completion step skipped — Complete module not yet available *)
        Printf.printf "\nNote: completion step skipped (module not yet implemented).\n"))
  in
  let term = Term.(const run $ db_path $ name_arg) in
  Cmd.v (Cmd.info "init" ~doc:"Initialize/organize files already in a library") term

(* -------------------------------------------------------------------------- *)
(* 5. status <name>                                                           *)
(* -------------------------------------------------------------------------- *)

let status_cmd =
  let name_arg =
    let doc = "Name of the library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let run db_opt name =
    with_db db_opt (fun db ->
      let lib = require_library db name in
      let entries = Db.list_entries db lib.id in
      Printf.printf "Library: %s\n" lib.name;
      Printf.printf "Location: %s\n" lib.location;
      Printf.printf "Created: %s\n" lib.created_at;
      Printf.printf "Entries: %d\n" (List.length entries);

      (* Show files in progress by status *)
      let statuses =
        [ Domain.Discovered; Domain.Hashed;
          Domain.Quarantined Domain.Hash_failed;
          Domain.Duplicate Domain.In_batch;
          Domain.Duplicate Domain.In_library;
          Domain.Imported ]
      in
      let any_in_progress = ref false in
      List.iter (fun status ->
        let files = Db.query_files_by_status db status in
        if files <> [] then begin
          if not !any_in_progress then begin
            Printf.printf "\nFiles in progress:\n";
            any_in_progress := true
          end;
          Printf.printf "  %-15s %d\n"
            (Domain.file_status_to_string status) (List.length files)
        end
      ) statuses;
      if not !any_in_progress then
        Printf.printf "\nNo files in progress.\n")
  in
  let term = Term.(const run $ db_path $ name_arg) in
  Cmd.v (Cmd.info "status" ~doc:"Show library status") term

(* -------------------------------------------------------------------------- *)
(* 6. verify <name>                                                           *)
(* -------------------------------------------------------------------------- *)

let verify_cmd =
  let name_arg =
    let doc = "Name of the library to verify." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let run db_opt name =
    with_db db_opt (fun db ->
      let lib = require_library db name in
      let entries = Db.list_entries db lib.id in
      Printf.printf "Library: %s\n" lib.name;
      Printf.printf "Location: %s\n" lib.location;
      Printf.printf "Total entries: %d\n" (List.length entries);

      let missing = ref 0 in
      List.iter (fun (entry : Domain.entry) ->
        let full_path = Filename.concat lib.location entry.relative_path in
        if not (Sys.file_exists full_path) then begin
          Printf.printf "  MISSING: %s\n" entry.relative_path;
          incr missing
        end
      ) entries;
      if !missing = 0 then
        Printf.printf "All entries present.\n"
      else
        Printf.printf "\n%d missing file(s).\n" !missing)
  in
  let term = Term.(const run $ db_path $ name_arg) in
  Cmd.v (Cmd.info "verify" ~doc:"Verify library integrity") term

(* -------------------------------------------------------------------------- *)
(* 7. hash <name>                                                             *)
(* -------------------------------------------------------------------------- *)

let hash_cmd =
  let name_arg =
    let doc = "Name of the library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let run db_opt name =
    with_db db_opt (fun db ->
      with_worker (fun w ->
        let _lib = require_library db name in

        let discovered = Db.query_files_by_status db Domain.Discovered in
        let ids = List.map (fun (r : Domain.file_record) -> r.id) discovered in
        if ids = [] then
          Printf.printf "No unhashed files found.\n"
        else begin
          Printf.printf "Hashing %d files...\n" (List.length ids);
          let hashed_ids = Pipeline.hash_files db w ids in
          Printf.printf "Hashed %d files successfully.\n" (List.length hashed_ids);
          let failed = List.length ids - List.length hashed_ids in
          if failed > 0 then
            Printf.printf "%d files failed hashing (quarantined).\n" failed
        end))
  in
  let term = Term.(const run $ db_path $ name_arg) in
  Cmd.v (Cmd.info "hash" ~doc:"Hash all unhashed entries in a library") term

(* -------------------------------------------------------------------------- *)
(* 8. duplicates <name>                                                       *)
(* -------------------------------------------------------------------------- *)

let duplicates_cmd =
  let name_arg =
    let doc = "Name of the library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let run db_opt name =
    with_db db_opt (fun db ->
      let lib = require_library db name in
      let entries = Db.list_entries db lib.id in

      (* Group entries by hash *)
      let tbl = Hashtbl.create (List.length entries) in
      List.iter (fun (e : Domain.entry) ->
        match e.md5_hash with
        | Some h ->
          let existing = try Hashtbl.find tbl h with Not_found -> [] in
          Hashtbl.replace tbl h (e :: existing)
        | None -> ()
      ) entries;

      let dup_count = ref 0 in
      let dup_groups = ref 0 in
      Hashtbl.iter (fun hash entries ->
        if List.length entries > 1 then begin
          incr dup_groups;
          Printf.printf "\nHash: %s (%d copies)\n" hash (List.length entries);
          List.iter (fun (e : Domain.entry) ->
            Printf.printf "  %s\n" e.relative_path;
            incr dup_count
          ) entries
        end
      ) tbl;

      if !dup_groups = 0 then
        Printf.printf "No duplicates found in %S.\n" name
      else
        Printf.printf "\n%d duplicate groups, %d total duplicate files.\n"
          !dup_groups !dup_count)
  in
  let term = Term.(const run $ db_path $ name_arg) in
  Cmd.v (Cmd.info "duplicates" ~doc:"Find and report duplicate entries by hash") term

(* -------------------------------------------------------------------------- *)
(* 9. relocate <name> <path>                                                  *)
(* -------------------------------------------------------------------------- *)

let relocate_cmd =
  let name_arg =
    let doc = "Name of the library." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let path_arg =
    let doc = "New filesystem path for the library." in
    Arg.(required & pos 1 (some string) None & info [] ~docv:"PATH" ~doc)
  in
  let run db_opt name path =
    with_db db_opt (fun db ->
      let lib = require_library db name in
      Db.update_library_location db lib.id path;
      Printf.printf "Library %S relocated from %s to %s\n" name lib.location path)
  in
  let term = Term.(const run $ db_path $ name_arg $ path_arg) in
  Cmd.v (Cmd.info "relocate" ~doc:"Update library location") term

(* -------------------------------------------------------------------------- *)
(* 10. delete <name>                                                          *)
(* -------------------------------------------------------------------------- *)

let delete_cmd =
  let name_arg =
    let doc = "Name of the library to delete." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"NAME" ~doc)
  in
  let yes_flag =
    let doc = "Skip confirmation prompt." in
    Arg.(value & flag & info [ "y"; "yes" ] ~doc)
  in
  let run db_opt name yes =
    with_db db_opt (fun db ->
      let lib = require_library db name in
      let confirmed =
        if yes then true
        else begin
          Printf.printf "Delete library %S (id=%d)? This removes the database record only, not files on disk.\n" name lib.id;
          Printf.printf "Type 'yes' to confirm: ";
          let line = try read_line () with End_of_file -> "" in
          String.lowercase_ascii (String.trim line) = "yes"
        end
      in
      if confirmed then begin
        Db.delete_library db lib.id;
        Printf.printf "Library %S deleted.\n" name
      end else
        Printf.printf "Cancelled.\n")
  in
  let term = Term.(const run $ db_path $ name_arg $ yes_flag) in
  Cmd.v (Cmd.info "delete" ~doc:"Delete a library") term

(* -------------------------------------------------------------------------- *)
(* Top-level group                                                            *)
(* -------------------------------------------------------------------------- *)

let info =
  Cmd.info "trove" ~version:Trove_lib.version
    ~doc:"Photo organization tool"

let cmd =
  Cmd.group info
    [ create_cmd
    ; list_cmd
    ; add_cmd
    ; init_cmd
    ; status_cmd
    ; verify_cmd
    ; hash_cmd
    ; duplicates_cmd
    ; relocate_cmd
    ; delete_cmd
    ]

let () = exit (Cmd.eval cmd)

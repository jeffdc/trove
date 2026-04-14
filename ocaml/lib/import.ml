(* Import planning and execution for trove. *)

type import_summary = {
  imported : int;
  dup_in_batch : int;
  dup_in_library : int;
  path_conflicts : int;
  errors : int;
}

(* ---------- resolve_target_path ---------- *)

let resolve_target_path db ~library_id target_path =
  match Db.get_entry_by_path db ~library_id ~relative_path:target_path with
  | None -> target_path
  | Some _ ->
    let dir_part, filename =
      match String.rindex_opt target_path '/' with
      | Some i ->
        ( String.sub target_path 0 i,
          String.sub target_path (i + 1) (String.length target_path - i - 1) )
      | None -> ("", target_path)
    in
    let ext = Filename.extension filename in
    let stem =
      if ext = "" then filename
      else String.sub filename 0 (String.length filename - String.length ext)
    in
    let rec try_suffix n =
      if n >= 10000 then
        failwith ("Cannot resolve target path: " ^ target_path)
      else
        let candidate = Printf.sprintf "%s-%d%s" stem n ext in
        let candidate_path =
          if dir_part = "" then candidate
          else dir_part ^ "/" ^ candidate
        in
        match Db.get_entry_by_path db ~library_id ~relative_path:candidate_path with
        | None -> candidate_path
        | Some _ -> try_suffix (n + 1)
    in
    try_suffix 1

(* ---------- classify_for_import ---------- *)

let classify_for_import db ~library_id ids config =
  ignore config;
  if ids = [] then
    { Domain.to_import = []; duplicates_in_batch = [];
      duplicates_in_library = []; path_conflicts = 0; skipped = [] }
  else
    let records = Db.query_files_by_ids db ids in
    (* Sort by id to ensure deterministic keeper selection (lowest id wins) *)
    let records =
      List.sort (fun (a : Domain.file_record) (b : Domain.file_record) ->
        compare a.id b.id) records
    in
    (* Separate files with target_path (importable) from those without (skipped) *)
    let importable, skipped =
      List.partition
        (fun (r : Domain.file_record) -> Option.is_some r.target_path)
        records
    in
    (* Batch dedup: group by md5_hash, keep first (lowest id), rest are dups *)
    let seen_hashes = Hashtbl.create 16 in
    let keepers = ref [] in
    let batch_dups = ref [] in
    List.iter
      (fun (r : Domain.file_record) ->
        match r.md5_hash with
        | None ->
          (* No hash — treat as unique *)
          keepers := r :: !keepers
        | Some h ->
          if Hashtbl.mem seen_hashes h then
            batch_dups := r :: !batch_dups
          else begin
            Hashtbl.add seen_hashes h true;
            keepers := r :: !keepers
          end)
      importable;
    let keepers = List.rev !keepers in
    let batch_dups = List.rev !batch_dups in
    (* Library dedup: check existing entries by size, then compare hashes *)
    let to_import = ref [] in
    let lib_dups = ref [] in
    List.iter
      (fun (r : Domain.file_record) ->
        let size_matches =
          Db.get_entries_by_size db ~library_id ~file_size:r.file_size
        in
        let is_lib_dup =
          match r.md5_hash with
          | None -> false
          | Some file_hash ->
            List.exists
              (fun (entry : Domain.entry) ->
                match entry.md5_hash with
                | Some entry_hash -> entry_hash = file_hash
                | None -> false)
              size_matches
        in
        if is_lib_dup then
          lib_dups := r :: !lib_dups
        else
          to_import := r :: !to_import)
      keepers;
    let to_import = List.rev !to_import in
    let lib_dups = List.rev !lib_dups in
    (* Path conflicts: count files whose target_path already has an entry *)
    let path_conflicts =
      List.fold_left
        (fun count (r : Domain.file_record) ->
          match r.target_path with
          | None -> count
          | Some tp ->
            match Db.get_entry_by_path db ~library_id ~relative_path:tp with
            | Some _ -> count + 1
            | None -> count)
        0 to_import
    in
    { Domain.to_import;
      duplicates_in_batch = batch_dups;
      duplicates_in_library = lib_dups;
      path_conflicts;
      skipped }

(* ---------- execute_import ---------- *)

let mark_duplicates db files status_kind =
  let status_str =
    Domain.file_status_to_string (Domain.Duplicate status_kind)
  in
  List.iter
    (fun (r : Domain.file_record) ->
      Db.update_file db r.id [ ("status", Some status_str) ])
    files

let execute_import_with_fns db library _config plan
    ~copy_fn ~mkdir_fn ~exists_fn ?hash_fn () =
  (* 1. Mark batch duplicates *)
  mark_duplicates db plan.Domain.duplicates_in_batch Domain.In_batch;
  let dup_in_batch = List.length plan.Domain.duplicates_in_batch in
  (* 2. Mark library duplicates *)
  mark_duplicates db plan.Domain.duplicates_in_library Domain.In_library;
  let dup_in_library = List.length plan.Domain.duplicates_in_library in
  (* 3. Import each file *)
  let imported = ref 0 in
  let errors = ref 0 in
  let path_conflicts = ref 0 in
  List.iter
    (fun (r : Domain.file_record) ->
      match r.target_path with
      | None -> incr errors
      | Some target_path ->
        (* a. Resolve path conflicts *)
        let resolved =
          resolve_target_path db ~library_id:library.Domain.id target_path
        in
        if resolved <> target_path then incr path_conflicts;
        (* b. Build absolute dest path *)
        let abs_dest = library.Domain.location ^ "/" ^ resolved in
        (* c. Mkdir parent *)
        let parent_dir = Filename.dirname abs_dest in
        (match mkdir_fn parent_dir with
         | Error _ ->
           incr errors
         | Ok () ->
           (* d. Check if file already exists (orphan recovery) *)
           let copy_result =
             match exists_fn abs_dest with
             | Ok true ->
               (* File exists — check hash *)
               let existing_hash =
                 match hash_fn with
                 | Some hf -> hf abs_dest
                 | None -> Error (Domain.Io_error "no hash function")
               in
               (match existing_hash, r.md5_hash with
                | Ok eh, Some fh when eh = fh ->
                  (* Hashes match — orphan recovery, skip copy *)
                  Ok fh
                | _ ->
                  (* Mismatch or error — copy normally *)
                  copy_fn ~src:r.source_path ~dst:abs_dest)
             | _ ->
               (* e. Copy file *)
               copy_fn ~src:r.source_path ~dst:abs_dest
           in
           match copy_result with
           | Error _ ->
             incr errors
           | Ok copy_hash ->
             (* f. Verify hash matches *)
             (match r.md5_hash with
              | Some expected when expected <> copy_hash ->
                incr errors
              | _ ->
                (* g. Atomic DB import *)
                let hash =
                  match r.md5_hash with
                  | Some h -> h
                  | None -> copy_hash
                in
                let _entry =
                  Db.import_file db
                    ~file_id:r.id
                    ~library_id:library.Domain.id
                    ~relative_path:resolved
                    ~file_size:r.file_size
                    ~md5_hash:hash
                    ~capture_date:r.capture_date
                    ~camera_model:r.camera_model
                    ~original_path:(Some r.source_path)
                in
                incr imported)))
    plan.Domain.to_import;
  { imported = !imported;
    dup_in_batch;
    dup_in_library;
    path_conflicts = !path_conflicts;
    errors = !errors }

let execute_import db worker library config plan =
  let copy_fn ~src ~dst = Worker_client.copy_and_hash worker ~src ~dst in
  let mkdir_fn path = Worker_client.mkdir_all worker path in
  let exists_fn path = Worker_client.path_exists worker path in
  let hash_fn path = Worker_client.hash_path worker path in
  execute_import_with_fns db library config plan
    ~copy_fn ~mkdir_fn ~exists_fn ~hash_fn ()

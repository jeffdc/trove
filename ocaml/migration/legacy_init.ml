(* Library initialization: classify existing files and execute the init plan. *)

type init_result = {
  indexed : int;
  moved : int;
  quarantined_count : int;
  errors : int;
}

(* ---------- relative_path ---------- *)

let relative_path ~lib_location source_path =
  let prefix_len = String.length lib_location in
  let source_len = String.length source_path in
  if source_len > prefix_len
     && String.sub source_path 0 prefix_len = lib_location
     && source_path.[prefix_len] = '/'
  then String.sub source_path (prefix_len + 1) (source_len - prefix_len - 1)
  else source_path

(* ---------- classify_for_init ---------- *)

let classify_for_init db ~library_id ~hashed_ids ~quarantined_ids config =
  (* 1. Build claimed paths from existing entries *)
  let entries = Legacy_db_impl.list_entries db library_id in
  let claimed =
    ref
      (List.fold_left
         (fun acc (e : Legacy_domain.entry) ->
           Legacy_pipeline.StringSet.add e.relative_path acc)
         Legacy_pipeline.StringSet.empty entries)
  in
  (* 2. Fetch hashed file records *)
  let hashed_records = Legacy_db_impl.query_files_by_ids db hashed_ids in
  (* 3. Fetch quarantined file records *)
  let quarantined_records = Legacy_db_impl.query_files_by_ids db quarantined_ids in
  (* 4. Process quarantined files *)
  let quarantined_out =
    List.map
      (fun (fr : Legacy_domain.file_record) ->
        let basename = Filename.basename fr.source_path in
        let normalized = Legacy_pipeline.normalize_filename basename in
        let qpath = config.Config.quarantine.path ^ normalized in
        let resolved = Legacy_pipeline.resolve_path qpath claimed in
        (fr, resolved))
      quarantined_records
  in
  (* 5. Process hashed files, sorted by ID for determinism *)
  let sorted_hashed =
    List.sort
      (fun (a : Legacy_domain.file_record) (b : Legacy_domain.file_record) ->
        compare a.id b.id)
      hashed_records
  in
  let already_correct = ref [] in
  let needs_move = ref [] in
  let lib_location =
    let lib = Legacy_db_impl.get_library_by_id db library_id in
    match lib with
    | Some l -> l.location
    | None -> ""
  in
  List.iter
    (fun (fr : Legacy_domain.file_record) ->
      match (fr.target_path, fr.md5_hash) with
      | Some target, Some _hash ->
        let rel = relative_path ~lib_location fr.source_path in
        let resolved = Legacy_pipeline.resolve_path target claimed in
        if rel = resolved then already_correct := fr :: !already_correct
        else needs_move := (fr, resolved) :: !needs_move
      | _ ->
        (* Skip files with no target_path or no md5_hash *)
        ())
    sorted_hashed;
  {
    Legacy_domain.already_correct = List.rev !already_correct;
    needs_move = List.rev !needs_move;
    duplicates = [];
    quarantined = quarantined_out;
  }

(* ---------- execute_init ---------- *)

let execute_init db worker (lib : Legacy_domain.library) (plan : Legacy_domain.init_plan) =
  let indexed = ref 0 in
  let moved = ref 0 in
  let quarantined_count = ref 0 in
  let errors = ref 0 in
  (* 1. Index already-correct files *)
  List.iter
    (fun (fr : Legacy_domain.file_record) ->
      let rel = relative_path ~lib_location:lib.location fr.source_path in
      let _entry =
        Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:rel
          ~file_size:fr.file_size ~md5_hash:fr.md5_hash
          ~capture_date:fr.capture_date ~camera_model:fr.camera_model
          ~original_path:None
      in
      Legacy_db_impl.delete_file db fr.id;
      incr indexed)
    plan.already_correct;
  (* 2. Move files *)
  List.iter
    (fun ((fr : Legacy_domain.file_record), target) ->
      let dst = lib.location ^ "/" ^ target in
      let parent = Filename.dirname dst in
      match Worker_client.mkdir_all worker parent with
      | Error _ ->
        incr errors
      | Ok () -> (
        match
          Worker_client.move_file worker ~src:fr.source_path ~dst
            ~expected_hash:fr.md5_hash
        with
        | Error _ ->
          incr errors
        | Ok _hash ->
          let old_rel =
            relative_path ~lib_location:lib.location fr.source_path
          in
          let _entry =
            Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:target
              ~file_size:fr.file_size ~md5_hash:fr.md5_hash
              ~capture_date:fr.capture_date ~camera_model:fr.camera_model
              ~original_path:(Some old_rel)
          in
          let src_parent = Filename.dirname fr.source_path in
          let _ =
            Worker_client.remove_empty_dirs worker ~path:src_parent
              ~stop_at:lib.location
          in
          Legacy_db_impl.delete_file db fr.id;
          incr moved))
    plan.needs_move;
  (* 3. Handle quarantined files — use resolved path from plan *)
  List.iter
    (fun ((fr : Legacy_domain.file_record), q_rel) ->
      let dst = lib.location ^ "/" ^ q_rel in
      let parent = Filename.dirname dst in
      match Worker_client.mkdir_all worker parent with
      | Error _ ->
        incr errors
      | Ok () -> (
        match
          Worker_client.move_file worker ~src:fr.source_path ~dst
            ~expected_hash:None
        with
        | Error _ ->
          incr errors
        | Ok _hash ->
          let _entry =
            Legacy_db_impl.create_entry db ~library_id:lib.id ~relative_path:q_rel
              ~file_size:fr.file_size ~md5_hash:fr.md5_hash
              ~capture_date:fr.capture_date ~camera_model:fr.camera_model
              ~original_path:None
          in
          Legacy_db_impl.delete_file db fr.id;
          incr quarantined_count))
    plan.quarantined;
  {
    indexed = !indexed;
    moved = !moved;
    quarantined_count = !quarantined_count;
    errors = !errors;
  }

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

let invalid_state ?(context = []) message =
  Utils.app_error ~code:Invalid_state ~context message

let basename_from_paths ~relative_path ~original_path =
  match original_path with
  | Some path -> Filename.basename path
  | None -> Filename.basename relative_path

let report_entry_without_md5 report (entry : Legacy_types.entry) =
  Migration_report.add_anomaly report
    {
      Migration_types.kind = Entry_without_md5;
      legacy_table = "entries";
      legacy_id = Some entry.id;
      detail =
        Printf.sprintf
          "entry has no md5_hash; durable library membership cannot be created \
           in the target schema for %s" entry.relative_path;
    };
  Migration_report.incr report ~counter:"legacy_rows_preserved"

let report_inconsistent_md5_group report (entry : Legacy_types.entry)
    (file_object : Domain.file_object) =
  Migration_report.add_anomaly report
    {
      Migration_types.kind = Inconsistent_md5_group;
      legacy_table = "entries";
      legacy_id = Some entry.id;
      detail =
        Printf.sprintf
          "entry md5 %s maps to existing file_object %d with size %d but entry \
           reports size %d" file_object.content_hash file_object.id
          file_object.size_bytes entry.file_size;
    }

let report_duplicate_library_membership report (entry : Legacy_types.entry)
    file_object_id =
  Migration_report.add_anomaly report
    {
      Migration_types.kind = Target_path_conflict;
      legacy_table = "entries";
      legacy_id = Some entry.id;
      detail =
        Printf.sprintf
          "library %d already has membership for file_object %d; cannot create \
           second placement for %s" entry.library_id file_object_id
          entry.relative_path;
    };
  Migration_report.incr report ~counter:"legacy_rows_preserved"

let ensure_file_object ~target ~state ~report (entry : Legacy_types.entry)
    md5_hash =
  let existing =
    match Hashtbl.find_opt state.Migration_types.file_object_ids_by_md5 md5_hash with
    | Some _ ->
      map_target_error (Db.get_file_object_by_content_hash target md5_hash)
    | None -> map_target_error (Db.get_file_object_by_content_hash target md5_hash)
  in
  match existing with
  | Error _ as error -> error
  | Ok (Some file_object) ->
    Hashtbl.replace state.file_object_ids_by_md5 md5_hash file_object.id;
    if file_object.size_bytes <> entry.file_size then
      report_inconsistent_md5_group report entry file_object;
    Ok file_object
  | Ok None ->
    let original_filename =
      basename_from_paths ~relative_path:entry.relative_path
        ~original_path:entry.original_path
    in
    let extension = Utils.extension_of_filename original_filename in
    match
      map_target_error
        (Db.create_file_object target ~content_hash:md5_hash
           ~hash_algorithm:Domain.Hash_algorithm.Md5
           ~size_bytes:entry.file_size ?capture_date:entry.capture_date
           ?camera_model:entry.camera_model ~original_filename
           ?extension ~created_at:entry.imported_at
           ~updated_at:entry.imported_at ())
    with
    | Error _ as error -> error
    | Ok file_object ->
      Hashtbl.replace state.file_object_ids_by_md5 md5_hash file_object.id;
      Migration_report.incr report ~counter:"file_objects_created";
      Ok file_object

let run ~legacy ~target ~(state : Migration_types.mapping_state) ~report =
  match Legacy_db.list_entries legacy with
  | Error _ as error -> error
  | Ok entries ->
    let rec loop = function
      | [] -> Ok ()
      | (entry : Legacy_types.entry) :: rest ->
        match Hashtbl.find_opt state.library_ids_by_legacy_id entry.library_id with
        | None ->
          Error
            (invalid_state
               ~context:
                 [
                   ("entry_id", string_of_int entry.id);
                   ("legacy_library_id", string_of_int entry.library_id);
                 ]
               "entry references an unmigrated legacy library")
        | Some target_library_id ->
          match entry.md5_hash with
          | None ->
            report_entry_without_md5 report entry;
            loop rest
          | Some md5_hash ->
            match ensure_file_object ~target ~state ~report entry md5_hash with
            | Error _ as error -> error
            | Ok file_object ->
              match
                map_target_error
                  (Db.get_library_item_by_library_and_file_object target
                     ~library_id:target_library_id
                     ~file_object_id:file_object.id)
              with
              | Error _ as error -> error
              | Ok (Some _) ->
                report_duplicate_library_membership report entry
                  file_object.id;
                loop rest
              | Ok None ->
                match
                  map_target_error
                    (Db.create_library_item target
                       ~library_id:target_library_id
                       ~file_object_id:file_object.id
                       ~status:Domain.Library_item_status.Active
                       ~created_at:entry.imported_at
                       ~updated_at:entry.imported_at ())
                with
                | Error _ as error -> error
                | Ok library_item ->
                  Migration_report.incr report
                    ~counter:"library_items_created";
                  Hashtbl.replace state.library_item_ids_by_entry_id
                    entry.id library_item.id;
                  match
                    map_target_error
                      (Db.create_library_placement target
                         ~library_item_id:library_item.id
                         ~library_id:target_library_id
                         ~intended_relative_path:entry.relative_path
                         ~actual_relative_path:entry.relative_path
                         ~placement_status:
                           Domain.Placement_status.Healthy
                         ~last_verified_at:entry.imported_at
                         ~created_at:entry.imported_at
                         ~updated_at:entry.imported_at ())
                  with
                  | Error _ as error -> error
                  | Ok _placement ->
                    Migration_report.incr report
                      ~counter:"library_placements_created";
                    Migration_report.incr report ~counter:"entries_migrated";
                    loop rest
    in
    loop entries

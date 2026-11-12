(** Import/init completion: verify all files are accounted for and clean up
    transient file records. *)

open Legacy_domain

type complete_plan = {
  imported : file_record list;
  duplicate : file_record list;
  quarantined : file_record list;
  unaccounted : file_record list;
}

type complete_result = {
  imported_count : int;
  duplicate_count : int;
  quarantined_count : int;
  unaccounted_count : int;
  records_cleaned : int;
  can_complete : bool;
}

let plan_complete db ~library_id =
  (* Query each base status once.  file_status_to_string maps all Duplicate
     variants to "duplicate" and all Quarantined variants to "quarantined",
     so a single query per base status is sufficient and avoids double-counting. *)
  let imported_files = Legacy_db_impl.query_files_by_status db Imported in
  let duplicate_files = Legacy_db_impl.query_files_by_status db (Duplicate In_batch) in
  let quarantined_files =
    Legacy_db_impl.query_files_by_status db (Quarantined Hash_failed)
  in
  let discovered_files = Legacy_db_impl.query_files_by_status db Discovered in
  let hashed_files = Legacy_db_impl.query_files_by_status db Hashed in
  (* Verify each imported file has a matching entry by hash *)
  let verified_imported, unverified_imported =
    List.partition
      (fun (fr : file_record) ->
        match fr.md5_hash with
        | None -> false
        | Some hash ->
          let entries =
            Legacy_db_impl.get_entries_by_hash db ~library_id ~md5_hash:hash
          in
          List.length entries > 0)
      imported_files
  in
  (* Unaccounted = discovered + hashed + imported-without-verification *)
  let unaccounted = discovered_files @ hashed_files @ unverified_imported in
  {
    imported = verified_imported;
    duplicate = duplicate_files;
    quarantined = quarantined_files;
    unaccounted;
  }

let execute_complete db plan =
  let imported_count = List.length plan.imported in
  let duplicate_count = List.length plan.duplicate in
  let quarantined_count = List.length plan.quarantined in
  let unaccounted_count = List.length plan.unaccounted in
  if unaccounted_count > 0 then
    {
      imported_count;
      duplicate_count;
      quarantined_count;
      unaccounted_count;
      records_cleaned = 0;
      can_complete = false;
    }
  else begin
    (* Delete by specific ID, not by status, to avoid touching
       file records that belong to other library operations. *)
    let all_terminal =
      plan.imported @ plan.duplicate @ plan.quarantined
    in
    List.iter
      (fun (fr : file_record) -> Legacy_db_impl.delete_file db fr.id)
      all_terminal;
    let total = List.length all_terminal in
    {
      imported_count;
      duplicate_count;
      quarantined_count;
      unaccounted_count;
      records_cleaned = total;
      can_complete = true;
    }
  end

let complete_import db ~library_id =
  let plan = plan_complete db ~library_id in
  execute_complete db plan

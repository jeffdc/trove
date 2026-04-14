(** Import/init completion: verify all files are accounted for and clean up
    transient file records. *)

open Domain

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
  (* Query each status category *)
  let imported_files = Db.query_files_by_status db Imported in
  let duplicate_files = Db.query_files_by_status db (Duplicate In_batch) in
  let quarantined_files = Db.query_files_by_status db (Quarantined Hash_failed) in
  let discovered_files = Db.query_files_by_status db Discovered in
  let hashed_files = Db.query_files_by_status db Hashed in
  (* Verify each imported file has a matching entry by hash *)
  let verified_imported, unverified_imported =
    List.partition
      (fun (fr : file_record) ->
        match fr.md5_hash with
        | None -> false
        | Some hash ->
          let entries = Db.get_entries_by_hash db ~library_id ~md5_hash:hash in
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
    let total = imported_count + duplicate_count + quarantined_count in
    if total > 0 then
      Db.delete_files_by_status db
        [Imported; Duplicate In_batch; Quarantined Hash_failed];
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

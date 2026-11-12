(** Schema database layer for the library-centric rewrite.

    This is additive for now so the old [Db] module can remain in place until
    runtime workflows are ported. *)

open Domain

type t

val open_db : string -> t
val close : t -> unit
val raw_db : t -> Sqlite3.db

val create_library :
  t ->
  name:string ->
  root_path:string ->
  config_json:string ->
  (library, app_error) result

val get_library_by_name : t -> string -> (library option, app_error) result
val get_library_by_id : t -> int -> (library option, app_error) result
val list_libraries : t -> (library list, app_error) result

val create_file_object :
  t ->
  content_hash:string ->
  hash_algorithm:Hash_algorithm.t ->
  size_bytes:int ->
  ?blake2b_256_hash:string ->
  ?quick_signature:string ->
  ?capture_date:string ->
  ?camera_model:string ->
  ?original_filename:string ->
  ?extension:string ->
  ?mime_type:string ->
  ?metadata_json:string ->
  ?metadata_extracted_at:string ->
  ?metadata_tool:string ->
  ?created_at:string ->
  ?updated_at:string ->
  unit ->
  (file_object, app_error) result

val get_file_object_by_content_hash :
  t -> string -> (file_object option, app_error) result

val list_file_objects : t -> (file_object list, app_error) result

val create_library_item :
  t ->
  library_id:int ->
  file_object_id:int ->
  ?admitted_from_run_item_id:int ->
  status:Library_item_status.t ->
  ?created_at:string ->
  ?updated_at:string ->
  unit ->
  (library_item, app_error) result

val get_library_item_by_library_and_file_object :
  t ->
  library_id:int ->
  file_object_id:int ->
  (library_item option, app_error) result

val list_library_items : t -> (library_item list, app_error) result

val update_library_item_status :
  t ->
  id:int ->
  status:Library_item_status.t ->
  updated_at:string ->
  (unit, app_error) result

val set_library_item_admitted_from_run_item :
  t ->
  id:int ->
  run_item_id:int ->
  updated_at:string ->
  (unit, app_error) result

val create_library_placement :
  t ->
  library_item_id:int ->
  library_id:int ->
  intended_relative_path:string ->
  ?actual_relative_path:string ->
  placement_status:Placement_status.t ->
  ?last_verified_at:string ->
  ?error_text:string ->
  ?created_at:string ->
  ?updated_at:string ->
  unit ->
  (library_placement, app_error) result

val list_library_placements : t -> (library_placement list, app_error) result

val get_library_placement_by_library_item_id :
  t -> int -> (library_placement option, app_error) result

val update_library_placement_state :
  t ->
  id:int ->
  placement_status:Placement_status.t ->
  ?last_verified_at:string ->
  ?error_text:string ->
  updated_at:string ->
  unit ->
  (unit, app_error) result

val create_source_root :
  t ->
  library_id:int ->
  root_path:string ->
  source_kind:Source_kind.t ->
  ?created_at:string ->
  unit ->
  (source_root, app_error) result

val list_source_roots : t -> (source_root list, app_error) result

val create_run :
  t ->
  library_id:int ->
  ?source_root_id:int ->
  mode:Run_mode.t ->
  status:Run_status.t ->
  ?options_json:string ->
  ?summary_json:string ->
  ?error_text:string ->
  started_at:string ->
  ?completed_at:string ->
  unit ->
  (run, app_error) result

val update_run_completion :
  t ->
  id:int ->
  status:Run_status.t ->
  ?summary_json:string ->
  ?error_text:string ->
  completed_at:string ->
  unit ->
  (unit, app_error) result

val list_runs : t -> (run list, app_error) result

val create_source_observation :
  t ->
  run_id:int ->
  source_root_id:int ->
  observed_path:string ->
  ?relative_path:string ->
  ?size_bytes:int ->
  ?mtime:string ->
  observed_at:string ->
  ?file_object_id:int ->
  unit ->
  (source_observation, app_error) result

val list_source_observations : t -> (source_observation list, app_error) result

val create_run_item :
  t ->
  run_id:int ->
  ?source_observation_id:int ->
  ?file_object_id:int ->
  workflow_state:Workflow_state.t ->
  ?planned_action:Planned_action.t ->
  ?disposition:Disposition.t ->
  ?planned_relative_path:string ->
  ?failure_reason:string ->
  created_at:string ->
  updated_at:string ->
  unit ->
  (run_item, app_error) result

val list_run_items : t -> (run_item list, app_error) result

val create_file_op :
  t ->
  run_id:int ->
  ?run_item_id:int ->
  ?library_item_id:int ->
  op_kind:File_op_kind.t ->
  ?src_path:string ->
  ?dst_path:string ->
  status:File_op_status.t ->
  ?error_text:string ->
  started_at:string ->
  ?completed_at:string ->
  unit ->
  (file_op, app_error) result

val list_file_ops : t -> (file_op list, app_error) result

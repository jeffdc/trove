(** Shared helpers for schema operations (init and import). *)

open Domain

val fallback_capture_date : string -> string option
(** Try to parse an mtime string as a capture date. *)

val ensure_mount : Worker_client.t -> string -> (unit, app_error) result
(** Check that a path is mounted via the worker. *)

val resolve_available_path :
  Worker_client.t ->
  library_root:string ->
  claimed:Utils.StringSet.t ref ->
  string ->
  (string * bool, app_error) result
(** Find a unique path that doesn't conflict with claimed paths or filesystem. *)

val ensure_file_object :
  Db.t ->
  content_hash:string ->
  size_bytes:int ->
  capture_date:string option ->
  original_filename:string ->
  created_at:string ->
  (file_object, app_error) result
(** Get existing file object by hash or create a new one. *)

val create_source_observation :
  Db.t ->
  run_id:int ->
  source_root_id:int ->
  observed_path:string ->
  relative_path:string ->
  size_bytes:int ->
  mtime:string ->
  observed_at:string ->
  ?file_object_id:int ->
  unit ->
  (source_observation, app_error) result

val create_run_item :
  Db.t ->
  run_id:int ->
  source_observation_id:int ->
  ?file_object_id:int ->
  workflow_state:Workflow_state.t ->
  ?planned_action:Planned_action.t ->
  ?disposition:Disposition.t ->
  ?planned_relative_path:string ->
  ?failure_reason:string ->
  created_at:string ->
  unit ->
  (run_item, app_error) result

val actual_managed_path : library_placement -> string
(** Return the actual path if set, otherwise the intended path. *)

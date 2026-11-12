(** Utility functions for Trove *)

val now_iso : unit -> string
(** Returns the current time as an ISO 8601 formatted string in UTC.
    Format: YYYY-MM-DDTHH:MM:SSZ *)

module StringSet : sig
  include Set.S with type elt = string
end
(** A set of strings *)

val string_of_worker_error : Domain.worker_error -> string
(** Convert a worker error to a human-readable string *)

val string_of_error_code : Domain.error_code -> string
(** Convert an application error code to a stable string. *)

val string_of_app_error : Domain.app_error -> string
(** Render an application error with any structured context. *)

val app_error :
  code:Domain.error_code ->
  ?retryable:bool ->
  ?context:(string * string) list ->
  string ->
  Domain.app_error
(** Construct an application error value. *)

val app_error_of_db_message :
  ?context:(string * string) list ->
  string ->
  Domain.app_error
(** Wrap a stringly database error in an application error. *)

val app_error_of_worker_error :
  op:string ->
  ?path:string ->
  Domain.worker_error ->
  Domain.app_error
(** Map a worker subsystem error into an application error. *)

val relative_to_root : root_path:string -> string -> string option
(** Compute the relative path by stripping the root prefix.
    Returns [Some ""] if path equals root_path,
    [Some rel] if path is under root_path,
    [None] otherwise. *)

val path_within_root : root_path:string -> string -> bool
(** Check whether a path is within or equal to a root path. *)

val extension_of_filename : string -> string option
(** Extract the extension from a filename (without the dot).
    Returns [None] if no valid extension exists. *)

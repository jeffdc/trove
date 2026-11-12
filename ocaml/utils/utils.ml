let now_iso () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (1900 + tm.tm_year)
    (1 + tm.tm_mon) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

module StringSet = Set.Make (String)

let string_of_worker_error = function
  | Domain.Timeout -> "timeout"
  | Domain.Not_found -> "not_found"
  | Domain.Permission_denied -> "permission_denied"
  | Domain.Cross_device -> "cross_device"
  | Domain.Io_error msg when String.equal msg "" -> "io_error"
  | Domain.Io_error msg -> "io_error: " ^ msg
  | Domain.Already_exists -> "already_exists"
  | Domain.Worker_crash -> "worker_crash"
  | Domain.Unknown msg -> "unknown: " ^ msg

let string_of_error_code = function
  | Domain.Worker_timeout -> "worker_timeout"
  | Domain.Filesystem_not_found -> "filesystem_not_found"
  | Domain.Filesystem_permission_denied -> "filesystem_permission_denied"
  | Domain.Filesystem_cross_device -> "filesystem_cross_device"
  | Domain.Filesystem_already_exists -> "filesystem_already_exists"
  | Domain.Filesystem_io_error -> "filesystem_io_error"
  | Domain.Worker_io_error -> "worker_io_error"
  | Domain.Worker_crash_error -> "worker_crash"
  | Domain.Worker_unknown -> "worker_unknown"
  | Domain.Mount_unavailable -> "mount_unavailable"
  | Domain.Library_not_found -> "library_not_found"
  | Domain.Db_error -> "db_error"
  | Domain.Invalid_state -> "invalid_state"
  | Domain.Unsupported_operation -> "unsupported_operation"

let app_error ~code ?(retryable = false) ?(context = []) message :
    Domain.app_error =
  { code; message; retryable; context }

let string_of_app_error (err : Domain.app_error) =
  match err.context with
  | [] -> Printf.sprintf "[%s] %s" (string_of_error_code err.code) err.message
  | context ->
    let render_pair (key, value) = key ^ "=" ^ value in
    Printf.sprintf "[%s] %s (%s)" (string_of_error_code err.code) err.message
      (String.concat ", " (List.map render_pair context))

let app_error_of_db_message ?(context = []) message =
  app_error ~code:Domain.Db_error ~context
    "database operation failed"
    |> fun err -> { err with context = ("detail", message) :: context }

let app_error_of_worker_error ~op ?path = function
  | Domain.Timeout ->
    app_error ~code:Domain.Worker_timeout ~retryable:true
      ~context:
        (("op", op)
        :: (match path with Some p -> [ ("path", p) ] | None -> []))
      "worker operation timed out"
  | Domain.Not_found ->
    app_error ~code:Domain.Filesystem_not_found
      ~context:
        (("op", op)
        :: (match path with Some p -> [ ("path", p) ] | None -> []))
      "filesystem path was not found"
  | Domain.Permission_denied ->
    app_error ~code:Domain.Filesystem_permission_denied
      ~context:
        (("op", op)
        :: (match path with Some p -> [ ("path", p) ] | None -> []))
      "filesystem permission denied"
  | Domain.Cross_device ->
    app_error ~code:Domain.Filesystem_cross_device
      ~context:
        (("op", op)
        :: (match path with Some p -> [ ("path", p) ] | None -> []))
      "filesystem operation crossed devices"
  | Domain.Already_exists ->
    app_error ~code:Domain.Filesystem_already_exists
      ~context:
        (("op", op)
        :: (match path with Some p -> [ ("path", p) ] | None -> []))
      "destination already exists"
  | Domain.Worker_crash ->
    app_error ~code:Domain.Worker_crash_error ~retryable:true
      ~context:
        (("op", op)
        :: (match path with Some p -> [ ("path", p) ] | None -> []))
      "worker process crashed"
  | Domain.Io_error msg ->
    let context =
      ("op", op)
      :: (match path with Some p -> [ ("path", p) ] | None -> [])
      @ (if String.equal msg "" then [] else [ ("detail", msg) ])
    in
    app_error ~code:Domain.Worker_io_error ~context "filesystem I/O error"
  | Domain.Unknown msg ->
    let context =
      ("op", op)
      :: (match path with Some p -> [ ("path", p) ] | None -> [])
      @ [ ("detail", msg) ]
    in
    app_error ~code:Domain.Worker_unknown ~context "unknown worker error"

let relative_to_root ~root_path path =
  let root_len = String.length root_path in
  let path_len = String.length path in
  if path = root_path then Some ""
  else if
    path_len > root_len
    && String.sub path 0 root_len = root_path
    && path.[root_len] = '/'
  then
    Some (String.sub path (root_len + 1) (path_len - root_len - 1))
  else None

let path_within_root ~root_path path =
  let root_len = String.length root_path in
  let path_len = String.length path in
  path = root_path
  || (path_len > root_len && String.sub path 0 root_len = root_path
      && path.[root_len] = '/')

let extension_of_filename name =
  match String.rindex_opt name '.' with
  | Some idx when idx > 0 && idx < String.length name - 1 ->
    Some (String.sub name (idx + 1) (String.length name - idx - 1))
  | _ -> None

(** Client for the Go worker child process.

    Includes a watchdog: if the worker does not respond within
    [response_timeout] seconds, it is killed (SIGKILL) and automatically
    restarted on the next call.  This prevents leaked goroutines from
    accumulating when NAS mounts hang. *)

type stat_result = { size : int; mtime : string; is_dir : bool }
type walk_item = { path : string; size : int; mtime : string }
type response_payload =
  | Json_result of Yojson.Safe.t
  | Worker_error_payload of string * string

type t = {
  worker_path : string;
  response_timeout : float;  (** seconds; 0 = no timeout *)
  mutable pid : int;
  mutable to_worker : out_channel;
  mutable from_worker : in_channel;
  mutable from_worker_fd : Unix.file_descr;
  mutable next_id : int;
  mutable alive : bool;
}

(* ---- helpers ---- *)

let json_member key json =
  match json with
  | `Assoc l -> List.assoc_opt key l
  | _ -> None

let protocol_error detail =
  Domain.Unknown ("worker protocol error: " ^ detail)

let invalid_json_error detail =
  Domain.Unknown ("worker returned invalid json: " ^ detail)

let require_member key json =
  match json_member key json with
  | Some v -> Ok v
  | None -> Error (protocol_error ("missing key: " ^ key))

let json_to_bool = function
  | `Bool b -> Ok b
  | _ -> Error (protocol_error "expected bool")

let json_to_int = function
  | `Int i -> Ok i
  | `Intlit s -> Ok (int_of_string s)
  | `Float f -> Ok (int_of_float f)
  | _ -> Error (protocol_error "expected int")

let json_to_string = function
  | `String s -> Ok s
  | _ -> Error (protocol_error "expected string")

let protocol_result f =
  try f () with
  | Failure msg -> Error (protocol_error msg)
  | Yojson.Json_error msg -> Error (invalid_json_error msg)
  | exn -> Error (protocol_error (Printexc.to_string exn))

let worker_error_of_unix_error err detail =
  match err with
  | Unix.ENOENT -> Domain.Not_found
  | Unix.EACCES | Unix.EPERM -> Domain.Permission_denied
  | Unix.EXDEV -> Domain.Cross_device
  | Unix.EEXIST -> Domain.Already_exists
  | _ -> Domain.Io_error detail

let start_result f =
  try Ok (f ()) with
  | Unix.Unix_error (err, _, _) ->
    Error (worker_error_of_unix_error err (Unix.error_message err))
  | Sys_error detail -> Error (Domain.Io_error detail)
  | Yojson.Json_error msg -> Error (invalid_json_error msg)
  | Failure msg -> Error (protocol_error msg)
  | exn -> Error (protocol_error (Printexc.to_string exn))

let ( let* ) = Result.bind

let next_id t =
  let id = t.next_id in
  t.next_id <- id + 1;
  id

(* ---- low-level send/receive ---- *)

let send_request t ~op ~args =
  let id = next_id t in
  let req =
    `Assoc [ ("id", `Int id); ("op", `String op); ("args", args) ]
  in
  let line = Yojson.Safe.to_string req in
  output_string t.to_worker line;
  output_char t.to_worker '\n';
  flush t.to_worker;
  id

let read_response t =
  let line = input_line t.from_worker in
  Yojson.Safe.from_string line

(* ---- lifecycle ---- *)

(** Spawn a worker process and read its hello message.
    Returns (pid, to_worker, from_worker, from_worker_fd). *)
let spawn_worker worker_path =
  start_result (fun () ->
      let in_read, in_write = Unix.pipe ~cloexec:true () in
      let out_read, out_write = Unix.pipe ~cloexec:true () in
      let cleanup_partial () =
        (try Unix.close in_read with _ -> ());
        (try Unix.close in_write with _ -> ());
        (try Unix.close out_read with _ -> ());
        (try Unix.close out_write with _ -> ())
      in
      try
        let pid =
          Unix.create_process worker_path [| worker_path |]
            in_read out_write Unix.stderr
        in
        Unix.close in_read;
        Unix.close out_write;
        let to_worker = Unix.out_channel_of_descr in_write in
        let from_worker = Unix.in_channel_of_descr out_read in
        let parsed =
          let hello_line = input_line from_worker in
          let hello = Yojson.Safe.from_string hello_line in
          let* version_json = require_member "protocol_version" hello in
          let* version = json_to_int version_json in
          if version <> 1 then
            Error
              (protocol_error
                 (Printf.sprintf
                    "unsupported worker protocol version: %d" version))
          else Ok (pid, to_worker, from_worker, out_read)
        in
        (match parsed with
        | Ok _ -> parsed
        | Error _ as error ->
          (try close_out to_worker with _ -> ());
          (try close_in from_worker with _ -> ());
          (try ignore (Unix.waitpid [] pid) with _ -> ());
          error)
      with
      | exn ->
        cleanup_partial ();
        raise exn)
  |> Result.join

let kill_worker t =
  if t.alive then begin
    t.alive <- false;
    (try Unix.kill t.pid Sys.sigkill with Unix.Unix_error _ -> ());
    (try close_out t.to_worker with _ -> ());
    (try close_in t.from_worker with _ -> ());
    (try ignore (Unix.waitpid [] t.pid) with Unix.Unix_error _ -> ())
  end

let parse_result_json t f =
  match protocol_result f with
  | Ok _ as ok -> ok
  | Error err ->
    kill_worker t;
    Error err

let restart_worker t =
  kill_worker t;
  match spawn_worker t.worker_path with
  | Error _ as error -> error
  | Ok (pid, to_w, from_w, fd) ->
    t.pid <- pid;
    t.to_worker <- to_w;
    t.from_worker <- from_w;
    t.from_worker_fd <- fd;
    t.next_id <- 1;
    t.alive <- true;
    Ok ()

(** Wait for data on the worker's stdout, with timeout.
    Returns true if data is available, false on timeout. *)
let wait_for_response t =
  if t.response_timeout <= 0.0 then true  (* no timeout *)
  else
    match Unix.select [ t.from_worker_fd ] [] [] t.response_timeout with
    | _ :: _, _, _ -> true
    | [], _, _ -> false

let call t ~op ~args =
  let ready =
    if t.alive then Ok () else restart_worker t
  in
  match ready with
  | Error _ as error -> error
  | Ok () ->
    let req_id = send_request t ~op ~args in
    if not (wait_for_response t) then begin
      (* Worker did not respond in time — kill and restart *)
      kill_worker t;
      Error Domain.Timeout
    end
    else
      let parsed =
        try
          let resp = read_response t in
          let parsed_response =
            protocol_result (fun () ->
              let* resp_id_json = require_member "id" resp in
              let* resp_id = json_to_int resp_id_json in
              let* ok_json = require_member "ok" resp in
              let* ok = json_to_bool ok_json in
              if resp_id <> req_id then
                Error
                  (protocol_error
                     (Printf.sprintf
                        "desync: sent request id=%d, got response id=%d" req_id
                        resp_id))
              else if ok then
                let* result = require_member "result" resp in
                Ok (Json_result result)
              else
                let* err = require_member "error" resp in
                let* kind_json = require_member "kind" err in
                let* kind = json_to_string kind_json in
                let* message_json = require_member "message" err in
                let* message = json_to_string message_json in
                Ok (Worker_error_payload (kind, message)))
          in
          match parsed_response with
          | Error _ as error -> error
          | Ok (Worker_error_payload (kind, message)) ->
            let we = Domain.worker_error_of_string kind in
            let we =
              match we with
              | Domain.Io_error "" -> Domain.Io_error message
              | _ -> we
            in
            Error we
          | Ok (Json_result result) -> Ok result
        with
        | End_of_file ->
          (* Worker crashed — kill to clean up, will restart on next call *)
          kill_worker t;
          Error (Domain.Io_error "worker process died unexpectedly")
      in
      match parsed with
      | Error Domain.Timeout ->
        kill_worker t;
        Error Domain.Timeout
      | Error (Domain.Unknown _ as err) ->
        kill_worker t;
        Error err
      | Error _ as error -> error
      | Ok _ as ok -> ok

let start ?(response_timeout = 120.0) ~worker_path () =
  match spawn_worker worker_path with
  | Error _ as error -> error
  | Ok (pid, to_w, from_w, fd) ->
    Ok
      {
        worker_path;
        response_timeout;
        pid;
        to_worker = to_w;
        from_worker = from_w;
        from_worker_fd = fd;
        next_id = 1;
        alive = true;
      }

let stop t = kill_worker t

let is_alive t =
  if not t.alive then false
  else
    match Unix.waitpid [ Unix.WNOHANG ] t.pid with
    | 0, _ -> true
    | _ ->
        t.alive <- false;
        false
    | exception Unix.Unix_error _ ->
        t.alive <- false;
        false

(* ---- operations ---- *)

let check_mount t ~path ~timeout_seconds =
  let args =
    `Assoc
      [
        ("path", `String path);
        ("timeout_seconds", `Int timeout_seconds);
      ]
  in
  match call t ~op:"check_mount" ~args with
  | Ok result ->
      parse_result_json t (fun () ->
          let* available_json = require_member "available" result in
          let* available = json_to_bool available_json in
          Ok available)
  | Error _ as e -> e

let path_exists t path =
  let args = `Assoc [ ("path", `String path) ] in
  match call t ~op:"path_exists" ~args with
  | Ok result ->
      parse_result_json t (fun () ->
          let* exists_json = require_member "exists" result in
          let* exists = json_to_bool exists_json in
          Ok exists)
  | Error _ as e -> e

let stat_path t path =
  let args = `Assoc [ ("path", `String path) ] in
  match call t ~op:"stat_path" ~args with
  | Ok result ->
      parse_result_json t (fun () ->
          let* size_json = require_member "size" result in
          let* size = json_to_int size_json in
          let* mtime_json = require_member "mtime" result in
          let* mtime = json_to_string mtime_json in
          let* is_dir_json = require_member "is_dir" result in
          let* is_dir = json_to_bool is_dir_json in
          Ok { size; mtime; is_dir })
  | Error _ as e -> e

let walk_tree t ~root ~extensions ~exclude_patterns =
  let args =
    `Assoc
      [
        ("root", `String root);
        ("extensions", `List (List.map (fun s -> `String s) extensions));
        ( "exclude_patterns",
          `List (List.map (fun s -> `String s) exclude_patterns) );
      ]
  in
  match call t ~op:"walk_tree" ~args with
  | Ok result ->
      parse_result_json t (fun () ->
          let* files_json = require_member "files" result in
          let* files =
            match files_json with
            | `List items ->
              let rec collect acc = function
                | [] -> Ok (List.rev acc)
                | item :: rest ->
                  let* path_json = require_member "path" item in
                  let* path = json_to_string path_json in
                  let* size_json = require_member "size" item in
                  let* size = json_to_int size_json in
                  let* mtime_json = require_member "mtime" item in
                  let* mtime = json_to_string mtime_json in
                  collect ({ path; size; mtime } :: acc) rest
              in
              collect [] items
            | _ -> Error (protocol_error "expected files array")
          in
          Ok files)
  | Error _ as e -> e

let hash_path t path =
  let args = `Assoc [ ("path", `String path) ] in
  match call t ~op:"hash_path" ~args with
  | Ok result ->
      parse_result_json t (fun () ->
          let* md5_json = require_member "md5" result in
          let* md5 = json_to_string md5_json in
          Ok md5)
  | Error _ as e -> e

let copy_and_hash t ~src ~dst =
  let args =
    `Assoc [ ("source", `String src); ("dest", `String dst) ]
  in
  match call t ~op:"copy_and_hash" ~args with
  | Ok result ->
      parse_result_json t (fun () ->
          let* md5_json = require_member "md5" result in
          let* md5 = json_to_string md5_json in
          Ok md5)
  | Error _ as e -> e

let move_file t ~src ~dst ~expected_hash =
  let hash_field =
    match expected_hash with
    | Some h -> [ ("expected_hash", `String h) ]
    | None -> [ ("expected_hash", `String "") ]
  in
  let args =
    `Assoc
      ([ ("source", `String src); ("dest", `String dst) ] @ hash_field)
  in
  match call t ~op:"move_file" ~args with
  | Ok result ->
      parse_result_json t (fun () ->
          let* md5_json = require_member "md5" result in
          let* md5 = json_to_string md5_json in
          Ok md5)
  | Error _ as e -> e

let unlink_path t path =
  let args = `Assoc [ ("path", `String path) ] in
  match call t ~op:"unlink_path" ~args with
  | Ok _result -> Ok ()
  | Error _ as e -> e

let mkdir_all t path =
  let args = `Assoc [ ("path", `String path) ] in
  match call t ~op:"mkdir_all" ~args with
  | Ok _result -> Ok ()
  | Error _ as e -> e

let remove_empty_dirs t ~path ~stop_at =
  let args =
    `Assoc [ ("path", `String path); ("stop_at", `String stop_at) ]
  in
  match call t ~op:"remove_empty_dirs" ~args with
  | Ok _result -> Ok ()
  | Error _ as e -> e

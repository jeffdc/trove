(** Client for the Go worker child process.

    Includes a watchdog: if the worker does not respond within
    [response_timeout] seconds, it is killed (SIGKILL) and automatically
    restarted on the next call.  This prevents leaked goroutines from
    accumulating when NAS mounts hang. *)

type stat_result = { size : int; mtime : string; is_dir : bool }
type walk_item = { path : string; size : int; mtime : string }

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

let json_member_exn key json =
  match json_member key json with
  | Some v -> v
  | None -> failwith ("missing key: " ^ key)

let json_to_bool = function
  | `Bool b -> b
  | _ -> failwith "expected bool"

let json_to_int = function
  | `Int i -> i
  | `Intlit s -> int_of_string s
  | `Float f -> int_of_float f
  | _ -> failwith "expected int"

let json_to_string = function
  | `String s -> s
  | _ -> failwith "expected string"

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
  let in_read, in_write = Unix.pipe ~cloexec:true () in
  let out_read, out_write = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process worker_path [| worker_path |]
      in_read out_write Unix.stderr
  in
  Unix.close in_read;
  Unix.close out_write;
  let to_worker = Unix.out_channel_of_descr in_write in
  let from_worker = Unix.in_channel_of_descr out_read in
  (* Read and verify the hello message *)
  let hello_line = input_line from_worker in
  let hello = Yojson.Safe.from_string hello_line in
  let version =
    json_member_exn "protocol_version" hello |> json_to_int
  in
  if version <> 1 then
    failwith
      (Printf.sprintf "unsupported worker protocol version: %d" version);
  (pid, to_worker, from_worker, out_read)

let kill_worker t =
  if t.alive then begin
    t.alive <- false;
    (try Unix.kill t.pid Sys.sigkill with Unix.Unix_error _ -> ());
    (try close_out t.to_worker with _ -> ());
    (try close_in t.from_worker with _ -> ());
    (try ignore (Unix.waitpid [] t.pid) with Unix.Unix_error _ -> ())
  end

let restart_worker t =
  kill_worker t;
  let pid, to_w, from_w, fd = spawn_worker t.worker_path in
  t.pid <- pid;
  t.to_worker <- to_w;
  t.from_worker <- from_w;
  t.from_worker_fd <- fd;
  t.next_id <- 1;
  t.alive <- true

(** Wait for data on the worker's stdout, with timeout.
    Returns true if data is available, false on timeout. *)
let wait_for_response t =
  if t.response_timeout <= 0.0 then true  (* no timeout *)
  else
    match Unix.select [ t.from_worker_fd ] [] [] t.response_timeout with
    | _ :: _, _, _ -> true
    | [], _, _ -> false

let call t ~op ~args =
  if not t.alive then restart_worker t;
  let req_id = send_request t ~op ~args in
  if not (wait_for_response t) then begin
    (* Worker did not respond in time — kill and restart *)
    kill_worker t;
    Error Domain.Timeout
  end
  else
    match read_response t with
    | resp ->
      let resp_id = json_member_exn "id" resp |> json_to_int in
      if resp_id <> req_id then
        failwith
          (Printf.sprintf
             "worker protocol desync: sent request id=%d, got response id=%d"
             req_id resp_id);
      let ok = json_member_exn "ok" resp |> json_to_bool in
      if ok then Ok (json_member_exn "result" resp)
      else
        let err = json_member_exn "error" resp in
        let kind = json_member_exn "kind" err |> json_to_string in
        let message = json_member_exn "message" err |> json_to_string in
        let we = Domain.worker_error_of_string kind in
        let we =
          match we with
          | Domain.Io_error "" -> Domain.Io_error message
          | _ -> we
        in
        Error we
    | exception End_of_file ->
      (* Worker crashed — kill to clean up, will restart on next call *)
      kill_worker t;
      Error (Domain.Io_error "worker process died unexpectedly")

let start ?(response_timeout = 120.0) ~worker_path () =
  let pid, to_w, from_w, fd = spawn_worker worker_path in
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
      let available = json_member_exn "available" result |> json_to_bool in
      Ok available
  | Error _ as e -> e

let path_exists t path =
  let args = `Assoc [ ("path", `String path) ] in
  match call t ~op:"path_exists" ~args with
  | Ok result ->
      let exists = json_member_exn "exists" result |> json_to_bool in
      Ok exists
  | Error _ as e -> e

let stat_path t path =
  let args = `Assoc [ ("path", `String path) ] in
  match call t ~op:"stat_path" ~args with
  | Ok result ->
      let size = json_member_exn "size" result |> json_to_int in
      let mtime = json_member_exn "mtime" result |> json_to_string in
      let is_dir = json_member_exn "is_dir" result |> json_to_bool in
      Ok { size; mtime; is_dir }
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
      let files =
        match json_member_exn "files" result with
        | `List items ->
            List.map
              (fun item ->
                let path = json_member_exn "path" item |> json_to_string in
                let size = json_member_exn "size" item |> json_to_int in
                let mtime = json_member_exn "mtime" item |> json_to_string in
                { path; size; mtime })
              items
        | _ -> failwith "expected files array"
      in
      Ok files
  | Error _ as e -> e

let hash_path t path =
  let args = `Assoc [ ("path", `String path) ] in
  match call t ~op:"hash_path" ~args with
  | Ok result ->
      let md5 = json_member_exn "md5" result |> json_to_string in
      Ok md5
  | Error _ as e -> e

let copy_and_hash t ~src ~dst =
  let args =
    `Assoc [ ("source", `String src); ("dest", `String dst) ]
  in
  match call t ~op:"copy_and_hash" ~args with
  | Ok result ->
      let md5 = json_member_exn "md5" result |> json_to_string in
      Ok md5
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
      let md5 = json_member_exn "md5" result |> json_to_string in
      Ok md5
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

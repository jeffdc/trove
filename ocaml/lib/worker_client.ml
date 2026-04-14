(** Client for the Go worker child process. *)

type stat_result = { size : int; mtime : string; is_dir : bool }
type walk_item = { path : string; size : int; mtime : string }

type t = {
  pid : int;
  to_worker : out_channel;    (** connected to worker's stdin *)
  from_worker : in_channel;   (** connected to worker's stdout *)
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

let call t ~op ~args =
  let _id = send_request t ~op ~args in
  let resp = read_response t in
  let ok = json_member_exn "ok" resp |> json_to_bool in
  if ok then Ok (json_member_exn "result" resp)
  else
    let err = json_member_exn "error" resp in
    let kind = json_member_exn "kind" err |> json_to_string in
    let message = json_member_exn "message" err |> json_to_string in
    let we = Domain.worker_error_of_string kind in
    (* For io_error, attach the message if the generic parsing left it empty *)
    let we =
      match we with
      | Domain.Io_error "" -> Domain.Io_error message
      | _ -> we
    in
    Error we

(* ---- lifecycle ---- *)

let start ~worker_path =
  (* Create pipes with cloexec so ALL FDs are closed on exec.
     Unix.create_process uses dup2 to wire child's stdin/stdout to FDs 0/1,
     and dup2 creates new FDs without CLOEXEC. So the child keeps only FDs
     0, 1, 2 — the leaked parent-side pipe ends are closed by exec. *)
  let in_read, in_write = Unix.pipe ~cloexec:true () in    (* worker's stdin *)
  let out_read, out_write = Unix.pipe ~cloexec:true () in  (* worker's stdout *)
  let pid =
    Unix.create_process worker_path [| worker_path |] in_read out_write Unix.stderr
  in
  (* Close the child-side ends in the parent *)
  Unix.close in_read;
  Unix.close out_write;
  let to_worker = Unix.out_channel_of_descr in_write in
  let from_worker = Unix.in_channel_of_descr out_read in
  let t =
    { pid; to_worker; from_worker; next_id = 1; alive = true }
  in
  (* Read and verify the hello message *)
  let hello_line = input_line from_worker in
  let hello = Yojson.Safe.from_string hello_line in
  let version =
    json_member_exn "protocol_version" hello |> json_to_int
  in
  if version <> 1 then
    failwith
      (Printf.sprintf "unsupported worker protocol version: %d" version);
  t

let stop t =
  if t.alive then begin
    t.alive <- false;
    (try close_out t.to_worker with _ -> ());
    (try close_in t.from_worker with _ -> ());
    (try ignore (Unix.waitpid [] t.pid) with _ -> ())
  end

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

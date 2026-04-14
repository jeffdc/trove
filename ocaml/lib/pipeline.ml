(* Composable pipeline stages for file processing.

   Each stage takes a list of file record IDs (except discover which produces
   them) and returns IDs for the next stage. Side effects are DB updates. *)

module StringSet = Set.Make (String)

(* ---------- normalize_filename ---------- *)

let max_basename = 200
let truncated_len = 192
let hash_len = 7

let is_unsafe_char = function
  | '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' -> true
  | _ -> false

let is_whitespace = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false

let strip_chars s chars =
  let len = String.length s in
  if len = 0 then s
  else
    let is_strip c = String.contains chars c in
    (* Find first non-strip char *)
    let start = ref 0 in
    while !start < len && is_strip s.[!start] do
      incr start
    done;
    (* Find last non-strip char *)
    let stop = ref (len - 1) in
    while !stop >= !start && is_strip s.[!stop] do
      decr stop
    done;
    if !start > !stop then ""
    else String.sub s !start (!stop - !start + 1)

(* Replace each char matching predicate with '_' *)
let replace_chars pred s =
  String.map (fun c -> if pred c then '_' else c) s

(* Collapse runs of underscores to a single underscore *)
let collapse_underscores s =
  let len = String.length s in
  if len = 0 then s
  else begin
    let buf = Buffer.create len in
    let prev_underscore = ref false in
    for i = 0 to len - 1 do
      if s.[i] = '_' then begin
        if not !prev_underscore then Buffer.add_char buf '_';
        prev_underscore := true
      end
      else begin
        Buffer.add_char buf s.[i];
        prev_underscore := false
      end
    done;
    Buffer.contents buf
  end

let is_windows_reserved s =
  let upper = String.uppercase_ascii s in
  match upper with
  | "CON" | "PRN" | "AUX" | "NUL" -> true
  | _ ->
    let len = String.length upper in
    if len = 4 then
      (String.sub upper 0 3 = "COM" || String.sub upper 0 3 = "LPT")
      && upper.[3] >= '1' && upper.[3] <= '9'
    else false

let normalize_filename name =
  (* 1. Unicode NFC — skipped, filenames are typically ASCII *)
  (* 2. Split basename and extension *)
  let ext = Filename.extension name in
  let basename_raw =
    if ext = "" then name
    else
      (* Remove the extension from the end *)
      String.sub name 0 (String.length name - String.length ext)
  in
  (* Handle leading-dot names like ".jpg" where Filename.extension returns ""
     and the whole name is treated as basename. Re-split after stripping dots. *)
  let basename, ext =
    if ext = "" && String.length basename_raw > 0 && basename_raw.[0] = '.' then
      let stripped = strip_chars basename_raw "." in
      if stripped = "" then ("", "")
      else
        let ext2 = Filename.extension stripped in
        if ext2 <> "" then
          let base2 = String.sub stripped 0 (String.length stripped - String.length ext2) in
          (base2, ext2)
        else
          ("", "." ^ stripped)
    else (basename_raw, ext)
  in
  (* 3. Replace path-unsafe characters *)
  let basename = replace_chars is_unsafe_char basename in
  (* 4. Replace whitespace *)
  let basename = replace_chars is_whitespace basename in
  (* 5. Collapse consecutive underscores *)
  let basename = collapse_underscores basename in
  (* 6. Strip leading/trailing dots and underscores *)
  let basename = strip_chars basename "._" in
  (* 7. Windows reserved name check *)
  let basename =
    if is_windows_reserved basename then "_" ^ basename
    else basename
  in
  (* 8. Empty basename fallback *)
  let basename = if basename = "" then "unnamed" else basename in
  (* 9. Truncate long basenames with hash suffix *)
  let basename =
    if String.length basename > max_basename then
      let hash_hex =
        Digest.to_hex (Digest.string basename)
      in
      let suffix = String.sub hash_hex 0 hash_len in
      String.sub basename 0 truncated_len ^ "_" ^ suffix
    else basename
  in
  (* 10. Rejoin *)
  basename ^ ext

(* ---------- parse_iso_date ---------- *)

let parse_iso_date s =
  (* Parse "YYYY-MM-DD" prefix from ISO date strings *)
  if String.length s < 10 then None
  else
    try
      let year = int_of_string (String.sub s 0 4) in
      if s.[4] <> '-' then None
      else
        let month = int_of_string (String.sub s 5 2) in
        if s.[7] <> '-' then None
        else
          let day = int_of_string (String.sub s 8 2) in
          if year < 0 || month < 1 || month > 12 || day < 1 || day > 31 then
            None
          else Some (year, month, day)
    with _ -> None

(* ---------- format_date_structure ---------- *)

let format_date_structure ~year ~month ~day structure =
  let buf = Buffer.create (String.length structure + 4) in
  let len = String.length structure in
  let i = ref 0 in
  while !i < len do
    if structure.[!i] = '%' && !i + 1 < len then begin
      (match structure.[!i + 1] with
       | 'Y' -> Buffer.add_string buf (Printf.sprintf "%04d" year)
       | 'm' -> Buffer.add_string buf (Printf.sprintf "%02d" month)
       | 'd' -> Buffer.add_string buf (Printf.sprintf "%02d" day)
       | c ->
         Buffer.add_char buf '%';
         Buffer.add_char buf c);
      i := !i + 2
    end
    else begin
      Buffer.add_char buf structure.[!i];
      incr i
    end
  done;
  Buffer.contents buf

(* ---------- compute_target_path ---------- *)

let compute_target_path ~capture_date ~camera_model ~filename config =
  match parse_iso_date capture_date with
  | None -> None
  | Some (year, month, day) ->
    let date_part =
      format_date_structure ~year ~month ~day config.Config.organization.structure
    in
    let normalized_filename = normalize_filename filename in
    if not config.Config.organization.include_camera_model then
      Some (date_part ^ "/" ^ normalized_filename)
    else
      let model_part =
        match camera_model with
        | None -> config.Config.organization.unknown_model_label
        | Some m -> normalize_filename m
      in
      Some (date_part ^ "/" ^ model_part ^ "/" ^ normalized_filename)

(* ---------- resolve_path ---------- *)

let resolve_path target_path claimed =
  if not (StringSet.mem target_path !claimed) then begin
    claimed := StringSet.add target_path !claimed;
    target_path
  end
  else begin
    let dir_part, filename =
      match String.rindex_opt target_path '/' with
      | Some i ->
        (String.sub target_path 0 i,
         String.sub target_path (i + 1) (String.length target_path - i - 1))
      | None -> ("", target_path)
    in
    let ext = Filename.extension filename in
    let stem =
      if ext = "" then filename
      else String.sub filename 0 (String.length filename - String.length ext)
    in
    let rec try_suffix i =
      if i >= 10000 then
        failwith ("Cannot resolve path for " ^ target_path)
      else
        let candidate = Printf.sprintf "%s-%d%s" stem i ext in
        let candidate_path =
          if dir_part = "" then candidate
          else dir_part ^ "/" ^ candidate
        in
        if StringSet.mem candidate_path !claimed then
          try_suffix (i + 1)
        else begin
          claimed := StringSet.add candidate_path !claimed;
          candidate_path
        end
    in
    try_suffix 1
  end

(* ---------- now_iso (helper) ---------- *)

let now_iso () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (1900 + tm.tm_year)
    (1 + tm.tm_mon) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec

(* ---------- relative_path helper ---------- *)

let relative_path ~root abs_path =
  (* Compute relative path by stripping root prefix *)
  let root_len = String.length root in
  let abs_len = String.length abs_path in
  if abs_len > root_len
     && String.sub abs_path 0 root_len = root
     && abs_path.[root_len] = '/'
  then
    String.sub abs_path (root_len + 1) (abs_len - root_len - 1)
  else abs_path

(* ---------- discover_and_persist_from_items ---------- *)

let discover_and_persist_from_items db ~source_path ~source_type items ~skip_paths =
  let new_ids = ref [] in
  let skip_count = ref 0 in
  List.iter
    (fun (item : Worker_client.walk_item) ->
      let abs_path = item.path in
      let rel_path = relative_path ~root:source_path abs_path in
      if StringSet.mem rel_path skip_paths then
        incr skip_count
      else begin
        match Db.get_file_by_path db abs_path with
        | Some existing ->
          if existing.file_size = item.size
             && existing.file_modify_date = item.mtime
          then
            (* Unchanged — skip *)
            incr skip_count
          else begin
            (* Changed — reset to discovered *)
            Db.update_file db existing.id
              [
                ("file_size", Some (string_of_int item.size));
                ("file_modify_date", Some item.mtime);
                ("status", Some "discovered");
                ("md5_hash", None);
                ("capture_date", None);
                ("camera_model", None);
                ("target_path", None);
                ("error_message", None);
                ("hashed_at", None);
              ];
            new_ids := existing.id :: !new_ids
          end
        | None ->
          let r =
            Db.insert_file db ~source_path:abs_path ~source_type
              ~file_size:item.size ~file_modify_date:item.mtime
          in
          new_ids := r.id :: !new_ids
      end)
    items;
  (List.rev !new_ids, !skip_count)

(* ---------- hash_files ---------- *)

let hash_files_with_fn db ids ~hash_fn =
  if ids = [] then []
  else begin
    let records = Db.query_files_by_ids db ids in
    let hashed_ids = ref [] in
    List.iter
      (fun (rec_ : Domain.file_record) ->
        match hash_fn rec_.source_path with
        | Ok hash_val ->
          let hash_time = now_iso () in
          Db.update_file db rec_.id
            [
              ("md5_hash", Some hash_val);
              ("status", Some "hashed");
              ("hashed_at", Some hash_time);
            ];
          hashed_ids := rec_.id :: !hashed_ids
        | Error _ ->
          Db.update_file db rec_.id
            [
              ("status", Some "quarantined");
              ("error_message", Some "hash_failed");
            ])
      records;
    List.rev !hashed_ids
  end

let hash_files db worker ids =
  hash_files_with_fn db ids ~hash_fn:(fun path ->
    Worker_client.hash_path worker path)

(* ---------- compute_paths ---------- *)

let compute_paths db ids config =
  if ids = [] then []
  else begin
    let records = Db.query_files_by_ids db ids in
    List.iter
      (fun (rec_ : Domain.file_record) ->
        match rec_.capture_date with
        | Some capture_date ->
          let original_filename = Filename.basename rec_.source_path in
          let target =
            compute_target_path ~capture_date
              ~camera_model:rec_.camera_model ~filename:original_filename
              config
          in
          (match target with
           | Some t ->
             Db.update_file db rec_.id [ ("target_path", Some t) ]
           | None -> ())
        | None -> ())
      records;
    ids
  end

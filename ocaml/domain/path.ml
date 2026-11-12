(** Pure path and date utilities used across the project. *)

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
    let start = ref 0 in
    while !start < len && is_strip s.[!start] do
      incr start
    done;
    let stop = ref (len - 1) in
    while !stop >= !start && is_strip s.[!stop] do
      decr stop
    done;
    if !start > !stop then ""
    else String.sub s !start (!stop - !start + 1)

let replace_chars pred s =
  String.map (fun c -> if pred c then '_' else c) s

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
  let ext = Filename.extension name in
  let basename_raw =
    if ext = "" then name
    else String.sub name 0 (String.length name - String.length ext)
  in
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
  let basename = replace_chars is_unsafe_char basename in
  let basename = replace_chars is_whitespace basename in
  let basename = collapse_underscores basename in
  let basename = strip_chars basename "._" in
  let basename =
    if is_windows_reserved basename then "_" ^ basename
    else basename
  in
  let basename = if basename = "" then "unnamed" else basename in
  let basename =
    if String.length basename > max_basename then
      let hash_hex = Digest.to_hex (Digest.string basename) in
      let suffix = String.sub hash_hex 0 hash_len in
      String.sub basename 0 truncated_len ^ "_" ^ suffix
    else basename
  in
  basename ^ ext

let parse_iso_date s =
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

let compute_library_path ~capture_date ~camera_model ~filename
    ~structure ~include_camera_model ~unknown_model_label =
  match parse_iso_date capture_date with
  | None -> None
  | Some (year, month, day) ->
    let date_part = format_date_structure ~year ~month ~day structure in
    let normalized_filename = normalize_filename filename in
    if not include_camera_model then
      Some (date_part ^ "/" ^ normalized_filename)
    else
      let model_part =
        match camera_model with
        | None -> unknown_model_label
        | Some m -> normalize_filename m
      in
      Some (date_part ^ "/" ^ model_part ^ "/" ^ normalized_filename)

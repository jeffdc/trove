open Domain

let map_target_error ?(context = []) = function
  | Ok value -> Ok value
  | Error err ->
    Error
      {
        err with
        context =
          if context = [] then err.context else err.context @ context;
      }

let run ~legacy ~target ~(state : Migration_types.mapping_state) ~report =
  match Legacy_db.list_libraries legacy with
  | Error _ as error -> error
  | Ok libraries ->
    let rec loop = function
      | [] -> Ok ()
      | (legacy_library : Legacy_types.library) :: rest -> (
          match
            map_target_error
              (Db.create_library target
                 ~name:legacy_library.name
                 ~root_path:legacy_library.location
                 ~config_json:legacy_library.config_json)
          with
          | Error _ as error -> error
          | Ok target_library ->
            Hashtbl.replace state.library_ids_by_legacy_id
              legacy_library.id target_library.id;
            Migration_report.incr report ~counter:"libraries_migrated";
            loop rest)
    in
    loop libraries

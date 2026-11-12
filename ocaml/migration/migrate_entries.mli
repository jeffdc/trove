(** Entry migration stage: library membership, file objects, and placements. *)

val run :
  legacy:Legacy_db.t ->
  target:Db.t ->
  state:Migration_types.mapping_state ->
  report:Migration_report.t ->
  (unit, Domain.app_error) result

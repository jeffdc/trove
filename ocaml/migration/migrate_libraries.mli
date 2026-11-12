(** First migration stage: move legacy libraries into the target schema. *)

val run :
  legacy:Legacy_db.t ->
  target:Db.t ->
  state:Migration_types.mapping_state ->
  report:Migration_report.t ->
  (unit, Domain.app_error) result

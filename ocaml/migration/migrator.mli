type options = {
  source_db_path : string;
  schema_db_path : string;
  report_path : string;
}

val run : options -> (unit, Domain.app_error) result

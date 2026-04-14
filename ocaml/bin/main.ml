let version_info = Cmdliner.Cmd.info "trove" ~version:Trove_lib.version

let cmd = Cmdliner.Cmd.v version_info (Cmdliner.Term.const ())

let () = exit (Cmdliner.Cmd.eval cmd)

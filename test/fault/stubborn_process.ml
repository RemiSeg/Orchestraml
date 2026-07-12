let () =
  Sys.set_signal Sys.sigterm Sys.Signal_ignore;
  while true do Unix.sleepf 1. done

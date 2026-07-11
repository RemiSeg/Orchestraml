let create () : Orchestraml_application.Ports.Clock.t = {
  now = (fun () -> Ptime_clock.now () |> Orchestraml_domain.Foundation.Timestamp.of_ptime)
}

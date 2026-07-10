open Foundation

type t = { cpu : Scalar.Cpu_millicores.t; memory : Scalar.Memory_mib.t }
let create ~cpu ~memory = { cpu; memory }
let cpu value = value.cpu
let memory value = value.memory
let fits ~required ~available =
  Scalar.Cpu_millicores.compare required.cpu available.cpu <= 0
  && Scalar.Memory_mib.compare required.memory available.memory <= 0
let subtract ~total ~reserved =
  let cpu = Scalar.Cpu_millicores.value total.cpu - Scalar.Cpu_millicores.value reserved.cpu in
  let memory = Scalar.Memory_mib.value total.memory - Scalar.Memory_mib.value reserved.memory in
  match Scalar.Cpu_millicores.create cpu, Scalar.Memory_mib.create memory with
  | Ok cpu, Ok memory -> Ok { cpu; memory }
  | _ -> Error (Validation_error.make ~field:"resources" "reserved resources exceed total resources")

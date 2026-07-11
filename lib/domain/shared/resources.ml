open Foundation

type t = { cpu : Scalar.Cpu_millicores.t; memory : Scalar.Memory_mib.t }
let create ~cpu ~memory = { cpu; memory }
let cpu value = value.cpu
let memory value = value.memory
let zero = {
  cpu = Result.get_ok (Scalar.Cpu_millicores.create 0);
  memory = Result.get_ok (Scalar.Memory_mib.create 0);
}
let fits ~required ~available =
  Scalar.Cpu_millicores.compare required.cpu available.cpu <= 0
  && Scalar.Memory_mib.compare required.memory available.memory <= 0
let safe_add ~field left right =
  if left > max_int - right then Error (Validation_error.make ~field "resource total overflow")
  else Ok (left + right)
let add left right =
  match safe_add ~field:"cpu_millicores" (Scalar.Cpu_millicores.value left.cpu)
          (Scalar.Cpu_millicores.value right.cpu),
        safe_add ~field:"memory_mib" (Scalar.Memory_mib.value left.memory)
          (Scalar.Memory_mib.value right.memory) with
  | Ok cpu, Ok memory ->
      Ok { cpu = Result.get_ok (Scalar.Cpu_millicores.create cpu);
           memory = Result.get_ok (Scalar.Memory_mib.create memory) }
  | Error error, _ | _, Error error -> Error error
let subtract ~total ~reserved =
  let cpu = Scalar.Cpu_millicores.value total.cpu - Scalar.Cpu_millicores.value reserved.cpu in
  let memory = Scalar.Memory_mib.value total.memory - Scalar.Memory_mib.value reserved.memory in
  match Scalar.Cpu_millicores.create cpu, Scalar.Memory_mib.create memory with
  | Ok cpu, Ok memory -> Ok { cpu; memory }
  | _ -> Error (Validation_error.make ~field:"resources" "reserved resources exceed total resources")

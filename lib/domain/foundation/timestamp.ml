type t = Ptime.t

let of_ptime value = value
let to_ptime value = value
let of_rfc3339 value =
  match Ptime.of_rfc3339 value with
  | Ok (timestamp, _, _) -> Ok timestamp
  | Error _ -> Error (Validation_error.make ~field:"timestamp" "must be RFC 3339 UTC time")
let to_rfc3339 value = Ptime.to_rfc3339 value
let compare = Ptime.compare
let equal left right = compare left right = 0
let add_seconds timestamp seconds =
  Ptime.add_span timestamp (Ptime.Span.of_int_s seconds)
let diff_seconds ~later ~earlier =
  Ptime.diff later earlier |> Ptime.Span.to_int_s
let pp formatter value = Format.pp_print_string formatter (to_rfc3339 value)

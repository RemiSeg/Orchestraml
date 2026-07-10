open Foundation

module type S = sig
  type t
  val of_string : string -> (t, Validation_error.t) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Make (Name : sig val field : string end) () = struct
  type t = Uuidm.t
  module Metadata = Name

  let of_string value =
    match Uuidm.of_string value with
    | Some uuid -> Ok uuid
    | None -> Error (Validation_error.make ~field:Name.field "must be a valid UUID")

  let to_string value = Uuidm.to_string value
  let equal = Uuidm.equal
  let compare = Uuidm.compare
  let pp formatter value = Format.pp_print_string formatter (to_string value)
end

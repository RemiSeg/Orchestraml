(** Shared interface implemented by each strongly typed UUID identifier. *)

open Foundation

module type S = sig
  type t

  val of_string : string -> (t, Validation_error.t) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Make (Name : sig val field : string end) () : sig
  include S
  module Metadata : module type of Name
end

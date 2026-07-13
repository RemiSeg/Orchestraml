(** Thin coordinator HTTP client used by the command-line application. *)
type error = Invalid_url of string | Transport of string | Protocol of int * string * string
  | Invalid_response of string
type t

val create : client:Cohttp_eio.Client.t -> base_uri:Uri.t -> clock:_ Eio.Time.clock ->
  request_timeout:float -> (t, error) result
val request_json : sw:Eio.Switch.t -> t -> ?headers:(string * string) list ->
  [ `GET | `POST ] -> string -> string option -> (Yojson.Safe.t, error) result
val follow_logs : sw:Eio.Switch.t -> t -> attempt_id:string -> after_sequence:int ->
  on_entry:(int -> Yojson.Safe.t -> unit) -> (int, error) result
val pp_error : Format.formatter -> error -> unit
val exit_code : error -> int

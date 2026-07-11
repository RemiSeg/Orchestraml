(** Ordered immutable SQL migration runner. *)
type error = Invalid_files of string | Database_error of string
val apply : Database.t -> directory:string -> (unit, error) result
val check_current : Database.t -> directory:string -> (unit, error) result

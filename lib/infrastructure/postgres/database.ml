type t = (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t

let connect ~sw ~(env : Eio_unix.Stdenv.base) uri =
  let stdenv : Caqti_eio.stdenv = (env :> Caqti_eio.stdenv) in
  match Caqti_eio_unix.connect_pool ~sw ~stdenv uri with
  | Ok pool -> Ok pool
  | Error error -> Error (Caqti_error.show error)
let health pool =
  let request = Caqti_request.Infix.(Caqti_type.unit ->! Caqti_type.int) "SELECT 1" in
  match Caqti_eio.Pool.use (fun (module Db : Caqti_eio.CONNECTION) ->
    Db.find request ()) pool with
  | Ok 1 -> Ok ()
  | Ok _ -> Error "unexpected health result"
  | Error error -> Error (Caqti_error.show error)

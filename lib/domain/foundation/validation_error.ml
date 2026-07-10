type t = { field : string; message : string }

let make ~field message = { field; message }
let pp formatter error =
  Format.fprintf formatter "%s: %s" error.field error.message

type t = string
let valid = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | ':' | '-' -> true
  | _ -> false
let create value =
  let value = String.trim value in
  if String.length value = 0 || String.length value > 128 then
    Error (Validation_error.make ~field:"idempotency_key" "must contain 1 to 128 characters")
  else if not (String.for_all valid value) then
    Error (Validation_error.make ~field:"idempotency_key"
      "may contain only letters, digits, '.', '_', ':', and '-'")
  else Ok value
let value value = value
let equal = String.equal
let pp = Format.pp_print_string

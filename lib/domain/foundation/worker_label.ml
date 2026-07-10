type t = string

let valid_character = function
  | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true
  | _ -> false

let create value =
  let normalized = String.lowercase_ascii (String.trim value) in
  if String.length normalized = 0 then
    Error (Validation_error.make ~field:"worker_label" "must not be empty")
  else if not (String.for_all valid_character normalized) then
    Error (Validation_error.make ~field:"worker_label"
      "may contain only lowercase letters, digits, '.', '_', and '-'")
  else Ok normalized

let value value = value
let compare = String.compare
let pp = Format.pp_print_string
module Set = Set.Make (String)

let json ~code ~message ?(fields=[]) () = `Assoc [
  "error", `Assoc ["code", `String code; "message", `String message;
    "fields", `List (List.map (fun (field, message) ->
      `Assoc ["field", `String field; "message", `String message]) fields)]]

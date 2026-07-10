open Foundation

type t = Command of { executable : string; arguments : string list }
       | Container of { image : string; command : string list }

let non_empty ~field value =
  let value = String.trim value in
  if String.length value = 0 then Error (Validation_error.make ~field "must not be empty")
  else Ok value

let command ~executable ~arguments =
  match non_empty ~field:"executable" executable with
  | Error error -> Error error
  | Ok executable -> Ok (Command { executable; arguments })

let container ~image ~command =
  match non_empty ~field:"container_image" image with
  | Error error -> Error error
  | Ok image -> Ok (Container { image; command })

let fold ~command ~container = function
  | Command value -> command value.executable value.arguments
  | Container value -> container value.image value.command

let read_body body =
  let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) body in
  Eio.Buf_read.take_all reader
let callback router _connection request body =
  let meth = Cohttp.Request.meth request |> Cohttp.Code.string_of_method in
  let target = Cohttp.Request.resource request in
  let headers = Cohttp.Request.headers request |> Cohttp.Header.to_list in
  let response = Api.Router.handle router { meth; target; headers; body = read_body body } in
  let status = Cohttp.Code.status_of_code response.status in
  let headers = Cohttp.Header.of_list response.headers in
  Cohttp_eio.Server.respond_string ~status ~headers ~body:response.body ()
let run ~sw ~net ~listen_address ~port router =
  let address = match listen_address with
    | "127.0.0.1" -> Eio.Net.Ipaddr.V4.loopback
    | "0.0.0.0" -> Eio.Net.Ipaddr.V4.any
    | "::1" -> Eio.Net.Ipaddr.V6.loopback
    | "::" -> Eio.Net.Ipaddr.V6.any
    | value -> invalid_arg ("unsupported listen address: " ^ value) in
  let socket = Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:128 (`Tcp (address, port)) in
  let server = Cohttp_eio.Server.make ~callback:(callback router) () in
  Cohttp_eio.Server.run socket server ~on_error:(fun error ->
    Format.eprintf "HTTP connection error: %s@." (Printexc.to_string error))

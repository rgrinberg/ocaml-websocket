open Websocket_lwt
open Lwt.Infix

let h = Hashtbl.create 17
let section = Lwt_log.Section.make "reynir"

let handler id req recv send =
  (try
     Hashtbl.find h id
   with Not_found ->
     Hashtbl.add h id ();
     Lwt_log.ign_info_f ~section "New connection (id = %d)" id;
     Lwt.async (fun () ->
         Lwt_unix.sleep 1.0 >|= fun () ->
         send @@ Frame.create ~content:"Delayed message" ()
       )
  );
  let rec recv_forever () =
    let open Frame in
    let react fr =
      Lwt_log.debug_f ~section "<- %s" (Frame.show fr) >>= fun () ->
      match fr.opcode with
      | Opcode.Ping ->
        send @@ Frame.create ~opcode:Opcode.Pong ~content:fr.content ()

      | Opcode.Close ->
        Lwt_log.info_f ~section "Client %d sent a close frame" id >>= fun () ->
        (* Immediately echo and pass this last message to the user *)
        (if String.length fr.content >= 2 then
           send @@ Frame.create ~opcode:Opcode.Close
             ~content:(String.sub fr.content 0 2) ()
         else send @@ Frame.close 1000) >>= fun () ->
        Lwt.fail Exit

      | Opcode.Pong -> Lwt.return_unit

      | Opcode.Text
      | Opcode.Binary -> send @@ Frame.create ~content:"OK" ()

      | _ ->
        send @@ Frame.close 1002 >>= fun () ->
        Lwt.fail Exit
    in
    recv () >>= react >>= recv_forever
  in
  try%lwt
    recv_forever ()
  with exn ->
    Lwt_log.info_f ~section "Connection to client %d lost" id >>= fun () ->
    Hashtbl.remove h id;
    Lwt.fail exn

let main uri =
  Resolver_lwt.resolve_uri ~uri Resolver_lwt_unix.system >>= fun endp ->
  Conduit_lwt_unix.(endp_to_server ~ctx:default_ctx endp >>= fun server ->
  establish_server ~ctx:default_ctx ~mode:server handler)

let () =
  let uri = ref "http://localhost:9001" in

  let speclist = Arg.align
      [
        "-v", Arg.String (fun s -> Lwt_log.(add_rule s Info)), "<section> Put <section> to Info level";
        "-vv", Arg.String (fun s -> Lwt_log.(add_rule s Debug)), "<section> Put <section> to Debug level"
      ]
  in
  let anon_fun s = uri := s in
  let usage_msg = "Usage: " ^ Sys.argv.(0) ^ " <options> uri\nOptions are:" in
  Arg.parse speclist anon_fun usage_msg;

  ignore @@ main @@ Uri.of_string !uri;
  Lwt_main.run (fst (Lwt.wait ()))

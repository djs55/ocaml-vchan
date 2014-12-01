(*
 * Copyright (C) Citrix Systems Inc.
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Sexplib.Std

(* FIXME: This should probably be pushed into xen-evtchn *)

(* Represent a listening event channel as a listening Unix domain socket *)

module Lwt_condition = struct
include Lwt_condition
type _t = unit with sexp
let sexp_of_t _ _ = sexp_of__t ()
end
module Lwt = struct
include Lwt
type _t = unit with sexp
let sexp_of_t _ _ = sexp_of__t ()
end
module Lwt_unix = struct
include Lwt_unix
type _file_descr = int with sexp
let sexp_of_file_descr fd =
  let unix = unix_file_descr fd in
  let (x: int) = Obj.magic unix in
  sexp_of__file_descr x
end

open Lwt

type 'a io = 'a Lwt.t

type port = string with sexp_of

let port_of_string x = `Ok x
let string_of_port x = x

let next_port = ref 0

type event = int with sexp_of
let initial = 0

type state =
| Listening of (Lwt_unix.file_descr * string)
| Connected of Lwt_unix.file_descr
| Closed with sexp_of

type channel = {
  mutable events: event; (* incremented on send *)
  c: unit Lwt_condition.t;
  mutable state: state;
  mutable th: unit Lwt.t option;
} with sexp_of

let rec receive_events t = match t.state with
| Connected fd ->
  let buf = String.create 1 in
  Lwt_unix.read fd buf 0 1
  >>= fun n ->
  t.events <- t.events + 1;
  Lwt_condition.signal t.c ();
  if n = 0
  then fail End_of_file
  else receive_events t
| Listening (_, _) ->
  let msg = "Cannot receive events in the Listening state" in
  Printf.fprintf stderr "%s\n%!" msg;
  fail (Failure msg)
| Closed ->
  let msg = "Cannot receive events in the Closed state" in
  Printf.fprintf stderr "%s\n%!" msg;
  fail (Failure msg)

let get_next_port_nr =
  let x = ref 0 in
  fun () ->
    let result = !x in
    incr x;
    result

let nr_connected = ref 0

let listen _ =
  let port_nr = get_next_port_nr () in
  Unix_common.get_socket_dir ()
  >>= fun dir ->
  let path = Filename.concat dir (string_of_int port_nr) in

  let fd = Lwt_unix.socket Lwt_unix.PF_UNIX Lwt_unix.SOCK_STREAM 0 in
  Lwt_unix.bind fd (Lwt_unix.ADDR_UNIX path);
  let events = initial in
  let c = Lwt_condition.create () in
  let state = Listening (fd, path) in
  let t = { events; c; state; th = None } in

  let th =
    Lwt_unix.listen fd 1;
    Lwt_unix.accept fd
    >>= fun (fd', sockaddr) ->
    t.state <- Connected fd';
    Lwt_unix.close fd
    >>= fun () ->
    Lwt_unix.unlink path
    >>= fun () ->
    receive_events t in
  t.th <- Some th;

  incr nr_connected;
  return (path, t)

let connect _ port =
  let fd = Lwt_unix.socket Lwt_unix.PF_UNIX Lwt_unix.SOCK_STREAM 0 in
  Lwt_unix.connect fd (Lwt_unix.ADDR_UNIX port)
  >>= fun () ->

  let events = initial in
  let c = Lwt_condition.create () in
  let state = Connected fd in
  let t = { events; c; state; th = None } in

  let th = receive_events t in
  t.th <- Some th;
  incr nr_connected;
  return t

let close t = match t with
| { state = Connected fd; th = Some th } ->
  t.state <- Closed;
  Lwt.cancel th;
  Lwt_unix.close fd
  >>= fun () ->
  decr nr_connected;
  return ()
| { state = Listening (fd, path); th = Some th } ->
  t.state <- Closed;
  Lwt.cancel th;
  Lwt_unix.close fd
  >>= fun () ->
  Lwt_unix.unlink path
  >>= fun () ->
  decr nr_connected;
  return ()
| { state = Closed } -> return ()
| _ ->
  let msg = "Invalid connection state" in
  Printf.fprintf stderr "%s\n%!" msg;
  fail (Failure msg)

let rec recv channel event =
  if channel.events > event
  then return channel.events
  else
    Lwt_condition.wait channel.c >>= fun () ->
    recv channel event

let send = function
| { state = Connected fd } ->
  let x = String.create 1 in
  (* This can fail if the fd is closed *)
  Lwt.catch
   (fun () -> Lwt_unix.write fd x 0 1 >>= fun _ -> return ())
   (function
     | Unix.Unix_error(Unix.EPIPE, _, _) -> return ()
     | e -> fail e)
| { state = Closed } ->
  return ()
| { state = Listening (_, _) } ->
  let msg = "Cannot send while in the Listening state" in
  Printf.fprintf stderr "%s\n%!" msg;
  fail (Failure "Cannot send while in the Listening state")

let assert_cleaned_up () =
  if !nr_connected <> 0
  then failwith (Printf.sprintf "%d event channels are still connected" !nr_connected)

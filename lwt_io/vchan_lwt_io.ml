(*
 * Copyright (c) 2014 Citrix Systems Inc
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
open Vchan

(* Delete when I've got a working Cohttp *)
module type Cohttp_IO_S = sig
  type +'a t
  val (>>=) : 'a t -> ('a -> 'b t) -> 'b t
  val return : 'a -> 'a t

  type ic
  type oc

  val iter : ('a -> unit t) -> 'a list -> unit t
  val read_line : ic -> string option t
  val read : ic -> int -> string t
  val read_exactly : ic -> int -> string option t

  val write : oc -> string -> unit t
  val flush : oc -> unit t
end

module type IO = sig
  include Cohttp_IO_S
    with type 'a t = 'a Lwt.t
     and type ic = Lwt_io.input_channel
     and type oc = Lwt_io.output_channel

  val open_client :
      domid:int -> port:Vchan.Port.t
      -> ?buffer_size:int
      -> unit
      -> (Lwt_io.input_channel * Lwt_io.output_channel) Lwt.t
  (** [open_client domid port ?buffer_size ()] creates a client
      connection to the server running on [domid] with port [port].
      This call will block until communication is established and it
      is safe to pass traffic. The underlying vchan connection will
      be disconnected when the input_channel is closed.
      If a ?buffer_size is given then 4 buffers of this size will be
      created: 2 for reading (vchan + Lwt_io) and 2 for writing.
   *)

  val open_server :
      domid: int -> port:Vchan.Port.t
      -> ?buffer_size:int
      -> unit
      -> (Lwt_io.input_channel * Lwt_io.output_channel) Lwt.t
  (** [open_server domid port ?buffer_size ()] creates a server
      connection to client [domid] with port [port]. If a ?buffer_size
      argument is given then 4 buffers of this size will be created:
      2 for reading (vchan + Lwt_io) and 2 for writing. *)

  val description: string
  (** Human-readable description suitable for help text or
      a manpage *)

end

module IO = struct
  type 'a t = 'a Lwt.t
  let ( >>= ) = Lwt.( >>= )
  let return = Lwt.return

  type ic = Lwt_io.input_channel
  type oc = Lwt_io.output_channel

  let iter = Lwt_list.iter_s

  let read_line = Lwt_io.read_line_opt

  let read ic count =
    Lwt.catch (fun () -> Lwt_io.read ~count ic)
       (function End_of_file -> return ""
        | e -> Lwt.fail e)

  let read_exactly ic buf off len =
    Lwt.catch (fun () -> Lwt_io.read_into_exactly ic buf off len >>= fun () ->  return true)
      (function End_of_file -> return false
       | e -> Lwt.fail e)

  let read_exactly ic len =
    let buf = String.create len in
    read_exactly ic buf 0 len >>= function
      | true -> return (Some buf)
      | false -> return None

  let write = Lwt_io.write

  let write_line = Lwt_io.write_line

  let flush = Lwt_io.flush
end

open Lwt

module Make(M: Vchan.S.ENDPOINT
  with type 'a io = 'a Lwt.t
   and type port = Vchan.Port.t
) = struct
  include IO

  let description = M.description

  let reader t =
    (* Last buffer from vchan *)
    let frag = ref (Cstruct.create 0) in
    let rec aux buf ofs len =
      if len = 0
      then return 0
      else
        let available = Cstruct.len !frag in
        if available = 0 then begin
          M.read t >>= function
          | `Ok b ->
            frag := b;
            aux buf ofs len
          | `Eof -> return 0
          | `Error (`Unknown msg) -> Lwt.fail (Failure msg)
        end else begin
          let n = min available len in
          Cstruct.blit !frag 0 (Cstruct.of_bigarray buf) ofs n;
          frag := Cstruct.shift !frag n;
          return n
        end in
    aux

  let writer t (buf: Lwt_bytes.t) (ofs: int) (len: int) =
    let b = Cstruct.sub (Cstruct.of_bigarray buf) ofs len in
    M.write t b >>= function
    | `Ok () ->
      return len
    | `Eof ->
      return 0
    | `Error (`Unknown msg) ->
      Lwt.fail (Failure msg)

  let open_client ~domid ~port ?(buffer_size = 1024) () =
    M.client ~domid ~port ()
    >>= fun t ->

    let close () = M.close t in

    let ic = Lwt_io.make ~buffer_size ~mode:Lwt_io.input ~close (reader t) in
    let oc = Lwt_io.make ~buffer_size ~mode:Lwt_io.output (writer t) in
    return (ic, oc)

  let open_server ~domid ~port ?(buffer_size = 1024) () =
    M.server ~domid ~port
      ~read_size:buffer_size ~write_size:buffer_size ()
    >>= fun t ->

    let close () = M.close t in

    let ic = Lwt_io.make ~buffer_size ~mode:Lwt_io.input ~close (reader t) in
    let oc = Lwt_io.make ~buffer_size ~mode:Lwt_io.output (writer t) in
    return (ic, oc)
end

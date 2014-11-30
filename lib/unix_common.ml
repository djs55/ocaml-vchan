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

open Lwt

let env_var = "XEN_ROOT"

let cache f =
  let c = ref None in
  fun () -> match !c with
  | Some x -> return x
  | None ->
    f ()
    >>= fun path ->
    c := Some path;
    return path

let get_xen_root = cache (fun () ->
  (* This is our lazy init function *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let rec loop counter =
    if counter > 100 then begin
      Printf.fprintf stderr "Failed to create a private sockets dir (I tried > 100 times!)\n%!";
      fail (Failure "failed to create private sockets dir")
    end else begin
      let path = Filename.(concat temp_dir_name (Printf.sprintf "%s.%d.%d" (basename Sys.argv.(0)) (Unix.getpid ()) counter)) in
      Lwt.catch
        (fun () ->
          Lwt.catch
            (fun () -> Lwt_unix.access path [ Lwt_unix.X_OK ])
            (fun _ -> Lwt_unix.mkdir path 0o0700)
          >>= fun () ->
          return path
        ) (fun _ -> loop (counter + 1))
      end in
  (* First look for a path in an environment variable *)
  Lwt.catch
    ( fun () ->
      (try return (Sys.getenv env_var) with e -> fail e)
      >>= fun root ->
      Lwt_unix.access root [ Lwt_unix.X_OK ]
      >>= fun () ->
      return root )
    (fun _ ->
      (* Fall back to creating a fresh path *)
      loop 0
      >>= fun path ->
      (* Print the environment variable needed for other apps to talk to us *)
      Printf.fprintf stderr "%s=%s\n%!" env_var path;
      return path)
)

let get_socket_dir = get_xen_root

let get_memory_dir = cache (fun () ->
  get_xen_root ()
  >>= fun root ->
  let dir = Filename.concat root "memory" in
  Lwt.catch
    (fun () -> Lwt_unix.access dir [ Lwt_unix.X_OK ])
    (fun _ -> Lwt_unix.mkdir dir 0o0700)
  >>= fun () ->
  return dir
)

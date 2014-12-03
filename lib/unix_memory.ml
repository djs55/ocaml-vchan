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

type 'a io = 'a Lwt.t

type grant = int32 with sexp

let grant_of_int32 x = x
let int32_of_grant x = x

(* A shared block of memory is represented by a file with path
   $XEN_ROOT/<domid>/<g0,g1,g2,gN> *)

type page = Io_page.t
let sexp_of_page _ = Sexplib.Sexp.Atom "<buffer>"

type share = {
  grants: grant list;
  mapping: page;
} with sexp_of

let grants_of_share x = x.grants
let buf_of_share x = x.mapping

let filename_of_grants grants =
  Unix_common.get_memory_dir ()
  >>= fun dir ->
  let basename = String.concat "," (List.map Int32.to_string grants) in
  return (Filename.concat dir basename)

let get =
  let g = ref Int32.zero in
  fun () ->
    g := Int32.succ !g;
    Int32.pred !g

let rec get_n n =
  if n = 0 then [] else get () :: (get_n (n-1))

let share ~domid ~npages ~rw =
  let grants = get_n npages in
  let size = npages * 4096 in
  filename_of_grants grants
  >>= fun name ->
  Lwt_unix.openfile name [ Lwt_unix.O_CREAT; Lwt_unix.O_TRUNC; Lwt_unix.O_RDWR ] 0o0600
  >>= fun fd ->
  (*
  Lwt_unix.lseek fd (npages * 4096 - 1) Unix.SEEK_SET
  >>= fun _ ->
  Lwt_unix.write fd "\000" 0 1
  >>= fun n ->
  *)
  let unix_fd = Lwt_unix.unix_file_descr fd in
  let mapping = Lwt_bytes.map_file ~fd:unix_fd ~shared:true ~size () in
  Lwt_unix.close fd
  >>= fun () ->
  (*
  if n <> 1 then begin
    let msg = Printf.sprintf "Failed to create %s with %d pages" name npages in
    Printf.forintf stderr "%s\n%!" msg;
    fail (Failure msg)
  end else
  *)
  return { grants; mapping }

let unshare share =
  filename_of_grants share.grants
  >>= fun name ->
  Lwt_unix.unlink name

type mapping = {
  mapping: page;
  grants: (int * int32) list;
} with sexp_of

let buf_of_mapping x = x.mapping

let mapv ~grants ~rw =
  filename_of_grants (List.map snd grants)
  >>= fun name ->
  Lwt_unix.openfile name [ Lwt_unix.O_RDWR ] 0o0600
  >>= fun fd ->
  let unix_fd = Lwt_unix.unix_file_descr fd in
  let mapping = Lwt_bytes.map_file ~fd:unix_fd ~shared:true () in
  Lwt_unix.close fd
  >>= fun () ->
  return { mapping; grants }

let map ~domid ~grant ~rw =
  let grants = [ domid, grant ] in
  mapv ~grants ~rw

let unmap { mapping; grants } = ()

let assert_cleaned_up () = ()

let description = "Memory pages will be shared using mmap(2)."

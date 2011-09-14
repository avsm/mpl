(*
 * Copyright (c) 2005 Anil Madhavapeddy <anil@recoil.org>
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
 *
 * $Id: mpl_stdlib.ml,v 1.55 2006/02/15 12:15:16 avsm Exp $
 *)

(* Standard library functions for MPL generated interfaces *)

open Printf

module Tree =
  struct
    type t = [ `Tree of (string * t list) | `Leaf of (string * string) ]
    let print (t : t) =
      let ind i = String.make (i * 2) ' ' in
      let ofn i x =
        output_string Pervasives.stderr (sprintf "%s%s" (ind i) x)
      in
      let onl = prerr_endline in
      let rec fn i =
        function
          `Tree (nm, tl) ->
            onl (sprintf "[ %s ]" nm);
            List.iter (fun t -> ofn i "|_ "; fn (i + 1) t) tl
        | `Leaf (k, v) -> onl (sprintf "%s = %s" k v)
      in
      fn 0 t; onl ""
  end

exception IO_error
exception Buffer_overflow

let rd = ref 0
let dbg x = ()
let dbg = prerr_endline

type fillfn = string -> int -> int -> int
let null_fillfn _ _ _ = 0

type env =
  { __bbuf : string;
    __blen : int ref;
    __bbase : int;
    mutable __bsz : int;
    mutable __bpos : int;
    mutable __fillfn : fillfn }

type frag = env

type data = [ `Sub of (env -> unit) | `Str of string | `Frag of frag | `None ]

type endian =
    Little_endian
  | Big_endian
let endian = ref Big_endian
let set_little_endian () = endian := Little_endian
let set_big_endian () = endian := Big_endian
let set_network_endian = set_big_endian

let whole_buffer env =
  let env' = {env with __bbase = 0} in
  env'.__bpos <- 0;
  env'.__bsz <- 0;
  env'.__blen := 0;
  env'.__fillfn <- null_fillfn;
  env'

let new_env ?(fillfn = null_fillfn) ?(length = 0) buf =
  let blen = ref length in
  {__bbase = 0; __bbuf = buf; __bsz = 0; __bpos = 0; __blen = blen;
   __fillfn = fillfn}

let set_fillfn env fn = env.__fillfn <- fn
let default_fillfn env = env.__fillfn <- null_fillfn

let string_of_env env = String.sub env.__bbuf env.__bbase env.__bsz

let string_of_full_env env = String.sub env.__bbuf 0 !(env.__blen)

let reset env = env.__blen := 0; env.__bsz <- 0; env.__bpos <- 0
    
(* Fill the buffer by at least min bytes or throw an exception *)
let fill ?(min = 1) env fd =
  assert (min >= 0);
  rd := 0;
  while !rd < min do
    let r =
      Unix.read fd env.__bbuf !(env.__blen)
        (String.length env.__bbuf - !(env.__blen))
    in
    if r = 0 then raise IO_error else env.__blen := !(env.__blen) + r;
    rd := !rd + r
  done;
  env.__bsz <- !(env.__blen)

(* Append a string into the buffer *)
let fill_string env buf =
  String.blit buf 0 env.__bbuf !(env.__blen) (String.length buf)

let size env = env.__bsz
let total_size env = String.length env.__bbuf

let incr_pos env amt =
  env.__bpos <- env.__bpos + amt;
  env.__bsz <- max env.__bsz env.__bpos;
  if env.__bpos + env.__bbase > !(env.__blen) then
    env.__blen := env.__bpos + env.__bbase

let check_bounds env am =
  let tpos = env.__bbase + env.__bpos + am in
  if tpos > !(env.__blen) then
    let r = env.__fillfn env.__bbuf !(env.__blen) (tpos - !(env.__blen)) in
    env.__blen := !(env.__blen) + r; env.__bsz <- env.__bsz + r

let skip env amt = check_bounds env amt; incr_pos env amt
let curbase env = env.__bbase
let curpos env = env.__bpos
let env_at env off sz =
  {env with __bbase = env.__bbase + off; __bsz = sz; __bpos = 0}
let env_pos env pos = {env with __bpos = pos}
let env_fn env fn = fn env.__bbuf (env.__bbase + env.__bpos) env.__bsz

let remaining env = assert (env.__bpos <= env.__bsz); env.__bsz - env.__bpos

let fold_env env f initial = 
	let rec fold acc = 
		if remaining env <= 0
		then acc
		else 
			let env' = env_at env (curpos env) (size env) in
			let acc' = f env' acc in
			skip env (curpos env');
			fold acc' in
	fold initial

(* Flush the environment to the file descriptor *)
let flush env fd = ignore (Unix.single_write fd env.__bbuf 0 !(env.__blen))

let sendto env s t = ignore (Unix.sendto s env.__bbuf 0 !(env.__blen) [] t)

(* XXX These are slow implementations of byte/uint16/uint32/bit, to be replaced
   by C bindings when the dust settles and all else is stable - avsm *)
module Mpl_byte =
  struct
    type t = char
    let __unmarshal env =
      let c = String.get env.__bbuf (env.__bbase + env.__bpos) in
      env.__bpos <- env.__bpos + 1; c
    let unmarshal env = check_bounds env 1; __unmarshal env
    let __marshal env v =
      String.set env.__bbuf (env.__bbase + env.__bpos) v; incr_pos env 1
    let marshal env v = __marshal env v
    let at env off = String.get env.__bbuf (env.__bbase + off)
    let to_char (x : t) = x
    let of_char (x : t) = x
    let to_int = int_of_char
    let of_int = char_of_int
    let prettyprint x = string_of_int (int_of_char x)
  end

module Mpl_uint16 =
  struct
    type t = int
    let __unmarshal env =
      let a = int_of_char (Mpl_byte.__unmarshal env) in
      let b = int_of_char (Mpl_byte.__unmarshal env) in
      match !endian with
        Big_endian -> a lsl 8 + b
      | Little_endian -> b lsl 8 + a
    let unmarshal env = check_bounds env 2; __unmarshal env
    let __marshal env v =
      match !endian with
        Big_endian ->
          Mpl_byte.__marshal env (char_of_int (v lsr 8 land 255));
          Mpl_byte.__marshal env (char_of_int (v land 255))
      | Little_endian ->
          Mpl_byte.__marshal env (char_of_int (v land 255));
          Mpl_byte.__marshal env (char_of_int (v lsr 8 land 255))
    let marshal env v = __marshal env v
    let at env off =
      let a = int_of_char (Mpl_byte.at env off) in
      let b = int_of_char (Mpl_byte.at env (off + 1)) in
      match !endian with
        Big_endian -> a lsl 8 + b
      | Little_endian -> b lsl 8 + a
    let prettyprint = string_of_int
    let to_int x = x
    let of_int x = x
    let dissect fn acc env =
      let bp = env.__bbase + env.__bpos in
      assert (env.__bsz + env.__bbase < String.length env.__bbuf);
      let amt = env.__bsz - env.__bpos in
      let n = amt / 2 in
      let acc = ref acc in
      let _ =
        match !endian with
          Big_endian ->
            for i = 0 to n - 1 do
              let a =
                int_of_char (String.unsafe_get env.__bbuf (bp + i * 2))
              in
              let b =
                int_of_char (String.unsafe_get env.__bbuf (bp + i * 2 + 1))
              in
              acc := fn !acc (a lsl 8 + b)
            done
        | Little_endian ->
            for i = 0 to n - 1 do
              let a =
                int_of_char (String.unsafe_get env.__bbuf (bp + i * 2))
              in
              let b =
                int_of_char (String.unsafe_get env.__bbuf (bp + i * 2 + 1))
              in
              acc := fn !acc (b lsl 8 + a)
            done
      in
      if amt mod 2 = 1 then
        begin
          let a = int_of_char (String.unsafe_get env.__bbuf (bp + amt - 1)) in
          acc :=
            fn !acc
               (match !endian with
                  Big_endian -> a lsl 8
                | Little_endian -> a)
        end;
      !acc
  end

module Mpl_uint32 =
  struct
    type t = int32
    let __unmarshal env =
      let module I = Int32
      in
      let a = Mpl_uint16.__unmarshal env in
      let b = Mpl_uint16.__unmarshal env in
      match !endian with
        Big_endian -> I.add (I.of_int b) (I.shift_left (I.of_int a) 16)
      | Little_endian -> I.add (I.of_int a) (I.shift_left (I.of_int b) 16)
    let unmarshal env = check_bounds env 4; __unmarshal env
    let __marshal env v =
      let module I = Int32
      in
      match !endian with
        Big_endian ->
          Mpl_uint16.__marshal env (I.to_int (I.shift_right_logical v 16));
          Mpl_uint16.__marshal env (I.to_int (I.logand v 65535l))
      | Little_endian ->
          Mpl_uint16.__marshal env (I.to_int (I.logand v 65535l));
          Mpl_uint16.__marshal env (I.to_int (I.shift_right_logical v 16))
    let marshal env v = __marshal env v
    let at env off =
      let module I = Int32
      in
      let a = Mpl_uint16.at env off in
      let b = Mpl_uint16.at env (off + 2) in
      match !endian with
        Big_endian -> I.add (I.of_int b) (I.shift_left (I.of_int a) 16)
      | Little_endian -> I.add (I.of_int a) (I.shift_left (I.of_int b) 16)
    let prettyprint x = Int32.to_string x
    let to_int32 x = x
    let of_int = Int32.of_int
    let of_int32 x = x
    let to_int = Int32.to_int
  end

module Mpl_uint64 =
  struct
    type t = int64
    let __unmarshal env =
      let module I = Int64
      in
      let a = Mpl_uint32.__unmarshal env in
      let b = Mpl_uint32.__unmarshal env in
      match !endian with
        Big_endian -> I.add (I.of_int32 b) (I.shift_left (I.of_int32 a) 32)
      | Little_endian -> I.add (I.of_int32 a) (I.shift_left (I.of_int32 b) 32)
    let unmarshal env = check_bounds env 8; __unmarshal env
    let __marshal env v =
      let module I = Int64
      in
      match !endian with
        Big_endian ->
          Mpl_uint32.__marshal env (I.to_int32 (I.shift_right_logical v 32));
          Mpl_uint32.__marshal env (I.to_int32 (I.logand v 4294967295L))
      | Little_endian ->
          Mpl_uint32.__marshal env (I.to_int32 (I.logand v 4294967295L));
          Mpl_uint32.__marshal env (I.to_int32 (I.shift_right_logical v 32))
    let marshal env v = __marshal env v
    let at env off =
      let module I = Int64
      in
      let a = Mpl_uint32.at env off in
      let b = Mpl_uint32.at env (off + 4) in
      match !endian with
        Big_endian -> I.add (I.of_int32 b) (I.shift_left (I.of_int32 a) 32)
      | Little_endian -> I.add (I.of_int32 a) (I.shift_left (I.of_int32 b) 32)
    let prettyprint = Int64.to_string
    let to_int64 x = x
    let of_int64 x = x
    let of_int = Int64.of_int
    let to_int = Int64.to_int
  end

module Mpl_raw =
  struct
    let marshal env str =
      let len = String.length str in
      String.blit str 0 env.__bbuf (env.__bbase + env.__bpos) len;
      incr_pos env len
    let at env off len = String.sub env.__bbuf (env.__bbase + off) len
    let frag env off len =
      {env with __bbase = env.__bbase + off; __bsz = len; __bpos = 0}
    let total_frag env = frag env 0 env.__bsz
    let frag_length env = env.__bsz
    let blit tenv fenv =
      String.blit fenv.__bbuf fenv.__bbase tenv.__bbuf
        (tenv.__bbase + tenv.__bpos) fenv.__bsz;
      incr_pos tenv fenv.__bsz
    let prettyprint s =
      let buf1 = Buffer.create 64 in
      let buf2 = Buffer.create 64 in
      let lines1 = ref [] in
      let lines2 = ref [] in
      for i = 0 to String.length s - 1 do
        if i <> 0 && i mod 8 = 0 then
          begin
            lines1 := Buffer.contents buf1 :: !lines1;
            lines2 := Buffer.contents buf2 :: !lines2;
            Buffer.reset buf1;
            Buffer.reset buf2
          end;
        let pchar c =
          let s = String.make 1 c in if Char.escaped c = s then s else "."
        in
        Buffer.add_string buf1
          (sprintf " %02X" (int_of_char (String.get s i)));
        Buffer.add_string buf2 (sprintf " %s" (pchar (String.get s i)))
      done;
      if Buffer.length buf1 > 0 then
        lines1 := Buffer.contents buf1 :: !lines1;
      if Buffer.length buf2 > 0 then
        lines2 := Buffer.contents buf2 :: !lines2;
      Buffer.reset buf1;
      Buffer.add_char buf1 '\n';
      List.iter2
        (fun l1 l2 ->
           Buffer.add_string buf1 (sprintf "   %-24s   |   %-16s   \n" l1 l2))
        (List.rev !lines1) (List.rev !lines2);
      Buffer.contents buf1
  end

let dump_env env =
  prerr_endline (Mpl_raw.prettyprint (String.sub env.__bbuf 0 !(env.__blen)))

exception Bad_dns_label

module Mpl_dns_label =
  struct
    type t = int * string
    let unmarshal_labels = Hashtbl.create 1
    let marshal_labels = Hashtbl.create 1
    let marshal_base = ref 0
    let unmarshal_base = ref 0
    let init_unmarshal env =
      Hashtbl.clear unmarshal_labels; unmarshal_base := env.__bbase
    let init_marshal env =
      Hashtbl.clear marshal_labels; marshal_base := env.__bbase
    let of_string ?(comp = false) s : t =
      let sz = ref 0 in
      let incrsz am = sz := !sz + am in
      let rec fn =
        function
          bit :: r as x ->
            if comp && Hashtbl.mem marshal_labels (String.concat "." x) then
              incrsz 2
            else begin incrsz 1; incrsz (String.length bit); fn r end
        | [] -> incrsz 1
      in
      fn (Str.split (Str.regexp_string ".") s); !sz, s
    let to_string (_, s : t) = s
    let marshal ?(comp = false) env (psz, t : t) =
      let abspos env = env.__bbase + env.__bpos - !marshal_base in
      let start_pos = curpos env in
      let toreg = ref [] in
      let rec fn =
        function
          bit :: r as x ->
            let bit = String.lowercase bit in
            let tail = String.concat "." x in
            if comp && Hashtbl.mem marshal_labels tail then
              let off = Hashtbl.find marshal_labels tail in
              let off' = off land 0b11111111111111 in
              if off <> off' then raise Bad_dns_label;
              let b = 0b11 lsl 14 + off' in
              Mpl_uint16.__marshal env (Mpl_uint16.of_int b)
            else
              let len = String.length bit in
              toreg := (tail, abspos env) :: !toreg;
              Mpl_byte.__marshal env (Mpl_byte.of_int len);
              Mpl_raw.marshal env bit;
              fn r
        | [] -> Mpl_byte.__marshal env (Mpl_byte.of_char '\000')
      in
      fn (Str.split (Str.regexp_string ".") t);
      List.iter (fun (tail, pos) -> Hashtbl.replace marshal_labels tail pos)
        !toreg;
      let size = curpos env - start_pos in assert (psz = size); size, t
    let unmarshal env : t =
      let start_size = curpos env in
      let rec fn acc =
        let sz = Mpl_byte.to_int (Mpl_byte.unmarshal env) in
        let ty = sz lsr 6 in
        let cnt = sz land 0b111111 in
        match ty, cnt with
          0b00, 0 -> acc
        | 0b00, x ->
            let off = env.__bbase + env.__bpos - 1 - !unmarshal_base in
            let str = String.lowercase (Mpl_raw.at env (curpos env) cnt) in
            skip env cnt; fn (`Label (off, str) :: acc)
        | 0b11, x ->
            let off = x lsl 8 + Mpl_byte.to_int (Mpl_byte.unmarshal env) in
            let str =
              try Hashtbl.find unmarshal_labels off with
                Not_found -> raise Bad_dns_label
            in
            `Off str :: acc
        | _ -> raise Bad_dns_label
      in
      let res =
        List.fold_left
          (fun a ->
             function
               `Off str -> str
             | `Label (off, str) ->
                 let str = sprintf "%s.%s" str a in
                 Hashtbl.replace unmarshal_labels off str; str)
          "" (fn [])
      in
      let res = if res = "" then "." else res in
      let endsz = curpos env - start_size in endsz, res
    let size (sz, _ : t) = sz
    let prettyprint (t : string) = t
  end

(* String with a uint32 indicating its length, used in ssh *)
module Mpl_string32 =
  struct
    type t = string
    let size (s : t) = String.length s + 4
    let unmarshal env : t =
      let sz = Mpl_uint32.to_int (Mpl_uint32.unmarshal env) in
      let off = curpos env in skip env sz; Mpl_raw.at env off sz
    let to_string (t : t) = t
    let of_string s : t = s
    let marshal env (t : t) : t =
      Mpl_uint32.__marshal env (Mpl_uint32.of_int (String.length t));
      Mpl_raw.marshal env t;
      t
    let prettyprint t = sprintf "%S [%d]" t (String.length t)
  end

(* String with a byte indicating its length, used in dns *)
module Mpl_string8 =
  struct
    type t = string
    let size (s : t) = String.length s + 1
    let unmarshal env : t =
      let sz = Mpl_byte.to_int (Mpl_byte.unmarshal env) in
      let off = curpos env in skip env sz; Mpl_raw.at env off sz
    let to_string (t : t) = t
    let of_string s : t = s
    let marshal env (t : t) : t =
      Mpl_byte.__marshal env (Mpl_byte.of_int (String.length t));
      Mpl_raw.marshal env t;
      t
    let prettyprint t = sprintf "%S [%d]" t (String.length t)
  end

(* Single byte, can be 0 or 1, any non-zero is considered true but
   can never be generated *)
module Mpl_boolean =
  struct
    type t = char
    let unmarshal env : t =
      let x = Mpl_byte.to_char (Mpl_byte.unmarshal env) in
      if x = '\000' then '\000' else '\001'
    let to_bool (x : t) = x <> '\000'
    let of_bool x : t = if x then '\001' else '\000'
    let marshal env (x : t) : t = Mpl_byte.__marshal env x; x
    let prettyprint t = sprintf "%b" t
  end

(* SSH mpint definition, same wire form as string32 but with some
   restrictions on how zeros are padded *)
module Mpl_mpint =
  struct
    type t = string
    let size = Mpl_string32.size
    let unmarshal = Mpl_string32.unmarshal
    let marshal = Mpl_string32.marshal
    let to_string x = x
    let of_string s =
      let strip_leaders leader x =
        let len = String.length x in
        if len = 0 then x
        else
          let same = ref 0 in
          let cont = ref true in
          while !cont && !same < len do
            if String.get x !same != leader then cont := false else incr same
          done;
          String.sub x !same (len - !same)
      in
      let x = strip_leaders '\000' s in
      let msb = Char.code (String.get x 0) in
      if String.length x = 1 && msb = 0 then ""
      else
        let needpad = msb land 128 <> 0 in
        match needpad with
          false -> x
        | true -> let pad = String.make 1 '\000' in pad ^ x
    let list_of_bytes x =
      if x = "" then false, ['\000']
      else
        let msb = Char.code (String.get x 0) in
        let negative = msb land 128 <> 0 in
        let rec add n =
          function
            [] -> [n]
          | x :: xs ->
              if x + n > 255 then 255 :: add (255 - x - n) xs else x + n :: xs
        in
        let normalise_msb x =
          if List.length x = 0 then x
          else if List.hd x = Char.chr 0 then List.tl x
          else x
        in
        let rec explode s =
          if String.length s = 0 then []
          else
            String.get s 0 :: explode (String.sub s 1 (String.length s - 1))
        in
        match negative with
          false -> false, normalise_msb (explode x)
        | true ->
            let bytes = List.rev (List.map Char.code (explode x)) in
            let bytes' =
              List.rev (add 1 (List.map (fun x -> x lxor 255) bytes))
            in
            true, normalise_msb (List.map Char.chr bytes')
    let prettyprint x =
      let string_of_byte x =
        let nibble x =
          String.make 1
            (if x < 10 then Char.chr (Char.code '0' + x)
             else Char.chr (Char.code 'a' + x - 10))
        in
        let low = Char.code x mod 16
        and high = Char.code x / 16 in
        nibble high ^ nibble low
      in
      let (neg, x) = list_of_bytes x in
      (if neg then "-" else "") ^ String.concat "" (List.map string_of_byte x)
    let bytes x = let (_, x) = list_of_bytes x in List.length x
    let bits x = bytes x * 8
  end

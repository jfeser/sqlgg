(* Code generation *)

open Printf
open ExtList
open ExtString
open Operators
open Stmt

let (inc_indent,dec_indent,make_indent) = 
  let v = ref 0 in
  (fun () -> v := !v + 2),
  (fun () -> v := !v - 2),
  (fun () -> String.make !v ' ')

let print_indent () = print_string (make_indent ())
let indent s = print_indent (); print_string s
let indent_endline s = print_indent (); print_endline s
let empty_line () = print_newline ()
let output fmt = kprintf indent_endline fmt
let print fmt = kprintf print_endline fmt

let name_of attr index = 
  match attr.RA.name with
  | "" -> sprintf "_%u" index
  | s -> s

let param_name_to_string id index =
  match id with 
  | Next -> sprintf "_%u" index 
  | Numbered x -> sprintf "_%u" x
  | Named s -> s

let make_name props default = Option.default default (Props.get props "name")
let default_name str index = sprintf "%s_%u" str index

let choose_name props kind index =
  let name = match kind with
  | Create t -> sprintf "create_%s" t
  | Update t -> sprintf "update_%s_%u" t index
  | Insert t -> sprintf "insert_%s_%u" t index
  | Delete t -> sprintf "delete_%s_%u" t index
  | Select   -> sprintf "select_%u" index
  in
  make_name props name

module type Lang = sig
  val generate_code : int -> RA.Scheme.t -> Stmt.params -> Stmt.kind -> Props.t -> unit
  val start_output : unit -> unit
  val finish_output : unit -> unit
  val comment : ('a,unit,string,unit) format4 -> 'a
end

module Make(S : Lang) = struct

let generate_code index stmt =
  let ((scheme,params,kind),props) = stmt in
  let sql = Props.get props "sql" >> Option.default "" in
  S.comment "%s" sql;
  if not (RA.Scheme.is_unique scheme) then
    Error.log "Error: this SQL statement will produce rowset with duplicate column names:\n%s\n" sql
  else
  begin
    S.generate_code index scheme params kind props
  end

let process stmts = 
  S.start_output ();
  List.iteri generate_code stmts;
  S.finish_output ()

end

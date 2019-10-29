(** *)

open Printf
open ExtLib
open Prelude

module Type = struct
  type t = Int | Text | Blob | Float | Bool | Datetime | Any
  [@@deriving show { with_path = false }]

  let to_string = show

  let matches x y = match (x, y) with Any, _ | _, Any -> true | _ -> x = y

  let order x y =
    if x = y then `Equal
    else
      match (x, y) with
      | Any, t | t, Any -> `Order (t, Any)
      | Int, Float | Float, Int -> `Order (Int, Float)
      | Text, Blob | Blob, Text -> `Order (Text, Blob)
      | Int, Datetime | Datetime, Int -> `Order (Int, Datetime)
      | _ -> `No

  let common_type f x y =
    match order x y with
    | `Equal -> Some x
    | `Order p -> Some (f p)
    | `No -> None

  let common_supertype = common_type snd

  let common_subtype = common_type fst

  let common_type x y = Option.is_some @@ common_subtype x y

  type tyvar = Typ of t | Var of int

  let string_of_tyvar = function
    | Typ t -> to_string t
    | Var i -> sprintf "'%c" (Char.chr @@ (Char.code 'a' + i))

  type func =
    | Group of t (* _ -> t *)
    | Agg (* 'a -> 'a *)
    | Multi of tyvar * tyvar (* 'a -> ... -> 'a -> 'b *)
    | Ret of t (* _ -> t *)
    (* TODO eliminate *)
    | F of tyvar * tyvar list

  let monomorphic ret args = F (Typ ret, List.map (fun t -> Typ t) args)

  let fixed = monomorphic

  let pp_func pp =
    let open Format in
    function
    | Agg -> fprintf pp "|'a| -> 'a"
    | Group ret -> fprintf pp "|_| -> %s" (to_string ret)
    | Ret ret -> fprintf pp "_ -> %s" (to_string ret)
    | F (ret, args) ->
        fprintf pp "%s -> %s"
          (String.concat " -> " @@ List.map string_of_tyvar args)
          (string_of_tyvar ret)
    | Multi (ret, each_arg) ->
        fprintf pp "{ %s }+ -> %s" (string_of_tyvar each_arg)
          (string_of_tyvar ret)

  let string_of_func = Format.asprintf "%a" pp_func

  let is_grouping = function
    | Group _ | Agg -> true
    | Ret _ | F _ | Multi _ -> false
end

module Constraint = struct
  type conflict_algo = Ignore | Replace | Abort | Fail | Rollback
  [@@deriving show { with_path = false }, ord]

  type t =
    | PrimaryKey
    | NotNull
    | Null
    | Unique
    | Autoincrement
    | OnConflict of conflict_algo
  [@@deriving show { with_path = false }, ord]
end

module Constraints = struct
  include Set.Make (Constraint)

  let show s = [%derive.show: Constraint.t list] (elements s)

  let pp fmt s = Format.fprintf fmt "%s" (show s)
end

type attr = { name : string; domain : Type.t; extra : Constraints.t }
[@@deriving show { with_path = false }]

let make_attribute name domain extra = { name; domain; extra }

module Schema = struct
  type t = attr list [@@deriving show]

  exception Error of t * string

  (** FIXME attribute case sensitivity? *)
  let by_name name = function attr -> attr.name = name

  let find_by_name t name = List.find_all (by_name name) t

  let find t name =
    match find_by_name t name with
    | [ x ] -> x
    | [] -> raise (Error (t, "missing attribute : " ^ name))
    | _ -> raise (Error (t, "duplicate attribute : " ^ name))

  let make_unique =
    List.unique ~cmp:(fun a1 a2 -> a1.name = a2.name && a1.name <> "")

  let is_unique t = List.length (make_unique t) = List.length t

  let check_unique t = is_unique t || raise (Error (t, "duplicate attributes"))

  let project names t = List.map (find t) names

  let change_inplace t before after =
    List.map
      (fun attr ->
        match by_name before attr with true -> after | false -> attr)
      t

  let exists t name =
    match (find t name : attr) with _ -> true | exception _ -> false

  let rename t oldname newname =
    if not (exists t oldname) then
      raise @@ Error (t, "no such column : " ^ oldname);
    if exists t newname then
      raise @@ Error (t, "column already exists : " ^ newname);
    List.map
      (fun attr ->
        if attr.name = oldname then { attr with name = newname } else attr)
      t

  let cross t1 t2 = t1 @ t2

  (** [contains t attr] tests whether schema [t] contains attribute [attr] *)
  let contains t attr = find t attr.name = attr

  let check_contains t attr =
    if not (contains t attr) then
      raise (Error (t, "type mismatch for attribute " ^ attr.name))

  let sub l a = List.filter (fun x -> not (List.mem x a)) l

  let to_string v =
    v
    |> List.map (fun attr ->
           sprintf "%s %s" (Type.to_string attr.domain) attr.name)
    |> String.concat ", " |> sprintf "[%s]"

  let names t =
    t
    |> List.map (fun attr -> attr.name)
    |> String.concat "," |> sprintf "[%s]"

  let natural_ t1 t2 =
    let common, t1only = List.partition (fun x -> List.mem x t2) t1 in
    if 0 = List.length common then failwith "natural'";
    let t2only = sub t2 common in
    common @ t1only @ t2only

  let natural t1 t2 =
    try natural_ t1 t2
    with _ ->
      raise
        (Error
           ( t1,
             "no common attributes for natural join of " ^ names t1 ^ " and "
             ^ names t2 ))

  let join_using l t1 t2 =
    let common = List.map (find t1) l in
    List.iter (check_contains t2) common;
    common @ sub t1 common @ sub t2 common

  let check_types t1 t2 =
    List.iter2
      (fun a1 a2 ->
        match (a1.domain, a2.domain) with
        | Type.Any, _ | _, Type.Any -> ()
        | x, y when x = y -> ()
        | _ ->
            raise
              (Error
                 ( t1,
                   sprintf
                     "Atributes do not match : %s of type %s and %s of type %s"
                     a1.name (Type.to_string a1.domain) a2.name
                     (Type.to_string a2.domain) )))
      t1 t2

  let check_types t1 t2 =
    try check_types t1 t2
    with List.Different_list_size _ ->
      raise (Error (t1, to_string t1 ^ " differs in size to " ^ to_string t2))

  let compound t1 t2 =
    check_types t1 t2;
    t1

  let add t col pos =
    match find_by_name t col.name with
    | [] -> (
        match pos with
        | `First -> col :: t
        | `Default -> t @ [ col ]
        | `After name -> (
            try
              let i, _ = List.findi (fun _ attr -> by_name name attr) t in
              let l1, l2 = List.split_nth (i + 1) t in
              l1 @ (col :: l2)
            with Not_found ->
              raise
                (Error
                   ( t,
                     "Can't insert column " ^ col.name
                     ^ " after non-existing column " ^ name )) ) )
    | _ -> raise (Error (t, "Already has column " ^ col.name))

  let drop t col =
    ignore (find t col);
    List.remove_if (by_name col) t

  let change t oldcol col pos =
    match pos with
    | `Default -> change_inplace t oldcol col
    | `First | `After _ -> add (drop t oldcol) col pos

  let to_string = show

  let print x = prerr_endline (to_string x)
end

module Op = struct
  open Base

  type num_op = [ `Add | `Sub | `Mul | `Div | `Mod ] [@@deriving sexp]

  type bool_op = [ `And | `Or | `Not ] [@@deriving sexp]

  type cmp_op = [ `Eq | `Neq | `Ge | `Le | `Gt | `Lt ] [@@deriving sexp]

  type bit_op = [ `Bit_and | `Bit_not | `Bit_or | `Lsh | `Rsh ]
  [@@deriving sexp]

  type agg_op = [ `Count | `Avg | `Sum | `Min | `Max ] [@@deriving sexp]

  type binop =
    [ `Add
    | `And
    | `Div
    | `Eq
    | `Ge
    | `Gt
    | `Le
    | `Lt
    | `Mod
    | `Mul
    | `Or
    | `Sub ]
  [@@deriving sexp]

  type unop = [ `IsNull | `Not ] [@@deriving sexp]

  type op =
    [ num_op
    | bool_op
    | cmp_op
    | bit_op
    | agg_op
    | `Between
    | `Call of string
    | `Concat
    | `In
    | `Interval of unit
    | `Is
    | `IsDistinct
    | `IsNull
    | `Ite
    | `Like
    | `NotDistinct
    | `Substring ]
  [@@deriving sexp]
end

include Op

type table = string * Schema.t [@@deriving show]

type schema = Schema.t

let print_table out (name, schema) =
  IO.write_line out name;
  schema
  |> List.iter (fun { name; domain; extra } ->
         IO.printf out "%10s %s %s\n" (Type.to_string domain) name
           (Constraints.show extra));
  IO.write_line out ""

type param_id = string option * (int * int) [@@deriving show]
(** optional name and start/end position in string *)

type param = param_id * Type.t [@@deriving show]

type params = param list [@@deriving show]

type ctor =
  | Simple of param_id * var list option
  | Verbatim of string * string

and var = Single of param | Choice of param_id * ctor list [@@deriving show]

type vars = var list [@@deriving show]

type alter_pos = [ `After of string | `Default | `First ]

type alter_action =
  [ `Add of attr * alter_pos
  | `RenameTable of string
  | `RenameColumn of string * string
  | `RenameIndex of string * string
  | `Drop of string
  | `Change of string * attr * alter_pos
  | `None ]

type select_result = schema * param list

type direction = [ `Asc | `Desc ] [@@deriving show]

type int_or_param = [ `Const of int | `Limit of param ]

type limit_t = [ `Limit | `Offset ]

type col_name = {
  cname : string;  (** column name *)
  tname : string option;  (** table name *)
}

and limit = param list * bool

and 'f nested = 'f source * ('f source * 'f join_cond) list
  constraint 'f = [< op ]

and 'f source1 =
  [ `Select of 'f select_full | `Table of string | `Nested of 'f nested ]
  constraint 'f = [< op ]

and 'f source = 'f source1 * string option constraint 'f = [< op ]

and 'f join_cond =
  [ `Cross | `Search of 'f expr | `Default | `Natural | `Using of string list ]
  constraint 'f = [< op ]

and 'f select = {
  columns : 'f column list;
  from : 'f nested option;
  where : 'f expr option;
  group : 'f expr list;
  having : 'f expr option;
}
  constraint 'f = [< op ]

and 'f select_full = {
  select : 'f select * 'f select list;
  order : 'f order;
  limit : limit option;
}
  constraint 'f = [< op ]

and 'f order = ('f expr * direction option) list constraint 'f = [< op ]

and 'expr choices = (param_id * 'expr option) list

and value =
  | Int of int
  | Date of string
  | String of string
  | Bool of bool
  | Float of float
  | Null

and 'f expr =
  | Value of value  (** literal value *)
  | Sequence of 'f expr list
  | Param of param
  | Choices of param_id * 'f expr choices
  | Fun of 'f * 'f expr list  (** parameters *)
  | Select of 'f select_full * [ `AsValue | `Exists ]
  | Column of col_name
  | Inserted of string  (** inserted value *)
  constraint 'f = [< op ]

and 'f column =
  | All
  | AllOf of string
  | Expr of 'f expr * string option  (** name *)
  constraint 'f = [< op ]
[@@deriving show { with_path = false }]

type 'f columns = 'f column list [@@deriving show]

type 'f expr_q =
  [ `Value of Type.t  (** literal value *)
  | `Param of param
  | `Choice of param_id * 'f expr_q choices
  | `Func of Type.func * 'f expr_q list
    (** return type, grouping, parameters *) ]
[@@deriving show]

let expr_to_string = show_expr

type 'f assignments = (col_name * 'f expr) list

type 'f insert_action = {
  target : string;
  action :
    [ `Set of 'f assignments option
    | `Values of string list option * 'f expr list list option
    | (* column names * list of value tuples *)
      `Select of
      string list option * 'f select_full ];
  on_duplicate : 'f assignments option;
}

type 'f stmt =
  | Create of string * [ `Schema of schema | `Select of 'f select_full ]
  | Drop of string
  | Alter of string * alter_action list
  | Rename of (string * string) list
  | CreateIndex of string * string * string list (* index name, table name, columns *)
  | Insert of 'f insert_action
  | Delete of string * 'f expr option
  | Set of string * 'f expr
  | Update of string * 'f assignments * 'f expr option * 'f order * param list (* where, order, limit *)
  | UpdateMulti of 'f source list * 'f assignments * 'f expr option
  | Select of 'f select_full
  | CreateRoutine of
      string * Type.t option * (string * Type.t * 'f expr option) list

(*
open Schema

let test = [{name="a";domain=Type.Int}; {name="b";domain=Type.Int}; {name="c";domain=Type.Text};];;

let () = print test
let () = print (project ["b";"c";"b"] test)
let () = print (project ["b";"d"] test)
let () = print (rename test "a" "new_a")
*)

module Function : sig
  val lookup : string -> int -> Type.func

  val add : int -> Type.func -> string -> unit

  val exclude : int -> string -> unit

  val monomorphic : Type.t -> Type.t list -> string -> unit

  val multi : ret:Type.tyvar -> Type.tyvar -> string -> unit

  val multi_polymorphic : string -> unit
end = struct
  let h = Hashtbl.create 10

  let add_ narg typ name =
    let name = String.lowercase name in
    if Hashtbl.mem h (name, narg) then
      let func =
        match narg with
        | None -> sprintf "%S" name
        | Some n -> sprintf "%S of %d arguments" name n
      in
      fail "Function %s already registered" func
    else Hashtbl.add h (name, narg) typ

  let exclude narg name = add_ (Some narg) None name

  let add_multi typ name = add_ None (Some typ) name

  let add narg typ name = add_ (Some narg) (Some typ) name

  let lookup name narg =
    let name = String.lowercase name in
    match Hashtbl.find h (name, Some narg) with
    | None -> fail "Wrong number of arguments for function %S" name
    | Some t -> t
    | exception _ -> (
        match Hashtbl.find h (name, None) with
        | None -> assert false
        | Some t -> t
        | exception _ -> fail "Unknown function %S of %d arguments" name narg )

  let monomorphic ret args name =
    add (List.length args) Type.(monomorphic ret args) name

  let multi_polymorphic name = add_multi Type.(Multi (Var 0, Var 0)) name

  let multi ~ret args name = add_multi Type.(Multi (ret, args)) name
end

let () =
  let open Type in
  let open Function in
  let ( ||> ) x f = List.iter f x in
  "count" |> add 0 (Group Int);

  (* count( * ) - asterisk is treated as no parameters in parser *)
  "count" |> add 1 (Group Int);
  "avg" |> add 1 (Group Float);
  [ "max"; "min"; "sum" ] ||> add 1 Agg;
  [ "max"; "min" ] ||> multi_polymorphic;

  (* sqlite3 *)
  [ "lower"; "upper" ] ||> monomorphic Text [ Text ];
  "length" |> monomorphic Int [ Text ];
  [ "random" ] ||> monomorphic Int [];
  [ "nullif"; "ifnull" ] ||> add 2 (F (Var 0, [ Var 0; Var 0 ]));
  [ "least"; "greatest"; "coalesce" ] ||> multi_polymorphic;
  "strftime" |> exclude 1;

  (* requires at least 2 arguments *)
  [ "concat"; "date"; "time"; "strftime" ] ||> multi ~ret:(Typ Text) (Typ Text);
  "julianday" |> multi ~ret:(Typ Float) (Typ Text);
  "from_unixtime" |> monomorphic Datetime [ Int ];
  "from_unixtime" |> monomorphic Text [ Int; Text ];
  "unix_timestamp" |> monomorphic Int [];
  "unix_timestamp" |> monomorphic Int [ Datetime ];
  "any_value" |> add 1 (F (Var 0, [ Var 0 ]));

  (* 'a -> 'a but not aggregate *)
  "substring" |> monomorphic Text [ Text; Int ];
  "substring" |> monomorphic Text [ Text; Int; Int ];
  "substring_index" |> monomorphic Text [ Text; Text; Int ];
  "last_insert_id" |> monomorphic Int [];
  "last_insert_id" |> monomorphic Int [ Int ];
  ()

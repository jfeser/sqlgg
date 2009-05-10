(** command-line *)

open Printf

let work = function
  | "-" -> Main.parse_sql (Std.input_all stdin)
  | filename -> Main.with_file filename Main.parse_sql

let usage_msg =
  let s1 = sprintf "SQL Guided (code) Generator ver. %s\n" Config.version in
  let s2 = sprintf "Usage: %s <options> <file.sql>\n" (Filename.basename Sys.executable_name) in
  let s3 = "Options are:" in
  s1 ^ s2 ^ s3

let show_version () = print_endline Config.version

let main () =
  let args = 
  [
    "-version", Arg.Unit show_version, " Show version";
    "-test", Arg.Unit Test.run, " Run unit tests";
  ]
  in
  Arg.parse (Arg.align args) work usage_msg

let _ = Printexc.print main ()

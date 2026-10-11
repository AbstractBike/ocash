(** Conversión de Unix.process_status a código de salida estilo bash. *)

(* OCaml representa las señales con constantes negativas propias; las
   traducimos a los números POSIX, que coinciden en Linux y macOS. *)
let signal_numbers = [
  Sys.sighup, 1; Sys.sigint, 2; Sys.sigquit, 3; Sys.sigill, 4;
  Sys.sigabrt, 6; Sys.sigfpe, 8; Sys.sigkill, 9; Sys.sigsegv, 11;
  Sys.sigpipe, 13; Sys.sigalrm, 14; Sys.sigterm, 15;
]

let signal_number s =
  match List.assoc_opt s signal_numbers with
  | Some n -> n
  | None -> if s > 0 then s else 0

(* 128 + número de señal, como bash: Ctrl-C → 130, kill -9 → 137. *)
let of_status = function
  | Unix.WEXITED n   -> n
  | Unix.WSIGNALED s -> 128 + signal_number s
  | Unix.WSTOPPED _  -> 128

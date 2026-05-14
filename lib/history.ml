(** Historial persistente de ocash con búsqueda fuzzy estilo fish.

    Almacenamiento: ~/.ocash/history (texto plano, una línea por comando,
    append-only). Se carga en memoria al arranque y se persiste cada
    nueva entrada. *)

let history_file () =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  Filename.concat home ".ocash/history"

let max_in_memory = 5000

(* En memoria: orden cronológico (más antiguo primero, más reciente último) *)
let entries : string list ref = ref []

let ensure_dir path =
  let d = Filename.dirname path in
  if not (Sys.file_exists d) then
    let rec mkdir_p p =
      if p = "/" || Sys.file_exists p then ()
      else begin
        mkdir_p (Filename.dirname p);
        try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      end
    in mkdir_p d

let load () =
  let path = history_file () in
  if not (Sys.file_exists path) then entries := []
  else begin
    let ic = open_in path in
    let acc = ref [] in
    (try
      while true do
        let line = input_line ic in
        if String.trim line <> "" then acc := line :: !acc
      done
    with End_of_file -> ());
    close_in ic;
    let lst = List.rev !acc in
    let n = List.length lst in
    entries := if n > max_in_memory
               then List.filteri (fun i _ -> i >= n - max_in_memory) lst
               else lst
  end

let add line =
  let line = String.trim line in
  if line = "" then ()
  else begin
    (* Evita duplicado consecutivo *)
    let dup = match List.rev !entries with
      | last :: _ when last = line -> true
      | _ -> false
    in
    if not dup then begin
      entries := !entries @ [line];
      if List.length !entries > max_in_memory then
        entries := List.tl !entries;
      (* Persist append *)
      let path = history_file () in
      ensure_dir path;
      let oc = open_out_gen [Open_wronly; Open_append; Open_creat] 0o644 path in
      output_string oc (line ^ "\n");
      close_out oc
    end
  end

let all () = !entries

let last_n n =
  let len = List.length !entries in
  if len <= n then !entries
  else List.filteri (fun i _ -> i >= len - n) !entries

(* Encuentra la entrada más reciente que comienza con el prefix dado.
   Usado para autosugerencia fish-style. *)
let find_prefix prefix =
  if prefix = "" then None
  else
    let rec loop = function
      | [] -> None
      | h :: tl ->
          if String.starts_with ~prefix h && h <> prefix
          then Some h
          else loop tl
    in
    loop (List.rev !entries)

(* Score fuzzy: cuenta cuántos chars del query aparecen en orden en target.
   Devuelve score >= 0; mayor = mejor match. -1 si no match. *)
let fuzzy_score query target =
  let q = String.lowercase_ascii query in
  let t = String.lowercase_ascii target in
  let ql = String.length q in
  let tl = String.length t in
  if ql = 0 then 0
  else if ql > tl then -1
  else begin
    let qi = ref 0 in
    let consecutive = ref 0 in
    let max_consec = ref 0 in
    let score = ref 0 in
    let ti = ref 0 in
    while !qi < ql && !ti < tl do
      if q.[!qi] = t.[!ti] then begin
        incr qi;
        incr consecutive;
        score := !score + 1 + !consecutive;
        if !consecutive > !max_consec then max_consec := !consecutive
      end else begin
        consecutive := 0
      end;
      incr ti
    done;
    if !qi < ql then -1
    else
      (* Bonus si el prefix del target hizo match al inicio *)
      let prefix_bonus = if String.length t >= ql && String.sub t 0 ql = q then 10 else 0 in
      !score + !max_consec + prefix_bonus
  end

(* Devuelve hasta N matches ordenados por score descendente. *)
let fuzzy_search ?(limit=20) query =
  let scored = List.filter_map (fun e ->
    let s = fuzzy_score query e in
    if s >= 0 then Some (s, e) else None
  ) (List.rev !entries) in
  let sorted = List.sort (fun (a, _) (b, _) -> compare b a) scored in
  let rec take n lst =
    if n <= 0 then []
    else match lst with
      | [] -> []
      | (_, e) :: tl -> e :: take (n - 1) tl
  in
  take limit sorted
  |> List.sort_uniq String.compare

(** Auto-start de llama-server si:
    - OCASH_LLAMA_AUTOSTART=1
    - llama-server está en PATH
    - existe un modelo (default: ~/.local/share/ocash/model.gguf o models/model.gguf)
    - el endpoint OCASH_AI_URL no responde ya

    Lanza el proceso en background, espera hasta que /health responda OK,
    y registra at_exit para hacer kill al salir. *)

open Lwt.Syntax

let cli_available bin =
  let path = try Sys.getenv "PATH" with Not_found -> "/usr/bin:/bin" in
  String.split_on_char ':' path
  |> List.exists (fun dir -> Sys.file_exists (Filename.concat dir bin))

let find_model () =
  let home = try Sys.getenv "HOME" with Not_found -> "" in
  let candidates = [
    Sys.getenv_opt "OCASH_MODEL_PATH";
    Some (Filename.concat home ".local/share/ocash/model.gguf");
    Some "models/model.gguf";
    Some "model.gguf";
  ] in
  List.find_map (fun c ->
    match c with
    | Some p when Sys.file_exists p -> Some p
    | _ -> None) candidates

let llama_pid = ref None

let kill_on_exit () =
  match !llama_pid with
  | Some pid ->
      (try Unix.kill pid Sys.sigterm with _ -> ())
  | None -> ()

(* Lanza llama-server detached y devuelve true si arrancó. *)
let start_if_needed ~url =
  let enabled = match Sys.getenv_opt "OCASH_LLAMA_AUTOSTART" with
    | Some ("1" | "true" | "on" | "yes") -> true
    | _ -> false
  in
  if not enabled then Lwt.return false
  else if not (cli_available "llama-server") then begin
    Printf.eprintf "ocash: OCASH_LLAMA_AUTOSTART=1 pero llama-server no está en PATH\n%!";
    Lwt.return false
  end
  else match find_model () with
    | None ->
        Printf.eprintf "ocash: OCASH_LLAMA_AUTOSTART=1 pero no encuentro model.gguf\n%!";
        Lwt.return false
    | Some model ->
        (* Comprueba si ya hay algo respondiendo en url *)
        let* already =
          Lwt.catch (fun () ->
            let uri = Uri.of_string (url ^ "/health") in
            let* (resp, _) = Cohttp_lwt_unix.Client.get uri in
            Lwt.return (Cohttp.Response.status resp = `OK))
           (fun _ -> Lwt.return false)
        in
        if already then Lwt.return true
        else begin
          let port =
            match Uri.port (Uri.of_string url) with
            | Some p -> string_of_int p
            | None -> "8080"
          in
          let ctx = try Sys.getenv "OCASH_LLAMA_CTX" with Not_found -> "4096" in
          let ngl = try Sys.getenv "OCASH_LLAMA_NGL" with Not_found -> "99" in
          let logfile =
            Filename.concat (try Sys.getenv "HOME" with Not_found -> "/tmp")
              ".ocash/llama.log"
          in
          (try
            let dir = Filename.dirname logfile in
            if not (Sys.file_exists dir) then Unix.mkdir dir 0o755
          with _ -> ());
          let log_fd = Unix.openfile logfile
            [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
          let args = [|
            "llama-server"; "-m"; model;
            "--port"; port; "--ctx-size"; ctx; "-ngl"; ngl
          |] in
          Printf.printf "→ arrancando llama-server: %s\n%!"
            (String.concat " " (Array.to_list args));
          let pid = Unix.create_process "llama-server" args
            Unix.stdin log_fd log_fd in
          Unix.close log_fd;
          llama_pid := Some pid;
          at_exit kill_on_exit;
          (* Espera hasta OCASH_LLAMA_TIMEOUT s (default 90) a que /health responda.
             Modelos grandes en CPU pueden tardar más de 30s en cargar. *)
          let timeout = try int_of_string (Sys.getenv "OCASH_LLAMA_TIMEOUT")
                        with _ -> 90 in
          let rec wait_ready n =
            if n <= 0 then Lwt.return false
            else
              let* ok = Lwt.catch (fun () ->
                let uri = Uri.of_string (url ^ "/health") in
                let* (resp, _) = Cohttp_lwt_unix.Client.get uri in
                Lwt.return (Cohttp.Response.status resp = `OK))
                (fun _ -> Lwt.return false)
              in
              if ok then Lwt.return true
              else
                let* () = Lwt_unix.sleep 1.0 in
                wait_ready (n - 1)
          in
          let* ready = wait_ready timeout in
          if not ready then
            Printf.eprintf
              "ocash: llama-server no respondió en %ds, ver %s\n  Sube el timeout con OCASH_LLAMA_TIMEOUT=N\n%!"
              timeout logfile;
          Lwt.return ready
        end

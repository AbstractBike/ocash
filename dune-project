(lang dune 3.12)
(name ocash)

; Profile dedicado a producir un fatbin estático.
; Uso: dune build --profile static
(env
 (static
  (flags (:standard))
  (ocamlopt_flags (:standard -O3 -unboxed-types))))

(lang dune 3.16)
(name orchestraml)
(generate_opam_files false)

(package
 (name orchestraml)
 (synopsis "A distributed job orchestration platform in OCaml")
 (depends
  (ocaml (>= 5.2))
  (dune (>= 3.16))
  uuidm
  ptime
  (alcotest :with-test)
  (qcheck :with-test)
  (qcheck-alcotest :with-test)))

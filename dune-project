(lang dune 3.0)
(name skip-lite)
(version 0.1.0)

(generate_opam_files true)

(license MIT)
(authors "ReScript Team")
(maintainers "rescript-lang")
(source (github rescript-lang/skip-lite))
(homepage "https://github.com/rescript-lang/skip-lite")
(bug_reports "https://github.com/rescript-lang/skip-lite/issues")

(package
 (name skip-lite)
 (synopsis "Portable OCaml runtime utilities from skip-ocaml")
 (description
  "Lightweight, stock-toolchain-compatible OCaml library derived from skip-ocaml. Provides memory-mapped file caching and other performance utilities that work with standard compilers on macOS and Linux.")
 (depends
  (ocaml (>= 5.0))
  (dune (>= 3.0))))


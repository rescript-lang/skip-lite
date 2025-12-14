# skip-lite

Portable OCaml runtime utilities from [skip-ocaml](https://github.com/rescript-lang/skip-ocaml) — works with stock toolchains on macOS and Linux.

## Overview

skip-lite provides high-performance utilities that work with standard OCaml toolchains (no special linker scripts, no objcopy, no fixed-address loading). It's designed for build tools and language servers that need efficient file caching.

## Modules

### Marshal_cache

Memory-mapped cache for marshalled OCaml files with automatic invalidation.

```ocaml
(* Read a marshalled file with automatic caching *)
Marshal_cache.with_unmarshalled_file "/path/to/file.marshal"
  (fun (data : my_type) ->
    (* Process data - mmap stays valid during callback *)
    process data
  )
```

**Features:**
- Zero-copy unmarshalling (OCaml 5+ `caml_input_value_from_block`)
- Automatic cache invalidation (mtime + size + inode)
- LRU eviction with configurable limits
- Off-heap storage (not scanned by GC)
- Thread-safe (mutex released during callbacks)

## Installation

```bash
opam pin add skip-lite https://github.com/rescript-lang/skip-lite.git
```

Or add to your dune-project:

```
(depends
 (skip-lite (>= 0.1)))
```

## Platform Support

| Platform | Status |
|----------|--------|
| macOS 10.13+ | ✅ Fully supported |
| Linux (glibc) | ✅ Fully supported |
| Linux (musl) | ⚠️ Should work (untested) |
| FreeBSD/OpenBSD | ⚠️ Should work (untested) |
| Windows | ❌ Not supported |

## Requirements

- OCaml 5.0+
- dune 3.0+
- C++17 compiler (clang or gcc)

## Building

```bash
dune build
dune runtest
```

## License

MIT License - see [LICENSE](LICENSE) file.

## Related

- [skip-ocaml](https://github.com/rescript-lang/skip-ocaml) - Full skip runtime (requires special toolchain setup)


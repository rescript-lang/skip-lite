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

(* Reactive/incremental: only process if file changed *)
match Marshal_cache.with_unmarshalled_if_changed path process with
| Some result -> (* file changed, got new result *)
| None -> (* file unchanged, use cached result *)
```

**Features:**
- Zero-copy unmarshalling (OCaml 5+ `caml_input_value_from_block`)
- Automatic cache invalidation (mtime + size + inode)
- LRU eviction with configurable limits
- Off-heap storage (not scanned by GC)
- Thread-safe (mutex released during callbacks)
- Reactive API for incremental systems (22-32x speedup)

### Reactive_file_collection

A reactive collection that maps file paths to processed values with delta-based updates. Designed for use with file watchers.

```ocaml
(* Create collection with processing function *)
let coll = Reactive_file_collection.create
  ~process:(fun (data : cmt_infos) -> extract_types data)

(* Initial load *)
List.iter (Reactive_file_collection.add coll) (glob "*.cmt")

(* On file watcher events *)
match event with
| Created path -> Reactive_file_collection.add coll path
| Deleted path -> Reactive_file_collection.remove coll path
| Modified path -> Reactive_file_collection.update coll path

(* Or batch updates *)
Reactive_file_collection.apply coll [Added "new.cmt"; Modified "changed.cmt"]

(* Iterate over all values *)
Reactive_file_collection.iter (fun path value -> ...) coll
```

**Features:**
- Delta-based API (add/remove/update) - no full rescans
- Batch event application
- Backed by Marshal_cache for efficient file access
- ~1000x speedup vs reading all files on each change

## Installation

```bash
opam pin add skip-lite https://github.com/rescript-lang/skip-lite.git
```

Or add to your dune-project:

```
(depends
 (skip-lite (>= 0.1)))
```

## Benchmark Results

With 10,000 files × 20KB each (195MB total), 10 files changing:

| Approach | Time per update | Speedup |
|----------|-----------------|---------|
| `Marshal.from_channel` (baseline) | 692 ms | 1x |
| `with_unmarshalled_file` (cache) | 512 ms | 1.4x |
| `with_unmarshalled_if_changed` | 22 ms | 32x |
| Known-changed only (file watcher) | 0.73 ms | **948x** |

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

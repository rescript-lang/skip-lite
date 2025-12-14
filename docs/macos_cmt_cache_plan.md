# Marshal Cache — Design Document

## Overview

A memory-mapped cache for marshalled OCaml files with automatic invalidation, plus a reactive collection abstraction for incremental systems.

**Target**: OCaml 5.0+, macOS and Linux, stock toolchains.

## Goal

- Load files containing exactly one OCaml `Marshal` payload
- Keep contents **off-heap** via `mmap` (not scanned by GC)
- Automatically refresh when files change on disk
- Process once per access via callback API (values not retained)
- Support reactive/incremental systems with delta-based updates

## API

### Marshal_cache

```ocaml
module Marshal_cache : sig
  exception Cache_error of string * string

  type stats = { entry_count : int; mapped_bytes : int }

  val with_unmarshalled_file : string -> ('a -> 'r) -> 'r
  (** Always unmarshals and calls callback. *)

  val with_unmarshalled_if_changed : string -> ('a -> 'r) -> 'r option
  (** Returns Some(result) if file changed, None if unchanged.
      Key primitive for reactive systems - avoids unmarshal if unchanged. *)

  val clear : unit -> unit
  val invalidate : string -> unit
  val set_max_entries : int -> unit  (** Default: 10000 *)
  val set_max_bytes : int -> unit    (** Default: 1GB *)
  val stats : unit -> stats
end
```

### Reactive_file_collection

```ocaml
module Reactive_file_collection : sig
  type 'v t
  type event = Added of string | Removed of string | Modified of string

  val create : process:('a -> 'v) -> 'v t
  val add : 'v t -> string -> unit
  val remove : 'v t -> string -> unit
  val update : 'v t -> string -> unit
  val apply : 'v t -> event list -> unit

  val get : 'v t -> string -> 'v option
  val iter : (string -> 'v -> unit) -> 'v t -> unit
  val fold : (string -> 'v -> 'acc -> 'acc) -> 'v t -> 'acc -> 'acc
end
```

## Implementation

### File Identity

Cache invalidation uses `(mtime_sec, mtime_nsec, size, inode)`:

```cpp
struct FileId {
  time_t mtime_sec;
  long mtime_nsec;
  off_t size;
  ino_t ino;
};
```

### Cache Structure

```cpp
class MarshalCache {
  std::unordered_map<std::string, Entry> cache_;
  std::list<std::string> lru_order_;
  std::mutex mutex_;
  size_t max_entries_ = 10000;
  size_t max_bytes_ = 1ULL << 30;
};
```

### Access Pattern

1. `acquire_mapping(path)`: Lock, stat, refresh if needed, return `changed` flag
2. Unmarshal via `caml_input_value_from_block` (zero-copy)
3. Call callback (mutex released)
4. `release_mapping(path)`: Cleanup

### Eviction

Only evict when adding NEW entries, not when updating existing ones. This prevents iterator invalidation bugs when cache is at capacity.

## Benchmark Results

10,000 files × 20KB (195MB), 10 files changing per iteration:

| Approach | Time | Speedup |
|----------|------|---------|
| `Marshal.from_channel` | 692 ms | 1x |
| `with_unmarshalled_file` | 512 ms | 1.4x |
| `with_unmarshalled_if_changed` | 22 ms | 32x |
| Known-changed only | 0.73 ms | **948x** |

## Platform Support

| Platform | Status |
|----------|--------|
| macOS 10.13+ | ✅ Supported |
| Linux (glibc) | ✅ Supported |
| FreeBSD/OpenBSD | ⚠️ Should work |
| Windows | ❌ Not supported |

## Testing

32 tests total:
- Marshal_cache: 22 tests (basic ops, modification detection, LRU, concurrent domains, fd leaks)
- Reactive_file_collection: 10 tests (CRUD, batch events, iteration, error handling)

# Marshal Cache — Design Document

## Overview

A memory-mapped cache for marshalled OCaml files with automatic invalidation.

**Target**: OCaml 5.0+, macOS and Linux, stock toolchains.

## Goal

- Load files containing exactly one OCaml `Marshal` payload
- Keep contents **off-heap** via `mmap` (not scanned by GC)
- Automatically refresh when files change on disk
- Process once per access via callback API (values not retained)

## API

```ocaml
module Marshal_cache : sig
  exception Cache_error of string * string
  (** (path, error_message) *)

  type stats = { entry_count : int; mapped_bytes : int }

  val with_unmarshalled_file : string -> ('a -> 'r) -> 'r
  (** [with_unmarshalled_file path f] calls [f] with the unmarshalled value.
      @raise Cache_error on file/mapping/unmarshal errors.
      @alert unsafe Caller must ensure the file contains data of type ['a]. *)

  val clear : unit -> unit
  val invalidate : string -> unit
  val set_max_entries : int -> unit  (** Default: 10000 *)
  val set_max_bytes : int -> unit    (** Default: 1GB *)
  val stats : unit -> stats
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

Platform-specific mtime access:
```cpp
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
  #define MTIME_SEC(st)  ((st).st_mtimespec.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtimespec.tv_nsec)
#else
  #define MTIME_SEC(st)  ((st).st_mtim.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtim.tv_nsec)
#endif
```

### Cache Structure

```cpp
struct Entry {
  std::string path;
  Mapping current;
  size_t in_use;                      // Active callback count
  std::vector<Mapping> old_mappings;  // Deferred unmaps
  std::list<std::string>::iterator lru_iter;
};

class MarshalCache {
  std::unordered_map<std::string, Entry> cache_;
  std::list<std::string> lru_order_;
  std::mutex mutex_;
  size_t max_entries_ = 10000;
  size_t max_bytes_ = 1ULL << 30;
  size_t current_bytes_ = 0;
};
```

### Access Pattern

1. `acquire_mapping(path)`: Lock mutex, stat file, refresh if needed, increment `in_use`, **release mutex**
2. Unmarshal via `caml_input_value_from_block` (zero-copy)
3. Call OCaml callback (mutex not held)
4. `release_mapping(path)`: Lock mutex, decrement `in_use`, cleanup `old_mappings` if `in_use == 0`

### Unmarshalling

Zero-copy using OCaml 5+ API:
```cpp
result = caml_input_value_from_block(ptr, len);
```

Validates marshal magic (0x8495A6BE or 0x8495A6BF) before unmarshalling.

### Empty Files

Empty files use sentinel pointer `(void*)1` and raise `Failure("marshal_cache: empty file")`.

### Error Handling

C++ exceptions convert to `Failure("path: message")`, then OCaml wrapper converts to `Cache_error(path, message)`.

## Platform Support

| Platform | Status |
|----------|--------|
| macOS 10.13+ | ✅ Supported |
| Linux (glibc) | ✅ Supported |
| FreeBSD/OpenBSD | ⚠️ Should work |
| Windows | ❌ Not supported |

## Known Limitations

1. **TOCTOU window**: File can change between `stat()` and `mmap()`. Benign (causes extra refresh, not stale data).
2. **Large files**: Files exceeding virtual address space will fail.
3. **Filesystem mtime precision**: Some filesystems only have second precision; inode check mitigates.

## Testing

16 tests covering:
- Basic/cached reads
- File modification detection
- Nested calls
- Exception propagation
- LRU eviction
- Empty/missing files
- Stats and clear/invalidate
- Invalid arguments

## Future Work

- Concurrent domain stress tests
- Performance benchmarks vs `Marshal.from_channel`
- Optional debug/tracing mode

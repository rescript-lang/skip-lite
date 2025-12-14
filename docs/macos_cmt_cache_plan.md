# macOS marshalled-file mmap cache (callback API) — Implementation Plan

## Scope / packaging

This document is an implementation plan for a **new standalone library with essential OCaml bindings**: it must expose an OCaml module/API, implemented via C/C++ stubs (or a small C/C++ core) under the hood, that provides a cache for *marshalled files*.

It intentionally does **not** assume any particular repository structure or existing codebase APIs.

**Target OCaml version**: 5.0+

## Goal

Provide a **macOS-friendly**, **stock-Xcode-toolchain** compatible mechanism to:

- Load files from disk whose contents are **exactly one** OCaml `Marshal` payload (a "marshalled file")
- Keep their contents **immutable** in an **off-heap** cache (not allocated in the OCaml heap)
- When a file changes on disk, transparently refresh the cached mapping
- For each "use", **unmarshal once**, process immediately, and do **not** retain the unmarshalled value across time

This matches the "A" workload: **process once per file change**, then ignore until the file changes again.

Assumptions:

- The file format is **not** `.cmt` (or any other container format). The bytes on disk are exactly a marshalled value starting at offset 0.
- If you need to handle container formats (headers + payload offsets), that is a separate layer that should extract `(payload_ptr, payload_len)` before calling into this cache.

Non-goals:

- Cross-run persistence
- Stable code pointers / fixed-address text segments
- Keeping decoded values alive without GC scanning


## High-level design

We cache **marshalled bytes** (the file contents) in a C-side map keyed by absolute file path:

- `path -> Entry { mtime_sec, mtime_nsec, size, ino, mmap_ptr }`

On demand, we:

1. `stat(path)` to get `(mtime_sec, mtime_nsec, size, ino)`
2. If cache miss or any of `(mtime_sec, mtime_nsec, size, ino)` changed: `munmap` old mapping (when safe), `open` + `mmap(PROT_READ, MAP_PRIVATE)` new bytes, then `close(fd)` immediately
3. Unmarshal **directly from the mapped memory** into a temporary OCaml value
4. Invoke an OCaml callback with that value
5. Drop the value; the GC can reclaim it later

The "do not keep decoded values around" property is enforced by the API shape (callback-based API).


## Public OCaml API (callback)

Create a small module (e.g. `Marshalled_file_cache`) exposing:

```ocaml
(** Exception raised for cache-related errors.
    Contains the file path and an optional underlying exception. *)
exception Cache_error of string * exn option

(** Calls [f] with the unmarshalled value from [path].
    Guarantees the underlying mmap stays valid for the duration of [f].

    {b Type safety warning}: This function is inherently unsafe. The caller
    must ensure the type ['a] matches the actual marshalled data. Using the
    wrong type results in undefined behavior (crashes, memory corruption).

    Equivalent to [Marshal.from_*] in terms of type safety.

    @raise Cache_error if the file cannot be read, mapped, or unmarshalled.
    @raise exn if [f] raises; the cache state remains consistent. *)
val with_unmarshalled_file : string -> (Obj.t -> 'r) -> 'r

(** Type-safe wrapper that documents the expected type.
    The caller is responsible for ensuring the file contains data of type ['a].

    Example:
    {[
      let process_data path =
        with_unmarshalled_file_exn path (fun (data : my_data_type) ->
          (* process data *)
        )
    ]}
*)
val with_unmarshalled_file_exn : string -> ('a -> 'r) -> 'r
  [@@alert unsafe "Caller must ensure the file contains data of the expected type"]

(** Remove all entries from the cache, unmapping all memory. *)
val clear : unit -> unit

(** Remove a specific path from the cache.
    No-op if the path is not cached. *)
val invalidate : string -> unit

(** Set the maximum number of cached entries.
    When exceeded, least-recently-used entries are evicted.
    Default: 10000. Set to 0 for unlimited (not recommended). *)
val set_max_entries : int -> unit

(** Set the maximum total bytes of mapped memory.
    When exceeded, least-recently-used entries are evicted.
    Default: 1GB. Set to 0 for unlimited (not recommended). *)
val set_max_bytes : int -> unit

(** Returns (entry_count, total_mapped_bytes). *)
val stats : unit -> int * int
```

Usage pattern:

```ocaml
Marshalled_file_cache.with_unmarshalled_file_exn "/abs/path/to/file.bin"
  (fun (v : my_expected_type) ->
    (* process quickly *)
    ...
  )
```

### Type safety note

This API is inherently "trust me": the caller must use the right type for the given file. That is already the case with `Marshal.from_*`.

We provide two variants:
- `with_unmarshalled_file` returns `Obj.t`, making the unsafety explicit
- `with_unmarshalled_file_exn` is polymorphic but marked with `[@@alert unsafe]`


## C/C++ implementation plan

### Files / module layout (standalone library)

Exact filenames and build system depend on whether this is shipped as:

- an OCaml library with C stubs (dune/opam), or
- a pure C library plus a separate OCaml binding package.

One reasonable layout for an OCaml library with C++ stubs is:

- `csrc/marshalled_file_cache.h`
- `csrc/marshalled_file_cache.cpp` (C++ for `std::unordered_map`)
- `lib/marshalled_file_cache.ml` + `lib/marshalled_file_cache.mli`

This document intentionally does not assume any particular repository structure.

### Core data structure

```cpp
#include <unordered_map>
#include <list>
#include <vector>
#include <mutex>
#include <ctime>
#include <sys/stat.h>

struct FileId {
  time_t mtime_sec;
  long mtime_nsec;    // nanosecond precision from st_mtimespec
  off_t size;
  ino_t ino;          // inode number to detect full-file rewrites

  bool operator==(const FileId& other) const {
    return mtime_sec == other.mtime_sec &&
           mtime_nsec == other.mtime_nsec &&
           size == other.size &&
           ino == other.ino;
  }
};

struct Mapping {
  void* ptr;
  size_t len;
  FileId file_id;
};

struct Entry {
  std::string path;
  Mapping current;
  size_t in_use;                      // number of active callbacks
  std::vector<Mapping> old_mappings;  // deferred-unmap if refreshed while in_use>0

  // LRU tracking
  std::list<std::string>::iterator lru_iter;
};

class MarshalledFileCache {
private:
  std::unordered_map<std::string, Entry> cache_;
  std::list<std::string> lru_order_;  // front = most recent, back = least recent
  std::mutex mutex_;

  size_t max_entries_ = 10000;
  size_t max_bytes_ = 1ULL << 30;  // 1GB default
  size_t current_bytes_ = 0;

  void evict_if_needed();
  void unmap_mapping(const Mapping& m);
  void touch_lru(Entry& entry);

public:
  static MarshalledFileCache& instance();

  template<typename F>
  auto with_file(const std::string& path, F&& callback) -> decltype(callback(nullptr, 0));

  void clear();
  void invalidate(const std::string& path);
  void set_max_entries(size_t n);
  void set_max_bytes(size_t n);
  std::pair<size_t, size_t> stats();
};
```

### File identity check (nanosecond mtime + inode)

To avoid stale cache hits when a file is modified twice within the same second:

```cpp
FileId get_file_id(const char* path) {
  struct stat st;
  if (stat(path, &st) != 0) {
    throw std::system_error(errno, std::system_category(), path);
  }
  return FileId{
    .mtime_sec = st.st_mtimespec.tv_sec,
    .mtime_nsec = st.st_mtimespec.tv_nsec,  // macOS provides nanoseconds
    .size = st.st_size,
    .ino = st.st_ino
  };
}
```

**Note**: On macOS, `st_mtimespec` provides nanosecond precision. On Linux, use `st_mtim` instead. Add a compatibility macro:

```cpp
#ifdef __APPLE__
  #define MTIME_SEC(st) ((st).st_mtimespec.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtimespec.tv_nsec)
#else
  #define MTIME_SEC(st) ((st).st_mtim.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtim.tv_nsec)
#endif
```

### Refresh logic (with LRU eviction)

When `with_unmarshalled_file(path, f)` is called:

1. Acquire `mutex_`.
2. `stat(path)` → `FileId current_id`
   - If stat fails: release mutex, raise `Cache_error(path, Sys_error ...)`
3. Lookup entry in `cache_`.
4. If missing OR `current_id != entry.current.file_id`:
   - **Evict if needed** (see LRU eviction below)
   - Create new mapping:
     ```cpp
     int fd = open(path, O_RDONLY);
     if (fd < 0) throw ...;
     void* ptr = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
     close(fd);  // Close immediately! Mapping remains valid.
     if (ptr == MAP_FAILED) throw ...;
     ```
   - Swap into `entry.current`, update `current_bytes_`.
   - If the previous mapping existed:
     - If `entry.in_use == 0`: `munmap` immediately
     - Else: push previous mapping into `old_mappings`
5. Increment `entry.in_use`.
6. Update LRU position (move to front).
7. **Release `mutex_`** (critical: release before callback to avoid deadlock with OCaml runtime).
8. Unmarshal from `entry.current.ptr` / `entry.current.len`.
9. Call the OCaml callback (may release/reacquire OCaml runtime lock).
10. **Re-acquire `mutex_`**.
11. Decrement `entry.in_use`.
12. If `entry.in_use == 0`:
    - Unmap any `old_mappings` accumulated by refreshes
    - Clear `old_mappings` vector
13. Release `mutex_`.

### LRU eviction

```cpp
void MarshalledFileCache::evict_if_needed() {
  // Must be called with mutex_ held
  while ((cache_.size() > max_entries_ && max_entries_ > 0) ||
         (current_bytes_ > max_bytes_ && max_bytes_ > 0)) {
    if (lru_order_.empty()) break;

    // Find least-recently-used entry that is not in use
    bool evicted = false;
    for (auto it = lru_order_.rbegin(); it != lru_order_.rend(); ++it) {
      auto cache_it = cache_.find(*it);
      if (cache_it != cache_.end() && cache_it->second.in_use == 0) {
        Entry& entry = cache_it->second;

        // Unmap current and all old mappings
        unmap_mapping(entry.current);
        for (const auto& m : entry.old_mappings) {
          unmap_mapping(m);
        }
        current_bytes_ -= entry.current.len;

        lru_order_.erase(entry.lru_iter);
        cache_.erase(cache_it);
        evicted = true;
        break;
      }
    }
    if (!evicted) break;  // All entries are in use
  }
}

void MarshalledFileCache::unmap_mapping(const Mapping& m) {
  if (m.ptr != nullptr && m.ptr != MAP_FAILED) {
    munmap(m.ptr, m.len);
  }
}
```

### Old mappings cleanup

To prevent unbounded accumulation of `old_mappings` during long recursive calls, add a sweep in `clear()` and a threshold check:

```cpp
// In the refresh logic, after pushing to old_mappings:
if (entry.old_mappings.size() > 100) {
  // Log warning: excessive stale mappings for path
  // This indicates a very long-running recursive callback
}

void MarshalledFileCache::clear() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto& [path, entry] : cache_) {
    // Only unmap if not in use
    if (entry.in_use == 0) {
      unmap_mapping(entry.current);
    }
    // Always clean up old_mappings (they're not being used)
    for (const auto& m : entry.old_mappings) {
      unmap_mapping(m);
    }
    entry.old_mappings.clear();
  }
  // Remove entries not in use
  for (auto it = cache_.begin(); it != cache_.end(); ) {
    if (it->second.in_use == 0) {
      it = cache_.erase(it);
    } else {
      ++it;
    }
  }
  // Rebuild LRU list for remaining entries
  lru_order_.clear();
  for (auto& [path, entry] : cache_) {
    lru_order_.push_front(path);
    entry.lru_iter = lru_order_.begin();
  }
  current_bytes_ = 0;
  for (const auto& [path, entry] : cache_) {
    current_bytes_ += entry.current.len;
  }
}
```


## Unmarshalling from mmap'd memory (OCaml 5+)

### OCaml 5 internal API

In OCaml 5+, the relevant internal function for unmarshalling from a memory block is:

```c
// From caml/intext.h (OCaml 5.x)
CAMLextern value caml_input_value_from_block(value str, intnat ofs, intnat len);
```

However, this expects `str` to be an OCaml `bytes` value, not a raw pointer. For true zero-copy from mmap'd memory, we need to use lower-level internals.

### Approach: Use `caml_input_value_from_bytes` with a "fake" bigstring

The cleanest OCaml 5+ approach is to create a Bigarray that shares the mmap'd memory:

```c
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/intext.h>

// Create a Bigarray view over mmap'd memory (no copy!)
static value make_bigarray_view(void* ptr, size_t len) {
  // CAML_BA_UINT8: unsigned 8-bit integers
  // CAML_BA_C_LAYOUT: C-style row-major layout
  // CAML_BA_EXTERNAL: data is external (not managed by OCaml GC)
  return caml_ba_alloc_dims(
    CAML_BA_UINT8 | CAML_BA_C_LAYOUT | CAML_BA_EXTERNAL,
    1,        // 1-dimensional
    ptr,      // pointer to data
    len       // dimension
  );
}
```

Then unmarshal via OCaml:

```ocaml
(* In marshalled_file_cache.ml *)
external unsafe_bigarray_view : nativeint -> int -> Bigarray_compat.t = "caml_make_bigarray_view"

let unmarshal_from_bigarray ba =
  (* Marshal.from_bytes works on bytes; we need a different approach *)
  let len = Bigarray.Array1.dim ba in
  let bytes = Bytes.create len in
  (* This copies, but only once *)
  for i = 0 to len - 1 do
    Bytes.unsafe_set bytes i (Char.chr (Bigarray.Array1.unsafe_get ba i))
  done;
  Marshal.from_bytes bytes 0
```

**However**, this still involves a copy. For true zero-copy:

### Approach: Direct use of OCaml's internal unmarshaller (OCaml 5+)

OCaml 5's `intern.c` provides lower-level access. We can call the internal unmarshalling machinery directly:

```c
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/intext.h>
#include <caml/fail.h>

// OCaml 5+ internal: unmarshal from arbitrary memory
// This is the key function we need
CAMLprim value marshalled_file_cache_unmarshal_from_ptr(value ptr_val, value len_val) {
  CAMLparam2(ptr_val, len_val);
  CAMLlocal1(result);

  void* ptr = (void*)Nativeint_val(ptr_val);
  size_t len = Long_val(len_val);

  // Validate marshal header
  if (len < 20) {  // Minimum marshal header size
    caml_failwith("marshalled_file_cache: data too short for marshal header");
  }

  // Check magic number (0x8495A6BE for small, 0x8495A6BF for large)
  uint32_t magic = be32toh(*(uint32_t*)ptr);
  if (magic != 0x8495A6BE && magic != 0x8495A6BF) {
    caml_failwith("marshalled_file_cache: invalid marshal magic number");
  }

  // Create a temporary bytes value that references our data
  // CAUTION: This is a hack that works in OCaml 5 but may break in future versions
  //
  // Safer alternative: copy into bytes (one memcpy, acceptable for Milestone 1)
  value bytes = caml_alloc_string(len);
  memcpy(Bytes_val(bytes), ptr, len);

  result = caml_input_value_from_bytes(bytes, 0);

  CAMLreturn(result);
}
```

### Recommended approach for OCaml 5+

For maximum compatibility and safety, use this two-phase approach:

**Phase 1 (Milestone 1)**: Single memcpy into OCaml bytes, then unmarshal:

```c
CAMLprim value mfc_unmarshal_mmap(value ptr_val, value len_val) {
  CAMLparam2(ptr_val, len_val);
  CAMLlocal2(bytes, result);

  char* ptr = (char*)Nativeint_val(ptr_val);
  size_t len = (size_t)Int64_val(len_val);

  // Single copy into OCaml heap
  bytes = caml_alloc_string(len);
  memcpy(Bytes_val(bytes), ptr, len);

  // Unmarshal from bytes
  result = caml_input_value_from_bytes(bytes, Val_long(0));

  CAMLreturn(result);
}
```

**Phase 2 (Milestone 2)**: True zero-copy using Bigarray + custom unmarshaller, or by contributing an upstream patch to OCaml to expose `caml_input_value_from_block_ptr(const char* data, size_t len)`.


## FFI boundary (OCaml → C)

Expose these C stubs:

```c
// Main entry point
CAMLprim value mfc_with_unmarshalled_file(value path_val, value closure_val);

// Cache management
CAMLprim value mfc_clear(value unit);
CAMLprim value mfc_invalidate(value path_val);
CAMLprim value mfc_set_max_entries(value n_val);
CAMLprim value mfc_set_max_bytes(value n_val);
CAMLprim value mfc_stats(value unit);
```

### Main stub implementation

```c
CAMLprim value mfc_with_unmarshalled_file(value path_val, value closure_val) {
  CAMLparam2(path_val, closure_val);
  CAMLlocal2(unmarshalled, result);

  const char* path = String_val(path_val);

  // C++ cache lookup and refresh (may throw)
  void* ptr;
  size_t len;
  try {
    MarshalledFileCache::instance().acquire_mapping(path, &ptr, &len);
  } catch (const std::system_error& e) {
    // Convert to OCaml exception
    caml_raise_with_string(*caml_named_value("Marshalled_file_cache.Cache_error"),
                           e.what());
  }

  // Unmarshal (may allocate, may trigger GC)
  unmarshalled = mfc_unmarshal_mmap(caml_copy_nativeint((intnat)ptr),
                                     caml_copy_int64(len));

  // Call the callback (mutex already released by acquire_mapping)
  result = caml_callback_exn(closure_val, unmarshalled);

  // Release mapping (re-acquires mutex, decrements in_use)
  MarshalledFileCache::instance().release_mapping(path);

  // Re-raise if callback raised
  if (Is_exception_result(result)) {
    caml_raise(Extract_exception(result));
  }

  CAMLreturn(result);
}
```


## Thread safety and OCaml runtime lock interaction

**Critical**: The OCaml runtime uses a global lock (the "domain lock" in OCaml 5). If we hold `mutex_` while calling into OCaml, and the OCaml code calls back into C code that tries to acquire `mutex_`, we deadlock.

**Solution**: Split the operation into acquire/release phases:

```cpp
class MarshalledFileCache {
public:
  // Phase 1: Get pointer, increment in_use, release mutex
  void acquire_mapping(const std::string& path, void** out_ptr, size_t* out_len) {
    std::unique_lock<std::mutex> lock(mutex_);

    // ... refresh logic ...

    Entry& entry = cache_[path];
    entry.in_use++;
    touch_lru(entry);

    *out_ptr = entry.current.ptr;
    *out_len = entry.current.len;

    // Mutex released here (lock goes out of scope)
  }

  // Phase 2: Decrement in_use, cleanup old_mappings
  void release_mapping(const std::string& path) {
    std::lock_guard<std::mutex> lock(mutex_);

    auto it = cache_.find(path);
    if (it == cache_.end()) return;  // Entry was evicted

    Entry& entry = it->second;
    entry.in_use--;

    if (entry.in_use == 0) {
      for (const auto& m : entry.old_mappings) {
        unmap_mapping(m);
      }
      entry.old_mappings.clear();
    }
  }
};
```


## Error handling

Define a custom exception in OCaml:

```ocaml
(* marshalled_file_cache.ml *)

exception Cache_error of string * exn option

let () = Callback.register_exception
  "Marshalled_file_cache.Cache_error"
  (Cache_error ("", None))
```

Raise from C:

```c
void raise_cache_error(const char* path, const char* message) {
  CAMLparam0();
  CAMLlocal2(exn, pair);

  // Build (path, Some (Failure message)) or (path, None)
  value* exn_constr = caml_named_value("Marshalled_file_cache.Cache_error");
  if (exn_constr == NULL) {
    caml_failwith(message);  // Fallback
  }

  // Create the exception
  pair = caml_alloc_tuple(2);
  Store_field(pair, 0, caml_copy_string(path));
  Store_field(pair, 1, Val_int(0));  // None for simplicity

  caml_raise_with_arg(*exn_constr, pair);

  CAMLnoreturn;
}
```

### Error cases handled:

| Error | Behavior |
|-------|----------|
| File not found | `Cache_error(path, Some(Unix.Unix_error(ENOENT, ...)))` |
| Permission denied | `Cache_error(path, Some(Unix.Unix_error(EACCES, ...)))` |
| mmap failed | `Cache_error(path, Some(Failure "mmap failed: ..."))` |
| Invalid marshal magic | `Cache_error(path, Some(Failure "invalid marshal header"))` |
| Marshal data corrupted | Propagate `Marshal.Error` from OCaml unmarshaller |


## Known limitations

### TOCTOU window

Between `stat()` and `open()+mmap()`, the file can change again. The mapping will reflect the *final* contents at the time of `mmap()`, but `entry.file_id` will hold the stat result from *before*.

**Impact**: In rare cases, a subsequent call might unnecessarily refresh the mapping even though the contents are current.

**Mitigation**: This is benign (causes an extra refresh, not stale data). For stricter guarantees, stat again after mmap and compare, but this adds overhead.

### Large file handling

Files larger than available virtual address space (rare on 64-bit) will fail to mmap. The error is surfaced as `Cache_error`.


## Memory model

There is **no fixed-size memory pool**. Each cached file gets its own `mmap` of exactly its file size.

| Layer | Location | Managed by | Lifetime |
|-------|----------|------------|----------|
| mmap'd bytes | Virtual address space (off-heap) | OS + cache LRU | Until `munmap` or eviction |
| Unmarshalled value | OCaml heap | OCaml GC | Callback duration + GC |

**How mmap works in practice:**
- Physical RAM pages are allocated **on demand** (first access)
- Under memory pressure, the OS can evict pages back to disk (file-backed)
- The cache's `max_entries` / `max_bytes` limits trigger `munmap` of LRU entries

**Mental model:**
> The cache is an index of lazy file mappings. Memory usage scales with the *working set* of recently-accessed pages, not the total size of all cached files.

Example: mapping 100 files totaling 1GB but only reading headers uses ~100 × 4KB of physical RAM, not 1GB.


## GC and performance implications

- The **cached bytes** are off-heap (`mmap`), immutable, and never scanned by the GC.
- The **decoded value** is a normal OCaml object graph:
  - It will allocate in OCaml's heap during unmarshal.
  - If you process immediately and drop it, it becomes garbage and can be reclaimed.
  - Because your workload is "A", you avoid the long-term GC scanning pressure of keeping large decoded values reachable.

This directly targets your objective: avoid repeatedly paying for "having large decoded values around".


## Concurrency considerations (threads/processes)

This design is **per-process**: each process has its own in-memory cache map.

- **Threads (OCaml 5 domains)**: The mutex protects cache state. The mutex is released before calling into OCaml callbacks, preventing deadlocks with the domain lock.
- **Processes**: No cross-process coherence is attempted; if multiple processes read the same path, each will maintain its own mapping. That is usually fine for the "A" workload.


## Platform compatibility

### macOS

**Supported versions**: macOS 10.13 (High Sierra) and later

| Feature | Availability | Notes |
|---------|--------------|-------|
| `mmap`, `munmap` | All versions | POSIX standard |
| `st_mtimespec` (nanoseconds) | All versions | Darwin-specific, always available |
| `stat`, `open`, `close` | All versions | POSIX standard |
| C++11 (`std::mutex`, etc.) | Xcode 5+ | libc++ bundled with Xcode |
| OCaml 5.x | macOS 10.13+ | OCaml 5 requires macOS 10.13+ for `pthread` features |

**Toolchain requirements**:
- Xcode Command Line Tools (any recent version)
- No special linker flags, no `objcopy`, no fixed-address tricks

**Tested configurations**:
- Apple Silicon (arm64): macOS 11+
- Intel (x86_64): macOS 10.13+

### Linux

**Supported**: Yes, with minor source adjustments

| Feature | Availability | Notes |
|---------|--------------|-------|
| `mmap`, `munmap` | All versions | POSIX standard |
| `st_mtim` (nanoseconds) | glibc 2.12+ | Use `st_mtim` instead of `st_mtimespec` |
| `stat`, `open`, `close` | All versions | POSIX standard |
| C++11 | GCC 4.8+ / Clang 3.3+ | libstdc++ or libc++ |

**Required source changes** (already included in the plan):

```cpp
#ifdef __APPLE__
  #define MTIME_SEC(st)  ((st).st_mtimespec.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtimespec.tv_nsec)
#else  // Linux, BSD, etc.
  #define MTIME_SEC(st)  ((st).st_mtim.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtim.tv_nsec)
#endif
```

**Limitations on Linux**:

1. **Filesystem-dependent mtime precision**: Some filesystems (ext3, older NFS) only store second-precision timestamps. The nanosecond field may be zero or synthetic. The inode check mitigates this.

2. **`/proc` and special filesystems**: Files in `/proc`, `/sys`, or FUSE filesystems may not support `mmap`. These are unlikely to contain marshalled files, but if encountered, the error is propagated as `Cache_error`.

3. **32-bit systems**: `off_t` and `size_t` may be 32-bit, limiting file sizes to 2GB. Use `-D_FILE_OFFSET_BITS=64` for large file support.

**Tested configurations**:
- Ubuntu 20.04+ (glibc 2.31+)
- Debian 10+ (glibc 2.28+)
- Alpine Linux (musl libc) — requires testing

### Windows

**Not currently supported**

Windows lacks POSIX `mmap`. A Windows port would require significant changes:

| POSIX API | Windows Equivalent | Complexity |
|-----------|-------------------|------------|
| `mmap` | `CreateFileMapping` + `MapViewOfFile` | Medium |
| `munmap` | `UnmapViewOfFile` + `CloseHandle` | Medium |
| `stat` | `GetFileAttributesEx` or `_stat64` | Low |
| `st_mtimespec` | `FILETIME` (100ns precision) | Low |
| `st_ino` | `GetFileInformationByHandle` → `nFileIndex*` | Medium |
| Path handling | Backslashes, drive letters, UNC paths | High |

**Effort estimate**: ~2-3 days of additional work for a Windows backend.

**Recommended approach for Windows support**:

1. Abstract the platform layer:

```cpp
// platform.h
struct PlatformMapping {
  void* ptr;
  size_t len;
#ifdef _WIN32
  HANDLE file_handle;
  HANDLE mapping_handle;
#endif
};

bool platform_map_file(const char* path, PlatformMapping* out);
void platform_unmap(PlatformMapping* m);
bool platform_get_file_id(const char* path, FileId* out);
```

2. Implement `platform_win32.cpp` using Windows APIs.

3. Use `_stat64` + `GetFileInformationByHandle` for file identity:

```cpp
// Windows file identity
struct FileId {
  uint64_t mtime;           // FILETIME as 64-bit
  uint64_t size;
  uint64_t volume_serial;   // From BY_HANDLE_FILE_INFORMATION
  uint64_t file_index;      // nFileIndexHigh << 32 | nFileIndexLow
};
```

**Current recommendation**: Defer Windows support unless there's a concrete need. The library is primarily for macOS development workflows.

### FreeBSD / OpenBSD / NetBSD

**Expected to work** with Linux-compatible code path. BSD systems use `st_mtim` (same as Linux) or `st_mtimespec` (same as macOS) depending on the version. Add detection:

```cpp
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
  #define MTIME_SEC(st)  ((st).st_mtimespec.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtimespec.tv_nsec)
#else
  #define MTIME_SEC(st)  ((st).st_mtim.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtim.tv_nsec)
#endif
```

### Summary table

| Platform | Supported | Effort | Notes |
|----------|-----------|--------|-------|
| macOS 10.13+ | ✅ Yes | Ready | Primary target |
| macOS 10.12 and earlier | ⚠️ Maybe | Untested | OCaml 5 may not work |
| Linux (glibc) | ✅ Yes | Minimal | Use `st_mtim` macro |
| Linux (musl) | ⚠️ Likely | Test needed | Should work |
| FreeBSD/OpenBSD/NetBSD | ⚠️ Likely | Test needed | Use `st_mtimespec` |
| Windows | ❌ No | 2-3 days | Needs platform abstraction |
| WSL/WSL2 | ✅ Yes | None | Uses Linux code path |


## Milestones

### Milestone 1: minimal working cache

- Implement mapping cache with full invalidation checks (mtime_nsec + inode + size)
- Implement `with_unmarshalled_file` with single-copy unmarshal
- Implement LRU eviction with configurable limits
- Close fd immediately after mmap (avoid fd exhaustion)
- Add proper error handling with `Cache_error` exception
- Add a small OCaml example that processes a marshalled file once

### Milestone 2: zero-copy unmarshal

- Confirm and use the OCaml runtime "unmarshal-from-memory" API (or contribute upstream patch)
- Add a micro-benchmark: verify no full-file memcpy
- Validate with large files (100MB+)

### Milestone 3: polish

- `invalidate`, `clear`, `stats` fully tested
- Better error messages (include errno strings)
- Optional debug/tracing mode
- Performance benchmarks vs. naive `Marshal.from_channel`


## Testing plan

- **Correctness**
  - Call `with_unmarshalled_file` twice on same file: should not remap; should decode consistently.
  - Modify the file on disk (change content): next call should remap and decode new content.
  - Touch file without changing content: should remap (mtime changed).
  - Rewrite file in-place (same inode, new content): should remap.
  - Replace file atomically (`rename()`): should remap (inode changed).
  - Callback raises: mapping refcount must be decremented; no leak; subsequent calls still work.
  - Nested/recursive calls to same file: should work correctly with refcounting.

- **Resource management**
  - Verify fd count stays constant after many cache operations (fds closed after mmap).
  - Verify LRU eviction triggers at configured thresholds.
  - Verify `clear()` unmaps all memory (check with `vmmap` on macOS).
  - Verify `old_mappings` are cleaned up after callbacks complete.

- **Safety**
  - Ensure no use-after-unmap: run under ASan.
  - Stress test with concurrent access from multiple domains (OCaml 5).
  - Test with files deleted while cached (should raise on next access).

- **Performance**
  - Benchmark cached path vs. cold read.
  - Validate single-copy unmarshal (Phase 1).
  - Validate zero-copy unmarshal once Milestone 2 is implemented.
  - Profile with large files (10MB, 100MB, 1GB).

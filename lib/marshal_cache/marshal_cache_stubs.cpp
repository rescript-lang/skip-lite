// marshal_cache_stubs.cpp
// skip-lite: Marshal cache with mmap and LRU eviction
// OCaml 5+ compatible
//
// =============================================================================
// WARNING: OCaml C FFI and GC Pitfalls
// =============================================================================
//
// This file interfaces with the OCaml runtime. The OCaml garbage collector
// can move values in memory at any allocation point. Failure to handle this
// correctly causes memory corruption and segfaults.
//
// KEY RULES:
//
// 1. NEVER use String_val(v) across an allocation
//    ------------------------------------------------
//    BAD:
//      const char* s = String_val(str_val);
//      some_ocaml_alloc();  // GC may run, str_val moves, s is now dangling
//      use(s);              // SEGFAULT
//
//    GOOD:
//      std::string s(String_val(str_val));  // Copy to C++ string first
//      some_ocaml_alloc();
//      use(s.c_str());  // Safe, C++ owns the memory
//
// 2. NEVER nest allocations in Store_field
//    ------------------------------------------------
//    BAD:
//      value tuple = caml_alloc_tuple(2);
//      Store_field(tuple, 0, caml_copy_string(s));  // DANGEROUS!
//      // caml_copy_string allocates, may trigger GC, tuple address is
//      // computed BEFORE the call, so we write to stale memory
//
//    GOOD:
//      value tuple = caml_alloc_tuple(2);
//      value str = caml_copy_string(s);  // Allocate first
//      Store_field(tuple, 0, str);       // Then store
//
// 3. CAMLlocal doesn't help with evaluation order
//    ------------------------------------------------
//    CAMLlocal registers a variable so GC updates it when values move.
//    But it doesn't fix the evaluation order problem in Store_field.
//    The address computation happens before the nested function call.
//
// 4. Raising exceptions from C is tricky
//    ------------------------------------------------
//    caml_raise* functions do a longjmp, so:
//    - CAMLparam/CAMLlocal frames are not properly unwound
//    - C++ destructors may not run (avoid RAII in throwing paths)
//    - Prefer raising simple exceptions (Failure) and converting in OCaml
//
// 5. Callbacks can trigger arbitrary GC
//    ------------------------------------------------
//    When calling caml_callback*, the OCaml code can allocate freely.
//    All value variables from before the callback may be stale after.
//    Either re-read them or use CAMLlocal to keep them updated.
//
// CURRENT APPROACH:
// - Errors are raised as Failure("path: message") from C
// - The OCaml wrapper catches Failure and converts to Cache_error
// - This avoids complex allocation sequences in exception-raising paths
//
// =============================================================================

#include <unordered_map>
#include <list>
#include <vector>
#include <mutex>
#include <string>
#include <cstring>
#include <cerrno>
#include <cstdint>
#include <stdexcept>

#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>

// OCaml headers
extern "C" {
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <caml/intext.h>
}

// Platform-specific mtime access (nanosecond precision)
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
  #define MTIME_SEC(st)  ((st).st_mtimespec.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtimespec.tv_nsec)
#else  // Linux and others
  #define MTIME_SEC(st)  ((st).st_mtim.tv_sec)
  #define MTIME_NSEC(st) ((st).st_mtim.tv_nsec)
#endif

namespace {

// File identity for cache invalidation (mtime + size + inode)
struct FileId {
  time_t mtime_sec;
  long mtime_nsec;
  off_t size;
  ino_t ino;

  bool operator==(const FileId& other) const {
    return mtime_sec == other.mtime_sec &&
           mtime_nsec == other.mtime_nsec &&
           size == other.size &&
           ino == other.ino;
  }

  bool operator!=(const FileId& other) const {
    return !(*this == other);
  }
};

// A memory mapping
struct Mapping {
  void* ptr = nullptr;
  size_t len = 0;
  FileId file_id = {};

  bool is_valid() const {
    return ptr != nullptr && ptr != MAP_FAILED && ptr != reinterpret_cast<void*>(1);
  }
};

// Cache entry for a single file
struct Entry {
  std::string path;
  Mapping current;
  size_t in_use = 0;                      // Number of active callbacks
  std::vector<Mapping> old_mappings;      // Deferred unmaps
  std::list<std::string>::iterator lru_iter;
};

// The global cache singleton
class MarshalCache {
public:
  static MarshalCache& instance() {
    static MarshalCache inst;
    return inst;
  }

  // Acquire a mapping, incrementing in_use. Returns pointer, length, and whether file changed.
  // Throws std::runtime_error on failure.
  void acquire_mapping(const std::string& path, void** out_ptr, size_t* out_len, bool* out_changed);

  // Release a mapping, decrementing in_use and cleaning up old mappings.
  void release_mapping(const std::string& path);

  // Clear all entries (only those not in use)
  void clear();

  // Invalidate a specific path
  void invalidate(const std::string& path);

  // Set limits
  void set_max_entries(size_t n) {
    std::lock_guard<std::mutex> lock(mutex_);
    max_entries_ = n;
    evict_if_needed();
  }

  void set_max_bytes(size_t n) {
    std::lock_guard<std::mutex> lock(mutex_);
    max_bytes_ = n;
    evict_if_needed();
  }

  // Stats: (entry_count, total_mapped_bytes)
  std::pair<size_t, size_t> stats() {
    std::lock_guard<std::mutex> lock(mutex_);
    return {cache_.size(), current_bytes_};
  }

private:
  MarshalCache() = default;
  ~MarshalCache() { clear_internal(); }

  // Prevent copying
  MarshalCache(const MarshalCache&) = delete;
  MarshalCache& operator=(const MarshalCache&) = delete;

  // Must be called with mutex_ held
  void evict_if_needed();
  void unmap_mapping(const Mapping& m);
  void touch_lru(Entry& entry);
  void clear_internal();

  // Get file identity, throws on error
  FileId get_file_id(const char* path);

  // Create a new mapping for a file, throws on error
  Mapping create_mapping(const char* path, const FileId& file_id);

  std::unordered_map<std::string, Entry> cache_;
  std::list<std::string> lru_order_;  // front = most recent
  std::mutex mutex_;

  size_t max_entries_ = 10000;
  size_t max_bytes_ = 1ULL << 30;  // 1GB default
  size_t current_bytes_ = 0;
};

FileId MarshalCache::get_file_id(const char* path) {
  struct stat st;
  if (stat(path, &st) != 0) {
    throw std::runtime_error(std::string("stat failed: ") + path + ": " + strerror(errno));
  }
  return FileId{
    MTIME_SEC(st),
    MTIME_NSEC(st),
    st.st_size,
    st.st_ino
  };
}

Mapping MarshalCache::create_mapping(const char* path, const FileId& file_id) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    throw std::runtime_error(std::string("open failed: ") + path + ": " + strerror(errno));
  }

  size_t len = static_cast<size_t>(file_id.size);
  void* ptr = nullptr;

  if (len > 0) {
    ptr = mmap(nullptr, len, PROT_READ, MAP_PRIVATE, fd, 0);
  } else {
    // Empty file: use a sentinel non-null pointer
    ptr = reinterpret_cast<void*>(1);
  }

  // Close fd immediately - mapping remains valid on POSIX
  close(fd);

  if (len > 0 && (ptr == MAP_FAILED || ptr == nullptr)) {
    throw std::runtime_error(std::string("mmap failed: ") + path + ": " + strerror(errno));
  }

  Mapping m;
  m.ptr = ptr;
  m.len = len;
  m.file_id = file_id;
  return m;
}

void MarshalCache::unmap_mapping(const Mapping& m) {
  if (m.is_valid() && m.len > 0) {
    munmap(m.ptr, m.len);
  }
}

void MarshalCache::touch_lru(Entry& entry) {
  // Move to front of LRU list
  lru_order_.erase(entry.lru_iter);
  lru_order_.push_front(entry.path);
  entry.lru_iter = lru_order_.begin();
}

void MarshalCache::evict_if_needed() {
  // Must be called with mutex_ held
  // Use >= because this is called BEFORE adding a new entry
  while ((max_entries_ > 0 && cache_.size() >= max_entries_) ||
         (max_bytes_ > 0 && current_bytes_ >= max_bytes_)) {
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

void MarshalCache::acquire_mapping(const std::string& path,
                                   void** out_ptr, size_t* out_len, bool* out_changed) {
  std::unique_lock<std::mutex> lock(mutex_);

  // Get current file identity
  FileId current_id = get_file_id(path.c_str());

  // Lookup or create entry
  auto it = cache_.find(path);
  bool needs_remap = false;

  if (it == cache_.end()) {
    needs_remap = true;
  } else if (it->second.current.file_id != current_id) {
    needs_remap = true;
  }

  if (needs_remap) {
    // Only evict if we're adding a NEW entry (not updating existing)
    // This prevents evicting the entry we're about to update
    if (it == cache_.end()) {
      evict_if_needed();
    }

    // Create new mapping (may throw)
    Mapping new_mapping = create_mapping(path.c_str(), current_id);

    if (it == cache_.end()) {
      // Insert new entry
      Entry entry;
      entry.path = path;
      entry.current = new_mapping;
      entry.in_use = 0;
      lru_order_.push_front(path);
      entry.lru_iter = lru_order_.begin();

      cache_[path] = std::move(entry);
      it = cache_.find(path);
    } else {
      // Update existing entry
      Entry& entry = it->second;
      Mapping old = entry.current;
      entry.current = new_mapping;

      // Handle old mapping
      if (old.is_valid()) {
        if (entry.in_use == 0) {
          unmap_mapping(old);
        } else {
          // Defer unmap until callbacks complete
          entry.old_mappings.push_back(old);
        }
        current_bytes_ -= old.len;
      }
    }

    current_bytes_ += new_mapping.len;
  }

  Entry& entry = it->second;
  entry.in_use++;
  touch_lru(entry);

  *out_ptr = entry.current.ptr;
  *out_len = entry.current.len;
  *out_changed = needs_remap;

  // Mutex released here (RAII)
}

void MarshalCache::release_mapping(const std::string& path) {
  std::lock_guard<std::mutex> lock(mutex_);

  auto it = cache_.find(path);
  if (it == cache_.end()) return;  // Entry was evicted

  Entry& entry = it->second;
  if (entry.in_use > 0) {
    entry.in_use--;
  }

  if (entry.in_use == 0 && !entry.old_mappings.empty()) {
    // Clean up deferred unmaps
    for (const auto& m : entry.old_mappings) {
      unmap_mapping(m);
    }
    entry.old_mappings.clear();
  }
}

void MarshalCache::clear_internal() {
  for (auto& [path, entry] : cache_) {
    if (entry.in_use == 0) {
      unmap_mapping(entry.current);
    }
    for (const auto& m : entry.old_mappings) {
      unmap_mapping(m);
    }
  }
  cache_.clear();
  lru_order_.clear();
  current_bytes_ = 0;
}

void MarshalCache::clear() {
  std::lock_guard<std::mutex> lock(mutex_);

  // Only clear entries not in use
  for (auto it = cache_.begin(); it != cache_.end(); ) {
    Entry& entry = it->second;

    // Always clean up old_mappings
    for (const auto& m : entry.old_mappings) {
      unmap_mapping(m);
    }
    entry.old_mappings.clear();

    if (entry.in_use == 0) {
      unmap_mapping(entry.current);
      current_bytes_ -= entry.current.len;
      lru_order_.erase(entry.lru_iter);
      it = cache_.erase(it);
    } else {
      ++it;
    }
  }
}

void MarshalCache::invalidate(const std::string& path) {
  std::lock_guard<std::mutex> lock(mutex_);

  auto it = cache_.find(path);
  if (it == cache_.end()) return;

  Entry& entry = it->second;

  // Clean up old_mappings
  for (const auto& m : entry.old_mappings) {
    unmap_mapping(m);
  }
  entry.old_mappings.clear();

  if (entry.in_use == 0) {
    unmap_mapping(entry.current);
    current_bytes_ -= entry.current.len;
    lru_order_.erase(entry.lru_iter);
    cache_.erase(it);
  }
  // If in_use > 0, the entry stays but will be refreshed on next access
}

}  // anonymous namespace


// =============================================================================
// OCaml FFI stubs
// =============================================================================

extern "C" {

// Helper to raise an error as Failure (converted to Cache_error in OCaml)
[[noreturn]]
static void raise_cache_error(const char* path, const char* message) {
  std::string full_msg = std::string(path) + ": " + message;
  caml_failwith(full_msg.c_str());
}

// Unmarshal from mmap'd memory (zero-copy using OCaml 5+ API)
static value unmarshal_from_ptr(void* ptr, size_t len) {
  CAMLparam0();
  CAMLlocal1(result);

  if (len == 0) {
    caml_failwith("marshal_cache: empty file");
  }

  // Validate marshal magic number
  if (len < 20) {
    caml_failwith("marshal_cache: file too small for marshal header");
  }

  const unsigned char* data = static_cast<const unsigned char*>(ptr);
  uint32_t magic = (static_cast<uint32_t>(data[0]) << 24) |
                   (static_cast<uint32_t>(data[1]) << 16) |
                   (static_cast<uint32_t>(data[2]) << 8) |
                   static_cast<uint32_t>(data[3]);

  // Marshal magic: 0x8495A6BE (small/32-bit) or 0x8495A6BF (large/64-bit)
  if (magic != 0x8495A6BEu && magic != 0x8495A6BFu) {
    caml_failwith("marshal_cache: invalid marshal magic number");
  }

  // OCaml 5+ API: unmarshal directly from memory block (zero-copy!)
  result = caml_input_value_from_block(static_cast<const char*>(ptr), static_cast<intnat>(len));

  CAMLreturn(result);
}

// Main entry point: with_unmarshalled_file
CAMLprim value mfc_with_unmarshalled_file(value path_val, value closure_val) {
  CAMLparam2(path_val, closure_val);
  CAMLlocal2(unmarshalled, result);

  const char* path = String_val(path_val);
  std::string path_str(path);

  void* ptr = nullptr;
  size_t len = 0;
  bool changed = false;

  // Acquire mapping (may throw)
  try {
    MarshalCache::instance().acquire_mapping(path_str, &ptr, &len, &changed);
  } catch (const std::exception& e) {
    // Use path_str.c_str() instead of path, because raise_cache_error
    // allocates and can trigger GC which would invalidate the pointer
    // from String_val(path_val)
    raise_cache_error(path_str.c_str(), e.what());
    CAMLreturn(Val_unit);  // Not reached
  }

  // Unmarshal (may allocate, may trigger GC, may raise)
  unmarshalled = unmarshal_from_ptr(ptr, len);

  // Call the OCaml callback
  result = caml_callback_exn(closure_val, unmarshalled);

  // Release mapping before potentially re-raising
  MarshalCache::instance().release_mapping(path_str);

  // Check if callback raised an exception
  if (Is_exception_result(result)) {
    value exn = Extract_exception(result);
    caml_raise(exn);
  }

  CAMLreturn(result);
}

// Reactive entry point: only unmarshal if file changed
// Returns Some(f(data)) if changed, None if unchanged
CAMLprim value mfc_with_unmarshalled_if_changed(value path_val, value closure_val) {
  CAMLparam2(path_val, closure_val);
  CAMLlocal3(unmarshalled, result, some_result);

  const char* path = String_val(path_val);
  std::string path_str(path);

  void* ptr = nullptr;
  size_t len = 0;
  bool changed = false;

  // Acquire mapping (may throw)
  try {
    MarshalCache::instance().acquire_mapping(path_str, &ptr, &len, &changed);
  } catch (const std::exception& e) {
    raise_cache_error(path_str.c_str(), e.what());
    CAMLreturn(Val_unit);  // Not reached
  }

  if (!changed) {
    // File unchanged - release and return None
    MarshalCache::instance().release_mapping(path_str);
    CAMLreturn(Val_none);
  }

  // File changed - unmarshal and call callback
  unmarshalled = unmarshal_from_ptr(ptr, len);

  // Call the OCaml callback
  result = caml_callback_exn(closure_val, unmarshalled);

  // Release mapping before potentially re-raising
  MarshalCache::instance().release_mapping(path_str);

  // Check if callback raised an exception
  if (Is_exception_result(result)) {
    value exn = Extract_exception(result);
    caml_raise(exn);
  }

  // Wrap in Some
  some_result = caml_alloc(1, 0);
  Store_field(some_result, 0, result);

  CAMLreturn(some_result);
}

// Clear all cache entries
CAMLprim value mfc_clear(value unit) {
  CAMLparam1(unit);
  MarshalCache::instance().clear();
  CAMLreturn(Val_unit);
}

// Invalidate a specific path
CAMLprim value mfc_invalidate(value path_val) {
  CAMLparam1(path_val);
  const char* path = String_val(path_val);
  std::string path_str(path);  // Copy immediately for consistency
  MarshalCache::instance().invalidate(path_str);
  CAMLreturn(Val_unit);
}

// Set max entries
CAMLprim value mfc_set_max_entries(value n_val) {
  CAMLparam1(n_val);
  size_t n = Long_val(n_val);
  MarshalCache::instance().set_max_entries(n);
  CAMLreturn(Val_unit);
}

// Set max bytes
CAMLprim value mfc_set_max_bytes(value n_val) {
  CAMLparam1(n_val);
  size_t n = Long_val(n_val);
  MarshalCache::instance().set_max_bytes(n);
  CAMLreturn(Val_unit);
}

// Get stats: returns (entry_count, total_mapped_bytes)
CAMLprim value mfc_stats(value unit) {
  CAMLparam1(unit);
  CAMLlocal1(result);

  auto [entries, bytes] = MarshalCache::instance().stats();

  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_long(entries));
  Store_field(result, 1, Val_long(bytes));

  CAMLreturn(result);
}

}  // extern "C"


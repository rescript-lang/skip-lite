# Agent Guidelines for skip-lite

This file provides guidelines for AI agents generating or modifying code in this library.

## Project Structure

```
skip-lite/
├── lib/marshal_cache/     # Marshal_cache module
│   ├── marshal_cache_stubs.cpp
│   ├── marshal_cache.ml
│   └── marshal_cache.mli
└── test/                  # Test suite
```

## Critical: OCaml C FFI Safety

This library contains C++ code that interfaces with the OCaml runtime. The OCaml garbage collector (GC) can move values in memory at any allocation point. **Incorrect handling causes memory corruption and segfaults.**

### DO NOT

1. **Do not use `String_val(v)` across allocations**
   ```cpp
   // BAD - s becomes dangling after allocation
   const char* s = String_val(str_val);
   caml_copy_string(other);  // GC may move str_val
   use(s);                   // CRASH
   ```

2. **Do not nest allocations inside `Store_field`**
   ```cpp
   // BAD - tuple address computed before caml_copy_string runs
   Store_field(tuple, 0, caml_copy_string(s));
   ```

3. **Do not raise custom exceptions directly from C**
   ```cpp
   // BAD - complex allocation sequence + longjmp = corruption
   value args = caml_alloc_tuple(2);
   Store_field(args, 0, caml_copy_string(path));
   caml_raise_with_arg(*exn, args);
   ```

4. **Do not assume values survive across `caml_callback*`**
   ```cpp
   // BAD - callback can trigger GC
   value result = caml_callback(closure, arg);
   use(String_val(some_other_value));  // may be stale
   ```

### DO

1. **Copy OCaml strings to C++ strings immediately**
   ```cpp
   std::string s(String_val(str_val));  // Safe copy
   caml_alloc(...);
   use(s.c_str());
   ```

2. **Allocate values before storing**
   ```cpp
   value str = caml_copy_string(s);
   Store_field(tuple, 0, str);
   ```

3. **Raise simple exceptions, convert in OCaml**
   ```cpp
   // C++: raise Failure with structured message
   std::string msg = path + ": " + error;
   caml_failwith(msg.c_str());
   ```
   ```ocaml
   (* OCaml: catch and convert *)
   try ... with Failure msg -> raise (Cache_error (parse msg))
   ```

4. **Use `CAMLparam`/`CAMLlocal` for values that must survive allocations**
   ```cpp
   CAMLparam1(input);
   CAMLlocal2(result, temp);
   // Now result and temp are updated if GC moves them
   ```

## Adding New Modules

When adding new modules to skip-lite:

1. Create a new directory under `lib/` (e.g., `lib/new_module/`)
2. Add a `dune` file with appropriate `(public_name skip-lite.new_module)`
3. Follow the same FFI safety patterns as `Marshal_cache`
4. Add tests in `test/`
5. Update README.md with module documentation

## Testing

Run tests with:
```bash
dune runtest
```

All tests must pass before committing changes.


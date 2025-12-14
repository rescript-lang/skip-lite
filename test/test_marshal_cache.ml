(* Test suite for Marshal_cache *)

let test_dir = Filename.concat (Filename.get_temp_dir_name ()) "mfc_test"
let test_file = Filename.concat test_dir "test.marshal"
let test_file2 = Filename.concat test_dir "test2.marshal"

let tests_passed = ref 0
let tests_failed = ref 0

let test name f =
  Printf.printf "  %s... " name;
  try
    f ();
    incr tests_passed;
    Printf.printf "OK\n%!"
  with e ->
    incr tests_failed;
    Printf.printf "FAILED: %s\n%!" (Printexc.to_string e)

let setup () =
  (* Create test directory *)
  (try Unix.mkdir test_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (* Create a marshalled file with a list *)
  let data = [1; 2; 3; 4; 5] in
  let oc = open_out_bin test_file in
  Marshal.to_channel oc data [];
  close_out oc

let setup_file path data =
  let oc = open_out_bin path in
  Marshal.to_channel oc data [];
  close_out oc

let cleanup () =
  (try Unix.unlink test_file with _ -> ());
  (try Unix.unlink test_file2 with _ -> ());
  (try Unix.rmdir test_dir with _ -> ())

(* Test: Basic read works *)
let test_basic_read () =
  test "basic read" (fun () ->
    Marshal_cache.with_unmarshalled_file test_file (fun (data : int list) ->
      assert (data = [1; 2; 3; 4; 5])
    )
  )

(* Test: Cached read (should not remap) *)
let test_cached_read () =
  test "cached read" (fun () ->
    (* First read *)
    Marshal_cache.with_unmarshalled_file test_file (fun (data : int list) ->
      assert (data = [1; 2; 3; 4; 5])
    );
    (* Second read (should use cache) *)
    Marshal_cache.with_unmarshalled_file test_file (fun (data : int list) ->
      assert (data = [1; 2; 3; 4; 5])
    )
  )

(* Test: Stats show correct values *)
let test_stats () =
  test "stats" (fun () ->
    Marshal_cache.clear ();
    let stats1 = Marshal_cache.stats () in
    assert (stats1.entry_count = 0);
    (* Read a file to populate cache *)
    Marshal_cache.with_unmarshalled_file test_file (fun (_data : int list) ->
      ()
    );
    let stats2 = Marshal_cache.stats () in
    assert (stats2.entry_count = 1);
    assert (stats2.mapped_bytes > 0)
  )

(* Test: Clear removes entries *)
let test_clear () =
  test "clear" (fun () ->
    (* Populate cache *)
    Marshal_cache.with_unmarshalled_file test_file (fun (_data : int list) ->
      ()
    );
    Marshal_cache.clear ();
    let stats = Marshal_cache.stats () in
    assert (stats.entry_count = 0);
    assert (stats.mapped_bytes = 0)
  )

(* Test: File modification detection *)
let test_file_modification () =
  test "file modification detection" (fun () ->
    setup ();
    (* First read *)
    Marshal_cache.with_unmarshalled_file test_file (fun (data : int list) ->
      assert (data = [1; 2; 3; 4; 5])
    );
    (* Small delay to ensure mtime changes *)
    Unix.sleepf 0.01;
    (* Modify the file *)
    let new_data = [10; 20; 30] in
    let oc = open_out_bin test_file in
    Marshal.to_channel oc new_data [];
    close_out oc;
    (* Read again (should detect change) *)
    Marshal_cache.with_unmarshalled_file test_file (fun (data : int list) ->
      assert (data = [10; 20; 30])
    )
  )

(* Test: Invalidate removes specific entry *)
let test_invalidate () =
  test "invalidate" (fun () ->
    Marshal_cache.clear ();
    setup ();
    (* Ensure file is cached *)
    Marshal_cache.with_unmarshalled_file test_file (fun (_data : int list) ->
      ()
    );
    let stats1 = Marshal_cache.stats () in
    assert (stats1.entry_count = 1);
    (* Invalidate *)
    Marshal_cache.invalidate test_file;
    let stats2 = Marshal_cache.stats () in
    assert (stats2.entry_count = 0)
  )

(* Test: Exception in callback is propagated *)
let test_exception_in_callback () =
  test "exception in callback" (fun () ->
    Marshal_cache.clear ();
    setup ();
    let raised = ref false in
    (try
      Marshal_cache.with_unmarshalled_file test_file (fun (_data : int list) ->
        failwith "test exception"
      )
    with Failure msg ->
      assert (msg = "test exception");
      raised := true
    );
    assert !raised;
    (* Cache should still be usable *)
    Marshal_cache.with_unmarshalled_file test_file (fun (data : int list) ->
      assert (List.length data > 0)
    )
  )

(* Test: Missing file raises Cache_error *)
let test_missing_file () =
  test "missing file" (fun () ->
    let test_path = "/nonexistent/path/file.marshal" in
    try
      Marshal_cache.with_unmarshalled_file test_path
        (fun (_data : int list) -> ());
      assert false (* Should not reach here *)
    with
    | Marshal_cache.Cache_error (path, msg) ->
      assert (path = test_path);
      assert (String.length msg > 0)
  )

(* Test: Nested calls to same file work *)
let test_nested_calls () =
  test "nested calls" (fun () ->
    setup ();
    Marshal_cache.with_unmarshalled_file test_file (fun (data1 : int list) ->
      Marshal_cache.with_unmarshalled_file test_file (fun (data2 : int list) ->
        assert (data1 = data2)
      )
    )
  )

(* Test: Multiple files *)
let test_multiple_files () =
  test "multiple files" (fun () ->
    Marshal_cache.clear ();
    setup_file test_file [1; 2; 3];
    setup_file test_file2 ["a"; "b"; "c"];
    Marshal_cache.with_unmarshalled_file test_file (fun (data : int list) ->
      assert (data = [1; 2; 3])
    );
    Marshal_cache.with_unmarshalled_file test_file2 (fun (data : string list) ->
      assert (data = ["a"; "b"; "c"])
    );
    let stats = Marshal_cache.stats () in
    assert (stats.entry_count = 2)
  )

(* Test: LRU eviction *)
let test_lru_eviction () =
  test "LRU eviction" (fun () ->
    Marshal_cache.clear ();
    Marshal_cache.set_max_entries 1;
    setup_file test_file [1; 2; 3];
    setup_file test_file2 [4; 5; 6];
    (* Read first file *)
    Marshal_cache.with_unmarshalled_file test_file (fun (_data : int list) ->
      ()
    );
    let stats1 = Marshal_cache.stats () in
    assert (stats1.entry_count = 1);
    (* Read second file - should evict first *)
    Marshal_cache.with_unmarshalled_file test_file2 (fun (_data : int list) ->
      ()
    );
    let stats2 = Marshal_cache.stats () in
    assert (stats2.entry_count = 1);
    (* Reset max entries *)
    Marshal_cache.set_max_entries 10000
  )

(* Test: Complex data types *)
let test_complex_data () =
  test "complex data types" (fun () ->
    Marshal_cache.clear ();
    let complex_data = {|
      Some complex structure
    |}, ([1;2;3], Some 42, (1.5, "hello")) in
    setup_file test_file complex_data;
    Marshal_cache.with_unmarshalled_file test_file
      (fun (data : string * (int list * int option * (float * string))) ->
        let (s, (lst, opt, (f, str))) = data in
        assert (String.length s > 0);
        assert (lst = [1;2;3]);
        assert (opt = Some 42);
        assert (f = 1.5);
        assert (str = "hello")
      )
  )

(* Test: Return value from callback *)
let test_return_value () =
  test "return value from callback" (fun () ->
    setup ();
    let result = Marshal_cache.with_unmarshalled_file test_file
      (fun (data : int list) ->
        List.fold_left (+) 0 data
      )
    in
    assert (result = 15)  (* 1+2+3+4+5 *)
  )

(* Test: Invalid argument for set_max_entries *)
let test_invalid_max_entries () =
  test "invalid max_entries" (fun () ->
    let raised = ref false in
    (try
      Marshal_cache.set_max_entries (-1)
    with Invalid_argument _ ->
      raised := true
    );
    assert !raised
  )

(* Test: Invalid argument for set_max_bytes *)
let test_invalid_max_bytes () =
  test "invalid max_bytes" (fun () ->
    let raised = ref false in
    (try
      Marshal_cache.set_max_bytes (-1)
    with Invalid_argument _ ->
      raised := true
    );
    assert !raised
  )

(* Test: Empty file raises Failure (not Cache_error, since unmarshal error doesn't include path) *)
let test_empty_file () =
  test "empty file" (fun () ->
    Marshal_cache.clear ();
    let empty_file = Filename.concat test_dir "empty.marshal" in
    (* Create an empty file *)
    let oc = open_out_bin empty_file in
    close_out oc;
    (try
      Marshal_cache.with_unmarshalled_file empty_file
        (fun (_data : int list) -> ());
      assert false (* Should not reach here *)
    with
    | Failure msg ->
      (* Empty file error is raised as Failure("marshal_cache: empty file") *)
      assert (msg = "marshal_cache: empty file")
    );
    (* Cleanup *)
    Unix.unlink empty_file
  )

(* Test: No file descriptor leaks after many operations *)
let test_no_fd_leak () =
  test "no fd leak" (fun () ->
    Marshal_cache.clear ();
    setup ();
    (* Get initial fd count (on macOS/Linux, count entries in /dev/fd or /proc/self/fd) *)
    let count_fds () =
      try
        let dir = if Sys.file_exists "/proc/self/fd" then "/proc/self/fd" else "/dev/fd" in
        Array.length (Sys.readdir dir)
      with _ -> -1  (* Skip test if we can't count fds *)
    in
    let initial_fds = count_fds () in
    if initial_fds < 0 then () else begin
      (* Do many cache operations *)
      for _ = 1 to 100 do
        Marshal_cache.with_unmarshalled_file test_file (fun (_ : int list) -> ());
        Marshal_cache.clear ()
      done;
      let final_fds = count_fds () in
      (* Allow some slack (±5) for other system activity *)
      assert (abs (final_fds - initial_fds) < 5)
    end
  )

(* Test: Concurrent access from multiple domains *)
let test_concurrent_domains () =
  test "concurrent domains" (fun () ->
    Marshal_cache.clear ();
    setup ();
    let n_domains = 4 in
    let iterations = 100 in
    let errors = Atomic.make 0 in

    let worker () =
      for _ = 1 to iterations do
        try
          Marshal_cache.with_unmarshalled_file test_file (fun (data : int list) ->
            (* Do some work *)
            ignore (List.length data)
          )
        with _ ->
          Atomic.incr errors
      done
    in

    (* Spawn domains *)
    let domains = List.init n_domains (fun _ -> Domain.spawn worker) in

    (* Wait for all to complete *)
    List.iter Domain.join domains;

    (* Check no errors *)
    assert (Atomic.get errors = 0);

    (* Cache should still be usable *)
    Marshal_cache.with_unmarshalled_file test_file (fun (data : int list) ->
      assert (List.length data > 0)
    )
  )

(* Test: Concurrent access to different files from different domains *)
let test_concurrent_different_files () =
  test "concurrent different files" (fun () ->
    Marshal_cache.clear ();
    let n_domains = 4 in
    let files_per_domain = 10 in
    let iterations = 20 in

    (* Create files for each domain *)
    let all_files = Array.init (n_domains * files_per_domain) (fun i ->
      let path = Filename.concat test_dir (Printf.sprintf "concurrent_%d.marshal" i) in
      let oc = open_out_bin path in
      Marshal.to_channel oc (List.init 100 (fun j -> i * 1000 + j)) [];
      close_out oc;
      path
    ) in

    let errors = Atomic.make 0 in
    let ops = Atomic.make 0 in

    let worker domain_id =
      let start_idx = domain_id * files_per_domain in
      for _ = 1 to iterations do
        for f = 0 to files_per_domain - 1 do
          let path = all_files.(start_idx + f) in
          try
            Marshal_cache.with_unmarshalled_file path (fun (data : int list) ->
              ignore (List.length data);
              Atomic.incr ops
            )
          with _ ->
            Atomic.incr errors
        done
      done
    in

    let domains = List.init n_domains (fun i -> Domain.spawn (fun () -> worker i)) in
    List.iter Domain.join domains;

    assert (Atomic.get errors = 0);
    assert (Atomic.get ops = n_domains * files_per_domain * iterations);

    (* Cleanup *)
    Array.iter (fun path -> try Unix.unlink path with _ -> ()) all_files
  )

(* Test: Concurrent modifications while other domains are reading.
   This tests that the system doesn't crash or corrupt memory during 
   concurrent file modifications. Some transient errors are expected
   (e.g., reading a partially written file). *)
let test_concurrent_modifications () =
  test "concurrent modifications" (fun () ->
    Marshal_cache.clear ();
    let n_readers = 3 in
    let n_iterations = 50 in

    (* Create initial file *)
    let path = Filename.concat test_dir "concurrent_modify.marshal" in
    let write_file value =
      let oc = open_out_bin path in
      Marshal.to_channel oc (value : int) [];
      close_out oc
    in
    write_file 0;

    let transient_errors = Atomic.make 0 in
    let reads = Atomic.make 0 in
    let stop = Atomic.make false in

    (* Reader worker: continuously read the file *)
    let reader () =
      while not (Atomic.get stop) do
        try
          Marshal_cache.with_unmarshalled_file path (fun (v : int) ->
            (* Value should be a valid int *)
            ignore v;
            Atomic.incr reads
          )
        with
        | Failure _ | Marshal_cache.Cache_error _ ->
          (* Transient errors during concurrent modification are expected *)
          Atomic.incr transient_errors
      done
    in

    (* Writer: modify the file periodically *)
    let writer () =
      for i = 1 to n_iterations do
        write_file i;
        (* Small delay to let readers catch some changes *)
        Unix.sleepf 0.001
      done;
      Atomic.set stop true
    in

    (* Start readers first *)
    let reader_domains = List.init n_readers (fun _ -> Domain.spawn reader) in
    (* Then start writer *)
    let writer_domain = Domain.spawn writer in

    Domain.join writer_domain;
    List.iter Domain.join reader_domains;

    (* Success = no crashes, some reads completed *)
    (* Transient errors during modification are acceptable *)
    assert (Atomic.get reads > 0);

    (* Verify cache is still usable after all the chaos *)
    Marshal_cache.clear ();
    write_file 999;
    Marshal_cache.with_unmarshalled_file path (fun (v : int) ->
      assert (v = 999)
    );

    Unix.unlink path
  )

(* Test: LRU eviction under heavy contention *)
let test_concurrent_eviction () =
  test "concurrent eviction" (fun () ->
    Marshal_cache.clear ();
    (* Set small cache to force eviction *)
    Marshal_cache.set_max_entries 10;

    let n_domains = 4 in
    let n_files = 50 in (* More files than cache size *)
    let iterations = 20 in

    (* Create files *)
    let files = Array.init n_files (fun i ->
      let path = Filename.concat test_dir (Printf.sprintf "evict_%d.marshal" i) in
      let oc = open_out_bin path in
      Marshal.to_channel oc (List.init 10 (fun j -> i * 100 + j)) [];
      close_out oc;
      path
    ) in

    let errors = Atomic.make 0 in

    let worker () =
      for _ = 1 to iterations do
        (* Access random files to trigger eviction *)
        let idx = Random.int n_files in
        try
          Marshal_cache.with_unmarshalled_file files.(idx) (fun (data : int list) ->
            ignore (List.length data)
          )
        with _ ->
          Atomic.incr errors
      done
    in

    let domains = List.init n_domains (fun _ -> Domain.spawn worker) in
    List.iter Domain.join domains;

    assert (Atomic.get errors = 0);

    (* Verify cache stats are consistent *)
    let stats = Marshal_cache.stats () in
    assert (stats.entry_count <= 10);

    (* Reset and cleanup *)
    Marshal_cache.set_max_entries 10000;
    Marshal_cache.clear ();
    Array.iter (fun path -> try Unix.unlink path with _ -> ()) files
  )

(* Test: Race between invalidate and with_unmarshalled_file *)
let test_concurrent_invalidate () =
  test "concurrent invalidate" (fun () ->
    Marshal_cache.clear ();
    let n_readers = 3 in
    let n_iterations = 100 in

    (* Create file *)
    let path = Filename.concat test_dir "concurrent_invalidate.marshal" in
    let oc = open_out_bin path in
    Marshal.to_channel oc ([1; 2; 3; 4; 5] : int list) [];
    close_out oc;

    let errors = Atomic.make 0 in
    let stop = Atomic.make false in

    (* Reader: continuously read *)
    let reader () =
      while not (Atomic.get stop) do
        try
          Marshal_cache.with_unmarshalled_file path (fun (data : int list) ->
            ignore (List.length data)
          )
        with _ ->
          Atomic.incr errors
      done
    in

    (* Invalidator: continuously invalidate *)
    let invalidator () =
      for _ = 1 to n_iterations do
        Marshal_cache.invalidate path
      done;
      Atomic.set stop true
    in

    let reader_domains = List.init n_readers (fun _ -> Domain.spawn reader) in
    let invalidator_domain = Domain.spawn invalidator in

    Domain.join invalidator_domain;
    List.iter Domain.join reader_domains;

    assert (Atomic.get errors = 0);
    Unix.unlink path
  )

(* Test: with_unmarshalled_if_changed returns Some on first access *)
let test_if_changed_first_access () =
  test "if_changed first access" (fun () ->
    Marshal_cache.clear ();
    setup ();
    let result = Marshal_cache.with_unmarshalled_if_changed test_file
      (fun (data : int list) -> List.length data)
    in
    assert (result = Some 5)
  )

(* Test: with_unmarshalled_if_changed returns None on unchanged file *)
let test_if_changed_unchanged () =
  test "if_changed unchanged" (fun () ->
    Marshal_cache.clear ();
    setup ();
    (* First access - should return Some *)
    let r1 = Marshal_cache.with_unmarshalled_if_changed test_file
      (fun (data : int list) -> List.length data)
    in
    assert (r1 = Some 5);
    (* Second access - should return None (unchanged) *)
    let r2 = Marshal_cache.with_unmarshalled_if_changed test_file
      (fun (_ : int list) -> failwith "should not be called")
    in
    assert (r2 = None)
  )

(* Test: with_unmarshalled_if_changed returns Some after file modification *)
let test_if_changed_after_modification () =
  test "if_changed after modification" (fun () ->
    Marshal_cache.clear ();
    setup ();
    (* First access *)
    let _ = Marshal_cache.with_unmarshalled_if_changed test_file
      (fun (_ : int list) -> ())
    in
    (* Modify the file *)
    Unix.sleepf 0.01;
    let new_data = [10; 20; 30] in
    let oc = open_out_bin test_file in
    Marshal.to_channel oc new_data [];
    close_out oc;
    (* Next access - should return Some (file changed) *)
    let result = Marshal_cache.with_unmarshalled_if_changed test_file
      (fun (data : int list) -> data)
    in
    assert (result = Some [10; 20; 30])
  )

(* Test: with_unmarshalled_if_changed works with regular with_unmarshalled_file *)
let test_if_changed_interop () =
  test "if_changed interop" (fun () ->
    Marshal_cache.clear ();
    setup ();
    (* Access with regular function first *)
    Marshal_cache.with_unmarshalled_file test_file (fun (_ : int list) -> ());
    (* if_changed should return None (already accessed) *)
    let result = Marshal_cache.with_unmarshalled_if_changed test_file
      (fun (_ : int list) -> failwith "should not be called")
    in
    assert (result = None)
  )

let () =
  Printf.printf "=== Marshal_cache Tests ===\n%!";
  setup ();
  (try
    test_basic_read ();
    test_cached_read ();
    test_stats ();
    test_clear ();
    test_file_modification ();
    test_invalidate ();
    test_exception_in_callback ();
    test_missing_file ();
    test_nested_calls ();
    test_multiple_files ();
    test_lru_eviction ();
    test_complex_data ();
    test_return_value ();
    test_invalid_max_entries ();
    test_invalid_max_bytes ();
    test_empty_file ();
    test_no_fd_leak ();
    test_concurrent_domains ();
    test_concurrent_different_files ();
    test_concurrent_modifications ();
    test_concurrent_eviction ();
    test_concurrent_invalidate ();
    test_if_changed_first_access ();
    test_if_changed_unchanged ();
    test_if_changed_after_modification ();
    test_if_changed_interop ();
  with e ->
    Printf.printf "Unexpected error: %s\n%!" (Printexc.to_string e)
  );
  cleanup ();
  Printf.printf "=== Results: %d passed, %d failed ===\n%!" !tests_passed !tests_failed;
  if !tests_failed > 0 then exit 1


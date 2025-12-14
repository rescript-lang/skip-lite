(* Realistic benchmark: 1000 files of ~10KB each, with incremental changes *)

let test_dir = Filename.concat (Filename.get_temp_dir_name ()) "mfc_realistic_bench"
let n_files = 10000
let file_size = 40 * 1024  (* target ~20KB actual after marshal *)
let n_iterations = 10
let changes_per_iteration = 10  (* 1% of files change each iteration *)

let files = Array.init n_files (fun i ->
  Filename.concat test_dir (Printf.sprintf "file_%04d.marshal" i)
)

(* Generate data of approximate size *)
let make_data ~target_bytes ~seed =
  let n = target_bytes / 8 in
  List.init n (fun i -> seed + i)

let setup () =
  Printf.printf "Setting up %d files...\n%!" n_files;
  (try Unix.mkdir test_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Array.iteri (fun i path ->
    let oc = open_out_bin path in
    Marshal.to_channel oc (make_data ~target_bytes:file_size ~seed:i) [];
    close_out oc
  ) files;
  (* Measure actual file sizes *)
  let total_bytes = Array.fold_left (fun acc path ->
    acc + (Unix.stat path).Unix.st_size
  ) 0 files in
  let avg_size = total_bytes / n_files in
  Printf.printf "Setup complete. Total size: %d MB (%d files × %d KB avg)\n%!"
    (total_bytes / 1024 / 1024) n_files (avg_size / 1024)

let cleanup () =
  Array.iter (fun path -> try Unix.unlink path with _ -> ()) files;
  (try Unix.rmdir test_dir with _ -> ())

(* Load all files using Marshal.from_channel *)
let load_all_from_channel () =
  Array.iter (fun path ->
    let ic = open_in_bin path in
    let (_ : int list) = Marshal.from_channel ic in
    close_in ic
  ) files

(* Load all files using Marshal_cache *)
let load_all_cached () =
  Array.iter (fun path ->
    Marshal_cache.with_unmarshalled_file path (fun (_ : int list) -> ())
  ) files

(* Load all files using reactive API - only unmarshal changed files *)
(* Store actual data to show realistic memory usage *)
let result_cache : (string, int list) Hashtbl.t = Hashtbl.create n_files

let load_all_reactive () =
  Array.iter (fun path ->
    match Marshal_cache.with_unmarshalled_if_changed path (fun (data : int list) -> data) with
    | Some result -> Hashtbl.replace result_cache path result
    | None -> ()  (* unchanged, keep cached result *)
  ) files

(* Load only known-changed files (simulates file watcher scenario) *)
let load_known_changed indices =
  List.iter (fun i ->
    let path = files.(i) in
    let result = Marshal_cache.with_unmarshalled_file path (fun (data : int list) -> data) in
    Hashtbl.replace result_cache path result
  ) indices

(* Modify a random subset of files *)
let modify_files indices =
  List.iter (fun i ->
    let path = files.(i) in
    let oc = open_out_bin path in
    (* Use current time as seed to get different data *)
    let seed = int_of_float (Unix.gettimeofday () *. 1000000.) + i in
    Marshal.to_channel oc (make_data ~target_bytes:file_size ~seed) [];
    close_out oc
  ) indices

(* Generate random indices for files to modify *)
let random_indices n max_val =
  let rec loop acc remaining =
    if remaining = 0 then acc
    else
      let idx = Random.int max_val in
      if List.mem idx acc then loop acc remaining
      else loop (idx :: acc) (remaining - 1)
  in
  loop [] n

let time_it name f =
  let start = Unix.gettimeofday () in
  f ();
  let elapsed = Unix.gettimeofday () -. start in
  Printf.printf "  %s: %.1f ms\n%!" name (elapsed *. 1000.0);
  elapsed

(* Measure just stat() overhead *)
let stat_all_files () =
  Array.iter (fun path -> ignore (Unix.stat path)) files

let print_memory_stats label =
  let stats = Marshal_cache.stats () in
  let gc_stats = Gc.stat () in
  Printf.printf "  %s:\n%!" label;
  Printf.printf "    mmap cache: %d entries, %.2f MB (off-heap, not GC scanned)\n%!"
    stats.Marshal_cache.entry_count
    (float stats.Marshal_cache.mapped_bytes /. 1024.0 /. 1024.0);
  Printf.printf "    OCaml heap: %.2f MB live, %.2f MB total (GC scanned)\n%!"
    (float (gc_stats.Gc.live_words * 8) /. 1024.0 /. 1024.0)
    (float (gc_stats.Gc.heap_words * 8) /. 1024.0 /. 1024.0);
  Printf.printf "    user result cache: %d entries (on OCaml heap)\n%!" (Hashtbl.length result_cache)

let () =
  Printf.printf "=== Realistic Marshal_cache Benchmark ===\n\n%!";
  Random.self_init ();
  setup ();

  (* Benchmark 1: Cold load all files *)
  Printf.printf "Benchmark 1: Load all %d files (cold)\n%!" n_files;
  let t_channel_cold = time_it "Marshal.from_channel" load_all_from_channel in

  Marshal_cache.clear ();
  let t_cache_cold = time_it "Marshal_cache (cold)" load_all_cached in

  (* Benchmark 2a: Warm load all files *)
  Printf.printf "\nBenchmark 2a: Load all %d files (warm cache)\n%!" n_files;
  let t_cache_warm = time_it "Marshal_cache (warm)" load_all_cached in

  (* Measure stat() overhead *)
  let t_stat = time_it "stat() only (1000 files)" stat_all_files in

  (* Benchmark 2b: Reactive (if_changed) on warm cache - no changes *)
  Printf.printf "\nBenchmark 2b: Load all %d files (reactive, no changes)\n%!" n_files;
  (* Prime reactive cache *)
  load_all_reactive ();
  let t_reactive = time_it "with_unmarshalled_if_changed" load_all_reactive in

  Printf.printf "\n  Cold speedup: %.2fx\n%!" (t_channel_cold /. t_cache_cold);
  Printf.printf "  Warm speedup: %.2fx\n%!" (t_channel_cold /. t_cache_warm);
  Printf.printf "  Reactive speedup (no changes): %.2fx\n%!" (t_channel_cold /. t_reactive);
  Printf.printf "  stat() overhead: %.1f%% of warm cache time\n%!" (t_stat /. t_cache_warm *. 100.0);

  (* Benchmark 3: Incremental updates - each approach runs in ISOLATION *)
  Printf.printf "\nBenchmark 3: %d iterations, %d file changes per iteration\n%!"
    n_iterations changes_per_iteration;
  Printf.printf "  (each approach runs in isolation for fair cache locality comparison)\n\n%!";

  (* Pre-generate all the random indices for reproducibility *)
  let all_indices = Array.init n_iterations (fun _ ->
    random_indices changes_per_iteration n_files
  ) in

  (* Helper to reset files to initial state *)
  let reset_files () =
    Array.iteri (fun i path ->
      let oc = open_out_bin path in
      Marshal.to_channel oc (make_data ~target_bytes:file_size ~seed:i) [];
      close_out oc
    ) files
  in

  (* Run one approach in isolation *)
  let run_isolated name prime_fn iter_fn =
    Printf.printf "  Running: %s\n%!" name;
    reset_files ();
    prime_fn ();
    let total = ref 0.0 in
    for iter = 0 to n_iterations - 1 do
      let indices = all_indices.(iter) in
      modify_files indices;
      let t1 = Unix.gettimeofday () in
      iter_fn indices;
      let t = Unix.gettimeofday () -. t1 in
      total := !total +. t
    done;
    !total
  in

  (* 1. Marshal.from_channel baseline *)
  let t_channel = run_isolated "Marshal.from_channel"
    (fun () -> ())
    (fun _ -> load_all_from_channel ())
  in

  (* 2. with_unmarshalled_file (cache, always unmarshal) *)
  let t_cache = run_isolated "with_unmarshalled_file"
    (fun () -> Marshal_cache.clear (); load_all_cached ())
    (fun _ -> load_all_cached ())
  in

  (* 3. with_unmarshalled_if_changed (stats all, unmarshal changed) *)
  let t_reactive = run_isolated "with_unmarshalled_if_changed"
    (fun () -> Marshal_cache.clear (); Hashtbl.clear result_cache; load_all_reactive ())
    (fun _ -> load_all_reactive ())
  in

  (* 4. Known-changed only (file watcher scenario) *)
  let t_known = run_isolated "known-changed only"
    (fun () -> Marshal_cache.clear (); Hashtbl.clear result_cache; load_all_reactive ())
    (fun indices -> load_known_changed indices)
  in

  Printf.printf "\n  --- Summary ---\n%!";
  Printf.printf "  Total time (Marshal.from_channel):        %.1f ms\n%!" (t_channel *. 1000.0);
  Printf.printf "  Total time (with_unmarshalled_file):      %.1f ms\n%!" (t_cache *. 1000.0);
  Printf.printf "  Total time (with_unmarshalled_if_changed): %.1f ms (stats all files)\n%!" (t_reactive *. 1000.0);
  Printf.printf "  Total time (known-changed only):          %.2f ms (no stat)\n%!" (t_known *. 1000.0);
  Printf.printf "\n  Speedup vs Marshal.from_channel:\n%!";
  Printf.printf "    with_unmarshalled_file:       %.1fx\n%!" (t_channel /. t_cache);
  Printf.printf "    with_unmarshalled_if_changed: %.1fx\n%!" (t_channel /. t_reactive);
  Printf.printf "    known-changed only:           %.0fx\n%!" (t_channel /. t_known);
  Printf.printf "\n  Average per iteration:\n%!";
  Printf.printf "    Marshal.from_channel:          %.1f ms\n%!"
    (t_channel *. 1000.0 /. float n_iterations);
  Printf.printf "    with_unmarshalled_file:        %.1f ms\n%!"
    (t_cache *. 1000.0 /. float n_iterations);
  Printf.printf "    with_unmarshalled_if_changed:  %.1f ms\n%!"
    (t_reactive *. 1000.0 /. float n_iterations);
  Printf.printf "    known-changed only:            %.2f ms (%d files)\n%!"
    (t_known *. 1000.0 /. float n_iterations) changes_per_iteration;

  (* Memory stats - measure BEFORE cleanup deletes files *)
  Gc.full_major ();  (* Clean up before measuring *)
  Printf.printf "\n  --- Memory Usage ---\n%!";
  Printf.printf "  (Note: mmap cache holds file bytes off-heap; user result cache is on-heap)\n%!";
  print_memory_stats "After benchmark";

  (* Show what it would look like if you kept unmarshalled data on-heap *)
  Printf.printf "\n  For comparison, if all 1000 files' data were kept on OCaml heap:\n%!";
  Printf.printf "    Would add ~%.1f MB to GC-scanned heap\n%!"
    (float (n_files * file_size) /. 1024.0 /. 1024.0);

  cleanup ();
  Printf.printf "\n=== Benchmark Complete ===\n%!"


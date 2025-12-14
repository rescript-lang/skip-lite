(* Realistic benchmark: 1000 files of ~10KB each, with incremental changes *)

let test_dir = Filename.concat (Filename.get_temp_dir_name ()) "mfc_realistic_bench"
let n_files = 1000
let file_size = 10 * 1024  (* ~10KB each *)
let n_iterations = 100
let changes_per_iteration = 10  (* 1% of files change each iteration *)

let files = Array.init n_files (fun i ->
  Filename.concat test_dir (Printf.sprintf "file_%04d.marshal" i)
)

(* Generate data of approximate size *)
let make_data ~target_bytes ~seed =
  let n = target_bytes / 8 in
  List.init n (fun i -> seed + i)

let setup () =
  Printf.printf "Setting up %d files of ~%dKB each...\n%!" n_files (file_size / 1024);
  (try Unix.mkdir test_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Array.iteri (fun i path ->
    let oc = open_out_bin path in
    Marshal.to_channel oc (make_data ~target_bytes:file_size ~seed:i) [];
    close_out oc
  ) files;
  Printf.printf "Setup complete. Total size: ~%dMB\n%!" (n_files * file_size / 1024 / 1024)

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
let result_cache : (string, int) Hashtbl.t = Hashtbl.create n_files

let load_all_reactive () =
  Array.iter (fun path ->
    match Marshal_cache.with_unmarshalled_if_changed path (fun (data : int list) -> List.length data) with
    | Some result -> Hashtbl.replace result_cache path result
    | None -> ()  (* unchanged, keep cached result *)
  ) files

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

let () =
  Printf.printf "=== Realistic Marshal_cache Benchmark ===\n\n%!";
  Random.self_init ();
  setup ();

  (* Benchmark 1: Cold load all files *)
  Printf.printf "Benchmark 1: Load all %d files (cold)\n%!" n_files;
  let t_channel_cold = time_it "Marshal.from_channel" load_all_from_channel in

  Marshal_cache.clear ();
  let t_cache_cold = time_it "Marshal_cache (cold)" load_all_cached in

  (* Benchmark 2: Warm load all files *)
  Printf.printf "\nBenchmark 2: Load all %d files (warm cache)\n%!" n_files;
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

  (* Benchmark 3: Incremental updates *)
  Printf.printf "\nBenchmark 3: %d iterations, %d file changes per iteration\n%!"
    n_iterations changes_per_iteration;
  Printf.printf "  (simulates incremental build with 1%% of files changing)\n\n%!";

  (* Reset for fair comparison *)
  Marshal_cache.clear ();

  (* Warm up cache first *)
  load_all_cached ();

  let total_channel = ref 0.0 in
  let total_cache = ref 0.0 in
  let total_reactive = ref 0.0 in

  (* Prime the reactive cache *)
  Hashtbl.clear result_cache;
  load_all_reactive ();

  for iter = 1 to n_iterations do
    (* Modify some files *)
    let indices = random_indices changes_per_iteration n_files in
    modify_files indices;

    (* Time loading all files with Marshal.from_channel *)
    let t1 = Unix.gettimeofday () in
    load_all_from_channel ();
    let t_channel = Unix.gettimeofday () -. t1 in
    total_channel := !total_channel +. t_channel;

    (* Time loading all files with cache (always unmarshals) *)
    let t2 = Unix.gettimeofday () in
    load_all_cached ();
    let t_cache = Unix.gettimeofday () -. t2 in
    total_cache := !total_cache +. t_cache;

    (* Time loading with reactive API (only unmarshal changed files) *)
    let t3 = Unix.gettimeofday () in
    load_all_reactive ();
    let t_reactive = Unix.gettimeofday () -. t3 in
    total_reactive := !total_reactive +. t_reactive;

    if iter mod 20 = 0 then
      Printf.printf "  Iteration %d/%d: channel=%.1fms, cache=%.1fms, reactive=%.1fms\n%!"
        iter n_iterations (t_channel *. 1000.0) (t_cache *. 1000.0) (t_reactive *. 1000.0)
  done;

  Printf.printf "\n  --- Summary ---\n%!";
  Printf.printf "  Total time (Marshal.from_channel):       %.1f ms\n%!" (!total_channel *. 1000.0);
  Printf.printf "  Total time (with_unmarshalled_file):     %.1f ms\n%!" (!total_cache *. 1000.0);
  Printf.printf "  Total time (with_unmarshalled_if_changed): %.1f ms\n%!" (!total_reactive *. 1000.0);
  Printf.printf "\n  Speedup vs Marshal.from_channel:\n%!";
  Printf.printf "    with_unmarshalled_file:      %.1fx\n%!" (!total_channel /. !total_cache);
  Printf.printf "    with_unmarshalled_if_changed: %.1fx\n%!" (!total_channel /. !total_reactive);
  Printf.printf "\n  Average per iteration:\n%!";
  Printf.printf "    Marshal.from_channel:          %.1f ms\n%!"
    (!total_channel *. 1000.0 /. float n_iterations);
  Printf.printf "    with_unmarshalled_file:        %.1f ms\n%!"
    (!total_cache *. 1000.0 /. float n_iterations);
  Printf.printf "    with_unmarshalled_if_changed:  %.1f ms\n%!"
    (!total_reactive *. 1000.0 /. float n_iterations);

  cleanup ();
  Printf.printf "\n=== Benchmark Complete ===\n%!"


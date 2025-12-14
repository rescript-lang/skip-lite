(* Benchmark for Reactive_file_collection *)

let test_dir = Filename.concat (Filename.get_temp_dir_name ()) "rfc_bench"
let n_files = 10000
let file_size = 40 * 1024  (* target ~20KB actual after marshal *)
let n_iterations = 10
let changes_per_iteration = 10

let files = Array.init n_files (fun i ->
  Filename.concat test_dir (Printf.sprintf "file_%05d.marshal" i)
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

(* Modify a random subset of files *)
let modify_files indices =
  List.iter (fun i ->
    let path = files.(i) in
    let oc = open_out_bin path in
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

let time_ms f =
  let start = Unix.gettimeofday () in
  f ();
  (Unix.gettimeofday () -. start) *. 1000.0

(* Processing function: compute sum of list *)
let process (data : int list) = List.fold_left (+) 0 data

let () =
  Printf.printf "=== Reactive_file_collection Benchmark ===\n\n%!";
  Random.self_init ();
  setup ();

  (* Create collection *)
  let coll = Reactive_file_collection.create ~process in

  (* Benchmark 1: Initial load *)
  Printf.printf "Benchmark 1: Initial load (%d files)\n%!" n_files;
  let t_load = time_ms (fun () ->
    Array.iter (fun path -> Reactive_file_collection.add coll path) files
  ) in
  Printf.printf "  Load time: %.1f ms\n%!" t_load;
  Printf.printf "  Collection size: %d entries\n%!" (Reactive_file_collection.length coll);

  (* Benchmark 2: Pure iteration (no file I/O) *)
  Printf.printf "\nBenchmark 2: Pure iteration (no file I/O)\n%!";
  let t_iter = time_ms (fun () ->
    let sum = ref 0 in
    Reactive_file_collection.iter (fun _ v -> sum := !sum + v) coll;
    ignore !sum
  ) in
  Printf.printf "  Iteration time: %.2f ms\n%!" t_iter;

  (* Benchmark 3: Compare with file-based approaches *)
  Printf.printf "\nBenchmark 3: Comparison (reading all values)\n%!";
  
  (* Marshal.from_channel baseline *)
  let t_channel = time_ms (fun () ->
    Array.iter (fun path ->
      let ic = open_in_bin path in
      let data : int list = Marshal.from_channel ic in
      close_in ic;
      ignore (process data)
    ) files
  ) in
  Printf.printf "  Marshal.from_channel: %.1f ms\n%!" t_channel;

  (* with_unmarshalled_file *)
  Marshal_cache.clear ();
  let _ = time_ms (fun () ->  (* warm up *)
    Array.iter (fun path ->
      Marshal_cache.with_unmarshalled_file path (fun data -> ignore (process data))
    ) files
  ) in
  let t_cache = time_ms (fun () ->
    Array.iter (fun path ->
      Marshal_cache.with_unmarshalled_file path (fun data -> ignore (process data))
    ) files
  ) in
  Printf.printf "  with_unmarshalled_file (warm): %.1f ms\n%!" t_cache;

  (* Collection iteration *)
  let t_coll = time_ms (fun () ->
    Reactive_file_collection.iter (fun _ v -> ignore v) coll
  ) in
  Printf.printf "  Reactive_file_collection.iter: %.2f ms\n%!" t_coll;

  Printf.printf "\n  Speedup vs Marshal.from_channel:\n%!";
  Printf.printf "    with_unmarshalled_file: %.1fx\n%!" (t_channel /. t_cache);
  Printf.printf "    Collection iteration:   %.0fx\n%!" (t_channel /. t_coll);

  (* Benchmark 4: Incremental updates *)
  Printf.printf "\nBenchmark 4: Incremental updates (%d iterations, %d changes each)\n%!"
    n_iterations changes_per_iteration;

  (* Pre-generate random indices *)
  let all_indices = Array.init n_iterations (fun _ ->
    random_indices changes_per_iteration n_files
  ) in

  let total_update = ref 0.0 in
  let total_iter = ref 0.0 in

  for iter = 0 to n_iterations - 1 do
    let indices = all_indices.(iter) in
    modify_files indices;

    (* Update collection *)
    let t_update = time_ms (fun () ->
      List.iter (fun i ->
        Reactive_file_collection.update coll files.(i)
      ) indices
    ) in
    total_update := !total_update +. t_update;

    (* Iterate to "use" the values *)
    let t_iter = time_ms (fun () ->
      Reactive_file_collection.iter (fun _ v -> ignore v) coll
    ) in
    total_iter := !total_iter +. t_iter;

    Printf.printf "  Iter %d/%d: update=%.2fms, iterate=%.2fms, total=%.2fms\n%!"
      (iter + 1) n_iterations t_update t_iter (t_update +. t_iter)
  done;

  Printf.printf "\n  --- Summary ---\n%!";
  Printf.printf "  Average per iteration:\n%!";
  Printf.printf "    Update (%d files):  %.2f ms\n%!" 
    changes_per_iteration (!total_update /. float n_iterations);
  Printf.printf "    Iterate (%d files): %.2f ms\n%!" 
    n_files (!total_iter /. float n_iterations);
  Printf.printf "    Total:              %.2f ms\n%!"
    ((!total_update +. !total_iter) /. float n_iterations);

  Printf.printf "\n  Comparison (per iteration):\n%!";
  Printf.printf "    Marshal.from_channel (all):   %.1f ms\n%!" t_channel;
  Printf.printf "    Reactive_file_collection:     %.2f ms\n%!"
    ((!total_update +. !total_iter) /. float n_iterations);
  Printf.printf "    Speedup: %.0fx\n%!"
    (t_channel /. ((!total_update +. !total_iter) /. float n_iterations));

  (* Memory stats *)
  Gc.full_major ();
  let gc_stats = Gc.stat () in
  let cache_stats = Marshal_cache.stats () in
  Printf.printf "\n  --- Memory Usage ---\n%!";
  Printf.printf "    mmap cache: %d entries, %.1f MB (off-heap)\n%!"
    cache_stats.Marshal_cache.entry_count
    (float cache_stats.Marshal_cache.mapped_bytes /. 1024.0 /. 1024.0);
  Printf.printf "    OCaml heap: %.1f MB live\n%!"
    (float (gc_stats.Gc.live_words * 8) /. 1024.0 /. 1024.0);
  Printf.printf "    Collection: %d entries\n%!" (Reactive_file_collection.length coll);

  cleanup ();
  Printf.printf "\n=== Benchmark Complete ===\n%!"


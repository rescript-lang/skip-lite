(* Benchmark: Marshal_cache vs Marshal.from_channel *)

let test_dir = Filename.concat (Filename.get_temp_dir_name ()) "mfc_bench"
let small_file = Filename.concat test_dir "small.marshal"
let medium_file = Filename.concat test_dir "medium.marshal"
let large_file = Filename.concat test_dir "large.marshal"

(* Generate test data of approximate size *)
let make_data ~target_bytes =
  (* Each int in a list is ~8 bytes in marshal format *)
  let n = target_bytes / 8 in
  List.init n (fun i -> i)

let setup () =
  (try Unix.mkdir test_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

  (* Small: ~1KB *)
  let oc = open_out_bin small_file in
  Marshal.to_channel oc (make_data ~target_bytes:1024) [];
  close_out oc;

  (* Medium: ~100KB *)
  let oc = open_out_bin medium_file in
  Marshal.to_channel oc (make_data ~target_bytes:(100 * 1024)) [];
  close_out oc;

  (* Large: ~1MB *)
  let oc = open_out_bin large_file in
  Marshal.to_channel oc (make_data ~target_bytes:(1024 * 1024)) [];
  close_out oc

let cleanup () =
  (try Unix.unlink small_file with _ -> ());
  (try Unix.unlink medium_file with _ -> ());
  (try Unix.unlink large_file with _ -> ());
  (try Unix.rmdir test_dir with _ -> ())

(* Benchmark using Marshal.from_channel (baseline) *)
let bench_from_channel path iterations =
  let start = Unix.gettimeofday () in
  for _ = 1 to iterations do
    let ic = open_in_bin path in
    let (_ : int list) = Marshal.from_channel ic in
    close_in ic
  done;
  Unix.gettimeofday () -. start

(* Benchmark using Marshal_cache (cached) *)
let bench_cache_cold path iterations =
  let start = Unix.gettimeofday () in
  for _ = 1 to iterations do
    Marshal_cache.clear ();  (* Force cold read each time *)
    Marshal_cache.with_unmarshalled_file path (fun (_ : int list) -> ())
  done;
  Unix.gettimeofday () -. start

let bench_cache_warm path iterations =
  (* Prime the cache *)
  Marshal_cache.with_unmarshalled_file path (fun (_ : int list) -> ());
  let start = Unix.gettimeofday () in
  for _ = 1 to iterations do
    Marshal_cache.with_unmarshalled_file path (fun (_ : int list) -> ())
  done;
  Unix.gettimeofday () -. start

let run_benchmark name path iterations =
  Printf.printf "\n%s (%d iterations):\n" name iterations;

  let t_channel = bench_from_channel path iterations in
  Printf.printf "  Marshal.from_channel:  %.3f ms (%.3f ms/iter)\n"
    (t_channel *. 1000.0) (t_channel *. 1000.0 /. float iterations);

  let t_cold = bench_cache_cold path iterations in
  Printf.printf "  Marshal_cache (cold):  %.3f ms (%.3f ms/iter)\n"
    (t_cold *. 1000.0) (t_cold *. 1000.0 /. float iterations);

  let t_warm = bench_cache_warm path iterations in
  Printf.printf "  Marshal_cache (warm):  %.3f ms (%.3f ms/iter)\n"
    (t_warm *. 1000.0) (t_warm *. 1000.0 /. float iterations);

  let speedup = t_channel /. t_warm in
  Printf.printf "  Speedup (warm vs channel): %.1fx\n" speedup

let () =
  Printf.printf "=== Marshal_cache Benchmark ===\n";
  setup ();
  Marshal_cache.clear ();

  (* Get file sizes *)
  let size path =
    let st = Unix.stat path in
    st.Unix.st_size
  in
  Printf.printf "\nFile sizes:\n";
  Printf.printf "  small:  %d bytes\n" (size small_file);
  Printf.printf "  medium: %d bytes\n" (size medium_file);
  Printf.printf "  large:  %d bytes\n" (size large_file);

  run_benchmark "Small (~1KB)" small_file 1000;
  run_benchmark "Medium (~100KB)" medium_file 100;
  run_benchmark "Large (~1MB)" large_file 10;

  cleanup ();
  Printf.printf "\n=== Benchmark Complete ===\n"


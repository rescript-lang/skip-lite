(* Tests for Reactive_file_collection *)

let test_dir = Filename.concat (Filename.get_temp_dir_name ()) "rfc_test"

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
  (try Unix.mkdir test_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let cleanup () =
  let files = try Sys.readdir test_dir with _ -> [||] in
  Array.iter (fun f -> 
    try Unix.unlink (Filename.concat test_dir f) with _ -> ()
  ) files;
  (try Unix.rmdir test_dir with _ -> ())

let write_file path data =
  let oc = open_out_bin path in
  Marshal.to_channel oc data [];
  close_out oc

let file_path name = Filename.concat test_dir name

(* Test: Create empty collection *)
let test_create_empty () =
  test "create empty" (fun () ->
    let coll = Reactive_file_collection.create ~process:(fun (x : int) -> x * 2) in
    assert (Reactive_file_collection.is_empty coll);
    assert (Reactive_file_collection.length coll = 0)
  )

(* Test: Add and get *)
let test_add_get () =
  test "add and get" (fun () ->
    let path = file_path "test1.marshal" in
    write_file path 42;
    
    let coll = Reactive_file_collection.create ~process:(fun (x : int) -> x * 2) in
    Reactive_file_collection.add coll path;
    
    assert (Reactive_file_collection.length coll = 1);
    assert (Reactive_file_collection.get coll path = Some 84);
    assert (Reactive_file_collection.mem coll path)
  )

(* Test: Remove *)
let test_remove () =
  test "remove" (fun () ->
    let path = file_path "test2.marshal" in
    write_file path 10;
    
    let coll = Reactive_file_collection.create ~process:(fun (x : int) -> x + 1) in
    Reactive_file_collection.add coll path;
    assert (Reactive_file_collection.length coll = 1);
    
    Reactive_file_collection.remove coll path;
    assert (Reactive_file_collection.length coll = 0);
    assert (Reactive_file_collection.get coll path = None)
  )

(* Test: Update *)
let test_update () =
  test "update" (fun () ->
    let path = file_path "test3.marshal" in
    write_file path 5;
    
    let coll = Reactive_file_collection.create ~process:(fun (x : int) -> x * 10) in
    Reactive_file_collection.add coll path;
    assert (Reactive_file_collection.get coll path = Some 50);
    
    (* Modify file *)
    write_file path 7;
    Reactive_file_collection.update coll path;
    assert (Reactive_file_collection.get coll path = Some 70)
  )

(* Test: Apply batch events *)
let test_apply_batch () =
  test "apply batch" (fun () ->
    let path1 = file_path "batch1.marshal" in
    let path2 = file_path "batch2.marshal" in
    let path3 = file_path "batch3.marshal" in
    write_file path1 1;
    write_file path2 2;
    write_file path3 3;
    
    let coll = Reactive_file_collection.create ~process:(fun (x : int) -> x) in
    
    (* Add all three *)
    Reactive_file_collection.apply coll [
      Reactive_file_collection.Added path1;
      Reactive_file_collection.Added path2;
      Reactive_file_collection.Added path3;
    ];
    assert (Reactive_file_collection.length coll = 3);
    
    (* Modify one, remove one *)
    write_file path1 100;
    Reactive_file_collection.apply coll [
      Reactive_file_collection.Modified path1;
      Reactive_file_collection.Removed path2;
    ];
    assert (Reactive_file_collection.length coll = 2);
    assert (Reactive_file_collection.get coll path1 = Some 100);
    assert (Reactive_file_collection.get coll path2 = None);
    assert (Reactive_file_collection.get coll path3 = Some 3)
  )

(* Test: Iteration *)
let test_iteration () =
  test "iteration" (fun () ->
    let path1 = file_path "iter1.marshal" in
    let path2 = file_path "iter2.marshal" in
    write_file path1 10;
    write_file path2 20;
    
    let coll = Reactive_file_collection.create ~process:(fun (x : int) -> x) in
    Reactive_file_collection.add coll path1;
    Reactive_file_collection.add coll path2;
    
    let sum = ref 0 in
    Reactive_file_collection.iter (fun _ v -> sum := !sum + v) coll;
    assert (!sum = 30);
    
    let total = Reactive_file_collection.fold (fun _ v acc -> v + acc) coll 0 in
    assert (total = 30);
    
    let values = Reactive_file_collection.values coll in
    assert (List.length values = 2);
    assert (List.mem 10 values);
    assert (List.mem 20 values)
  )

(* Test: Complex data types *)
let test_complex_data () =
  test "complex data" (fun () ->
    let path = file_path "complex.marshal" in
    let data = (["a"; "b"; "c"], Some 42, (1.5, true)) in
    write_file path data;
    
    let coll = Reactive_file_collection.create 
      ~process:(fun (lst, opt, (f, b)) -> 
        (List.length lst, opt, f, b)
      ) 
    in
    Reactive_file_collection.add coll path;
    
    match Reactive_file_collection.get coll path with
    | Some (len, opt, f, b) ->
      assert (len = 3);
      assert (opt = Some 42);
      assert (f = 1.5);
      assert (b = true)
    | None -> assert false
  )

(* Test: Error handling - missing file *)
let test_missing_file () =
  test "missing file error" (fun () ->
    let coll = Reactive_file_collection.create ~process:(fun (x : int) -> x) in
    let raised = ref false in
    (try
      Reactive_file_collection.add coll "/nonexistent/file.marshal"
    with Marshal_cache.Cache_error _ ->
      raised := true
    );
    assert !raised
  )

(* Test: find raises Not_found *)
let test_find_not_found () =
  test "find Not_found" (fun () ->
    let coll = Reactive_file_collection.create ~process:(fun (x : int) -> x) in
    let raised = ref false in
    (try
      let _ = Reactive_file_collection.find coll "nonexistent" in ()
    with Not_found ->
      raised := true
    );
    assert !raised
  )

(* Test: to_list and paths *)
let test_to_list_paths () =
  test "to_list and paths" (fun () ->
    let path1 = file_path "list1.marshal" in
    let path2 = file_path "list2.marshal" in
    write_file path1 1;
    write_file path2 2;
    
    let coll = Reactive_file_collection.create ~process:(fun (x : int) -> x) in
    Reactive_file_collection.add coll path1;
    Reactive_file_collection.add coll path2;
    
    let lst = Reactive_file_collection.to_list coll in
    assert (List.length lst = 2);
    assert (List.mem (path1, 1) lst);
    assert (List.mem (path2, 2) lst);
    
    let ps = Reactive_file_collection.paths coll in
    assert (List.length ps = 2);
    assert (List.mem path1 ps);
    assert (List.mem path2 ps)
  )

let () =
  Printf.printf "=== Reactive_file_collection Tests ===\n%!";
  setup ();
  (try
    test_create_empty ();
    test_add_get ();
    test_remove ();
    test_update ();
    test_apply_batch ();
    test_iteration ();
    test_complex_data ();
    test_missing_file ();
    test_find_not_found ();
    test_to_list_paths ();
  with e ->
    Printf.printf "Unexpected error: %s\n%!" (Printexc.to_string e)
  );
  cleanup ();
  Printf.printf "=== Results: %d passed, %d failed ===\n%!" !tests_passed !tests_failed;
  if !tests_failed > 0 then exit 1


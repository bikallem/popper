module Stream = Stream
module Random = Random
module Proposition = Proposition
open Stream

type 'a output = {
  value : 'a;
  consumed : Stream.consumed list;
  rest : int32 Seq.t;
}

let data_of_output { consumed; _ } =
  consumed |> List.concat_map (fun { data; _ } -> data) |> List.to_seq

type 'a gen = { gen : int32 Seq.t -> 'a output }

let run cs { gen } = gen cs

let mk_output ~value ~consumed rest = { value; consumed; rest }

let map_output f { value; consumed; rest } =
  { value = f value; consumed; rest }

let make_input seed =
  let module R = PRNG.Splitmix.Pure in
  let accum s =
    let n, s = R.int32 Int32.max_int s in
    Some (n, s)
  in
  Seq.unfold accum seed

let make_input_self_init () =
  let module R = PRNG.Splitmix.Pure in
  make_input @@ R.make_self_init ()

let run_self_init g = run (make_input_self_init ()) g

let eval_self_init g =
  let { value; _ } = run_self_init g in
  value

let make gen = { gen }

let tag tag gen =
  make (fun cs ->
    let { value; consumed; rest } = run cs gen in
    let data = List.fold_left (fun ds { data; _ } -> ds @ data) [] consumed in
    let consumed = [ { tag; data } ] in
    { value; consumed; rest })

let map f gen = make (fun cs -> map_output f @@ run cs gen)

let return value = make (fun cs -> mk_output ~value ~consumed:[] cs)

let bind gen f =
  make (fun cs ->
    let { value; rest; consumed = c1 } = run cs gen in
    let { value; rest; consumed = c2 } = run rest (f value) in
    { value; rest; consumed = c1 @ c2 })

let both g1 g2 =
  let ( let* ) = bind in
  let* x = g1 in
  let* y = g2 in
  return (x, y)

let int32 =
  make (fun cs ->
    match cs () with
    | Nil -> failwith "End-of-sequence"
    | Cons (value, rest) ->
      mk_output ~value ~consumed:[ { tag = Value; data = [ value ] } ] rest)

module Syntax = struct
  let ( let* ) = bind

  let ( let+ ) x f = map f x

  let ( and* ) = both

  let ( and+ ) = both
end

open Syntax

let rec sequence gs =
  match gs with
  | [] -> return []
  | g :: gs ->
    let* x = g in
    let* xs = sequence gs in
    return (x :: xs)

let many g =
  let* n = tag Operator @@ map Int32.to_int int32 in
  sequence @@ List.init (n mod 10) (fun _ -> g)

let range mn mx =
  let+ n = tag Int int32 in
  mn + (Int32.to_int n mod (mx - mn))

let one_of gs =
  let* n = range 0 (List.length gs) in
  List.nth gs n

let char =
  let+ n = tag Char @@ map Int32.to_int int32 in
  Char.chr (48 + (n mod (122 - 48)))

let one_value_of vs = one_of @@ List.map return vs

let promote f =
  make (fun input ->
    let value x =
      let g = f x in
      let { value; _ } = run input g in
      value
    in
    let consumed =
      [
        { tag = Function; data = Containers.Seq.take 1 input |> List.of_seq };
      ]
    in
    let rest = Containers.Seq.drop 1 input in
    mk_output ~value ~consumed rest)
  |> tag Function

let float =
  let+ n = tag Float int32 in
  Int32.float_of_bits n

let int64 =
  let+ f = float in
  Int64.of_float f

let bool = one_value_of [ false; true ]

let arrow g =
  let f x =
    make (fun input ->
      let () =
        match Containers.Seq.head input with
        | Some x -> Printf.printf "Value %d\n" (Int32.to_int x)
        | None -> ()
      in
      let h = Int32.of_int @@ Hashtbl.hash x in
      let data = Seq.map (Int32.logxor h) input in
      let () =
        match Containers.Seq.head data with
        | Some x -> Printf.printf "Data value %d\n" (Int32.to_int x)
        | None -> ()
      in
      run data g)
  in
  promote f

let int =
  let* b = tag Sign int32 in
  let* n = tag Int int32 in
  let n = Int32.to_int n in
  let b = Int32.to_int b mod 2 = 0 in
  return (if b then Int.neg n else n)

let string =
  map (fun cs -> String.concat "" @@ List.map (String.make 1) cs) (many char)

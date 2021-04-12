type 'a t = { gen : Input.t -> 'a Output.t }

let run input { gen } = gen input
let make gen = { gen }
let tag tag gen = make (fun input -> Output.tag tag @@ run input gen)
let map f gen = make (fun input -> Output.map f @@ run input gen)

let return value =
  make (fun input ->
    let max_size = Input.max_size input in
    Output.make
      ~value
      ~max_size
      ~consumed:Consumed.empty
      ~remaining:input
      ~log:Log.empty)

let bind gen f =
  make (fun input ->
    let o1 = run input gen in
    let o2 = run (Output.remaining o1) (f @@ Output.value o1) in
    let consumed = Consumed.add (Output.consumed o1) (Output.consumed o2) in
    let log = Log.add (Output.log o1) (Output.log o2) in
    o2 |> Output.set_consumed consumed |> Output.set_log log)

let both g1 g2 =
  let ( let* ) = bind in
  let* x = g1 in
  let* y = g2 in
  return (x, y)

let delayed f = make (fun input -> run input @@ f ())

let log log =
  make (fun input ->
    let max_size = Input.max_size input in
    Output.make
      ~value:()
      ~max_size
      ~consumed:Consumed.empty
      ~remaining:input
      ~log)

let log_string s =
  let pp out = Format.pp_print_string out s in
  log @@ Log.of_pp pp

let log_with pp x =
  let pp out = Format.fprintf out "%a" pp x in
  log @@ Log.of_pp pp

let log_key_value key value =
  let lines = String.split_on_char '\n' value in
  let pp out () =
    Format.fprintf
      out
      "@[<hv 2>%a@;=@;%a@]"
      (Util.Format.yellow Format.pp_print_string)
      key
      (Util.Format.blue (Format.pp_print_list Format.pp_print_string))
      lines
  in
  log_with pp ()

let int32 =
  make (fun input ->
    match Input.head_tail input with
    | None -> failwith "End-of-sequence"
    | Some (value, remaining) ->
      Output.make
        ~value
        ~max_size:(Input.max_size input)
        ~consumed:(Consumed.make [ value ])
        ~remaining
        ~log:Log.empty)

module Syntax = struct
  let ( let* ) = bind
  let ( let+ ) x f = map f x
  let ( and* ) = both
  let ( and+ ) = both
end

open Syntax

let with_log key pp gen =
  let* value = gen in
  let pp out () =
    Format.fprintf
      out
      "@[<hv 2>%a@;=@;%a@]"
      (Util.Format.yellow Format.pp_print_string)
      key
      (Util.Format.blue pp)
      value
  in
  let* () = log_with pp () in
  return value

let rec sequence gs =
  match gs with
  | [] -> return []
  | g :: gs ->
    let* x = g in
    let* xs = sequence gs in
    return (x :: xs)

let range mn mx =
  let n = mx - mn in
  let n = Int32.of_int n in
  let block = Int32.div Int32.max_int n in
  let+ r = int32 in
  let offset = Int32.to_int @@ Int32.div r block in
  mn + offset

let one_of gs =
  let* n = tag Tag.Operator @@ range 0 (List.length gs) in
  List.nth gs n

let max_size = make (fun input -> run input (return @@ Input.max_size input))

let float_range mn mx =
  let n = mx -. mn in
  let n = Int32.of_float n in
  let block = Int32.div Int32.max_int n in
  let+ r = int32 in
  let offset = Int32.to_float r /. Int32.to_float block in
  mn +. offset

let choose opts =
  let sum = List.fold_left (fun s (fr, _) -> s +. fr) 0. opts in
  let* rand = float_range 0. sum in
  let rec aux acc = function
    | [ (_, r) ] -> r
    | (f, r) :: frs ->
      let acc = acc +. f in
      if acc >= rand then
        r
      else
        aux acc frs
    | [] -> failwith "Empty"
  in
  aux 0. opts

let sized f =
  let* n = tag Tag.Size int32 in
  let* max_size = max_size in
  let max_size = Int32.of_int max_size in
  let block = Int32.div Int32.max_int max_size in
  let n = Int32.to_int @@ Int32.div n block in
  f n

let set_max_size max_size g =
  make (fun input -> run (Input.set_max_size max_size input) g)

let list g =
  let aux size =
    if size <= 0 then
      return []
    else
      let* n = range 0 size in
      sequence @@ List.init n (fun _ -> g)
  in
  sized aux

let option g =
  sized (fun size ->
    if size <= 1 then
      return None
    else
      one_of [ return None; map Option.some g ])

let result ~ok ~error = one_of [ map Result.ok ok; map Result.error error ]

let char =
  let+ n = tag Char @@ map Int32.to_int int32 in
  Char.chr (48 + (n mod (122 - 48)))

let one_value_of vs = one_of @@ List.map return vs

let promote f =
  make (fun input ->
    let value x = Output.value @@ run input @@ f x in
    let consumed =
      Consumed.tag Tag.Function @@ Consumed.make (Input.take 1 input)
    in
    let remaining = Input.drop 1 input in
    Output.make
      ~value
      ~max_size:(Input.max_size input)
      ~consumed
      ~remaining
      ~log:Log.empty)

let float =
  tag Tag.Float
  @@ let+ n = tag Float int32 in
     Int32.float_of_bits n

let int64 =
  let+ f = float in
  Int64.of_float f

let bool = one_value_of [ false; true ]

let arrow g =
  let f x =
    make (fun input ->
      let h = Int32.of_int @@ Hashtbl.hash x in
      let data = Input.map (Int32.logxor h) input in
      run data g)
  in
  promote f

let string =
  map
    (fun input -> String.concat "" @@ List.map (String.make 1) input)
    (list char)

let with_consumed g =
  make (fun input ->
    let output = run input g in
    let c = Output.consumed output in
    Output.map (fun x -> (x, c)) output)

let small_int = range (-10) 10
let medium_int = range (-1000) 1000

let any_int =
  let* b = tag Sign int32 in
  let* n = tag Int int32 in
  let n = Int32.to_int n in
  let b = Int32.to_int b mod 2 <> 0 in
  return (if b then Int.neg n else n)

let int =
  tag Int
  @@ choose
       [ (1., return 0)
       ; (1., return 1)
       ; (1., return (-1))
       ; (5., small_int)
       ; (10., medium_int)
       ; (10., any_int)
       ]

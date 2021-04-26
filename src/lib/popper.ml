module Comparator = Comparator
module Sample = Sample
module Proposition = Proposition
module Test = Test
module Random = Random
module Input = Input
module Consumed = Consumed
module Output = Output
module Tag = Tag
module Syntax = Sample.Syntax

exception Popper_error

let test ?count ?verbose = Test.make ?count ?verbose
let suite ts = Test.suite ts
let eq ?loc testable x y = Sample.return @@ Proposition.eq ?loc testable x y
let lt ?loc testable x y = Sample.return @@ Proposition.lt ?loc testable x y
let gt ?loc testable x y = Sample.return @@ Proposition.gt ?loc testable x y
let gte ?loc testable x y = Sample.return @@ Proposition.gte ?loc testable x y
let lte ?loc testable x y = Sample.return @@ Proposition.lte ?loc testable x y
let is_true ?loc b = Sample.return @@ Proposition.is_true ?loc b
let is_false ?loc b = Sample.return @@ Proposition.is_false ?loc b
let all ps = Sample.sequence ps |> Sample.map Proposition.all
let any ps = Sample.sequence ps |> Sample.map Proposition.any
let with_log k pp gen = Sample.with_log k pp gen
let pass = Sample.return Proposition.pass
let fail ?loc s = Sample.return @@ Proposition.fail_with ?loc s

let run ?seed t =
  if Test.run ?seed t then
    ()
  else
    raise Popper_error

let run_test f = run (Test.make f)
module type S =
sig
  type t
  val id : t
  val equal : t -> t -> bool
  val is_id : t -> bool
  val lt : t -> t -> bool
  val leq : t -> t -> bool
  val compose : t -> t -> t
  val dump : Format.formatter -> t -> unit
end

module Int :
sig
  include S
  val int : int -> t
end
=
struct
  type t = int
  let id = 0
  let int x = x
  let equal = Int.equal
  let is_id = function 0 -> true | _ -> false
  let lt : int -> int -> bool = (<)
  let leq : int -> int -> bool = (<=)
  let compose : int -> int -> int = (+)
  let dump = Format.pp_print_int
end

module WithConst (Base : S) :
sig
  include S
  val apply : Base.t -> t
  val const : Base.t -> t
end
=
struct
  type t = Apply of Base.t | Const of Base.t
  let apply x = Apply x
  let const x = Const x
  let id = apply Base.id
  let equal x y =
    match x, y with
    | Apply x, Apply y -> Base.equal x y
    | Const x, Const y -> Base.equal x y
    | _ -> false
  let is_id = function Apply s -> Base.is_id s | _ -> false
  let lt x y =
    match x, y with
    | Apply x, Apply y -> Base.lt x y
    | Const x, Const y -> Base.lt x y
    | _ -> false
  let leq x y =
    match x, y with
    | Apply x, Apply y -> Base.leq x y
    | Const x, Const y -> Base.leq x y
    | _ -> false
  let compose x y =
    match x, y with
    | _, Const _ -> y
    | Const x, Apply y -> const (Base.compose x y)
    | Apply x, Apply y -> apply (Base.compose x y)
  let dump fmt =
    function
    | Const x ->
      Format.fprintf fmt "@[<1>(const@ @[%a@])@]" Base.dump x
    | Apply x ->
      Format.fprintf fmt "@[<1>(apply@ @[%a@])@]" Base.dump x
end

module type MultiExpr =
sig
  type var
  type t
  val var : var -> t
  val subst : (var -> t) -> t -> t
  val equal : t -> t -> bool
  val lt : t -> t -> bool
  val leq : t -> t -> bool
  val dump : Format.formatter -> t -> unit
end

module type OrderedType =
sig
  include Map.OrderedType
  val dump : Format.formatter -> t -> unit
end

module Semilattice (Var : OrderedType) :
sig
  include MultiExpr
  val nat : int -> t
  val succ : t -> t
  val max : t -> t -> t
end
=
struct
  type var = Var.t
  module M = Map.Make (Var)
  (* invariants: max vars <= const *)
  type t = { const : Stdlib.Int.t; vars : Stdlib.Int.t M.t }

  let nat n =
    if n < 0 then invalid_arg "Shift.MultiNat.Expr.nat";
    { const = n; vars = M.empty }
  let zero = nat 0
  let var v = { const = 0; vars = M.singleton v 0 }
  let trans n e =
    { const = e.const + n
    ; vars = M.map (fun l -> l + n) e.vars
    }
  let succ e = trans 1 e
  let max e1 e2 =
    { const = Stdlib.Int.max e1.const e2.const
    ; vars = M.union (fun _ x y -> Some (Stdlib.Int.max x y)) e1.vars e2.vars
    }
  let equal e1 e2 =
    Stdlib.Int.equal e1.const e2.const && M.equal Stdlib.Int.equal e1.vars e2.vars
  let lt e1 e2 =
    e1.const < e2.const &&
    M.for_all (fun v s1 -> match M.find_opt v e2.vars with Some s2 -> s1 < s2 | None -> false) e1.vars
  let leq e1 e2 =
    e1.const <= e2.const &&
    M.for_all (fun v s1 -> match M.find_opt v e2.vars with Some s2 -> s1 <= s2 | None -> false) e1.vars
  let subst f e =
    max (nat e.const) @@
    M.fold (fun v i e -> max (trans i (f v)) e) e.vars zero
  let dump_vars fmt vs =
    Format.pp_print_seq
      ~pp_sep:(fun fmt () -> Format.pp_print_string fmt ",@,")
      (fun fmt (v, n) ->
         if n = 0 then
           Format.fprintf fmt ".@[%a@]" Var.dump v
         else
           Format.fprintf fmt "@[.@[%a@]@,+%i@]" Var.dump v n)
      fmt
      (M.to_seq vs)
  let dump fmt e =
    if M.is_empty e.vars then
      Format.pp_print_int fmt e.const
    else if e.const = 0 then
      Format.fprintf fmt "@[<2>max(%a)@]" dump_vars e.vars
    else
      Format.fprintf fmt "@[<2>%i@,+max(%a)@]" e.const dump_vars e.vars
end

module Multi (V : OrderedType) (E : MultiExpr with type var = V.t) :
sig
  include S
  type expr = E.t
  val singleton : V.t -> E.t -> t
  val find : V.t -> t -> expr
  val update : V.t -> expr -> t -> t
  val of_seq : (V.t * expr) Seq.t -> t
end
=
struct
  module M = Map.Make (V)

  type expr = E.t
  type t = expr M.t

  let singleton v e = M.singleton v e
  let find v s = Option.value ~default:(E.var v) (M.find_opt v s)
  let update v e s = M.add v e s
  let of_seq s = M.of_seq s

  let id = M.empty

  let zip s1 s2 =
    M.merge
      (fun v e1 e2 ->
         let e1 = Option.value ~default:(E.var v) e1
         and e2 = Option.value ~default:(E.var v) e2
         in
         Some (e1, e2))
      s1 s2

  let equal s1 s2 =
    M.for_all (fun _ (e1, e2) -> E.equal e1 e2) (zip s1 s2)

  let is_id s = M.for_all (fun k e -> E.equal (E.var k) e) s

  let lt s1 s2 =
    M.for_all (fun _ (e1, e2) -> E.lt e1 e2) (zip s1 s2)

  let leq s1 s2 =
    let s1s2 = zip s1 s2 in
    M.for_all (fun _ (e1, e2) -> E.leq e1 e2) s1s2 &&
    M.exists (fun _ (e1, e2) -> E.lt e1 e2) s1s2

  let subst s e = E.subst (fun v -> find v s) e

  let compose s1 s2 =
    M.merge (fun _ e2 e1 ->
        match e2 with
        | None -> e1
        | Some e2 -> Some (subst s1 e2))
      s2 s1

  let dump fmt s =
    Format.fprintf fmt "{%a}"
      (Format.pp_print_seq
         ~pp_sep:(fun fmt () -> Format.pp_print_string fmt ",@,")
         (fun fmt (v, e) -> Format.fprintf fmt "@[.@[%a@]@,=%a@]" V.dump v E.dump e))
      (M.to_seq s)
end

module Fractal (Base : S) :
sig
  include S
  val embed : Base.t -> t
  val push : Base.t -> t -> t
end
=
struct
  type t = Base.t * Base.t list

  let embed s : t = s, []
  let push s1 (s2, s2s) = s1, (s2 :: s2s)

  let id = embed Base.id

  let is_id = function s, [] -> Base.is_id s | _ -> false

  let equal (i1, is1) (i2, is2) =
    List.equal Base.equal (i1 :: is1) (i2 :: is2)

  let rec lt (<) (=) xs ys =
    match xs, ys with
    | [], [] -> false
    | [], _ -> true
    | _::_, [] -> false
    | x::xs, y::ys -> x < y || (x = y && lt (<) (=) xs ys)

  let lt (i1, is1) (i2, is2) = lt Base.lt Base.equal (i1 :: is1) (i2 :: is2)

  let rec leq (<) (=) xs ys =
    match xs, ys with
    | [], _ -> true
    | _::_, [] -> false
    | x::xs, y::ys -> x < y || (x = y && leq (<) (=) xs ys)

  let leq (i1, is1) (i2, is2) = leq Base.leq Base.equal (i1 :: is1) (i2 :: is2)

  let rec compose s1 s2 =
    match s1, s2 with
    | (s1, []), (s2, s2s) -> Base.compose s1 s2, s2s
    | (s1, (s11 :: s1s)), _ -> push s1 (compose (s11, s1s) s2)

  let dump fmt (s, ss) =
    if ss = [] then
      Base.dump fmt s
    else
      Format.fprintf fmt "@[<2>(%a)@]"
        (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.pp_print_string fmt ")@,.(") Base.dump)
        (s :: ss)
end

module LexicalPair (X : S) (Y : S) :
sig
  include S
  val pair : X.t -> Y.t -> t
end
=
struct
  type t = X.t * Y.t

  let pair x y : t = x, y

  let id = X.id, Y.id

  let is_id (x, y) = X.is_id x && Y.is_id y

  let equal (x1, y1) (x2, y2) = X.equal x1 x2 && Y.equal y1 y2

  let lt (x1, y1) (x2, y2) = X.lt x1 x2 || (X.equal x1 x2 && Y.lt y1 y2)

  let leq (x1, y1) (x2, y2) = X.lt x1 x2 || (X.equal x1 x2 && Y.leq y1 y2)

  let compose (x1, y1) (x2, y2) = X.compose x1 x2, Y.compose y1 y2

  let dump fmt (x, y) =
    Format.fprintf fmt "@[<2>(pair@ @[%a@]@ @[%a@])@]" X.dump x Y.dump y
end

module type TypeWithEquality =
sig
  type t
  val equal : t -> t -> bool
  val dump : Format.formatter -> t -> unit
end

module Prefix (Base : TypeWithEquality) :
sig
  include S
  val prepend : Base.t -> t -> t
end
=
struct
  type t = Base.t list

  let prepend x xs = x :: xs

  let id = []

  let is_id l = l = []

  let equal x y = List.equal Base.equal x y

  let rec lt x y =
    match x, y with
    | [], [] -> false
    | [], _::_ -> true
    | _::_, [] -> false
    | x::xs, y::ys -> Base.equal x y && lt xs ys

  let rec leq x y =
    match x, y with
    | [], _ -> true
    | _::_, [] -> false
    | x::xs, y::ys -> Base.equal x y && leq xs ys

  let compose x y = x @ y

  let dump fmt x =
    Format.fprintf fmt "@[<1>[%a]@]"
      (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.pp_print_string fmt ";@,") Base.dump)
      x
end

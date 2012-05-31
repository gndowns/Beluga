open Store
open Store.Cid
open Syntax
open Id

(* module Unify = Unify.EmptyTrail  *)
module Unify = Unify.StdTrail 
module C     = Whnf

(* **********************************************************************)
(* Pretty printing                                                      *)
module P = Pretty.Int.DefaultPrinter
module R = Store.Cid.DefaultRenderer
module RR = Store.Cid.NamedRenderer


let (dprint, dprnt) = Debug.makeFunctions (Debug.toFlags [11])

type error =
  | IllTypedElab    of Int.LF.mctx * Int.LF.dctx * Int.LF.tclo
  | TypMismatchElab of Int.LF.mctx * Int.LF.dctx * Int.LF.tclo * Int.LF.tclo
  | LeftoverConstraints of Id.name
  | SubIllTyped 
  | PruningFailed
  | IllTypedIdSub
  | CompTypAnn       
  | NotPatternSpine

exception Error of Syntax.Loc.t * error

let _ = Error.register_printer
  (fun (Error (loc, err)) ->
    Error.print_with_location loc (fun ppf ->
      match err with
        | TypMismatchElab (cD, cPsi, sA1, sA2) ->
          Format.fprintf ppf
            "ill-typed expression\n  expected: %a\n  inferred: %a\n "
            (P.fmt_ppr_lf_typ cD cPsi    Pretty.std_lvl) (Whnf.normTyp sA1)
            (P.fmt_ppr_lf_typ cD cPsi    Pretty.std_lvl) (Whnf.normTyp sA2)

        | IllTypedElab (cD, cPsi, sA) ->
          Format.fprintf ppf
            "ill-typed expression\n  inferred type: %a \n "
            (P.fmt_ppr_lf_typ cD cPsi Pretty.std_lvl) (Whnf.normTyp sA)

        | LeftoverConstraints x ->
          Format.fprintf ppf
            "cannot reconstruct a type for free variable %s (leftover constraints)"
            (R.render_name x)

	| PruningFailed -> 
          Format.fprintf ppf "Pruning a type failed; this can happen when you have some free meta-variables whose type cannot be inferred." 

        | SubIllTyped ->
          Format.fprintf ppf "Ill-typed substitution during elaboration."

        | IllTypedIdSub ->
          Format.fprintf ppf "ill-typed substitution" (* TODO *) 

        | CompTypAnn -> 
          Format.fprintf ppf "Type synthesis of term failed (use typing annotation)" 

        | NotPatternSpine ->
          Format.fprintf ppf "Non-pattern spine -- cannot reconstruct the type of a variable or hole" (* TODO *) ))

let rec conv_listToString clist = match clist with 
  | [] -> " "
  | x::xs -> string_of_int x ^ ", " ^ conv_listToString xs

let rec what_head = function
  | Apx.LF.BVar _ -> "BVar"
  | Apx.LF.Const _ -> "Const"
  | Apx.LF.MVar _ -> "MVar"
  | Apx.LF.PVar (Apx.LF.Offset _ , _ ) -> "PVar Offset "
  | Apx.LF.PVar (Apx.LF.PInst _ , _ ) -> "PVar PInst "
  | Apx.LF.Proj (head, k) -> "Proj " ^ what_head head ^ "." ^ string_of_int k
  | Apx.LF.FVar _ -> "FVar"
  | Apx.LF.FMVar _ -> "FMVar"
  | Apx.LF.FPVar _ -> "FPVar"


(* ******************************************************************* *)
type reconType = Pibox | Pi

exception NotPatSpine

(* ******************************************************************* *)
let rec mkShift recT cPsi = match recT with
  | Pibox -> 
      Int.LF.Shift (Int.LF.NoCtxShift, 0)

  | Pi ->
      let (None, d) = Context.dctxToHat cPsi in
        Int.LF.Shift (Int.LF.NoCtxShift, d) 

(* ******************************************************************* *)
let rec pruningTyp locOpt cD cPsi phat sA (ms, ss)  = 
  if Substitution.LF.isId ss then 
    Whnf.normTyp sA 
  else 
    begin try
      Unify.pruneTyp cD cPsi phat sA (ms, ss) (Unify.MVarRef (ref None))
    with _ -> raise (Error (locOpt, PruningFailed))
    end 

let rec unify_phat psihat phihat = 
  match phihat with
    | (Some (Int.LF.CInst ({contents = None} as cref, _, _, _ )), d) -> 
        begin match psihat with 
          | (Some (Int.LF.CInst ({contents = None} as cref', _, _, _) as c_var) , d') -> 
	      if cref == cref' then 
		d = d'
	      else 
		(cref := Some (Int.LF.CtxVar (c_var))  ; true)
          | ((Some (c_var)) , d') -> 
              if d = d' then 
                (cref := Some (Int.LF.CtxVar (c_var))  ; true)
              else                 
                (dprint (fun () -> "[unify_phat - 1] unify ctx_var with a full context");
                 raise Error.NotImplemented)
          | (None , d') -> 
              if d = d' then 
                (cref := Some (Int.LF.Null) ; true)
              else 
                (dprint (fun () -> "[unify_phat - 2] unify ctx_var with a full context");
                 raise Error.NotImplemented)
        end 

    | _ ->  (psihat = phihat)

(* ******************************************************************* *)

let rec getSchema cD ctxvar  = match ctxvar with 
  | Some ((Int.LF.CtxOffset offset ) as phi) -> 
      Schema.get_schema (Context.lookupCtxVarSchema cD  phi) 
  | Some (Int.LF.CtxName n) -> 
      let (_ , Int.LF.CDecl (_, s_cid, _dep)) = FCVar.get n in 
	Schema.get_schema s_cid 
  | _ -> raise (Error.Violation "No context variable for which we could retrieve a schema")

(* ******************************************************************* *)
(* Eta-expansion                                                       *)

  let rec addPrefix loc m tA = 
    begin match tA with
      | Int.LF.Atom _ -> m
      | Int.LF.PiTyp ((Int.LF.TypDecl (x, _ ) , _ ) , tA') -> 
          let _ = dprint (fun () -> "eta FMV - add Lam ") in             
        Apx.LF.Lam (loc, x, addPrefix loc m tA')
    end 

  let rec etaExpSub k s tA = begin match tA with
    | Int.LF.Atom _ -> (k, s)
    | Int.LF.PiTyp (_ , tA') -> 
        let (k',s') = etaExpSub (k+1) s tA' in 
       (k'-1, Apx.LF.Dot(Apx.LF.Head(Apx.LF.BVar(k')),s'))
  end 

  let rec etaExpandFMV  loc (Apx.LF.FMVar (x, s)) tA = 
    let ( _ , s') = etaExpSub 0 s tA  in 
      addPrefix loc (Apx.LF.Root(loc, Apx.LF.FMVar(x, s'), Apx.LF.Nil)) tA

  let rec etaExpandMV loc (Apx.LF.MVar (x,s)) tA = 
    let ( _ , s') = etaExpSub 0 s tA  in 
      addPrefix loc (Apx.LF.Root(loc, Apx.LF.MVar(x, s'), Apx.LF.Nil)) tA


(* Eta-expansion of bound variables which have function type *)
let rec etaExpandHead loc h tA = 
  let rec etaExpSpine k tS tA = begin match  tA with
    | Int.LF.Atom _  -> (k, tS)
        
    | Int.LF.PiTyp (_ , tA') -> 
        let tN = Int.LF.Root (loc, Int.LF.BVar k, Int.LF.Nil) in                   
          etaExpSpine (k+1)  (Int.LF.App(tN, tS)) tA'
  end in 
    
  let rec etaExpPrefix loc (tM, tA) = begin match tA with
    | Int.LF.Atom _ -> tM
    | Int.LF.PiTyp ((Int.LF.TypDecl (x, _ ), _ ) , tA') -> 
        Int.LF.Lam (loc, x, etaExpPrefix loc (tM, tA')) 
  end in
    
  let (k, tS') = etaExpSpine 1 (Int.LF.Nil) tA in 
  let h'       =  begin match h with 
                    | Int.LF.BVar x -> Int.LF.BVar (x+k-1)
                    | Int.LF.FVar _ -> h 
                  end  in
    etaExpPrefix loc (Int.LF.Root(loc, h' , tS'), tA)   




let rec etaExpandApxHead loc h tA = 
  let rec etaExpApxSpine k tS tA = begin match  tA with
    | Int.LF.Atom _  -> (k, tS)
        
    | Int.LF.PiTyp (_ , tA') -> 
        let tN = Apx.LF.Root(loc, Apx.LF.BVar k, Apx.LF.Nil) in                   
          etaExpApxSpine (k+1)  (Apx.LF.App(tN, tS)) tA'
  end in 
    
  let rec etaExpApxPrefix loc (tM, tA) = begin match tA with
    | Int.LF.Atom _ -> tM
    | Int.LF.PiTyp ((Int.LF.TypDecl (x, _ ), _ ) , tA') -> 
        Apx.LF.Lam (loc, x, etaExpApxPrefix loc (tM, tA')) 
  end in
    
  let (k, tS') = etaExpApxSpine 1 (Apx.LF.Nil) tA in 
  let h'       =  begin match h with 
                    | Apx.LF.BVar x -> Apx.LF.BVar (x+k-1)
                    | Apx.LF.FVar _ -> h 
                  end  in
    etaExpApxPrefix loc (Apx.LF.Root(loc, h' , tS'), tA)   


let rec etaExpandApxTerm  loc h tS tA = 
  let rec etaExpApxSpine k tS tA = begin match  tA with
    | Int.LF.Atom _  -> (k, tS)
        
    | Int.LF.PiTyp (_ , tA') -> 
        let tN = Apx.LF.Root(loc, Apx.LF.BVar k, Apx.LF.Nil) in                   
          etaExpApxSpine (k+1)  (Apx.LF.App(tN, tS)) tA'
  end in 
    
  let rec etaExpApxPrefix loc (tM, tA) = begin match tA with
    | Int.LF.Atom _ -> tM
    | Int.LF.PiTyp ((Int.LF.TypDecl (x, _ ), _ ) , tA') -> 
        let _ = dprint (fun () -> "eta - add Lam ") in
        Apx.LF.Lam (loc, x, etaExpApxPrefix loc (tM, tA')) 
  end in

  let rec appendSpine tS1 tS2 = begin match tS1 with
    | Apx.LF.Nil -> tS2
    | Apx.LF.App (tM, tS) -> 
        Apx.LF.App (tM, appendSpine tS tS2) 
  end in 

  let (k, tS') = etaExpApxSpine 1 (Apx.LF.Nil) tA in 
  let _ = dprint (fun () -> "etaExpApxSpine k = " ^ string_of_int k )in
  let tS''     = appendSpine (Apxnorm.shiftApxSpine (k-1) tS) tS' in 
  (* let tS''     = appendSpine tS tS' in  *)
    
  let h'       =  begin match h with 
                    | Apx.LF.BVar x -> Apx.LF.BVar (x+k-1)
                    |  _ -> h 
                  end  in
    etaExpApxPrefix loc (Apx.LF.Root(loc, h' , tS''), tA)   


(* ******************************************************************* *)
(* Pattern substitutions and spines                                    *)
(* patSpine s = true iff
 *
 *     cPsi |- s : A <- P  and
 *     s is a pattern spine (simple approximate),
 *     i.e. it consists of distinct bound variables
 *)
let rec patSpine spine =
  let rec etaUnroll k m= begin match m with
    | Apx.LF.Lam (_ , _, n) ->  etaUnroll (k+1) n
    |  _ ->  (k, m) 
  end in
         
  let rec patSpine' seen_vars spine = match spine with
    | Apx.LF.Nil ->
        (0, spine)

    | Apx.LF.App (Apx.LF.Root (loc, Apx.LF.BVar x, Apx.LF.Nil), spine) ->
        if not (List.mem x seen_vars) then
          let (k, p_spine) = patSpine' (x :: seen_vars) spine in
            (k+1, Apx.LF.App (Apx.LF.Root (loc, Apx.LF.BVar x, Apx.LF.Nil), p_spine))
        else
           raise NotPatSpine

    | Apx.LF.App (Apx.LF.Lam _ as m, spine) -> 
        begin match etaUnroll 0 m with 
          | (k, Apx.LF.Root( loc , Apx.LF.BVar x, spine')) -> 
              (let (l', _p_spine') = patSpine spine' in  
                 if l' = k && x > k then 
                    let (l, p_spine) = patSpine'  ((x-k)::seen_vars) spine in 
                      (l+1, Apx.LF.App(Apx.LF.Root(loc, Apx.LF.BVar (x-k), Apx.LF.Nil), p_spine))
                  else 
                    raise NotPatSpine
              )
          | (k, Apx.LF.Root( loc , Apx.LF.FVar x, spine')) -> 
              let (l', _p_spine') = patSpine spine' in  
                (if l' = k  then 
                   let (l, p_spine) = patSpine' seen_vars spine in 
                     (l+1, Apx.LF.App(Apx.LF.Root(loc, Apx.LF.FVar x, Apx.LF.Nil), p_spine))
                 else 
                   raise NotPatSpine)                  
          | _ ->  raise NotPatSpine
        end 
    | _ ->  raise NotPatSpine 

  in
  let s = patSpine' [] spine in 
    (dprint (fun () -> "[check pat spine] done" ) ; s)



(* isPatSub s = bool *)
let rec isPatSub s = match s with
  | Apx.LF.Id _ ->
      true

  | Apx.LF.EmptySub ->
      true

  | Apx.LF.Dot (Apx.LF.Head (Apx.LF.BVar _k), s) ->
      isPatSub s

(* We cannot handle this at the moment; to infer the type of 
   FMVars which are associated with projections and impose a restriction;
   the issues arises in pruning the type of FMVars where the most general
   type is generated as a id sub from a context containing blocks to another
   one containing blocks; instead we would need to create FMVars as
   going from a flattened block context to its block equivalent, and
   unroll the id substitution to b.1 b.2 b.3 etc instead of b
     
    | Apx.LF.Dot (Apx.LF.Head (Apx.LF.Proj(Apx.LF.BVar _k,_j)), s) ->
      isPatSub s
*)
  | Apx.LF.Dot (Apx.LF.Head _, _s) -> false

  | Apx.LF.Dot (Apx.LF.Obj  _, _s) -> false


(* ******************************************************************* *)
(* isProjPatSub s = true *)
let rec isProjPatSub s = match s with
  | Apx.LF.Id _ -> true

  | Apx.LF.EmptySub -> true

  | Apx.LF.Dot (Apx.LF.Head (Apx.LF.BVar k), s) ->
      isProjPatSub s

  | Apx.LF.Dot (Apx.LF.Head (Apx.LF.Proj(Apx.LF.BVar _k,_j)), s) ->
     isProjPatSub s

  | Apx.LF.Dot (Apx.LF.Head _, _s) -> false

  | Apx.LF.Dot (Apx.LF.Obj  _, _s) -> false

let rec flattenProjPat s conv_list = match s with
  | Apx.LF.Id cpsi -> Apx.LF.Id cpsi
  | Apx.LF.EmptySub -> Apx.LF.EmptySub
  | Apx.LF.Dot (Apx.LF.Head (Apx.LF.BVar k), s) -> 
      let s' = flattenProjPat s conv_list in 
        Apx.LF.Dot (Apx.LF.Head (Apx.LF.BVar (ConvSigma.new_index k conv_list )), s')

  | Apx.LF.Dot (Apx.LF.Head (Apx.LF.Proj(Apx.LF.BVar k, j)), s) ->
      let s' = flattenProjPat s conv_list in 
      let _ = dprint (fun () -> "flattenProjPat Proj Case: k = " ^ string_of_int k ^ "    j = "  ^ string_of_int j ^ "\n") in 
      let k' = (ConvSigma.new_index k conv_list) - j + 1  in
        Apx.LF.Dot (Apx.LF.Head (Apx.LF.BVar k'), s')

 (* these are the only cases which can happen *)


(* ******************************************************************* *)
let rec projectCtxIntoDctx = function
  | Int.LF.Empty            -> Int.LF.Null
  | Int.LF.Dec (rest, last) -> Int.LF.DDec (projectCtxIntoDctx rest, last)


(* ******************************************************************* *)
(* PHASE 1 : Elaboration and Reconstruction (one pass)                 *)
(*  elTerm recT cD cPsi m sA = M
 *
 *  Pre-condition:
 *
 *  U = FV(m) (FV(a), FV(k) resp.)
 *  O = meta-variables in M (A, K, resp.)
 *
 * Invariant:
 *  If  O1; U1 ; (cD ; cPsi) |- m <- [s]A /_r (O2, U2) M 
 *      and there exists a modal substitution r
 *      s.t. O2 |- r <= O1
 *  then
 *
 *     elTerm cD cPsi m sA succeeds and
 *
 *     O2 ; [|r|]U2 ; ([|r|]cD ; [|r|]cPsi) |- M <= [|r|][s]A
 *
 * Post-condition:
 *
 *   O2 |- U2 fvar_ctx    and   . |-{U2} O2 mvar_ctx 
 *   (circular dependency between O2 and U2)
 *
 *   O2 s.t. O2 |-{U2} r <= O1 , and
 *
 * In the implementation:
 *   - meta-variables in O1 and O2 are handled destructively, and O1 and O2 resp characterize the state of memory.
 *   - r is not explicit but implicit since we  update all meta-variables in O1 destructively
 *   - U1 and U2 are the fvar_ctx; they are handled globally and hence are not carried explicitely as an argument
 *     to elTerm 
 *   - may raise Error, if no modal substitution r exists.
 *
 * Similar invariants and pre- and post-conditions for:
 *
 *  elKind cD cPsi k = K'
 *  elTyp  cD cPsi a = A'
 *)

(* ******************************************************************* *)
(* Free variable constraints:
 *
 * fvar_cnstr  C := . | Root (FVar X, tS) & C
 *
 * The constraints are generated when encountering
 * a free variable X whose type is yet unknown and has a
 * non-pattern spine tS. This means we cannot easily infer
 * the type of the free variable X.
 *)


(* Constraints for free bound variables *)
let fvar_cnstr : ((Int.LF.typ_free_var * Apx.LF.normal * Int.LF.cvar)  list) ref = ref [] 

let add_fvarCnstr  c = fvar_cnstr := c :: !fvar_cnstr

let reset_fvarCnstr () = (fvar_cnstr := [])

(* Constraints for free metavariables and parameter variables  *)
let fcvar_cnstr : ((Apx.LF.normal * Int.LF.cvar)  list) ref = ref []

let add_fcvarCnstr  c = fcvar_cnstr := c :: !fcvar_cnstr
let reset_fcvarCnstr () = (fcvar_cnstr := [])

(* ******************************************************************* *)

(* synDom cPsi s = (cPhi , s')
 *
 * If s is a pattern substitution in approximate syntax
 *    cPsi is the range of the pattern substitution
 *
 * then
 *     s' the pattern substitution in internal syntax
 *     corresponding to s and
 *
 *     cPsi |- s' <= cPhi
 *)
let rec synDom cD loc cPsi s = begin match s with
  | Apx.LF.Id _ ->
      begin match Context.dctxToHat cPsi with
        | (Some psi, d) ->
            (Int.LF.CtxVar psi, Int.LF.Shift (Int.LF.NoCtxShift, d))

        | (None, _d) ->
            raise (Index.Error (loc, Index.UnboundIdSub))
      end

  | Apx.LF.EmptySub ->
      begin match Context.dctxToHat cPsi with
        | (Some psi, d) ->
            (Int.LF.Null, Int.LF.Shift (Int.LF.CtxShift psi, d))

        | (None, d) ->
            (Int.LF.Null, Int.LF.Shift (Int.LF.NoCtxShift, d))
      end

  | Apx.LF.Dot (Apx.LF.Head (Apx.LF.BVar k), s) ->
      begin match Context.ctxDec cPsi k with
        | Int.LF.TypDecl (x, tA) ->
            let (cPhi, s') = synDom cD loc cPsi s in
              (*  cPsi |- s <= cPhi
               *  cPsi |- tA <= type
               *  tA' = [s]^-1(tA)
               *
               * Note: We may need to check that [s]^-1(tA) actually exists.
               *
               *  Wed Jan 14 13:51:11 2009 -bp
               *)
            let ss = Substitution.LF.invert s' in 
            let tA' = pruningTyp loc cD cPsi (*?*) 
	      (Context.dctxToHat cPsi) (tA, Substitution.LF.id)  (Int.LF.MShift 0, ss)  in
              (Int.LF.DDec (cPhi,
                            Int.LF.TypDecl (x, tA')),
               Int.LF.Dot (Int.LF.Head(Int.LF.BVar k), s'))
(*       | _ -> raise (Error.Violation "Undefined bound variable") *)
      end

   | Apx.LF.Dot (Apx.LF.Head (Apx.LF.Proj(Apx.LF.BVar k,j)), s) ->
      begin match Context.ctxDec cPsi k with
        | Int.LF.TypDecl (x, tB) -> (* tB = block x1:A1. ... xn:An *)
           let (cPhi, s') = synDom cD loc cPsi s in 
              (*  cPsi |- s <= cPhi
               *  cPsi |- tA <= type
               *  tA' = [s]^-1(tA)
               *
               * Note: We may need to check that [s]^-1(tA) actually exists; 
               * Wed Jan 14 13:51:11 2009 -bp
               *)
            let ss = Substitution.LF.invert s' in 

            let Int.LF.Sigma typRec = 
              pruningTyp loc cD cPsi (*?*) (Context.dctxToHat cPsi) (tB, Substitution.LF.id) (Int.LF.MShift 0, ss)  in

            let sQ = Int.LF.getType  (Int.LF.BVar k) (typRec, Substitution.LF.id) k 1 in 

              (Int.LF.DDec (cPhi,
                            Int.LF.TypDecl (x, Int.LF.TClo sQ)),
               Int.LF.Dot (Int.LF.Head(Int.LF.Proj(Int.LF.BVar k, j)), s'))
         | _ -> raise (Error.Violation "Undefined bound variable") 
      end


  | _ -> raise (Error.Violation "Encountered non-pattern substitution")

end

(* ******************************************************************* *)
(* ELABORATION OF KINDS                                                *)
(* ******************************************************************* *)
(* elKind  cPsi k = K *)
let rec elKind cD cPsi k = match k with
  | Apx.LF.Typ ->
      Int.LF.Typ

  | Apx.LF.PiKind ((Apx.LF.TypDecl (x, a),dep), k) ->
      let dep'  = match dep with Apx.LF.No -> Int.LF.No | Apx.LF.Maybe -> Int.LF.Maybe in
      let tA    = elTyp
                    Pi 
                    (*cD=*)Int.LF.Empty
                    cPsi
                    a
      in
      let cPsi' = (Int.LF.DDec (cPsi, Int.LF.TypDecl (x, tA))) in
      let tK    = elKind cD cPsi' k in
        Int.LF.PiKind ((Int.LF.TypDecl (x, tA), dep'), tK)

(* ******************************************************************* *)
(* ELABORATION OF KINDS                                                *)
(* ******************************************************************* *)
(* elTyp recT  cD cPsi a = A
 *
 * Pre-condition:
 *     U = set of free variables
 *     O = set of meta-variables (references subject to instantiation)
 *
 * if cD ; cPsi |- a <= type and a is in beta normal form
 *   
 * then
 *        [|r|]cD ;  [|r|]cPsi   |- A <= type 
 * and A is in beta-eta normal form.
 *
 * Effect:
 *     U' = FV(A)  where U' is an extension of U s.t. [|r|]U,U0 = U'
 *     O' = FMV(A) where O' |-{U'} r <= O
 *)
and elTyp recT cD cPsi a = match a with
  | Apx.LF.Atom (loc, a, s) ->
    let tK = (Typ.get a).Typ.kind in
    let i  = (Typ.get a).Typ.implicit_arguments in
    let s'  = mkShift recT cPsi in
    (* let s' = Substitution.LF.id in *)
    let tS = elKSpineI loc recT cD cPsi s i (tK, s') in
    Int.LF.Atom (loc, a, tS)

  | Apx.LF.PiTyp ((Apx.LF.TypDecl (x, a), dep), b) ->
      let dep'  = match dep with Apx.LF.No -> Int.LF.No | Apx.LF.Maybe -> Int.LF.Maybe in
      let tA    = elTyp recT cD cPsi a in
      let cPsi' = (Int.LF.DDec (cPsi, Int.LF.TypDecl (x, tA))) in
      let tB    = elTyp recT cD cPsi' b in
        Int.LF.PiTyp ((Int.LF.TypDecl (x, tA),dep'), tB)

  | Apx.LF.Sigma typRec ->
      let typRec' = elTypRec recT cD cPsi typRec in
        Int.LF.Sigma typRec' 
   
       
and elTypRec recT cD cPsi typ_rec = begin match typ_rec with
  | Apx.LF.SigmaLast a ->
      let tA = elTyp recT cD cPsi a in 
      let _ = dprint (fun () -> "[elTypRec] Last " ^ " : " ^ P.typToString cD cPsi (tA, Substitution.LF.id)) in 
        Int.LF.SigmaLast tA 

  | Apx.LF.SigmaElem (name, a, typRec) ->
      let tA = elTyp recT cD cPsi a in
      let _ = dprint (fun () -> "[elTypRec] " ^ R.render_name name ^ " : " ^
      P.typToString cD cPsi (tA, Substitution.LF.id)) in 
      let cPsi' = Int.LF.DDec (cPsi, Int.LF.TypDecl (name, tA)) in
      let typRec' = elTypRec recT cD cPsi' typRec in
        Int.LF.SigmaElem (name, tA, typRec')
end

(* elTerm recT  cD cPsi m sA = M
 * elTerm recT  cD cPsi m sA = M  where sA = (A,s) is in whnf
 *                              m is in beta normal form.
 * Pre-condition:
 *     U = set of free variables   O |- U fvar_ctx
 *     O = set of meta-variables (references subject to instantiation)
 *                                 . |-{U} O mvar_ctx
 * if cD ; cPsi |- M <= [s]A'
 *
 *    cD |- cPsi ctx
 *    cD ; cPsi  |- s <= cPsi'
 *    cD ; cPsi' |- A <= type 
 *
 * then
 *    [|r|]cD ; [|r|]cPsi |- M <= [|r|]A 
 *
 * and M is in beta-eta normal form, i.e.
 *   all free variables are eta-expanded.
 *
 * Effect:
 *     U' = FV(A)  where U' is an extension of U s.t. [|r|]U,U0 = U'
 *     O' = FMV(A) where O' |-{U'} r <= O
 *)
and elTerm recT cD cPsi m sA = elTermW recT cD cPsi m (Whnf.whnfTyp sA)

and elTermW recT cD cPsi m sA = match (m, sA) with
  | (Apx.LF.Lam (loc, x, m),  (Int.LF.PiTyp ((Int.LF.TypDecl (_x, _tA) as decl, _ ), tB), s)) ->
       (* cPsi' = cPsi, x:tA *)
      let cPsi' = Int.LF.DDec (cPsi, Substitution.LF.decSub decl s) in
      let tM    = elTerm recT cD cPsi' m (tB, Substitution.LF.dot1 s) in
        Int.LF.Lam (loc, x, tM)
  
  | (Apx.LF.Root (_loc, _h, _spine),  (Int.LF.Atom _, _s)) ->
      elTerm' recT cD cPsi m  sA  
  
  | (Apx.LF.Tuple (loc, tuple),  (Int.LF.Sigma typRec, s)) -> 
      let tuple' = elTuple recT cD cPsi tuple (typRec, s) in
        Int.LF.Tuple (loc, tuple')

  | (Apx.LF.Root (loc, Apx.LF.FMVar (x, s),  _spine),  (Int.LF.PiTyp _ as tA, _s)) ->
      let n = etaExpandFMV loc (Apx.LF.FMVar (x,s)) tA in 
        elTerm recT cD cPsi n sA
(*      raise (Error.Error (loc, Error.EtaExpandFMV (x, cD, cPsi, sA))) *)

  | (Apx.LF.Root (loc, Apx.LF.MVar (x, s),  _spine),  (Int.LF.PiTyp _ as tA, _s)) ->
      let n = etaExpandMV loc (Apx.LF.MVar (x,s)) tA in 
        elTerm recT cD cPsi n sA

  | (Apx.LF.Root (loc, h, spine ), (Int.LF.PiTyp _ as tA, _s)) -> 
      let n = etaExpandApxTerm loc h spine tA in 
        elTerm recT cD cPsi n sA
  
  | (Apx.LF.Lam (loc, _, _ ), _ ) ->  
      raise (Error (loc, IllTypedElab (cD, cPsi, sA))) 

  | (Apx.LF.Tuple (loc, _ ),  _) ->
      raise (Error (loc, IllTypedElab (cD, cPsi, sA))) 

and elTuple recT cD cPsi tuple (typRec, s) =
  match (tuple, typRec) with
  | (Apx.LF.Last m,
     Int.LF.SigmaLast tA) 
    ->
      Int.LF.Last (elTerm' recT cD cPsi m (tA, s))

  | (Apx.LF.Cons(m, restOfTuple),
     Int.LF.SigmaElem(_x, tA, restOfTypRec))
    ->
      let tM = elTerm recT  cD cPsi m (tA, s) in
      let extended_s = Int.LF.Dot (Int.LF.Obj tM, s) in
      let tuple' = elTuple recT cD cPsi restOfTuple (restOfTypRec, extended_s) in
        Int.LF.Cons (tM, tuple')

  | (_, _) -> raise (Error.Violation ("elTuple arity mismatch"))


and elTerm' recT cD cPsi r sP = match r with

  | Apx.LF.Root (loc, Apx.LF.Const c, spine) ->
      let tA = (Term.get c).Term.typ in
      let i  = (Term.get c).Term.implicit_arguments in
      (* let s  = mkShift recT cPsi in *)
      let s = Substitution.LF.id in 
      let (tS, sQ) = elSpineI loc recT cD cPsi spine i (tA, s) in
      let tR = Int.LF.Root (loc, Int.LF.Const c, tS)  in 
      begin
	try
          Unify.unifyTyp cD cPsi sQ sP;
	  tR
        with
         | Unify.Unify msg ->
           raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
         | Unify.Error msg -> 
           raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
         | Unify.NotInvertible -> 
           raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
      end

  | Apx.LF.Root (loc, Apx.LF.BVar x, spine) ->
    begin
      try
        let Int.LF.TypDecl (_, tA) = Context.ctxDec cPsi x in
        let (tS, sQ) = elSpine loc recT cD cPsi spine (tA, Substitution.LF.id) in
        begin
	  try
	    (Unify.unifyTyp cD  cPsi sQ sP;
	     Int.LF.Root (loc, Int.LF.BVar x, tS))
          with
	    | Unify.Unify msg ->
	      raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
            | _ -> raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
        end
      with _ -> raise (Error (loc, CompTypAnn))
      end

  | Apx.LF.Root (loc, Apx.LF.FVar x, spine) as m ->
   (* This case can only happen durin Pi *) 
      begin match recT with 
        | Pi -> 
            begin try
              let Int.LF.Type tA = FVar.get x in
                (* For type reconstruction to succeed, we must have
                 *
                 *  . |- tA <= type
                 *  This will be enforced during abstraction
                 *)
              let s = mkShift recT cPsi in
              let (tS, sQ) = elSpine loc recT cD cPsi spine (tA, s) in
              begin
		try
                  Unify.unifyTyp cD cPsi sQ sP;
                  Int.LF.Root (loc, Int.LF.FVar x, tS)
                with
		  | Unify.Unify msg ->
                    raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
                  | _ ->
                    raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
              end


            with Not_found ->
              begin
		try
                  let (_l, p_spine) = patSpine spine in
                  let s = mkShift recT cPsi in              
                  let (tS, tA) =  elSpineSynth recT  cD cPsi p_spine s sP in 
                  (* For type reconstruction to succeed, we must have
                   *  . |- tA <= type  and cPsi |- tS : tA <= [s]tP
                   *  This will be enforced during abstraction.
                   *)
                  FVar.add x (Int.LF.Type tA);
                  Int.LF.Root (loc, Int.LF.FVar x, tS)
		with NotPatSpine -> 
                  (let _ = dprint (fun () -> "[elTerm'] FVar case -- Not a pattern spine...") in  
                   let v = Whnf.newMVar (cPsi, Int.LF.TClo sP) in
                   let tAvar = Int.LF.TypVar (Int.LF.TInst (ref None, cPsi, Int.LF.Typ, ref [])) in  
                   add_fvarCnstr (tAvar, m, v);
                   Int.LF.Root (loc, Int.LF.MVar (v, Substitution.LF.id), Int.LF.Nil))
                  | _  ->                 
                    raise (Error (loc, IllTypedElab (cD, cPsi, sP)))
              end
            end
        | Pibox -> raise (Index.Error (loc, Index.UnboundName x))
      end 
              

  | Apx.LF.Root (loc, Apx.LF.Hole, spine) ->
      begin try 
     (let (_l, pat_spine) = patSpine spine in
      let sshift = mkShift recT cPsi in
      let (tS, tA) = elSpineSynth recT  cD cPsi pat_spine sshift sP in
        (* For Beluga type reconstruction to succeed, we must have
         *  cPsi |- tA <= type  and cPsi |- tS : tA <= [s]tP
         *  This will be enforced during abstraction.
         *)
        (* For LF type reconstruction to succeed, we must have
         *  . |- tA <= type  and cPsi |- tS : tA <= [s]tP
         *  This will be enforced during abstraction.
         *)
        (* Potentially need to handle eta-expansion -bp *)
        begin match recT with
          | Pi -> 
              (* let u =  Whnf.newMVar (cPsi, tA) in 
                Int.LF.Root (loc, Int.LF.MVar(u, Substitution.LF.id), tS) *)
              let u =  Whnf.newMVar (Int.LF.Null, tA) in 
                Int.LF.Root (loc, Int.LF.MVar(u, sshift), tS)
          | Pibox -> 
              let u =  Whnf.newMMVar (cD, cPsi, tA) in
                Int.LF.Root (loc, Int.LF.MMVar(u, (Whnf.m_id, Substitution.LF.id)), tS)
        end)
      with NotPatSpine -> raise (Error (loc, NotPatternSpine))
      end
  (* We only allow free meta-variables of atomic type *)
  | Apx.LF.Root (loc, Apx.LF.FMVar (u, s), Apx.LF.Nil) as m ->
      begin try
        let (cD_d, Int.LF.MDecl(_, tQ, cPhi)) = FCVar.get u in
	let _ = dprint (fun () -> "Retrieving type of FMV " ^ R.render_name u ^
      " of type " ^ P.typToString cD_d cPhi (tQ, Substitution.LF.id) ^ "[" ^
			  P.dctxToString cD_d cPhi ^ "]") in
	let d = Context.length cD - Context.length cD_d in 
	let (tQ', cPhi') = if d = 0 then (tQ, cPhi) else 
	  (Whnf.cnormTyp (tQ, Int.LF.MShift d), Whnf.cnormDCtx (cPhi, Int.LF.MShift d)) in 
          (* For type reconstruction to succeed, we must have
           *    . ; cPsi |- tA <= type , i.e. cPsi and tA cannot depend on
           * meta-variables in cD. This will be enforced during abstraction *)
        let s'' = elSub loc recT cD cPsi s cPhi' in
          (* We do not check here that tP approx. [s']tP' --
           * this check is delayed to reconstruction *)
        let tR = Int.LF.Root (loc, Int.LF.FMVar (u, s''), Int.LF.Nil) in 
        begin try
		Unify.unifyTyp cD  cPsi (tQ', s'') sP ; 
		tR
	  with Unify.Unify msg -> 
            raise (Check.LF.Error (loc, Check.LF.TypMismatch (cD, cPsi, (tR, Substitution.LF.id), (tQ', s''), sP)))
            |_ -> raise (Check.LF.Error (loc, Check.LF.TypMismatch (cD, cPsi, (tR, Substitution.LF.id), (tQ', s''), sP)))
          end
      with 
        | Not_found ->
          if isPatSub s then
          (* 1) given cPsi and s synthesize the domain cPhi
           * 2) [s]^-1 ([s']tP) is the type of u
           *)
          let _ = dprint (fun () -> "Synthesize domain for meta-variable " ^ u.string_of_name ) in
          let (cPhi, s'') = synDom cD loc cPsi s in
          let ss =  Substitution.LF.invert s'' in 
              let tP = pruningTyp loc cD cPsi (*?*) (Context.dctxToHat cPsi) sP (Int.LF.MShift 0, ss) in
                (* let tP = Int.LF.TClo (Int.LF.TClo sP, Substitution.LF.invert s'') in *)
                (* For type reconstruction to succeed, we must have
                 * . ; cPhi |- tP <= type  and . ; cPsi |- s <= cPhi
                 * This will be enforced during abstraction.
                 *)
	      let _ = dprint (fun () -> "Added FMVar " ^ R.render_name u ^ 
				" of type " ^ P.typToString cD cPhi (tP, Substitution.LF.id) ^ 
				"[" ^ P.dctxToString cD cPhi ^ "]") in 
                FCVar.add u (cD, Int.LF.MDecl(u, tP, cPhi));
                Int.LF.Root (loc, Int.LF.FMVar (u, s''), Int.LF.Nil)
          else
           if isProjPatSub s then 
             let _ = dprint (fun () -> "Synthesize domain for meta-variable " ^ u.string_of_name ) in
             let _ = dprint (fun () -> "isProjPatSub ... " ) in 
             let (flat_cPsi, conv_list) = ConvSigma.flattenDCtx cPsi in  
             let _ = dprint (fun () -> "flattenDCtx done " ^ P.dctxToString cD flat_cPsi ^ "\n") in 
             let _ = dprint (fun () -> "conv_list " ^ conv_listToString conv_list ) in 
             let flat_s = flattenProjPat s conv_list in 
             let _ = dprint (fun () -> "flattenProjPat done " ) in

             let (cPhi, s'') = synDom cD loc flat_cPsi flat_s in 
             let ss =  Substitution.LF.invert s'' in  

             let tP' = ConvSigma.strans_typ sP conv_list in 
             let _ = dprint (fun () -> "[synDom] Prune type " ^ P.typToString cD cPsi sP ) in  
             let _ = dprint (fun () -> "[synDom] Prune flattened type " ^ P.typToString cD cPhi (tP', Substitution.LF.id) ) in  
             let _ = dprint (fun () -> "         with respect to ss = " ^ P.subToString cD cPhi ss ) in  

             let tP = pruningTyp loc cD flat_cPsi (*?*) 
                         (Context.dctxToHat flat_cPsi) (tP', Substitution.LF.id) (Int.LF.MShift 0, ss)  in 

             let sorig = elSub loc recT cD cPsi s cPhi in
             let _ = dprint (fun () -> "sorig = " ^ P.subToString cD cPsi sorig ^ "\n") in 
            (* For type reconstruction to succeed, we must have
             * . ; cPhi |- tP <= type  and . ; cPsi |- s <= cPhi
             * This will be enforced during abstraction.
             *)
             let _ = dprint (fun () -> "Type of mvar " ^ u.string_of_name ^ ":" ^ 
                               P.typToString cD cPhi (tP, Substitution.LF.id) ^ " [ " ^ 
                               P.dctxToString cD cPhi ^ " ] ") in
 
            FCVar.add u (cD, Int.LF.MDecl (u, tP, cPhi)); 
            Int.LF.Root (loc, Int.LF.FMVar (u, sorig), Int.LF.Nil)

            else 
              let v = Whnf.newMVar (cPsi, Int.LF.TClo sP) in
                add_fcvarCnstr (m, v);
                Int.LF.Root (loc, Int.LF.MVar (v, Substitution.LF.id), Int.LF.Nil)

        | Error.Violation msg  -> 
            dprint (fun () -> "[elClosedTerm] Violation: " ^ msg) ; 
            raise (Error (loc, CompTypAnn ))

      end



  | Apx.LF.Root (loc, Apx.LF.FPVar (p, s), spine) as m ->
      begin try
        let (cD_d, Int.LF.PDecl (_, tA, cPhi)) = FCVar.get p in
	let d = Context.length cD - Context.length cD_d in 
	let (tA, cPhi) = if d = 0 then (tA, cPhi) else 
	  (Whnf.cnormTyp (tA, Int.LF.MShift d), Whnf.cnormDCtx (cPhi, Int.LF.MShift d)) in 
          (* For type reconstruction to succeed, we must have
           *    . ; cPsi |- tA <= type , i.e. cPsi and tA cannot depend on
           * meta-variables in cD. This will be enforced during abstraction *)
          
        let s'' = elSub loc recT cD cPsi s cPhi in
        let (tS, sQ ) = elSpine loc recT cD cPsi spine (tA, s'')  in
        let tR = Int.LF.Root (loc, Int.LF.FPVar (p, s''), tS) in
          begin try
            Unify.unifyTyp cD cPsi sQ sP;
            tR
            with
	      | Unify.Unify msg -> 
		raise (Check.LF.Error (loc, Check.LF.TypMismatch (cD, cPsi, (tR, Substitution.LF.id), sQ, sP)))
              | _ ->
		raise (Check.LF.Error (loc, Check.LF.TypMismatch (cD, cPsi, (tR, Substitution.LF.id), sQ, sP)))
          end
      
      with 
        | Not_found ->
          begin match (spine, isPatSub s) with
            | (Apx.LF.Nil, true) ->
                (* 1) given cPsi and s, synthesize the domain cPhi
                 * 2) [s]^-1 ([s']tP) is the type of u
                 *)
                (* Need to check that the inferred type for p is indeed in cPsi's schema -bp *)
                let (cPhi, s'') = synDom cD loc cPsi s in
                let si          = Substitution.LF.invert s'' in
                let tP = pruningTyp loc cD cPsi (*?*) (Context.dctxToHat cPsi) sP 
                                (Int.LF.MShift 0, si)  in
                (* let tP          = Whnf.normTyp (Int.LF.TClo sP, si) in*)
                  (* For type reconstruction to succeed, we must have
                   * . ; cPhi |- tP <= type  and . ; cPsi |- s <= cPhi
                   * This will be enforced during abstraction.
                   *)
                  FCVar.add p (cD, Int.LF.PDecl(p, Whnf.normTyp (tP,Substitution.LF.id),  cPhi));
                  Int.LF.Root (loc, Int.LF.FPVar (p, s''), Int.LF.Nil)
            
            | (Apx.LF.Nil, false) ->
                let q = Whnf.newPVar (cPsi, Int.LF.TClo sP) in
                  add_fcvarCnstr (m, q);
                  Int.LF.Root (loc, Int.LF.PVar (q, Substitution.LF.id), Int.LF.Nil)

            | (_, _) ->  raise (Error (loc, NotPatternSpine))
          end
        | Error.Violation msg  -> 
            dprint (fun () -> "[elClosedTerm] Violation: " ^ msg) ;
            raise (Error (loc, CompTypAnn ))
      end

  (* Reconstruct: Projection *)
  | Apx.LF.Root (loc,  Apx.LF.Proj (Apx.LF.FPVar (p, s), k), spine) as m ->
      (* Other case where spine is not empty is not implemented -bp *)
        begin try          
          let _ = dprint (fun () -> "[Reconstruct Projection Parameter] #" ^
			    p.string_of_name ^ "." ^ string_of_int k) in 
          let (cD_d, Int.LF.PDecl (_, ((Int.LF.Sigma typRec) as tA), cPhi)) = FCVar.get  p in 
	  let d = Context.length cD - Context.length cD_d in 
	  let (tA, cPhi) = if d = 0 then (tA, cPhi) else 
	    (Whnf.cnormTyp (tA, Int.LF.MShift d), Whnf.cnormDCtx (cPhi, Int.LF.MShift d)) in 
	    
          let _ = dprint (fun () -> "[Reconstruct Projection Parameter] Found its type ") in 
          let _ = dprint (fun () -> "      with type " ^ 
			    P.typToString cD cPhi (tA, Substitution.LF.id) ^ "[" ^ P.dctxToString cD cPhi ^ "]") in 
          let s'' = elSub loc recT cD cPsi s cPhi in
(*          let Int.LF.Sigma typRec = tA *)
          let sA = Int.LF.getType  (Int.LF.FPVar (p, s'')) (typRec, s'') k 1 in  
          let (tS, sQ ) = elSpine loc recT cD cPsi spine (Int.LF.TClo sA, s'')  in
            begin try
              (Unify.unifyTyp cD cPsi (Int.LF.TClo sQ, s'') sP ;
               Int.LF.Root (loc,  Int.LF.Proj (Int.LF.FPVar (p, s''), k), tS))
              with
		| Unify.Unify msg ->
		  raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
		| _ ->
		  raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
            end
        with Not_found ->
	  (dprint (fun () -> "[Reconstruct Projection Parameter] #" ^
			    p.string_of_name ^ "." ^ string_of_int k ^ " NOT FOUND") ;
          begin match (isPatSub s, spine) with
            | (true, Apx.LF.Nil) ->
                let (cPhi, s'') = synDom cD loc cPsi s in
                let si          = Substitution.LF.invert s'' in
                let tP = pruningTyp loc cD cPsi (*?*) 
		  (Context.dctxToHat  cPsi) sP (Int.LF.MShift 0, si)  in 
                let schema =  getSchema cD (Context.ctxVar cPsi) in
		let _ = dprint (fun () -> "[ctxVar] done") in 
                let h = Int.LF.FPVar (p, Substitution.LF.id) in
                let (typRec, s_inst) = 
                  begin match synSchemaElem loc recT cD cPhi (tP, Substitution.LF.id) (h, k) schema with
                  | None -> raise (Error.Violation ("type sP = " ^ P.typToString cD cPhi (tP, Substitution.LF.id) ^ " not in schema " ^ 
                                             P.schemaToString schema))
                  | Some (typrec, subst) -> (typrec, subst)  
                  end in       
                let tB  =  
                  begin match typRec with 
                  | Int.LF.SigmaLast tA -> 
                      (dprint (fun () -> "synType for PVar: [SigmaLast]" ^ P.typToString cD cPhi (tA, s_inst) ^ "\n"); tA) 
                  | typRec' -> 
                      (dprint (fun () -> "synType for PVar: [SigmaElem]" ^ P.typRecToString cD cPhi (typRec', s_inst) ^ "\n") ; 
                       Int.LF.Sigma typRec' )
                  end in 
                  FCVar.add p (cD, Int.LF.PDecl (p, Whnf.normTyp (tB, s_inst), cPhi));
                  Int.LF.Root (loc,  Int.LF.Proj (Int.LF.FPVar (p, s''), k),  Int.LF.Nil) 
                  
            | (false, Apx.LF.Nil) ->
                let q = Whnf.newPVar (cPsi, Int.LF.TClo sP) in
                  add_fcvarCnstr (m, q);
                  Int.LF.Root (loc,  Int.LF.Proj (Int.LF.PVar (q, Substitution.LF.id), k),  Int.LF.Nil)

            | ( _ , _ ) -> raise (Error.Violation ("Projection on a parameter variable has a functional type"))
          end
	  )
        end

  (* Reconstruction for meta-variables  *)
  | Apx.LF.Root (loc, Apx.LF.MVar (Apx.LF.MInst (tN, tQ, cPhi), s'), Apx.LF.Nil)  ->
          let _ = dprint (fun () -> "[elTerm] Projected type of already reconstructed object " ^ 
			    " which is embedded into an approximate object:\n                  " ^ 
			    P.dctxToString cD cPhi ^ " |- " ^ 
			    P.normalToString cD cPhi (tN, Substitution.LF.id) ^ 
			    " : " ^ P.typToString cD cPhi (tQ, Substitution.LF.id)) in 
          let _ = dprint (fun () -> " in cD = " ^ P.mctxToString cD ) in

          let _ = dprint (fun () -> "\n Show cPsi = " ^ P.dctxToString cD  cPsi) in
          let _ = dprint (fun () -> "\n Show cPhi = " ^ P.dctxToString cD cPhi) in
          let s'' = elSub loc recT cD cPsi s' cPhi in

          let _ = dprint (fun () -> "[elTerm] " ^ P.dctxToString cD cPsi ^ " |- " ^ P.subToString cD cPsi s'' ^ " : " ^ P.dctxToString cD cPhi ) in 

          let _   = dprint (fun () -> "[elTerm] Apx-mvar: Expected type: " ^ P.typToString cD cPsi sP ^ "\n") in 
          let _   = dprint (fun () -> "[elTerm] Inferred type: " ^ P.typToString cD cPsi (tQ, s'') ^ "\n") in  
          begin
	    try
	      (* This case only applies to Beluga; MInst are introduced during cnormApxTerm. *)
	      Unify.unifyTyp cD  cPsi (tQ, s'') sP ;
	      dprint (fun () -> "[elTerm] reconstruction of mvar done ");
	      dprint (fun () -> "  sQ = " ^ P.typToString cD cPsi (tQ,s'') ^ " == " ^ P.typToString cD cPsi sP) ; 
	      dprint (fun () -> "  tN = " ^ P.normalToString cD cPsi (tN, s''));
	      Int.LF.Clo(tN, s'')
	    with Error.Violation msg  -> 
              (dprint (fun () -> "[elTerm] Violation: " ^ msg);
               dprint (fun () -> "[elTerm] Encountered term: " ^ P.normalToString cD cPsi (tN,s''));
               raise (Error (loc, CompTypAnn)))
              |  Unify.Unify msg  -> 
		dprint (fun () -> "[elTerm] Unification Violation: " ^ msg) ;
		dprint (fun () -> "[elTerm] Encountered term: " ^ P.normalToString cD cPsi (tN,s''));
		dprint (fun () -> "[elTerm] Expected type: " ^ P.typToString cD cPsi sP);
		dprint (fun () -> "[elTerm] Inferred type: " ^ P.typToString cD cPsi (tQ, s''));
		dprint (fun () -> "[elTerm] cD = " ^ P.mctxToString cD);
		raise (Error (loc, CompTypAnn))
              | _ ->
		begin
		  dprint (fun () -> "[elTerm] Encountered term: " ^ P.normalToString cD cPsi (tN,s''));
		  dprint (fun () -> "[elTerm] Inferred type: " ^ P.typToString cD cPsi (tQ, s'') ^ " does not match expected type");
		  raise (Error (loc, CompTypAnn))
		end
	  end

  | Apx.LF.Root (loc, Apx.LF.MVar (Apx.LF.Offset u, s'), spine) ->
      begin try
        let (_, tA, cPhi) = Whnf.mctxMDec cD u in
        let s'' = elSub loc recT cD cPsi s' cPhi in
        let (tS, sQ) = elSpine loc recT cD cPsi spine (tA, s'') in
        let tR = Int.LF.Root (loc, Int.LF.MVar (Int.LF.Offset u, s''), tS) in 
        begin
	  try
            Unify.unifyTyp cD cPsi sQ sP; 
            tR
          with
	    | Unify.Unify msg ->
              raise (Check.LF.Error (loc, Check.LF.TypMismatch (cD, cPsi, (tR, Substitution.LF.id), sQ, sP)))
            | _ ->
              raise (Check.LF.Error (loc, Check.LF.TypMismatch (cD, cPsi, (tR, Substitution.LF.id), sQ, sP)))
          end
      with Error.Violation msg ->
        dprint (fun () -> "[elTerm] Violation: " ^ msg);
        raise (Error (loc, CompTypAnn))
      end

  (* Reconstruction for parameter variables *)
  | Apx.LF.Root (loc, Apx.LF.PVar (Apx.LF.PInst (h, tA, cPhi), s'), spine) ->
      begin try
        let s'' = elSub loc recT cD cPsi s' cPhi in
        let (tS, sQ ) = elSpine loc recT cD cPsi spine (tA, s'')  in
        let _ = Unify.unifyTyp cD cPsi sQ sP  in
          begin match h with 
              | Int.LF.BVar k -> 
                  begin match Substitution.LF.bvarSub k s'' with 
                    | Int.LF.Head (Int.LF.BVar j) -> Int.LF.Root (loc, Int.LF.BVar j, tS)
                    | Int.LF.Head (Int.LF.PVar (p,r'))   -> Int.LF.Root (loc, Int.LF.PVar (p, Substitution.LF.comp r' s''), tS)
                  end 
              | Int.LF.PVar (p, r) -> Int.LF.Root (loc, Int.LF.PVar (p, Substitution.LF.comp r s''), tS)
            end              
            
      with _  -> 
        raise (Error (loc, CompTypAnn ))
        (* raise (Error (loc, TypMismatch (cD, cPsi, (tR, Substitution.LF.id), sQ, sP)))*)
      end


  | Apx.LF.Root (loc, Apx.LF.PVar (Apx.LF.Offset p,s'), spine) ->
    begin
      try 
        let (_, tA, cPhi) = Whnf.mctxPDec cD p in
        let s'' = elSub loc recT cD cPsi s' cPhi in
        let (tS, sQ) = elSpine loc recT cD cPsi spine (tA, s'')  in
        let tR = Int.LF.Root (loc, Int.LF.PVar (Int.LF.Offset p, s''), tS) in 
        begin
	  try
            Unify.unifyTyp cD cPsi sQ sP ; 
            tR
          with
	    | Unify.Unify msg -> 
              raise (Check.LF.Error (loc, Check.LF.TypMismatch (cD, cPsi, (tR, Substitution.LF.id), sQ, sP)))
        end
      with Error.Violation msg  -> 
        dprint (fun () -> "[elTerm] Violation: " ^ msg);
        raise (Error (loc, CompTypAnn ))
    end

  (* Reconstruction for projections *)
  | Apx.LF.Root (loc,  Apx.LF.Proj (Apx.LF.BVar x , k),  spine) ->
      let Int.LF.TypDecl (_, Int.LF.Sigma recA) = Context.ctxSigmaDec cPsi x in
      let sA       = Int.LF.getType (Int.LF.BVar x) (recA, Substitution.LF.id) k 1 in 
      let (tS, sQ) = elSpine loc recT cD  cPsi spine sA in 
      begin
	try
          Unify.unifyTyp cD cPsi sQ sP;
          Int.LF.Root (loc, Int.LF.Proj (Int.LF.BVar x, k), tS)
        with
	  | Unify.Unify msg ->
           raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
      end

  | Apx.LF.Root (loc,  Apx.LF.Proj (Apx.LF.PVar (Apx.LF.Offset p,t), k),  spine) ->
    begin
      match Whnf.mctxPDec cD p with
        | (_, Int.LF.Sigma recA, cPsi') -> 
          let t' = elSub loc recT cD  cPsi t cPsi' in 
          let  sA = Int.LF.getType (Int.LF.PVar (Int.LF.Offset p, t')) (recA, t') k 1 in 
          let (tS, sQ) = elSpine loc recT cD  cPsi spine sA in 
          begin
	    try
              Unify.unifyTyp cD cPsi sQ sP;
              Int.LF.Root (loc, Int.LF.Proj (Int.LF.PVar (Int.LF.Offset p,t'), k), tS)
	    with
	      | Unify.Unify msg ->
                raise (Error (loc, TypMismatchElab (cD, cPsi, sP, sQ)))
          end
        | _  -> raise (Error (loc, IllTypedElab (cD, cPsi, sP)))
    end


  | Apx.LF.Root (loc, Apx.LF.Proj(Apx.LF.PVar (Apx.LF.PInst (h, tA, cPhi), s'), k), spine) ->
      begin try
        let recA =
              match tA with
              | Int.LF.Sigma recA -> recA
              | _ -> 
                  dprint (fun () -> "Type of Parameter variable " ^ P.headToString cD cPhi h
                                  ^ "not a Sigma-Type, yet used with Projection; found "
                                  ^ P.typToString cD cPhi (tA, Substitution.LF.id) ^ "\n ill-typed") ;
                  raise (Error.Violation "Type of Parameter variable not a Sigma-Type, yet used with Projection; ill-typed")
        in 
        let s''       = elSub loc recT cD cPsi s' cPhi in
        let sA        = Int.LF.getType h (recA, s'') k 1 in 
        let (tS, sQ ) = elSpine loc recT cD cPsi spine sA  in
        let _ = Unify.unifyTyp cD cPsi sQ sP  in
          begin match h with 
              | Int.LF.BVar y -> 
                  begin match Substitution.LF.bvarSub y s'' with 
                    | Int.LF.Head (Int.LF.BVar x) -> 
                        Int.LF.Root (loc, Int.LF.Proj(Int.LF.BVar x, k), tS)
                    | Int.LF.Head (Int.LF.PVar (p,r'))   -> 
                        Int.LF.Root (loc, Int.LF.Proj(Int.LF.PVar (p, Substitution.LF.comp r' s''), k), tS)
                  end 
              | Int.LF.PVar (p, r) -> 
                  Int.LF.Root (loc, Int.LF.Proj(Int.LF.PVar (p, Substitution.LF.comp r s''), k), tS)
            end              
            
      with _   -> 
        raise (Error (loc, CompTypAnn ))
        (* raise (Error.Error (loc, Error.TypMismatch (cD, cPsi, (tR, Substitution.LF.id), sQ, sP)))*)
      end

  | Apx.LF.Root (loc, Apx.LF.Proj (Apx.LF.PVar (Apx.LF.MInst _ , _), _ ), _) ->
      raise (Error.Violation "[elTerm'] Proj (PVar (MInst _, _  ) _ , _ )")

  | Apx.LF.Root (loc, Apx.LF.Proj (Apx.LF.FMVar _, _ ), _) ->
      raise (Error.Violation "[elTerm'] Proj (FMVar _ , _ )")

  | Apx.LF.Root (loc, Apx.LF.PVar _, _) ->
      raise (Error.Violation "[elTerm'] PVar ")

  | Apx.LF.Root (loc, h, _s) -> 
      (dprint (fun () -> "[elTerm' **] h = " ^ what_head h ^ "\n") ;
            raise (Error (loc, CompTypAnn )))

  and instanceOfSchElem loc cD cPsi (tA, s) (some_part, sB) = 
    let _ = dprint (fun () -> "[instanceOfSchElem] Begin \n") in 
   (* let sArec = match Whnf.whnfTyp (tA, s) with
      | (Int.LF.Sigma tArec,s') ->  (tArec, s') 
      | (nonsigma, s')          ->  (Int.LF.SigmaLast nonsigma, s') in *)
    let _ = dprint (fun () -> ("tA =" ^ P.typToString cD cPsi (tA, s) ^ " \n")) in 
    let dctx        = projectCtxIntoDctx some_part in  
    let dctxSub     = Ctxsub.ctxToSub' cD cPsi dctx in

    (* let phat        = dctxToHat cPsi in *)

    let _ =  dprint (fun () -> "***Unify.unifyTyp (" 
                        ^ "\n   cPsi = " ^ P.dctxToString cD cPsi
                        ^ "\n   dctx = " ^ P.dctxToString cD dctx  
                        ^ "\n   " ^  P.typToString cD cPsi (tA, s) ) in
    let _ = dprint (fun () -> "dctxSub = " ^ P.subToString cD cPsi dctxSub ^ "\n") in

    let _ = dprint (fun () ->  P.typToString cD cPsi (tA,s)) in  
    let _ = dprint (fun () ->  "== " ) in 
    let _ = dprint (fun () -> P.typToString cD cPsi (Int.LF.TClo sB, dctxSub) ^ "\n" )  in
    let nB  = Whnf.normTyp (Int.LF.TClo sB, dctxSub) in 
    let nA  = Whnf.normTyp (tA,s) in 
      begin
        try
          Unify.unifyTyp cD cPsi (nA, Substitution.LF.id) (nB, Substitution.LF.id) 
        ; dprint (fun () -> "instanceOfSchElem\n"
                            ^ "  block_part = " ^ P.typToString cD cPsi (Int.LF.TClo sB, dctxSub) ^ "\n"
                            ^ "  succeeded.")
        ; (Int.LF.TClo sB, dctxSub)
        with (Unify.Unify _)  ->
          (dprint (fun () -> "Type " ^ P.typToString cD cPsi (tA,s) ^ " doesn't unify with schema element\n");
(*          dprint (fun () ->  P.typRecToString cD cPsi (block_part, dctxSub)) *)
           
             raise (Error (loc, TypMismatchElab (cD, cPsi, (nA, Substitution.LF.id), (nB, Substitution.LF.id)))))
          | exn -> 
              (dprint (fun () -> "[instanceOfSchElem] Non-Unify ERROR -2- "); raise exn)
      end
  
  and instanceOfSchElemProj loc cD cPsi (tA, s) (var, k) (Int.LF.SchElem (cPhi, trec)) = 
    let _ = dprint (fun () -> "[instanceOfSchElemProj] getType of " ^ string_of_int k ^ ". argument\n") in 
    let cPhi'  = projectCtxIntoDctx cPhi in  
    let _ = dprint (fun () -> " of " ^ P.typRecToString cD cPhi' (trec, Substitution.LF.id)) in
    let _ = dprint (fun () -> " var = " ^ P.headToString cD cPsi var) in
    let sA_k (* : tclo *) = Int.LF.getType var (trec, Substitution.LF.id) k 1 in  (* bp - generates  general type with some-part still intact; this tA_k is supposed to be the type of #p.1 s - hence,eventually it the some part needs to be restricted appropriately. Tue May 25 10:13:07 2010 -bp *)
    let _ = dprint (fun () -> "[instanceOfSchElemProj] retrieved the type  " ^ P.typToString cD cPhi' sA_k) in
    let (_tA'_k, subst) =
      instanceOfSchElem loc cD cPsi (tA, s) (cPhi, sA_k)
      (* tA'_k = [subst] (sA_k) = [s]tA *)
    in
      (trec, subst) 

(* Synthesize the type for a free parameter variable *)
and synSchemaElem loc recT  cD cPsi ((_, s) as sP) (head, k) ((Int.LF.Schema elements) as schema) =
  let self = synSchemaElem loc recT cD cPsi sP (head, k) in 
  let _ = dprint (fun () -> "synSchemaElem ... head = " ^ 
                    P.headToString cD cPsi head ^ " Projection " ^ 
                    string_of_int k  ^ "\n") in
  let _ = dprint (fun () -> "[synSchemaElem]  " ^ P.typToString cD cPsi sP
                    ^ "  schema= " ^ P.schemaToString schema) in
    match elements with
      | [] -> None
      | (Int.LF.SchElem (_some_part, block_part)) as elem  ::  rest  ->
          try
            let _ = dprint (fun () -> "[instanceOfSchElemProj ] ... ") in
            let (typRec, subst) = instanceOfSchElemProj loc cD cPsi sP (head, k) elem in 
              (* Check.LF.instanceOfSchElemProj loc cO cD cPsi sP (head, k) elem in *)
            dprint (fun () -> "synSchemaElem RESULT = "
                            ^ P.typRecToString cD cPsi (typRec, subst))
          ; Some (typRec, subst) (* sP *)
          with Unify.Unify _  -> self (Int.LF.Schema rest)
            | Not_found -> self (Int.LF.Schema rest) 



and elClosedTerm' recT cD cPsi r = match r with
  | Apx.LF.Root (loc, Apx.LF.Const c, spine) ->
      let tA = (Term.get c).Term.typ in
      let i  = (Term.get c).Term.implicit_arguments in
      (* let s  = mkShift recT cPsi in *)
      let s = Substitution.LF.id in
      let (tS, sQ ) = elSpineI loc recT cD cPsi spine i (tA, s)   in
        (Int.LF.Root (loc, Int.LF.Const c, tS), sQ)

  | Apx.LF.Root (loc, Apx.LF.BVar x, spine) ->
      let Int.LF.TypDecl (_, tA) = Context.ctxDec cPsi x in
      let (tS, sQ ) = elSpine loc recT cD cPsi spine (tA, Substitution.LF.id) in
        (Int.LF.Root (loc, Int.LF.BVar x, tS), sQ)

  | Apx.LF.Root (loc, Apx.LF.MVar (Apx.LF.Offset u, s), spine) ->
      begin try 
        let (_ , tA, cPhi) = Whnf.mctxMDec cD u in
        let s'' = elSub loc recT cD cPsi s cPhi in
        let (tS, sQ ) = elSpine loc recT cD cPsi spine (tA, s'')  in
          (Int.LF.Root (loc, Int.LF.MVar (Int.LF.Offset u, s''), tS) , sQ)
      with Error.Violation msg  -> 
        dprint (fun () -> "[elClosedTerm] Violation: " ^ msg);
         raise (Error (loc, CompTypAnn))
      end

  | Apx.LF.Root (loc, Apx.LF.PVar (Apx.LF.Offset p, s'), spine) ->
      begin try
        let (_, tA, cPhi) = Whnf.mctxPDec cD p in
        let s'' = elSub loc recT cD cPsi s' cPhi in
        let (tS, sQ ) = elSpine loc recT cD cPsi spine (tA, s'')  in
          (Int.LF.Root (loc, Int.LF.PVar (Int.LF.Offset p, s''), tS) , sQ)
      with Error.Violation msg  -> 
        dprint (fun () -> "[elClosedTerm] Violation: " ^ msg);
         raise (Error (loc, CompTypAnn ))
      end


  | Apx.LF.Root (loc, Apx.LF.PVar (Apx.LF.PInst (Int.LF.PVar (p0,s0), tA, cPhi), s'), spine) -> 
      begin try 
        let s'' = elSub loc recT cD cPsi s' cPhi in
        let (tS, sQ ) = elSpine loc recT cD cPsi spine (tA, s'')  in
          (Int.LF.Root(loc, Int.LF.PVar (p0, Substitution.LF.comp s0 s''), tS)  , sQ)
      with Error.Violation msg  -> 
        dprint (fun () -> "[elClosedTerm] Violation: " ^ msg);
         raise (Error (loc, CompTypAnn))
      end


  | Apx.LF.Root (loc, Apx.LF.MVar (Apx.LF.MInst (tM', tA, cPhi), s'), spine) -> 
      begin try 
        let s'' = elSub loc recT cD cPsi s' cPhi in
        let (tS, sQ ) = elSpine loc recT cD cPsi spine (tA, s'')  in
          (Whnf.reduce (tM', s'') tS  , sQ)
      with Error.Violation msg  -> 
        dprint (fun () -> "[elClosedTerm] Violation: " ^ msg);
         raise (Error (loc, CompTypAnn))
      end

  | Apx.LF.Root (loc,  Apx.LF.Proj (Apx.LF.BVar x , k),  spine) ->
      let Int.LF.TypDecl (_, Int.LF.Sigma recA) = Context.ctxSigmaDec cPsi x in
      let sA       = Int.LF.getType (Int.LF.BVar x) (recA, Substitution.LF.id) k 1 in 
      let (tS, sQ) = elSpine loc recT cD  cPsi spine sA in 
        (Int.LF.Root (loc, Int.LF.Proj (Int.LF.BVar x, k), tS) , sQ)

  | Apx.LF.Root (loc,  Apx.LF.Proj (Apx.LF.PVar (Apx.LF.Offset p,t), k),  spine) ->
      begin match Whnf.mctxPDec cD p with
        | (_, Int.LF.Sigma recA, cPsi') -> 
            let t' = elSub loc recT cD  cPsi t cPsi' in 
            let  sA = Int.LF.getType (Int.LF.PVar (Int.LF.Offset p, t')) (recA, t') k 1 in 
            let (tS, sQ) = elSpine loc recT cD  cPsi spine sA in 
              (Int.LF.Root (loc, Int.LF.Proj (Int.LF.PVar (Int.LF.Offset p,t'), k), tS) , sQ)
        | _  -> 
	    dprint (fun () -> "[elClosedTerm'] Looking for p with offset " ^ R.render_offset p);
	    dprint (fun () -> "in context cD = " ^ P.mctxToString cD);
	    raise (Error (loc, CompTypAnn))
      end

  | Apx.LF.Root (loc, Apx.LF.Proj (Apx.LF.PVar (Apx.LF.PInst (h, tA, cPsi' ) , s ), k ) , spine ) ->
      begin match (h, tA) with 
	| (Int.LF.PVar (Int.LF.Offset p, s') , Int.LF.Sigma recA) -> 
	    let t' = elSub loc recT cD  cPsi s cPsi' in 
	    let s = Substitution.LF.comp s' t' in 
	    let  sA = Int.LF.getType (Int.LF.PVar (Int.LF.Offset p, s)) (recA, t') k 1 in 
	    let (tS, sQ) = elSpine loc recT cD  cPsi spine sA in 
	      (Int.LF.Root (loc, Int.LF.Proj (Int.LF.PVar (Int.LF.Offset p,s), k), tS) , sQ)
		
        | _  -> 
	    dprint (fun () -> "[elClosedTerm'] Looking for p " ^ P.headToString cD cPsi' h);
		  raise (Error (loc, CompTypAnn))
      end 




  | Apx.LF.Root (loc, _ , _ ) ->
      (dprint (fun () -> "[elClosedTerm'] Head not covered?");
      raise (Error (loc, CompTypAnn )))

  | Apx.LF.Lam (loc, _, _ ) -> 
      raise (Error (loc, CompTypAnn ))

  | _ -> (dprint (fun () -> "[elClosedTerm] Violation?");
                raise (Error (Syntax.Loc.ghost, CompTypAnn)))



(* elSub recT cD cPsi s cPhi = s' *)
and elSub loc recT cD cPsi s cPhi =
  match (s, cPhi) with
  | (Apx.LF.EmptySub, Int.LF.Null) ->
    begin match Context.dctxToHat cPsi with
      | (Some psi, d) -> Int.LF.Shift (Int.LF.CtxShift psi, d)
      | (None, d)     -> Int.LF.Shift (Int.LF.NoCtxShift, d)
    end

  | (Apx.LF.SVar (Apx.LF.Offset offset, s), (Int.LF.CtxVar phi as cPhi)) ->
    let (_, Int.LF.CtxVar phi', cPhi2) = Whnf.mctxSDec cD offset in
    if phi = phi' then
      let s' = elSub loc recT cD cPsi s cPhi in
      Int.LF.SVar (Int.LF.Offset offset, s')
    else raise (Error (loc, SubIllTyped))

  | (Apx.LF.Id _ , Int.LF.CtxVar phi) ->
      begin match Context.dctxToHat (C.cnormDCtx (cPsi, C.m_id)) with
        | (Some psi, d)  ->
(*            if psi = phi then  *)
            let _ = dprint (fun () -> "[elSub] \n cD = " ^ 
                              P.mctxToString cD ^ "\n cPsi " ^ P.dctxToString cD cPsi 
                              ^ "\n phi = " ^ P.dctxToString cD cPhi ^ "\n") in
            if unify_phat (Some phi, 0) (Some psi, 0) then   
              Int.LF.Shift(Int.LF.NoCtxShift, d)
            else
              (* check for context subsumption *)
              if Check.LF.subsumes cD phi psi (* psi |- wk_sub : phi *)then
                Int.LF.Shift (Int.LF.NoCtxShift, d)
              else 
                raise (Error.Violation ("elSub: not identity substitution between ctxvar: "
                                        ^ "`" ^ P.dctxToString cD cPhi ^ "' does not match `" ^ 
                                        P.dctxToString cD cPsi ^ "'"))
                
        | _ ->
            raise (Error.Violation "Id must be associated with ctxvar")
      end


  | (Apx.LF.Dot (Apx.LF.Head h, s),   Int.LF.DDec (cPhi', Int.LF.TypDecl (_, tA))) ->
      (* NOTE: if decl = x:A, and cPsi(h) = A' s.t. A =/= A'
       *       we will fail during reconstruction / type checking
       *)
      let _ = dprint (fun () -> "[elSub] elaborate head ") in 
      let _ = dprint (fun () -> "[elSub] in cPsi = " ^ P.dctxToString cD  cPsi) in
      let (h', sA') = elHead loc recT cD cPsi h in 
      let s' = elSub  loc recT cD cPsi s cPhi' in 
      begin try 
          Unify.unifyTyp cD cPsi sA' (tA, s');
          Int.LF.Dot (Int.LF.Head h', s')
      with
        |  _ -> raise (Error (loc, TypMismatchElab (cD, cPsi, sA', (tA, s'))))
      end


  | (Apx.LF.Dot (Apx.LF.Obj m, s),   Int.LF.DDec (cPhi', Int.LF.TypDecl(_, tA))) ->
      let s' = elSub loc recT cD cPsi s cPhi' in
      let m' = elTerm recT cD cPsi m (tA, s') in
        Int.LF.Dot (Int.LF.Obj m', s')

  | (s, cPhi) ->
      (dprint (fun () -> 
                 let s = begin match s with 
                   | Apx.LF.Dot _ -> "Dot _ " 
                   | Apx.LF.EmptySub -> " . " 
                   | Apx.LF.Id _ -> " .. " 
                 end in 
                   "Expected substitution : " ^ P.dctxToString cD cPsi  ^ 
                     " |- " ^ s ^ " : " ^ P.dctxToString cD cPhi) ;
       raise (Error (loc, IllTypedIdSub)))


and elHead loc recT cD cPsi = function
  | Apx.LF.BVar x ->
      let _ = dprint (fun () -> "[elHead] cPsi = " ^ P.dctxToString cD cPsi ^ "|- BVar " ^ string_of_int x ) in 
      let Int.LF.TypDecl (_, tA') = Context.ctxDec (Whnf.cnormDCtx (cPsi, Whnf.m_id)) x in
      let _ = dprint (fun () -> "[elHead] done") in 
        (Int.LF.BVar x,  (tA' , Substitution.LF.id))

  | Apx.LF.Const c ->
      let tA = (Term.get c).Term.typ in
        (Int.LF.Const c , (tA, Substitution.LF.id))

  | Apx.LF.MVar (Apx.LF.Offset u, s) ->
      begin try
        let (_ , tA, cPhi) = Whnf.mctxMDec cD u in
        let s'  = elSub loc recT cD cPsi s cPhi in 
          (Int.LF.MVar (Int.LF.Offset u, s') , (tA, s'))
      with Error.Violation msg  -> 
        dprint (fun () -> "[elHead] Violation: " ^ msg);
         raise (Error (loc, CompTypAnn ))
      end 

  | Apx.LF.PVar (Apx.LF.Offset p, s) ->
      begin try 
        let (_, tA, cPhi) = Whnf.mctxPDec cD p in 
        let s' = elSub loc recT cD cPsi s cPhi in 
          (Int.LF.PVar (Int.LF.Offset p, s') , (tA, s'))
      with Error.Violation msg  -> 
        dprint (fun () -> "[elHead] Violation: " ^ msg);
        raise (Error (loc, CompTypAnn ))
      end

  | Apx.LF.PVar (Apx.LF.PInst (Int.LF.PVar (p,r), tA, cPhi), s) -> 
      begin try
        let s' = elSub loc recT cD cPsi s cPhi in 
        let r' = Substitution.LF.comp r s' in 
         (Int.LF.PVar (p, r') , (tA, r')) 
      with Error.Violation msg -> 
        dprint (fun () -> "[elHead] Violation: " ^ msg);
        raise (Error (loc, CompTypAnn ))
      end
      

  | Apx.LF.FVar x ->
      raise (Index.Error (loc, Index.UnboundName x))
      (* Int.LF.FVar x *)

  | Apx.LF.FMVar (u, s) ->       
      begin try 
        let (offset, (tP, cPhi)) = Whnf.mctxMVarPos cD u  in
        let s' = elSub loc recT cD cPsi s cPhi in 
         (Int.LF.MVar (Int.LF.Offset offset,s'), (tP, s'))
      with Whnf.Fmvar_not_found -> 
       raise (Index.Error (Syntax.Loc.ghost, Index.UnboundName u))
      end 

  | Apx.LF.FPVar (p, s) ->
      let (offset, (tA, cPhi)) = Whnf.mctxPVarPos cD p  in
      let s' = elSub loc recT cD cPsi s cPhi in 
        (Int.LF.PVar (Int.LF.Offset offset, s') , (tA, s'))

  | Apx.LF.Proj (head, i) ->
      let (head', sA) = elHead loc recT cD cPsi head in
      let sAi = begin match Whnf.whnfTyp sA with
                 | (Int.LF.Sigma tA'rec, s') ->
                     Int.LF.getType head' (tA'rec, s') i 1 
                 | (tA',s') -> raise (Error.Violation ("[elHead] expected Sigma type  " 
                                                 ^ "found type " ^ P.typToString cD cPsi (tA', s')))
                end
      in
        (Int.LF.Proj (head', i) , sAi )

  | h -> raise (Error.Violation (what_head h))

(* elSpineI  recT cD cPsi spine i sA  = (S : sP)
 * elSpineIW recT cD cPsi spine i sA  = (S : sP)
 *
 *   where sA = (A,s) and sP = (P,s')
 *     and sA and sP in whnf
 *
 * Pre-condition:
 *   U = free variables
 *   O = meta-variables for implicit arguments
 *
 * Invariant:
 *
 * If O1 ; U1 ; (cD ; cPsi) |- spine <= [s]A  /_r (O2 ; U2) S
 * then
 *    O2 ; U2 ; [|r|](cD ; cPsi) |- S <= [|r|]([s]A) : [|r|]([s']P)
 *
 *
 * Post-condition:
 *     U2 = FV(A)  where U2 is an extension of U1 s.t. [|r|]U1,U0 = U2
 *     O2 = FMV(A) where O2 |-{U2} r <= O1

 *   U2 = extension of U1 containing all free variables of S
 *   O2 = extension of O1 containing i new meta-variables
 *            for implicit arguments
 *
 *   S is in beta-eta-normalform
 *
 * Comment: elSpineI will insert new meta-variables (as references)
 *   for omitted implicit type arguments; 
 *)
and elSpineI loc recT cD cPsi spine i sA =
  elSpineIW loc recT cD cPsi spine i (Whnf.whnfTyp sA) 

and elSpineIW loc recT cD cPsi spine i sA  =
  if i = 0 then
    elSpine loc recT cD cPsi spine sA 
  else
    match (sA, recT) with
      | ((Int.LF.PiTyp ((Int.LF.TypDecl (_, tA), _ ), tB), s), Pi) ->
          (* cPsi' |- tA <= typ
           * cPsi  |- s  <= cPsi'      cPsi |- tN <= [s]A
           *
           * tN = u[s']  and u::A'[.]
           *
           * s.t.  cPsi |- u[s'] => [s']A'  where cPsi |- s' : .
           *   and    [s]A = [s']A'. Therefore A' = [s']^-1([s]A)
           *)
          (* let (_, d) = Context.dctxToHat cPsi in
          let tN     = Whnf.etaExpandMV Int.LF.Null (tA, s) (Int.LF.Shift(Int.LF.NoCtxShift, d)) in   *)
          let tN     = Whnf.etaExpandMV cPsi (tA, s) Substitution.LF.id in 

          let (spine', sP) = elSpineI loc recT cD cPsi spine (i - 1) (tB, Int.LF.Dot (Int.LF.Obj tN, s)) in
            (Int.LF.App (tN, spine'), sP)

      | ((Int.LF.PiTyp ((Int.LF.TypDecl (_, tA), _), tB), s), Pibox) ->
          (* cPsi' |- tA <= typ
           * cPsi  |- s  <= cPsi'      cPsi |- tN <= [s]A
           *
           * tN = u[s']  and u::P[Psi, x1:A1,....xn:An]  and A = Pi x1:A1 ... Pi xn:An.P
           *
           * s.t.  cPsi |- \x1...\xn. u[id] => [id]A  where cPsi |- id : cPsi
           *)
           let tN     = Whnf.etaExpandMMV loc cD cPsi (tA, s) Substitution.LF.id in 
          (* let tN     = etaExpandMMVstr loc cO cD cPsi (tA, s) in *)

          let (spine', sP) = elSpineI loc recT cD cPsi spine (i - 1) (tB, Int.LF.Dot (Int.LF.Obj tN, s)) in
            (Int.LF.App (tN, spine'), sP)

      (* other cases impossible by (soundness?) of abstraction *)

(* elSpine loc recT cD cPsi spine sA = S
 * elSpineW cD cPsi spine sA  = S
 *   where sA = (A,s) and sA in whnf
 *
 * Pre-condition:
 *   U = free variables
 *   O = meta-variables for implicit arguments
 *
 * Invariant:
 *
 * If O ; U ; cPsi |- spine <- [s]A  (approx)
 * then
 *    O' ; U' ; cPsi |- S <- [s]A  (pre-dependent)
 *
 *
 * Post-condition:
 *   U' = extension of U containing all free variables of S
 *   O' = extension of O containing new meta-variables of S
 *)
and elSpine loc recT cD cPsi spine sA =
  let rec spineLength = function
    | Apx.LF.Nil -> 0
    | Apx.LF.App (_, tS) -> 1 + spineLength tS in

  let rec typLength = function
    | Int.LF.Atom _ -> 0
    | Int.LF.PiTyp (_, tB2) -> 1 + typLength tB2 in

  (* Check first that we didn't supply too many arguments. *)
  if typLength (fst sA) < spineLength spine then
    raise (Check.LF.Error (loc, Check.LF.SpineIllTyped (typLength (fst sA), spineLength spine)));
  let rec elSpine loc rectT cD cPsi spine sA = match spine, sA with
    | Apx.LF.Nil, sP ->
      (Int.LF.Nil, sP) (* errors are postponed to reconstruction phase *)

    | Apx.LF.App (m, spine), (Int.LF.PiTyp ((Int.LF.TypDecl (_, tA), _ ), tB), s) ->
      let tM = elTerm recT cD cPsi m (tA, s) in
      let (tS, sP) = elSpine loc recT cD cPsi spine (tB, Int.LF.Dot (Int.LF.Obj tM, s)) in
      (Int.LF.App (tM, tS), sP)
  in elSpine loc recT cD cPsi spine (Whnf.whnfTyp sA)

(* see invariant for elSpineI *)
and elKSpineI loc recT cD cPsi spine i sK =
  if i = 0 then
    elKSpine loc recT cD cPsi spine sK
  else
    match (sK, recT) with
      | ((Int.LF.PiKind ((Int.LF.TypDecl (_, tA), _), tK), s), Pi) ->
          (* let sshift = mkShift recT cPsi in *)
          (* let tN     = Whnf.etaExpandMV Int.LF.Null (tA,s) sshift in *)
          let tN     = Whnf.etaExpandMV cPsi (tA, s) Substitution.LF.id in
          let spine' = elKSpineI loc recT cD cPsi spine (i - 1) (tK, Int.LF.Dot (Int.LF.Obj tN, s)) in
            Int.LF.App (tN, spine')
      | ((Int.LF.PiKind ((Int.LF.TypDecl (_, tA), _), tK), s), Pibox) ->
          (* let sshift = mkShift recT cPsi in *)
          let tN     = Whnf.etaExpandMMV Syntax.Loc.ghost cD cPsi (tA, s) Substitution.LF.id in 
          (* let tN = etaExpandMMVstr None cO cD cPsi (tA, s) in  *)
          let spine' = elKSpineI loc recT cD cPsi spine (i - 1) (tK, Int.LF.Dot (Int.LF.Obj tN, s)) in
            Int.LF.App (tN, spine')


(* see invariant for elSpine *)
and elKSpine loc recT cD cPsi spine sK =
  let rec spineLength = function
    | Apx.LF.Nil -> 0
    | Apx.LF.App (_, tS) -> 1 + spineLength tS in

  let rec kindLength = function
    | Int.LF.Typ -> 0
    | Int.LF.PiKind (_, tK) -> 1 + kindLength tK in

  (* Check first that we didn't supply too many arguments. *)
  if kindLength (fst sK) < spineLength spine then
    raise (Check.LF.Error (loc, Check.LF.SpineIllTyped (kindLength (fst sK), spineLength spine)));
  let rec elKSpine loc recT cD cPsi spine sK = match spine, sK with
    | Apx.LF.Nil, (Int.LF.Typ, _s) ->
      Int.LF.Nil (* errors are postponed to reconstruction phase *)

    | Apx.LF.App (m, spine), (Int.LF.PiKind ((Int.LF.TypDecl (_, tA), _), tK), s) ->
      let tM = elTerm recT cD cPsi m (tA, s) in
      let tS = elKSpine loc recT cD cPsi spine (tK, Int.LF.Dot (Int.LF.Obj tM, s)) in
      Int.LF.App (tM, tS)
  in elKSpine loc recT cD cPsi spine sK

(* elSpineSynth cD cPsi p_spine s' = (S, A')
 *
 * Pre-condition:
 *   U = free variables
 *   O = meta-variables for implicit arguments
 *
 * Invariant:
 *
 * If O ; U ; (cD ; cPsi) |- spine < [s]P
 *    and spine is a pattern spine
 *
 *            cD ; cPsi |- s' <= .      |cPsi| = d  and s' = ^d
 *
 *
 *            cD ; cPsi |- s   <= cPsi'
 *            Cd ;   .  |- ss' <= cPsi
 *
 * then O ; U ; (cD ; cPsi) |- S : [s']A' < [s]P
 *
 * Post-condition:
 *   U = containing all free variables of S (unchanged)
 *   O = containing new meta-variables of S (unchanged)
 *)
and elSpineSynth recT cD cPsi spine s' sP = match (spine, sP) with
  | (Apx.LF.Nil, (_tP, _s))  ->
      let ss = Substitution.LF.invert s' in
      let tQ = pruningTyp Syntax.Loc.ghost cD cPsi (*?*) (Context.dctxToHat cPsi) sP (Int.LF.MShift 0, ss) in 
      (* PROBLEM: [s'][ss] [s]P is not really P; in fact [ss][s]P may not exist;
       * We use pruning to ensure that [ss][s]P does exist
       *)
        (Int.LF.Nil, tQ) 

  | (Apx.LF.App (Apx.LF.Root (loc, Apx.LF.BVar x, Apx.LF.Nil), spine), sP) ->
      let Int.LF.TypDecl (_, tA) = Context.ctxDec cPsi x in
        (* cPsi |- tA : type
         * cPsi |- s' : cPsi'
         *)
      let ss = Substitution.LF.invert s' in
      (* let tA' = Whnf.normTyp (tA, ss) in *)
      (* Is [ss]A  always guaranteed to exist? - No. Use pruning to ensure it does exist. *)
      let tA' = pruningTyp loc cD cPsi (*?*) (Context.dctxToHat cPsi)  (tA, Substitution.LF.id) (Int.LF.MShift 0, ss) in 

      let _ = dprint (fun () -> "elSpineSynth: PruneTyp done\n") in 

      (*   cPsi |- s', x : cPsi', y:tA' *)
      let (tS, tB) = elSpineSynth recT  cD cPsi spine (Int.LF.Dot (Int.LF.Head(Int.LF.BVar x), s')) sP in
        (*  cPsi |- tS : [s', x]tB <= sP  *)
        (*  cPsi, y:A |- tB' <= type  *)
      let _ = dprint (fun () -> "elSpineSynth done \n") in 
      let tB' =  Int.LF.PiTyp ((Int.LF.TypDecl (Id.mk_name (Id.BVarName (Typ.gen_var_name tA')), tA'), 
                                Int.LF.Maybe), tB) in 

      let tN' = etaExpandHead loc (Int.LF.BVar x) tA' in 
        (Int.LF.App (tN', tS), tB')

   (* other cases impossible *)


let rec elCtxVar c_var = match c_var with 
  | Apx.LF.CtxOffset offset  -> Int.LF.CtxOffset offset
  | Apx.LF.CtxName psi       -> Int.LF.CtxName psi

let rec elDCtx recT cD psi = match psi with
  | Apx.LF.Null -> Int.LF.Null

  | Apx.LF.CtxVar (c_var) -> 
      let cPsi = Int.LF.CtxVar(elCtxVar c_var) in 
	(dprint (fun () -> "[elDCtx] " ^ P.dctxToString cD cPsi );
	cPsi)

  | Apx.LF.DDec (psi', Apx.LF.TypDecl (x, a)) ->
      let cPsi = elDCtx recT cD psi' in
      let _ = dprint (fun () -> "[elDCtx] cPsi = " ^ P.dctxToString cD cPsi) in 
      let tA   = elTyp  recT cD cPsi a in
      let _ = dprint (fun () -> "[elDCtx] " ^ R.render_name x ^ ":" ^
                        P.typToString cD cPsi (tA, Substitution.LF.id)) in 
        Int.LF.DDec (cPsi, Int.LF.TypDecl (x, tA))

(* ******************************************************************* *)
(* Solve free variable constraints *)

let rec solve_fvarCnstr recT cD cnstr = match cnstr with
  | [] -> ()
  | ((_ , Apx.LF.Root (loc, Apx.LF.FVar x, spine), 
      Int.LF.Inst ({contents = None} as r, cPsi, tP, _)) :: cnstrs) -> 
      begin try
	begin match FVar.get x with
          | Int.LF.Type tA -> 
              (* For type reconstruction to succeed, we must have
               *  . |- tA <= type
               *  This will be enforced during abstraction.
               *)
              let sshift = mkShift recT cPsi in

              (* let tS = elSpine cPsi spine (tA, Substitution.LF.id) (tP,s) in *)
              let (tS, sQ ) = elSpine loc recT cD cPsi spine (tA, sshift) in
	      begin
		try
                  Unify.unifyTyp cD cPsi sQ (tP, Substitution.LF.id);
                  r := Some (Int.LF.Root (loc, Int.LF.FVar x, tS));
                  solve_fvarCnstr recT cD cnstrs
		with
		  | Unify.Unify msg ->
		    raise (Error (loc, TypMismatchElab (cD, cPsi, (tP, Substitution.LF.id), sQ)))
	      end
          | Int.LF.TypVar _ -> 
              raise (Error (loc, LeftoverConstraints x))
	end
      with _ -> raise (Index.Error (loc, Index.UnboundName x)) 
      end 


  | ((_ , Apx.LF.Root (loc, Apx.LF.FVar x, spine), 
      Int.LF.Inst ({contents = Some tR}, cPsi, tP, _ )) :: cnstrs) ->
      begin try 
        begin match FVar.get x with
        | Int.LF.Type tA -> 
          (* For type reconstruction to succeed, we must have
           *  . |- tA <= type
           *  This will be enforced during abstraction.
           *)
            let sshift = mkShift recT cPsi in

            (* let tS = elSpine cPsi spine (tA, Substitution.LF.id) (tP,s) in *)
            let (tS, sQ ) = elSpine loc recT cD cPsi spine (tA, sshift) in
            (* let psihat = Context.dctxToHat cPsi in *)
            begin
	      try 
                Unify.unifyTyp cD cPsi sQ (tP, Substitution.LF.id) ;
                Unify.unify cD cPsi 
		  (Int.LF.Root (loc, Int.LF.FVar x, tS), Substitution.LF.id) 
		  (tR, Substitution.LF.id);
		(* r := Some (Int.LF.Root (loc, Int.LF.FVar x, tS)); *)
		solve_fvarCnstr recT cD cnstrs
	      with
		| Unify.Unify msg ->
		  raise (Error (loc, TypMismatchElab (cD, cPsi, (tP, Substitution.LF.id), sQ)))
            end
        | Int.LF.TypVar _ -> 
          raise (Error (loc, LeftoverConstraints x))
      end

    with _ -> raise (Index.Error (loc, Index.UnboundName x)) 
    end 

let rec solve_fcvarCnstr cD cnstr = match cnstr with
  | [] -> ()
  | ((Apx.LF.Root (loc, Apx.LF.FMVar (u,s), _nil_spine), Int.LF.Inst (r, cPsi, _, _)) :: cnstrs) ->
      begin try
        let (cD_d, Int.LF.MDecl (_, _tP, cPhi)) = FCVar.get u in
	let d = Context.length cD - Context.length cD_d in 
	let cPhi = (if d = 0 then cPhi else 
                      Whnf.cnormDCtx (cPhi, Int.LF.MShift d)) in 
        let s'' = elSub loc Pibox cD cPsi s cPhi in
          r := Some (Int.LF.Root (loc, Int.LF.FMVar (u, s''), Int.LF.Nil));
          solve_fcvarCnstr cD cnstrs
      with Not_found ->
        raise (Error (loc, LeftoverConstraints u))
      end

  | ((Apx.LF.Root (loc, Apx.LF.FPVar (x,s), spine), Int.LF.Inst (r, cPsi, _, _)) :: cnstrs) ->
      begin try
        let (cD_d, Int.LF.PDecl (_, tA, cPhi)) = FCVar.get x in
	let d = Context.length cD - Context.length cD_d in 
	let (tA, cPhi) = if d = 0 then (tA, cPhi) else 
	  (Whnf.cnormTyp (tA, Int.LF.MShift d), Whnf.cnormDCtx (cPhi, Int.LF.MShift d)) in 

        let s'' = elSub loc Pibox cD cPsi s cPhi in

        (* let tS = elSpine cPsi spine (tA, LF.id) (tP,s) in *)
        let (tS, _ ) = elSpine loc Pibox cD cPsi spine (tA, s'') in
          r := Some (Int.LF.Root (loc, Int.LF.FPVar (x,s''), tS));
          solve_fcvarCnstr cD cnstrs
      with Not_found ->
        raise (Error (loc, LeftoverConstraints x))
      end

let solve_constraints cD' = 
  (solve_fcvarCnstr cD' !fcvar_cnstr ; 
  reset_fcvarCnstr (); 
  Unify.forceGlobalCnstr (!Unify.globalCnstrs); 
  Unify.resetGlobalCnstrs () ) 

let solve_fvarCnstr rectyp = 
  solve_fvarCnstr rectyp Int.LF.Empty !fvar_cnstr
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, PatternGuards #-}

{- A high level language of tactic composition, for building
   elaborators from a high level language into the core theory.

   This is our interface to proof construction, rather than
   ProofState, because this gives us a language to build derived
   tactics out of the primitives.
-}

module Core.Elaborate(module Core.Elaborate, 
                      module Core.ProofState) where

import Core.ProofState
import Core.TT
import Core.Evaluate
import Core.Typecheck

import Control.Monad.State
import Data.Char
import Data.List
import Debug.Trace

-- I don't really want this here, but it's useful for the test shell
data Command = Theorem Name Raw
             | Eval Raw
             | Quit
             | Print Name
             | Tac (Elab ())

data ElabState aux = ES (ProofState, aux) String (Maybe (ElabState aux))
  deriving Show
type Elab' aux a = StateT (ElabState aux) TC a
type Elab a = Elab' () a

proof :: ElabState aux -> ProofState
proof (ES (p, _) _ _) = p

saveState :: Elab' aux ()
saveState = do e@(ES p s _) <- get
               put (ES p s (Just e))

loadState :: Elab' aux ()
loadState = do (ES p s e) <- get
               case e of
                  Just st -> put st
                  _ -> fail "Nothing to undo"

erun :: FC -> Elab' aux a -> Elab' aux a
erun f elab = do s <- get
                 case runStateT elab s of
                    OK (a, s')     -> do put s'
                                         return a
                    Error (At f e) -> lift $ Error (At f e)
                    Error e        -> lift $ Error (At f e)

runElab :: aux -> Elab' aux a -> ProofState -> TC (a, ElabState aux)
runElab a e ps = runStateT e (ES (ps, a) "" Nothing)

execElab :: aux -> Elab' aux a -> ProofState -> TC (ElabState aux)
execElab a e ps = execStateT e (ES (ps, a) "" Nothing)

initElaborator :: Name -> Context -> Type -> ProofState
initElaborator = newProof

elaborate :: Context -> Name -> Type -> aux -> Elab' aux a -> TC (a, String)
elaborate ctxt n ty d elab = do let ps = initElaborator n ctxt ty
                                (a, ES ps' str _) <- runElab d elab ps
                                return (a, str)

updateAux :: (aux -> aux) -> Elab' aux ()
updateAux f = do ES (ps, a) l p <- get
                 put (ES (ps, f a) l p)

getAux :: Elab' aux aux
getAux = do ES (ps, a) _ _ <- get
            return a

processTactic' t = do ES (p, a) logs prev <- get
                      (p', log) <- lift $ processTactic t p
                      put (ES (p', a) (logs ++ log) prev)
                      return ()

-- Some handy gadgets for pulling out bits of state

-- get the global context
get_context :: Elab' aux Context
get_context = do ES p _ _ <- get
                 return (context (fst p))

-- get the proof term
get_term :: Elab' aux Term
get_term = do ES p _ _ <- get
              return (pterm (fst p))

-- get the local context at the currently in focus hole
get_env :: Elab' aux Env
get_env = do ES p _ _ <- get
             lift $ envAtFocus (fst p)

get_holes :: Elab' aux [Name]
get_holes = do ES p _ _ <- get
               return (holes (fst p))

-- get the current goal type
goal :: Elab' aux Type
goal = do ES p _ _ <- get
          b <- lift $ goalAtFocus (fst p)
          return (binderTy b)

-- Get the guess at the current hole, if there is one
get_guess :: Elab' aux Type
get_guess = do ES p _ _ <- get
               b <- lift $ goalAtFocus (fst p)
               case b of
                    Guess t v -> return v
                    _ -> fail "Not a guess"

-- typecheck locally
get_type :: Raw -> Elab' aux Type
get_type tm = do ctxt <- get_context
                 env <- get_env
                 (val, ty) <- lift $ check ctxt env tm
                 return (finalise ty)

-- get holes we've deferred for later definition
get_deferred :: Elab' aux [Name]
get_deferred = do ES p _ _ <- get
                  return (deferred (fst p))

get_inj :: Elab' aux [(Term, Term, Term)]
get_inj = do ES p _ _ <- get
             return (injective (fst p))

checkInjective :: (Term, Term, Term) -> Elab' aux ()
checkInjective (tm, l, r) = if isInjective tm then return ()
                                else lift $ tfail (NotInjective tm l r) 

-- get instance argument names
get_instances :: Elab' aux [Name]
get_instances = do ES p _ _ <- get
                   return (instances (fst p))

-- given a desired hole name, return a unique hole name
unique_hole :: Name -> Elab' aux Name
unique_hole n = do ES p _ _ <- get
                   let bs = bound_in (pterm (fst p)) ++ bound_in (ptype (fst p))
                   n' <- uniqueNameCtxt (context (fst p)) n (holes (fst p) ++ bs)
                   return n'
  where
    bound_in (Bind n b sc) = n : bi b ++ bound_in sc
      where
        bi (Let t v) = bound_in t ++ bound_in v
        bi (Guess t v) = bound_in t ++ bound_in v
        bi b = bound_in (binderTy b)
    bound_in (App f a) = bound_in f ++ bound_in a
    bound_in _ = []

uniqueNameCtxt :: Context -> Name -> [Name] -> Elab' aux Name
uniqueNameCtxt ctxt n hs 
    | n `elem` hs = uniqueNameCtxt ctxt (nextName n) hs
    | [_] <- lookupTy Nothing n ctxt = uniqueNameCtxt ctxt (nextName n) hs
    | otherwise = return n

elog :: String -> Elab' aux ()
elog str = do ES p logs prev <- get
              put (ES p (logs ++ str ++ "\n") prev)

-- The primitives, from ProofState

attack :: Elab' aux ()
attack = processTactic' Attack

claim :: Name -> Raw -> Elab' aux ()
claim n t = processTactic' (Claim n t)

exact :: Raw -> Elab' aux ()
exact t = processTactic' (Exact t)

fill :: Raw -> Elab' aux ()
fill t = processTactic' (Fill t)

prep_fill :: Name -> [Name] -> Elab' aux ()
prep_fill n ns = processTactic' (PrepFill n ns)

complete_fill :: Elab' aux ()
complete_fill = processTactic' CompleteFill

solve :: Elab' aux ()
solve = processTactic' Solve

start_unify :: Name -> Elab' aux ()
start_unify n = processTactic' (StartUnify n)

end_unify :: Elab' aux ()
end_unify = processTactic' EndUnify

regret :: Elab' aux ()
regret = processTactic' Regret

compute :: Elab' aux ()
compute = processTactic' Compute

eval_in :: Raw -> Elab' aux ()
eval_in t = processTactic' (EvalIn t)

check_in :: Raw -> Elab' aux ()
check_in t = processTactic' (CheckIn t)

intro :: Maybe Name -> Elab' aux ()
intro n = processTactic' (Intro n)

introTy :: Raw -> Maybe Name -> Elab' aux ()
introTy ty n = processTactic' (IntroTy ty n)

forall :: Name -> Raw -> Elab' aux ()
forall n t = processTactic' (Forall n t)

letbind :: Name -> Raw -> Raw -> Elab' aux ()
letbind n t v = processTactic' (LetBind n t v)

rewrite :: Raw -> Elab' aux ()
rewrite tm = processTactic' (Rewrite tm)

patvar :: Name -> Elab' aux ()
patvar n = do env <- get_env
              if (n `elem` map fst env) then do apply (Var n) []; solve
                else do n' <- case n of
                                    UN _ -> return n
                                    MN _ _ -> unique_hole n
                                    NS _ _ -> return n
                        processTactic' (PatVar n')

patbind :: Name -> Elab' aux ()
patbind n = processTactic' (PatBind n)

focus :: Name -> Elab' aux ()
focus n = processTactic' (Focus n)

movelast :: Name -> Elab' aux ()
movelast n = processTactic' (MoveLast n)

defer :: Name -> Elab' aux ()
defer n = do n' <- unique_hole n
             processTactic' (Defer n')

instanceArg :: Name -> Elab' aux ()
instanceArg n = processTactic' (Instance n)

proofstate :: Elab' aux ()
proofstate = processTactic' ProofState

reorder_claims :: Name -> Elab' aux ()
reorder_claims n = processTactic' (Reorder n)

qed :: Elab' aux Term
qed = do processTactic' QED
         ES p _ _ <- get
         return (pterm (fst p))

undo :: Elab' aux ()
undo = processTactic' Undo

prepare_apply :: Raw -> [Bool] -> Elab' aux [Name]
prepare_apply fn imps =
    do ty <- get_type fn
       ctxt <- get_context
       env <- get_env
       -- let claims = getArgs ty imps
       claims <- mkClaims (normalise ctxt env ty) imps []
       ES (p, a) s prev <- get
       -- reverse the claims we made so that args go left to right
       let n = length (filter not imps)
       let (h : hs) = holes p
       put (ES (p { holes = h : (reverse (take n hs) ++ drop n hs) }, a) s prev)
--        case claims of
--             [] -> return ()
--             (h : _) -> reorder_claims h
       return claims
  where
    mkClaims (Bind n' (Pi t) sc) (i : is) claims =
        do n <- unique_hole (mkMN n')
--            when (null claims) (start_unify n)
           let sc' = instantiate (P Bound n t) sc
           claim n (forget t)
           when i (movelast n)
           mkClaims sc' is (n : claims)
    mkClaims t [] claims = return (reverse claims)
    mkClaims _ _ _ 
            | Var n <- fn
                   = do ctxt <- get_context
                        case lookupTy Nothing n ctxt of
                                [] -> lift $ tfail $ NoSuchVariable n  
                                _ -> fail $ "Too many arguments for " ++ show fn
            | otherwise = fail $ "Too many arguments for " ++ show fn

    doClaim ((i, _), n, t) = do claim n t
                                when i (movelast n)

    mkMN n@(MN _ _) = n
    mkMN n@(UN x) = MN 0 x
    mkMN (NS n xs) = NS (mkMN n) xs

apply :: Raw -> [(Bool, Int)] -> Elab' aux [Name]
apply fn imps = 
    do args <- prepare_apply fn (map fst imps)
       fill (raw_apply fn (map Var args))
       -- *Don't* solve the arguments we're specifying by hand.
       -- (remove from unified list before calling end_unify)
       -- HMMM: Actually, if we get it wrong, the typechecker will complain!
       -- so do nothing
       ptm <- get_term
       let dontunify = [] -- map fst (filter (not.snd) (zip args (map fst imps)))
       ES (p, a) s prev <- get
       let (n, hs) = unified p
       let unify = (n, filter (\ (n, t) -> not (n `elem` dontunify)) hs)
       put (ES (p { unified = unify }, a) s prev)
       end_unify
       return (map (updateUnify hs) args)
  where updateUnify hs n = case lookup n hs of
                                Just (P _ t _) -> t
                                _ -> n

apply2 :: Raw -> [Maybe (Elab' aux ())] -> Elab' aux () 
apply2 fn elabs = 
    do args <- prepare_apply fn (map isJust elabs)
       fill (raw_apply fn (map Var args))
       elabArgs args elabs
       ES (p, a) s prev <- get
       let (n, hs) = unified p
       end_unify
       solve
  where elabArgs [] [] = return ()
        elabArgs (n:ns) (Just e:es) = do focus n; e
                                         elabArgs ns es
        elabArgs (n:ns) (_:es) = elabArgs ns es

        isJust (Just _) = False 
        isJust _        = True

apply_elab :: Name -> [Maybe (Int, Elab' aux ())] -> Elab' aux ()
apply_elab n args = 
    do ty <- get_type (Var n)
       ctxt <- get_context
       env <- get_env
       claims <- doClaims (normalise ctxt env ty) args []
       prep_fill n (map fst claims)
       let eclaims = sortBy (\ (_, x) (_,y) -> priOrder x y) claims
       elabClaims [] False claims
       complete_fill
       end_unify
  where
    priOrder Nothing Nothing = EQ
    priOrder Nothing _ = LT
    priOrder _ Nothing = GT
    priOrder (Just (x, _)) (Just (y, _)) = compare x y

    doClaims (Bind n' (Pi t) sc) (i : is) claims =
        do n <- unique_hole (mkMN n')
           when (null claims) (start_unify n)
           let sc' = instantiate (P Bound n t) sc
           claim n (forget t)
           doClaims sc' is ((n, i) : claims)
    doClaims t [] claims = return (reverse claims)
    doClaims _ _ _ = fail $ "Wrong number of arguments for " ++ show n

    elabClaims failed r [] 
        | null failed = return ()
        | otherwise = if r then elabClaims [] False failed
                           else return ()
    elabClaims failed r ((n, Nothing) : xs) = elabClaims failed r xs
    elabClaims failed r (e@(n, Just (_, elaboration)) : xs)
        | r = try (do ES p _ _ <- get
                      focus n; elaboration; elabClaims failed r xs)
                  (elabClaims (e : failed) r xs)
        | otherwise = do ES p _ _ <- get
                         focus n; elaboration; elabClaims failed r xs

    mkMN n@(MN _ _) = n
    mkMN n@(UN x) = MN 0 x
    mkMN (NS n ns) = NS (mkMN n) ns

simple_app :: Elab' aux () -> Elab' aux () -> Elab' aux ()
simple_app fun arg =
    do a <- unique_hole (MN 0 "a")
       b <- unique_hole (MN 0 "b")
       f <- unique_hole (MN 0 "f")
       s <- unique_hole (MN 0 "s")
       claim a RSet
       claim b RSet
       claim f (RBind (MN 0 "aX") (Pi (Var a)) (Var b))
       start_unify s
       claim s (Var a)
       prep_fill f [s]
       -- try elaborating in both orders, since we might learn something useful
       -- either way
       try (do focus s; arg
               focus f; fun)
           (do focus f; fun
               focus s; arg)
       complete_fill
       end_unify

-- Abstract over an argument of unknown type, giving a name for the hole
-- which we'll fill with the argument type too.
arg :: Name -> Name -> Elab' aux ()
arg n tyhole = do ty <- unique_hole tyhole
                  claim ty RSet
                  forall n (Var ty)

-- Try a tactic, if it fails, try another
try :: Elab' aux a -> Elab' aux a -> Elab' aux a
try t1 t2 = do s <- get
               case runStateT t1 s of
                    OK (v, s') -> do put s'
                                     return v
                    Error e1 -> do put s
                                   case runStateT t2 s of
                                     OK (v, s') -> do put s'; return v
                                     Error e2 -> if score e1 > score e2 
                                                    then lift (tfail e1) 
                                                    else lift (tfail e2)
                        
-- Try a selection of tactics. Exactly one must work, all others must fail
tryAll :: [(Elab' aux a, String)] -> Elab' aux a
tryAll xs = tryAll' [] (cantResolve, 0) (map fst xs)
  where
    cantResolve :: Elab' aux a
    cantResolve = fail $ "Couldn't resolve alternative: " 
                                  ++ showSep ", " (map snd xs)

    tryAll' :: [Elab' aux a] -> -- successes
               (Elab' aux a, Int) -> -- smallest failure
               [Elab' aux a] -> -- still to try
               Elab' aux a
    tryAll' [res] _   [] = res
    tryAll' (_:_) _   [] = cantResolve
    tryAll' [] (f, _) [] = f
    tryAll' cs f (x:xs) = do s <- get
                             case runStateT x s of
                                    OK (v, s') -> tryAll' ((do put s'
                                                               return v):cs)  f xs
                                    Error err -> do put s
                                                    if (score err) < 100
                                                      then
                                                        tryAll' cs (better err f) xs
                                                      else
                                                        tryAll' [] (better err f) xs -- give up

    better err (f, i) = let s = score err in
                            if (s >= i) then (lift (tfail err), s)
                                        else (f, i)


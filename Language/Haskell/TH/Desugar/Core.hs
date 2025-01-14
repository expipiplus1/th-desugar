{- Language/Haskell/TH/Desugar/Core.hs

(c) Richard Eisenberg 2013
rae@cs.brynmawr.edu

Desugars full Template Haskell syntax into a smaller core syntax for further
processing. The desugared types and constructors are prefixed with a D.
-}

{-# LANGUAGE TemplateHaskellQuotes, LambdaCase, CPP, ScopedTypeVariables,
             TupleSections, DeriveDataTypeable, DeriveGeneric #-}

module Language.Haskell.TH.Desugar.Core where

import Prelude hiding (mapM, foldl, foldr, all, elem, exp, concatMap, and)

import Language.Haskell.TH hiding (match, clause, cxt)
import Language.Haskell.TH.Datatype.TyVarBndr
import Language.Haskell.TH.Syntax hiding (lift)

import Control.Monad hiding (forM_, mapM)
import qualified Control.Monad.Fail as Fail
import Control.Monad.Trans (MonadTrans(..))
import Control.Monad.Writer (MonadWriter(..), WriterT(..))
import Control.Monad.Zip
import Data.Data (Data)
import Data.Either (lefts)
import Data.Foldable as F hiding (concat, notElem)
import qualified Data.Map as M
import Data.Map (Map)
import Data.Maybe (isJust, mapMaybe)
import Data.Monoid (All(..))
import qualified Data.Set as S
import Data.Set (Set)
import Data.Traversable

#if __GLASGOW_HASKELL__ >= 803
import GHC.OverloadedLabels ( fromLabel )
#endif

#if __GLASGOW_HASKELL__ >= 807
import GHC.Classes (IP(..))
#endif

#if __GLASGOW_HASKELL__ >= 902
import Data.List.NonEmpty (NonEmpty(..))
import GHC.Records (HasField(..))
#endif

import GHC.Exts
import GHC.Generics (Generic)

import Language.Haskell.TH.Desugar.AST
import Language.Haskell.TH.Desugar.FV
import qualified Language.Haskell.TH.Desugar.OSet as OS
import Language.Haskell.TH.Desugar.OSet (OSet)
import Language.Haskell.TH.Desugar.Util
import Language.Haskell.TH.Desugar.Reify

-- | Desugar an expression
dsExp :: DsMonad q => Exp -> q DExp
dsExp (VarE n) = return $ DVarE n
dsExp (ConE n) = return $ DConE n
dsExp (LitE lit) = return $ DLitE lit
dsExp (AppE e1 e2) = DAppE <$> dsExp e1 <*> dsExp e2
dsExp (InfixE Nothing op Nothing) = dsExp op
dsExp (InfixE (Just lhs) op Nothing) = DAppE <$> (dsExp op) <*> (dsExp lhs)
dsExp (InfixE Nothing op (Just rhs)) = do
  lhsName <- newUniqueName "lhs"
  op' <- dsExp op
  rhs' <- dsExp rhs
  return $ DLamE [lhsName] (foldl DAppE op' [DVarE lhsName, rhs'])
dsExp (InfixE (Just lhs) op (Just rhs)) =
  DAppE <$> (DAppE <$> dsExp op <*> dsExp lhs) <*> dsExp rhs
dsExp (UInfixE _ _ _) =
  fail "Cannot desugar unresolved infix operators."
dsExp (ParensE exp) = dsExp exp
dsExp (LamE pats exp) = do
  exp' <- dsExp exp
  (pats', exp'') <- dsPatsOverExp pats exp'
  mkDLamEFromDPats pats' exp''
dsExp (LamCaseE matches) = do
  x <- newUniqueName "x"
  matches' <- dsMatches x matches
  return $ DLamE [x] (DCaseE (DVarE x) matches')
dsExp (TupE exps) = dsTup tupleDataName exps
dsExp (UnboxedTupE exps) = dsTup unboxedTupleDataName exps
dsExp (CondE e1 e2 e3) =
  dsExp (CaseE e1 [mkBoolMatch 'True e2, mkBoolMatch 'False e3])
  where
    mkBoolMatch :: Name -> Exp -> Match
    mkBoolMatch boolDataCon rhs =
      Match (ConP boolDataCon
#if __GLASGOW_HASKELL__ >= 901
                  []
#endif
                  []) (NormalB rhs) []
dsExp (MultiIfE guarded_exps) =
  let failure = mkErrorMatchExpr MultiWayIfAlt in
  dsGuards guarded_exps failure
dsExp (LetE decs exp) = do
  (decs', ip_binder) <- dsLetDecs decs
  exp' <- dsExp exp
  return $ DLetE decs' $ ip_binder exp'
    -- the following special case avoids creating a new "let" when it's not
    -- necessary. See #34.
dsExp (CaseE (VarE scrutinee) matches) = do
  matches' <- dsMatches scrutinee matches
  return $ DCaseE (DVarE scrutinee) matches'
dsExp (CaseE exp matches) = do
  scrutinee <- newUniqueName "scrutinee"
  exp' <- dsExp exp
  matches' <- dsMatches scrutinee matches
  return $ DLetE [DValD (DVarP scrutinee) exp'] $
           DCaseE (DVarE scrutinee) matches'
#if __GLASGOW_HASKELL__ >= 900
dsExp (DoE mb_mod stmts) = dsDoStmts mb_mod stmts
#else
dsExp (DoE        stmts) = dsDoStmts Nothing stmts
#endif
dsExp (CompE stmts) = dsComp stmts
dsExp (ArithSeqE (FromR exp)) = DAppE (DVarE 'enumFrom) <$> dsExp exp
dsExp (ArithSeqE (FromThenR exp1 exp2)) =
  DAppE <$> (DAppE (DVarE 'enumFromThen) <$> dsExp exp1) <*> dsExp exp2
dsExp (ArithSeqE (FromToR exp1 exp2)) =
  DAppE <$> (DAppE (DVarE 'enumFromTo) <$> dsExp exp1) <*> dsExp exp2
dsExp (ArithSeqE (FromThenToR e1 e2 e3)) =
  DAppE <$> (DAppE <$> (DAppE (DVarE 'enumFromThenTo) <$> dsExp e1) <*>
                               dsExp e2) <*>
            dsExp e3
dsExp (ListE exps) = go exps
  where go [] = return $ DConE '[]
        go (h : t) = DAppE <$> (DAppE (DConE '(:)) <$> dsExp h) <*> go t
dsExp (SigE exp ty) = DSigE <$> dsExp exp <*> dsType ty
dsExp (RecConE con_name field_exps) = do
  con <- dataConNameToCon con_name
  reordered <- reorder con
  return $ foldl DAppE (DConE con_name) reordered
  where
    reorder con = case con of
                    NormalC _name fields -> non_record fields
                    InfixC field1 _name field2 -> non_record [field1, field2]
                    RecC _name fields -> reorder_fields fields
                    ForallC _ _ c -> reorder c
                    GadtC _names fields _ret_ty -> non_record fields
                    RecGadtC _names fields _ret_ty -> reorder_fields fields

    reorder_fields fields = reorderFields con_name fields field_exps
                                          (repeat $ DVarE 'undefined)

    non_record fields | null field_exps
                        -- Special case: record construction is allowed for any
                        -- constructor, regardless of whether the constructor
                        -- actually was declared with records, provided that no
                        -- records are given in the expression itself. (See #59).
                        --
                        -- Con{} desugars down to Con undefined ... undefined.
                      = return $ replicate (length fields) $ DVarE 'undefined

                      | otherwise =
                          impossible $ "Record syntax used with non-record constructor "
                                       ++ (show con_name) ++ "."

dsExp (RecUpdE exp field_exps) = do
  -- here, we need to use one of the field names to find the tycon, somewhat dodgily
  first_name <- case field_exps of
                  ((name, _) : _) -> return name
                  _ -> impossible "Record update with no fields listed."
  info <- reifyWithLocals first_name
  applied_type <- case info of
                    VarI _name ty _m_dec -> extract_first_arg ty
                    _ -> impossible "Record update with an invalid field name."
  type_name <- extract_type_name applied_type
  (_, cons) <- getDataD "This seems to be an error in GHC." type_name
  let filtered_cons = filter_cons_with_names cons (map fst field_exps)
  exp' <- dsExp exp
  matches <- mapM con_to_dmatch filtered_cons
  let all_matches
        | length filtered_cons == length cons = matches
        | otherwise                           = matches ++ [error_match]
  return $ DCaseE exp' all_matches
  where
    extract_first_arg :: DsMonad q => Type -> q Type
    extract_first_arg (AppT (AppT ArrowT arg) _) = return arg
    extract_first_arg (ForallT _ _ t) = extract_first_arg t
    extract_first_arg (SigT t _) = extract_first_arg t
    extract_first_arg _ = impossible "Record selector not a function."

    extract_type_name :: DsMonad q => Type -> q Name
    extract_type_name (AppT t1 _) = extract_type_name t1
    extract_type_name (SigT t _) = extract_type_name t
    extract_type_name (ConT n) = return n
    extract_type_name _ = impossible "Record selector domain not a datatype."

    filter_cons_with_names cons field_names =
      filter has_names cons
      where
        args_contain_names args =
          let con_field_names = map fst_of_3 args in
          all (`elem` con_field_names) field_names

        has_names (RecC _con_name args) =
          args_contain_names args
        has_names (RecGadtC _con_name args _ret_ty) =
          args_contain_names args
        has_names (ForallC _ _ c) = has_names c
        has_names _               = False

    rec_con_to_dmatch con_name args = do
      let con_field_names = map fst_of_3 args
      field_var_names <- mapM (newUniqueName . nameBase) con_field_names
      DMatch (DConP con_name [] (map DVarP field_var_names)) <$>
             (foldl DAppE (DConE con_name) <$>
                    (reorderFields con_name args field_exps (map DVarE field_var_names)))

    con_to_dmatch :: DsMonad q => Con -> q DMatch
    con_to_dmatch (RecC con_name args) = rec_con_to_dmatch con_name args
    -- We're assuming the GADT constructor has only one Name here, but since
    -- this constructor was reified, this assumption should always hold true.
    con_to_dmatch (RecGadtC [con_name] args _ret_ty) = rec_con_to_dmatch con_name args
    con_to_dmatch (ForallC _ _ c) = con_to_dmatch c
    con_to_dmatch _ = impossible "Internal error within th-desugar."

    error_match = DMatch DWildP (mkErrorMatchExpr RecUpd)

    fst_of_3 (x, _, _) = x
dsExp (StaticE exp) = DStaticE <$> dsExp exp
dsExp (UnboundVarE n) = return (DVarE n)
#if __GLASGOW_HASKELL__ >= 801
dsExp (AppTypeE exp ty) = DAppTypeE <$> dsExp exp <*> dsType ty
dsExp (UnboxedSumE exp alt arity) =
  DAppE (DConE $ unboxedSumDataName alt arity) <$> dsExp exp
#endif
#if __GLASGOW_HASKELL__ >= 803
dsExp (LabelE str) = return $ DVarE 'fromLabel `DAppTypeE` DLitT (StrTyLit str)
#endif
#if __GLASGOW_HASKELL__ >= 807
dsExp (ImplicitParamVarE n) = return $ DVarE 'ip `DAppTypeE` DLitT (StrTyLit n)
dsExp (MDoE {}) = fail "th-desugar currently does not support RecursiveDo"
#endif
#if __GLASGOW_HASKELL__ >= 902
dsExp (GetFieldE arg field) = DAppE (mkGetFieldProj field) <$> dsExp arg
dsExp (ProjectionE fields) =
  case fields of
    f :| fs -> return $ foldl' comp (mkGetFieldProj f) fs
  where
    comp :: DExp -> String -> DExp
    comp acc f = DVarE '(.) `DAppE` mkGetFieldProj f `DAppE` acc
#endif
#if __GLASGOW_HASKELL__ >= 903
dsExp (LamCasesE clauses) = do
  clauses' <- dsClauses CaseAlt clauses
  numArgs <-
    case clauses' of
      (DClause pats _:_) -> return $ length pats
      [] -> fail "\\cases expression must have at least one alternative"
  args <- replicateM numArgs (newUniqueName "x")
  return $ DLamE args $ DCaseE (mkUnboxedTupleDExp (map DVarE args))
                               (map dClauseToUnboxedTupleMatch clauses')
#endif

-- | Convert a 'DClause' to a 'DMatch' by bundling all of the clause's patterns
-- into a match on a single unboxed tuple pattern. That is, convert this:
--
-- @
-- f x y z = rhs
-- @
--
-- To this:
--
-- @
-- f (# x, y, z #) = rhs
-- @
--
-- This is used to desugar @\\cases@ expressions into lambda expressions.
dClauseToUnboxedTupleMatch :: DClause -> DMatch
dClauseToUnboxedTupleMatch (DClause pats rhs) =
  DMatch (mkUnboxedTupleDPat pats) rhs

#if __GLASGOW_HASKELL__ >= 809
dsTup :: DsMonad q => (Int -> Name) -> [Maybe Exp] -> q DExp
dsTup = ds_tup
#else
dsTup :: DsMonad q => (Int -> Name) -> [Exp]       -> q DExp
dsTup tuple_data_name = ds_tup tuple_data_name . map Just
#endif

-- | Desugar a tuple (or tuple section) expression.
ds_tup :: forall q. DsMonad q
       => (Int -> Name) -- ^ Compute the 'Name' of a tuple (boxed or unboxed)
                        --   data constructor from its arity.
       -> [Maybe Exp]   -- ^ The tuple's subexpressions. 'Nothing' entries
                        --   denote empty fields in a tuple section.
       -> q DExp
ds_tup tuple_data_name mb_exps = do
  section_exps <- mapM ds_section_exp mb_exps
  let section_vars = lefts section_exps
      tup_body     = mk_tup_body section_exps
  if null section_vars
     then return tup_body -- If this isn't a tuple section,
                          -- don't create a lambda.
     else mkDLamEFromDPats (map DVarP section_vars) tup_body
  where
    -- If dealing with an empty field in a tuple section (Nothing), create a
    -- unique name and return Left. These names will be used to construct the
    -- lambda expression that it desugars to.
    -- (For example, `(,5)` desugars to `\ts -> (,) ts 5`.)
    --
    -- If dealing with a tuple subexpression (Just), desugar it and return
    -- Right.
    ds_section_exp :: Maybe Exp -> q (Either Name DExp)
    ds_section_exp = maybe (Left <$> qNewName "ts") (fmap Right . dsExp)

    mk_tup_body :: [Either Name DExp] -> DExp
    mk_tup_body section_exps =
      foldl' apply_tup_body (DConE $ tuple_data_name (length section_exps))
             section_exps

    apply_tup_body :: DExp -> Either Name DExp -> DExp
    apply_tup_body f (Left n)  = f `DAppE` DVarE n
    apply_tup_body f (Right e) = f `DAppE` e

-- | Convert a list of 'DPat' arguments and a 'DExp' body into a 'DLamE'. This
-- is needed since 'DLamE' takes a list of 'Name's for its bound variables
-- instead of 'DPat's, so some reorganization is needed.
mkDLamEFromDPats :: Quasi q => [DPat] -> DExp -> q DExp
mkDLamEFromDPats pats exp
  | Just names <- mapM stripDVarP_maybe pats
  = return $ DLamE names exp
  | otherwise
  = do arg_names <- replicateM (length pats) (newUniqueName "arg")
       let scrutinee = mkUnboxedTupleDExp (map DVarE arg_names)
           match     = DMatch (mkUnboxedTupleDPat pats) exp
       return $ DLamE arg_names (DCaseE scrutinee [match])
  where
    stripDVarP_maybe :: DPat -> Maybe Name
    stripDVarP_maybe (DVarP n) = Just n
    stripDVarP_maybe _          = Nothing

#if __GLASGOW_HASKELL__ >= 902
mkGetFieldProj :: String -> DExp
mkGetFieldProj field = DVarE 'getField `DAppTypeE` DLitT (StrTyLit field)
#endif

-- | Desugar a list of matches for a @case@ statement
dsMatches :: DsMonad q
          => Name     -- ^ Name of the scrutinee, which must be a bare var
          -> [Match]  -- ^ Matches of the @case@ statement
          -> q [DMatch]
dsMatches scr = go
  where
    go :: DsMonad q => [Match] -> q [DMatch]
    go [] = return []
    go (Match pat body where_decs : rest) = do
      rest' <- go rest
      let failure = maybeDCaseE CaseAlt (DVarE scr) rest'
      exp' <- dsBody body where_decs failure
      (pat', exp'') <- dsPatOverExp pat exp'
      uni_pattern <- isUniversalPattern pat' -- incomplete attempt at #6
      if uni_pattern
      then return [DMatch pat' exp'']
      else return (DMatch pat' exp'' : rest')

-- | Desugar a @Body@
dsBody :: DsMonad q
       => Body      -- ^ body to desugar
       -> [Dec]     -- ^ "where" declarations
       -> DExp      -- ^ what to do if the guards don't match
       -> q DExp
dsBody (NormalB exp) decs _ = do
  (decs', ip_binder) <- dsLetDecs decs
  exp' <- dsExp exp
  return $ maybeDLetE decs' $ ip_binder exp'
dsBody (GuardedB guarded_exps) decs failure = do
  (decs', ip_binder) <- dsLetDecs decs
  guarded_exp' <- dsGuards guarded_exps failure
  return $ maybeDLetE decs' $ ip_binder guarded_exp'

-- | If decs is non-empty, delcare them in a let:
maybeDLetE :: [DLetDec] -> DExp -> DExp
maybeDLetE [] exp   = exp
maybeDLetE decs exp = DLetE decs exp

-- | If matches is non-empty, make a case statement; otherwise make an error statement
maybeDCaseE :: MatchContext -> DExp -> [DMatch] -> DExp
maybeDCaseE mc _     []      = mkErrorMatchExpr mc
maybeDCaseE _  scrut matches = DCaseE scrut matches

-- | Desugar guarded expressions
dsGuards :: DsMonad q
         => [(Guard, Exp)]  -- ^ Guarded expressions
         -> DExp            -- ^ What to do if none of the guards match
         -> q DExp
dsGuards [] thing_inside = return thing_inside
dsGuards ((NormalG gd, exp) : rest) thing_inside =
  dsGuards ((PatG [NoBindS gd], exp) : rest) thing_inside
dsGuards ((PatG stmts, exp) : rest) thing_inside = do
  success <- dsExp exp
  failure <- dsGuards rest thing_inside
  dsGuardStmts stmts success failure

-- | Desugar the @Stmt@s in a guard
dsGuardStmts :: DsMonad q
             => [Stmt]  -- ^ The @Stmt@s to desugar
             -> DExp    -- ^ What to do if the @Stmt@s yield success
             -> DExp    -- ^ What to do if the @Stmt@s yield failure
             -> q DExp
dsGuardStmts [] success _failure = return success
dsGuardStmts (BindS pat exp : rest) success failure = do
  success' <- dsGuardStmts rest success failure
  (pat', success'') <- dsPatOverExp pat success'
  exp' <- dsExp exp
  return $ DCaseE exp' [DMatch pat' success'', DMatch DWildP failure]
dsGuardStmts (LetS decs : rest) success failure = do
  (decs', ip_binder) <- dsLetDecs decs
  success' <- dsGuardStmts rest success failure
  return $ DLetE decs' $ ip_binder success'
  -- special-case a final pattern containing "otherwise" or "True"
  -- note that GHC does this special-casing, too, in DsGRHSs.isTrueLHsExpr
dsGuardStmts [NoBindS exp] success _failure
  | VarE name <- exp
  , name == 'otherwise
  = return success

  | ConE name <- exp
  , name == 'True
  = return success
dsGuardStmts (NoBindS exp : rest) success failure = do
  exp' <- dsExp exp
  success' <- dsGuardStmts rest success failure
  return $ DCaseE exp' [ DMatch (DConP 'True  [] []) success'
                       , DMatch (DConP 'False [] []) failure ]
dsGuardStmts (ParS _ : _) _ _ = impossible "Parallel comprehension in a pattern guard."
#if __GLASGOW_HASKELL__ >= 807
dsGuardStmts (RecS {} : _) _ _ = fail "th-desugar currently does not support RecursiveDo"
#endif

-- | Desugar the @Stmt@s in a @do@ expression
dsDoStmts :: forall q. DsMonad q => Maybe ModName -> [Stmt] -> q DExp
dsDoStmts mb_mod = go
  where
    go :: [Stmt] -> q DExp
    go [] = impossible "do-expression ended with something other than bare statement."
    go [NoBindS exp] = dsExp exp
    go (BindS pat exp : rest) = do
      rest' <- go rest
      dsBindS mb_mod exp pat rest' "do expression"
    go (LetS decs : rest) = do
      (decs', ip_binder) <- dsLetDecs decs
      rest' <- go rest
      return $ DLetE decs' $ ip_binder rest'
    go (NoBindS exp : rest) = do
      exp' <- dsExp exp
      rest' <- go rest
      let sequence_name = mk_qual_do_name mb_mod '(>>)
      return $ DAppE (DAppE (DVarE sequence_name) exp') rest'
    go (ParS _ : _) = impossible "Parallel comprehension in a do-statement."
#if __GLASGOW_HASKELL__ >= 807
    go (RecS {} : _) = fail "th-desugar currently does not support RecursiveDo"
#endif

-- | Desugar the @Stmt@s in a list or monad comprehension
dsComp :: DsMonad q => [Stmt] -> q DExp
dsComp [] = impossible "List/monad comprehension ended with something other than a bare statement."
dsComp [NoBindS exp] = DAppE (DVarE 'return) <$> dsExp exp
dsComp (BindS pat exp : rest) = do
  rest' <- dsComp rest
  dsBindS Nothing exp pat rest' "monad comprehension"
dsComp (LetS decs : rest) = do
  (decs', ip_binder) <- dsLetDecs decs
  rest' <- dsComp rest
  return $ DLetE decs' $ ip_binder rest'
dsComp (NoBindS exp : rest) = do
  exp' <- dsExp exp
  rest' <- dsComp rest
  return $ DAppE (DAppE (DVarE '(>>)) (DAppE (DVarE 'guard) exp')) rest'
dsComp (ParS stmtss : rest) = do
  (pat, exp) <- dsParComp stmtss
  rest' <- dsComp rest
  DAppE (DAppE (DVarE '(>>=)) exp) <$> mkDLamEFromDPats [pat] rest'
#if __GLASGOW_HASKELL__ >= 807
dsComp (RecS {} : _) = fail "th-desugar currently does not support RecursiveDo"
#endif

-- Desugar a binding statement in a do- or list comprehension.
--
-- In the event that the pattern in the statement is partial, the desugared
-- case expression will contain a catch-all case that calls 'fail' from either
-- 'MonadFail' or 'Monad', depending on whether the @MonadFailDesugaring@
-- language extension is enabled or not. (On GHCs older than 8.0, 'fail' from
-- 'Monad' is always used.)
dsBindS :: forall q. DsMonad q
        => Maybe ModName -> Exp -> Pat -> DExp -> String -> q DExp
dsBindS mb_mod bind_arg_exp success_pat success_exp ctxt = do
  bind_arg_exp' <- dsExp bind_arg_exp
  (success_pat', success_exp') <- dsPatOverExp success_pat success_exp
  is_univ_pat <- isUniversalPattern success_pat'
  let bind_into = DAppE (DAppE (DVarE bind_name) bind_arg_exp')
  if is_univ_pat
     then bind_into <$> mkDLamEFromDPats [success_pat'] success_exp'
     else do arg_name  <- newUniqueName "arg"
             fail_name <- mk_fail_name
             return $ bind_into $ DLamE [arg_name] $ DCaseE (DVarE arg_name)
               [ DMatch success_pat' success_exp'
               , DMatch DWildP $
                 DVarE fail_name `DAppE`
                   DLitE (StringL $ "Pattern match failure in " ++ ctxt)
               ]
  where
    bind_name = mk_qual_do_name mb_mod '(>>=)

    mk_fail_name :: q Name
#if __GLASGOW_HASKELL__ >= 807
    -- GHC 8.8 deprecates the MonadFailDesugaring extension since its effects
    -- are always enabled. Furthermore, MonadFailDesugaring is no longer
    -- enabled by default, so simply use MonadFail.fail. (That happens to
    -- be the same as Prelude.fail in 8.8+.)
    mk_fail_name = return fail_MonadFail_name
#else
    mk_fail_name = do
      mfd <- qIsExtEnabled MonadFailDesugaring
      return $ if mfd then fail_MonadFail_name else fail_Prelude_name
#endif

    fail_MonadFail_name = mk_qual_do_name mb_mod 'Fail.fail

#if __GLASGOW_HASKELL__ < 807
    fail_Prelude_name = mk_qual_do_name mb_mod 'Prelude.fail
#endif

-- | Desugar the contents of a parallel comprehension.
--   Returns a @Pat@ containing a tuple of all bound variables and an expression
--   to produce the values for those variables
dsParComp :: DsMonad q => [[Stmt]] -> q (DPat, DExp)
dsParComp [] = impossible "Empty list of parallel comprehension statements."
dsParComp [r] = do
  let rv = foldMap extractBoundNamesStmt r
  dsR <- dsComp (r ++ [mk_tuple_stmt rv])
  return (mk_tuple_dpat rv, dsR)
dsParComp (q : rest) = do
  let qv = foldMap extractBoundNamesStmt q
  (rest_pat, rest_exp) <- dsParComp rest
  dsQ <- dsComp (q ++ [mk_tuple_stmt qv])
  let zipped = DAppE (DAppE (DVarE 'mzip) dsQ) rest_exp
  return (DConP (tupleDataName 2) [] [mk_tuple_dpat qv, rest_pat], zipped)

-- helper function for dsParComp
mk_tuple_stmt :: OSet Name -> Stmt
mk_tuple_stmt name_set =
  NoBindS (mkTupleExp (F.foldr ((:) . VarE) [] name_set))

-- helper function for dsParComp
mk_tuple_dpat :: OSet Name -> DPat
mk_tuple_dpat name_set =
  mkTupleDPat (F.foldr ((:) . DVarP) [] name_set)

-- | Desugar a pattern, along with processing a (desugared) expression that
-- is the entire scope of the variables bound in the pattern.
dsPatOverExp :: DsMonad q => Pat -> DExp -> q (DPat, DExp)
dsPatOverExp pat exp = do
  (pat', vars) <- runWriterT $ dsPat pat
  let name_decs = map (uncurry (DValD . DVarP)) vars
  return (pat', maybeDLetE name_decs exp)

-- | Desugar multiple patterns. Like 'dsPatOverExp'.
dsPatsOverExp :: DsMonad q => [Pat] -> DExp -> q ([DPat], DExp)
dsPatsOverExp pats exp = do
  (pats', vars) <- runWriterT $ mapM dsPat pats
  let name_decs = map (uncurry (DValD . DVarP)) vars
  return (pats', maybeDLetE name_decs exp)

-- | Desugar a pattern, returning a list of (Name, DExp) pairs of extra
-- variables that must be bound within the scope of the pattern
dsPatX :: DsMonad q => Pat -> q (DPat, [(Name, DExp)])
dsPatX = runWriterT . dsPat

-- | Desugaring a pattern also returns the list of variables bound in as-patterns
-- and the values they should be bound to. This variables must be brought into
-- scope in the "body" of the pattern.
type PatM q = WriterT [(Name, DExp)] q

-- | Desugar a pattern.
dsPat :: DsMonad q => Pat -> PatM q DPat
dsPat (LitP lit) = return $ DLitP lit
dsPat (VarP n) = return $ DVarP n
dsPat (TupP pats) = DConP (tupleDataName (length pats)) [] <$> mapM dsPat pats
dsPat (UnboxedTupP pats) = DConP (unboxedTupleDataName (length pats)) [] <$>
                           mapM dsPat pats
#if __GLASGOW_HASKELL__ >= 901
dsPat (ConP name tys pats) = DConP name <$> mapM dsType tys <*> mapM dsPat pats
#else
dsPat (ConP name     pats) = DConP name [] <$> mapM dsPat pats
#endif
dsPat (InfixP p1 name p2) = DConP name [] <$> mapM dsPat [p1, p2]
dsPat (UInfixP _ _ _) =
  fail "Cannot desugar unresolved infix operators."
dsPat (ParensP pat) = dsPat pat
dsPat (TildeP pat) = DTildeP <$> dsPat pat
dsPat (BangP pat) = DBangP <$> dsPat pat
dsPat (AsP name pat) = do
  pat' <- dsPat pat
  pat'' <- lift $ removeWilds pat'
  tell [(name, dPatToDExp pat'')]
  return pat''
dsPat WildP = return DWildP
dsPat (RecP con_name field_pats) = do
  con <- lift $ dataConNameToCon con_name
  reordered <- reorder con
  return $ DConP con_name [] reordered
  where
    reorder con = case con of
                     NormalC _name fields -> non_record fields
                     InfixC field1 _name field2 -> non_record [field1, field2]
                     RecC _name fields -> reorder_fields_pat fields
                     ForallC _ _ c -> reorder c
                     GadtC _names fields _ret_ty -> non_record fields
                     RecGadtC _names fields _ret_ty -> reorder_fields_pat fields

    reorder_fields_pat fields = reorderFieldsPat con_name fields field_pats

    non_record fields | null field_pats
                        -- Special case: record patterns are allowed for any
                        -- constructor, regardless of whether the constructor
                        -- actually was declared with records, provided that
                        -- no records are given in the pattern itself. (See #59).
                        --
                        -- Con{} desugars down to Con _ ... _.
                      = return $ replicate (length fields) DWildP
                      | otherwise = lift $ impossible
                                         $ "Record syntax used with non-record constructor "
                                           ++ (show con_name) ++ "."

dsPat (ListP pats) = go pats
  where go [] = return $ DConP '[] [] []
        go (h : t) = do
          h' <- dsPat h
          t' <- go t
          return $ DConP '(:) [] [h', t']
dsPat (SigP pat ty) = DSigP <$> dsPat pat <*> dsType ty
#if __GLASGOW_HASKELL__ >= 801
dsPat (UnboxedSumP pat alt arity) =
  DConP (unboxedSumDataName alt arity) [] <$> ((:[]) <$> dsPat pat)
#endif
dsPat (ViewP _ _) =
  fail "View patterns are not supported in th-desugar. Use pattern guards instead."

-- | Convert a 'DPat' to a 'DExp'. Fails on 'DWildP'.
dPatToDExp :: DPat -> DExp
dPatToDExp (DLitP lit) = DLitE lit
dPatToDExp (DVarP name) = DVarE name
dPatToDExp (DConP name tys pats) = foldl DAppE (foldl DAppTypeE (DConE name) tys) (map dPatToDExp pats)
dPatToDExp (DTildeP pat) = dPatToDExp pat
dPatToDExp (DBangP pat) = dPatToDExp pat
dPatToDExp (DSigP pat ty) = DSigE (dPatToDExp pat) ty
dPatToDExp DWildP = error "Internal error in th-desugar: wildcard in rhs of as-pattern"

-- | Remove all wildcards from a pattern, replacing any wildcard with a fresh
--   variable
removeWilds :: DsMonad q => DPat -> q DPat
removeWilds p@(DLitP _) = return p
removeWilds p@(DVarP _) = return p
removeWilds (DConP con_name tys pats) = DConP con_name tys <$> mapM removeWilds pats
removeWilds (DTildeP pat) = DTildeP <$> removeWilds pat
removeWilds (DBangP pat) = DBangP <$> removeWilds pat
removeWilds (DSigP pat ty) = DSigP <$> removeWilds pat <*> pure ty
removeWilds DWildP = DVarP <$> newUniqueName "wild"

-- | Desugar @Info@
dsInfo :: DsMonad q => Info -> q DInfo
dsInfo (ClassI dec instances) = do
  [ddec]     <- dsDec dec
  dinstances <- dsDecs instances
  return $ DTyConI ddec (Just dinstances)
dsInfo (ClassOpI name ty parent) =
  DVarI name <$> dsType ty <*> pure (Just parent)
dsInfo (TyConI dec) = do
  [ddec] <- dsDec dec
  return $ DTyConI ddec Nothing
dsInfo (FamilyI dec instances) = do
  [ddec]     <- dsDec dec
  dinstances <- dsDecs instances
  return $ DTyConI ddec (Just dinstances)
dsInfo (PrimTyConI name arity unlifted) =
  return $ DPrimTyConI name arity unlifted
dsInfo (DataConI name ty parent) =
  DVarI name <$> dsType ty <*> pure (Just parent)
dsInfo (VarI name ty Nothing) =
  DVarI name <$> dsType ty <*> pure Nothing
dsInfo (VarI name _ (Just _)) =
  impossible $ "Declaration supplied with variable: " ++ show name
dsInfo (TyVarI name ty) = DTyVarI name <$> dsType ty
#if __GLASGOW_HASKELL__ >= 801
dsInfo (PatSynI name ty) = DPatSynI name <$> dsType ty
#endif

-- | Desugar arbitrary @Dec@s
dsDecs :: DsMonad q => [Dec] -> q [DDec]
dsDecs = concatMapM dsDec

-- | Desugar a single @Dec@, perhaps producing multiple 'DDec's
dsDec :: DsMonad q => Dec -> q [DDec]
dsDec d@(FunD {}) = dsTopLevelLetDec d
dsDec d@(ValD {}) = dsTopLevelLetDec d
dsDec (DataD cxt n tvbs mk cons derivings) =
  dsDataDec Data cxt n tvbs mk cons derivings
dsDec (NewtypeD cxt n tvbs mk con derivings) =
  dsDataDec Newtype cxt n tvbs mk [con] derivings
dsDec (TySynD n tvbs ty) =
  (:[]) <$> (DTySynD n <$> mapM dsTvbUnit tvbs <*> dsType ty)
dsDec (ClassD cxt n tvbs fds decs) =
  (:[]) <$> (DClassD <$> dsCxt cxt <*> pure n <*> mapM dsTvbUnit tvbs
                     <*> pure fds <*> dsDecs decs)
dsDec (InstanceD over cxt ty decs) =
  (:[]) <$> (DInstanceD over Nothing <$> dsCxt cxt <*> dsType ty <*> dsDecs decs)
dsDec d@(SigD {}) = dsTopLevelLetDec d
dsDec (ForeignD f) = (:[]) <$> (DForeignD <$> dsForeign f)
dsDec d@(InfixD {}) = dsTopLevelLetDec d
dsDec d@(PragmaD {}) = dsTopLevelLetDec d
dsDec (OpenTypeFamilyD tfHead) =
  (:[]) <$> (DOpenTypeFamilyD <$> dsTypeFamilyHead tfHead)
dsDec (DataFamilyD n tvbs m_k) =
  (:[]) <$> (DDataFamilyD n <$> mapM dsTvbUnit tvbs <*> mapM dsType m_k)
#if __GLASGOW_HASKELL__ >= 807
dsDec (DataInstD cxt mtvbs lhs mk cons derivings) =
  case unfoldType lhs of
    (ConT n, tys) -> dsDataInstDec Data cxt n mtvbs tys mk cons derivings
    (_, _)        -> fail $ "Unexpected data instance LHS: " ++ pprint lhs
dsDec (NewtypeInstD cxt mtvbs lhs mk con derivings) =
  case unfoldType lhs of
    (ConT n, tys) -> dsDataInstDec Newtype cxt n mtvbs tys mk [con] derivings
    (_, _)        -> fail $ "Unexpected newtype instance LHS: " ++ pprint lhs
#else
dsDec (DataInstD cxt n tys mk cons derivings) =
  dsDataInstDec Data cxt n Nothing (map TANormal tys) mk cons derivings
dsDec (NewtypeInstD cxt n tys mk con derivings) =
  dsDataInstDec Newtype cxt n Nothing (map TANormal tys) mk [con] derivings
#endif
#if __GLASGOW_HASKELL__ >= 807
dsDec (TySynInstD eqn) = (:[]) <$> (DTySynInstD <$> dsTySynEqn unusedArgument eqn)
#else
dsDec (TySynInstD n eqn) = (:[]) <$> (DTySynInstD <$> dsTySynEqn n eqn)
#endif
dsDec (ClosedTypeFamilyD tfHead eqns) =
  (:[]) <$> (DClosedTypeFamilyD <$> dsTypeFamilyHead tfHead
                                <*> mapM (dsTySynEqn (typeFamilyHeadName tfHead)) eqns)
dsDec (RoleAnnotD n roles) = return [DRoleAnnotD n roles]
#if __GLASGOW_HASKELL__ >= 801
dsDec (PatSynD n args dir pat) = do
  dir' <- dsPatSynDir n dir
  (pat', vars) <- dsPatX pat
  unless (null vars) $
    fail $ "Pattern synonym definition cannot contain as-patterns (@)."
  return [DPatSynD n args dir' pat']
dsDec (PatSynSigD n ty) = (:[]) <$> (DPatSynSigD n <$> dsType ty)
dsDec (StandaloneDerivD mds cxt ty) =
  (:[]) <$> (DStandaloneDerivD <$> mapM dsDerivStrategy mds
                               <*> pure Nothing <*> dsCxt cxt <*> dsType ty)
#else
dsDec (StandaloneDerivD cxt ty) =
  (:[]) <$> (DStandaloneDerivD Nothing Nothing <$> dsCxt cxt <*> dsType ty)
#endif
dsDec (DefaultSigD n ty) = (:[]) <$> (DDefaultSigD n <$> dsType ty)
#if __GLASGOW_HASKELL__ >= 807
dsDec (ImplicitParamBindD {}) = impossible "Non-`let`-bound implicit param binding"
#endif
#if __GLASGOW_HASKELL__ >= 809
dsDec (KiSigD n ki) = (:[]) <$> (DKiSigD n <$> dsType ki)
#endif
#if __GLASGOW_HASKELL__ >= 903
dsDec (DefaultD tys) = (:[]) <$> (DDefaultD <$> mapM dsType tys)
#endif

-- | Desugar a 'DataD' or 'NewtypeD'.
dsDataDec :: DsMonad q
          => NewOrData -> Cxt -> Name -> [TyVarBndrUnit]
          -> Maybe Kind -> [Con] -> [DerivingClause] -> q [DDec]
dsDataDec nd cxt n tvbs mk cons derivings = do
  tvbs' <- mapM dsTvbUnit tvbs
  let h98_tvbs = case mk of
                   -- If there's an explicit return kind, we're dealing with a
                   -- GADT, so this argument goes unused in dsCon.
                   Just {} -> unusedArgument
                   Nothing -> tvbs'
      h98_return_type = nonFamilyDataReturnType n tvbs'
  (:[]) <$> (DDataD nd <$> dsCxt cxt <*> pure n
                       <*> pure tvbs' <*> mapM dsType mk
                       <*> concatMapM (dsCon h98_tvbs h98_return_type) cons
                       <*> mapM dsDerivClause derivings)

-- | Desugar a 'DataInstD' or a 'NewtypeInstD'.
dsDataInstDec :: DsMonad q
              => NewOrData -> Cxt -> Name -> Maybe [TyVarBndrUnit] -> [TypeArg]
              -> Maybe Kind -> [Con] -> [DerivingClause] -> q [DDec]
dsDataInstDec nd cxt n mtvbs tys mk cons derivings = do
  mtvbs' <- mapM (mapM dsTvbUnit) mtvbs
  tys'   <- mapM dsTypeArg tys
  let lhs' = applyDType (DConT n) tys'
      h98_tvbs =
        case (mk, mtvbs') of
          -- If there's an explicit return kind, we're dealing with a
          -- GADT, so this argument goes unused in dsCon.
          (Just {}, _)          -> unusedArgument
          -- H98, and there is an explicit `forall` in front. Just reuse the
          -- type variable binders from the `forall`.
          (Nothing, Just tvbs') -> tvbs'
          -- H98, and no explicit `forall`. Compute the bound variables
          -- manually.
          (Nothing, Nothing)    -> dataFamInstTvbs tys'
      h98_fam_inst_type = dataFamInstReturnType n tys'
  (:[]) <$> (DDataInstD nd <$> dsCxt cxt <*> pure mtvbs'
                           <*> pure lhs' <*> mapM dsType mk
                           <*> concatMapM (dsCon h98_tvbs h98_fam_inst_type) cons
                           <*> mapM dsDerivClause derivings)

-- | Desugar a @FamilyResultSig@
dsFamilyResultSig :: DsMonad q => FamilyResultSig -> q DFamilyResultSig
dsFamilyResultSig NoSig          = return DNoSig
dsFamilyResultSig (KindSig k)    = DKindSig <$> dsType k
dsFamilyResultSig (TyVarSig tvb) = DTyVarSig <$> dsTvbUnit tvb

-- | Desugar a @TypeFamilyHead@
dsTypeFamilyHead :: DsMonad q => TypeFamilyHead -> q DTypeFamilyHead
dsTypeFamilyHead (TypeFamilyHead n tvbs result inj)
  = DTypeFamilyHead n <$> mapM dsTvbUnit tvbs
                      <*> dsFamilyResultSig result
                      <*> pure inj

typeFamilyHeadName :: TypeFamilyHead -> Name
typeFamilyHeadName (TypeFamilyHead n _ _ _) = n

-- | Desugar @Dec@s that can appear in a @let@ expression. See the
-- documentation for 'dsLetDec' for an explanation of what the return type
-- represents.
dsLetDecs :: DsMonad q => [Dec] -> q ([DLetDec], DExp -> DExp)
dsLetDecs decs = do
  (let_decss, ip_binders) <- mapAndUnzipM dsLetDec decs
  let let_decs :: [DLetDec]
      let_decs = concat let_decss

      ip_binder :: DExp -> DExp
      ip_binder = foldr (.) id ip_binders
  return (let_decs, ip_binder)

-- | Desugar a single 'Dec' that can appear in a @let@ expression.
-- This produces the following output:
--
-- * One or more 'DLetDec's (a single 'Dec' can produce multiple 'DLetDec's
--   in the event of a value declaration that binds multiple things by way
--   of pattern matching.
--
-- * A function of type @'DExp' -> 'DExp'@, which should be applied to the
--   expression immediately following the 'DLetDec's. This function prepends
--   binding forms for any implicit params that were bound in the argument
--   'Dec'. (If no implicit params are bound, this is simply the 'id'
--   function.)
--
-- For instance, if the argument to 'dsLetDec' is the @?x = 42@ part of this
-- expression:
--
-- @
-- let { ?x = 42 } in ?x
-- @
--
-- Then the output is:
--
-- * @let new_x_val = 42@
--
-- * @\\z -> 'bindIP' \@\"x\" new_x_val z@
--
-- This way, the expression
-- @let { new_x_val = 42 } in 'bindIP' \@"x" new_x_val ('ip' \@\"x\")@ can be
-- formed. The implicit param binders always come after all the other
-- 'DLetDec's to support parallel assignment of implicit params.
dsLetDec :: DsMonad q => Dec -> q ([DLetDec], DExp -> DExp)
dsLetDec (FunD name clauses) = do
  clauses' <- dsClauses (FunRhs name) clauses
  return ([DFunD name clauses'], id)
dsLetDec (ValD pat body where_decs) = do
  (pat', vars) <- dsPatX pat
  body' <- dsBody body where_decs error_exp
  let extras = uncurry (zipWith (DValD . DVarP)) $ unzip vars
  return (DValD pat' body' : extras, id)
  where
    error_exp = mkErrorMatchExpr (LetDecRhs pat)
dsLetDec (SigD name ty) = do
  ty' <- dsType ty
  return ([DSigD name ty'], id)
dsLetDec (InfixD fixity name) = return ([DInfixD fixity name], id)
dsLetDec (PragmaD prag) = do
  prag' <- dsPragma prag
  return ([DPragmaD prag'], id)
#if __GLASGOW_HASKELL__ >= 807
dsLetDec (ImplicitParamBindD n e) = do
  new_n_name <- qNewName $ "new_" ++ n ++ "_val"
  e' <- dsExp e
  let let_dec :: DLetDec
      let_dec = DValD (DVarP new_n_name) e'

      ip_binder :: DExp -> DExp
      ip_binder = (DVarE 'bindIP        `DAppTypeE`
                     DLitT (StrTyLit n) `DAppE`
                     DVarE new_n_name   `DAppE`)
  return ([let_dec], ip_binder)
#endif
dsLetDec _dec = impossible "Illegal declaration in let expression."

-- | Desugar a single 'Dec' corresponding to something that could appear after
-- the @let@ in a @let@ expression, but occurring at the top level. Because the
-- 'Dec' occurs at the top level, there is nothing that would correspond to the
-- @in ...@ part of the @let@ expression. As a consequence, this function does
-- not return a @'DExp' -> 'DExp'@ function corresonding to implicit param
-- binders (these cannot occur at the top level).
dsTopLevelLetDec :: DsMonad q => Dec -> q [DDec]
dsTopLevelLetDec = fmap (map DLetDec . fst) . dsLetDec
  -- Note the use of fst above: we're silently throwing away any implicit param
  -- binders that dsLetDec returns, since there is invariant that there will be
  -- no implicit params in the first place.

-- | Desugar a single @Con@.
--
-- Because we always desugar @Con@s to GADT syntax (see the documentation for
-- 'DCon'), it is not always possible to desugar with just a 'Con' alone.
-- For instance, we must desugar:
--
-- @
-- data Foo a = forall b. MkFoo b
-- @
--
-- To this:
--
-- @
-- data Foo a :: Type where
--   MkFoo :: forall a b. b -> Foo a
-- @
--
-- If our only argument was @forall b. MkFoo b@, it would be somewhat awkward
-- to figure out (1) what the set of universally quantified type variables
-- (@[a]@) was, and (2) what the return type (@Foo a@) was. For this reason,
-- we require passing these as arguments. (If we desugar an actual GADT
-- constructor, these arguments are ignored.)
dsCon :: DsMonad q
      => [DTyVarBndrUnit] -- ^ The universally quantified type variables
                          --   (used if desugaring a non-GADT constructor).
      -> DType            -- ^ The original data declaration's type
                          --   (used if desugaring a non-GADT constructor).
      -> Con -> q [DCon]
dsCon univ_dtvbs data_type con = do
  dcons' <- dsCon' con
  return $ flip map dcons' $ \(n, dtvbs, dcxt, fields, m_gadt_type) ->
    case m_gadt_type of
      Nothing ->
        let ex_dtvbs   = dtvbs
            expl_dtvbs = changeDTVFlags SpecifiedSpec univ_dtvbs ++
                         ex_dtvbs
            impl_dtvbs = changeDTVFlags SpecifiedSpec $
                         toposortTyVarsOf $ mapMaybe extractTvbKind expl_dtvbs in
        DCon (impl_dtvbs ++ expl_dtvbs) dcxt n fields data_type
      Just gadt_type ->
        let univ_ex_dtvbs = dtvbs in
        DCon univ_ex_dtvbs dcxt n fields gadt_type

-- Desugar a Con in isolation. The meaning of the returned DTyVarBndrs changes
-- depending on what the returned Maybe DType value is:
--
-- * If returning Just gadt_ty, then we've encountered a GadtC or RecGadtC,
--   so the returned DTyVarBndrs are both the universally and existentially
--   quantified tyvars.
-- * If returning Nothing, we're dealing with a non-GADT constructor, so
--   the returned DTyVarBndrs are the existentials only.
dsCon' :: DsMonad q
       => Con -> q [(Name, [DTyVarBndrSpec], DCxt, DConFields, Maybe DType)]
dsCon' (NormalC n stys) = do
  dtys <- mapM dsBangType stys
  return [(n, [], [], DNormalC False dtys, Nothing)]
dsCon' (RecC n vstys) = do
  vdtys <- mapM dsVarBangType vstys
  return [(n, [], [], DRecC vdtys, Nothing)]
dsCon' (InfixC sty1 n sty2) = do
  dty1 <- dsBangType sty1
  dty2 <- dsBangType sty2
  return [(n, [], [], DNormalC True [dty1, dty2], Nothing)]
dsCon' (ForallC tvbs cxt con) = do
  dtvbs <- mapM dsTvbSpec tvbs
  dcxt <- dsCxt cxt
  dcons' <- dsCon' con
  return $ flip map dcons' $ \(n, dtvbs', dcxt', fields, m_gadt_type) ->
    (n, dtvbs ++ dtvbs', dcxt ++ dcxt', fields, m_gadt_type)
dsCon' (GadtC nms btys rty) = do
  dbtys <- mapM dsBangType btys
  drty  <- dsType rty
  sequence $ flip map nms $ \nm -> do
    mbFi <- reifyFixityWithLocals nm
    -- A GADT data constructor is declared infix when these three
    -- properties hold:
    let decInfix = isInfixDataCon (nameBase nm) -- 1. Its name uses operator syntax
                                                --    (e.g., (:*:))
                && length dbtys == 2            -- 2. It has exactly two fields
                && isJust mbFi                  -- 3. It has a programmer-specified
                                                --    fixity declaration
    return (nm, [], [], DNormalC decInfix dbtys, Just drty)
dsCon' (RecGadtC nms vbtys rty) = do
  dvbtys <- mapM dsVarBangType vbtys
  drty   <- dsType rty
  return $ flip map nms $ \nm ->
    (nm, [], [], DRecC dvbtys, Just drty)

-- | Desugar a @BangType@.
dsBangType :: DsMonad q => BangType -> q DBangType
dsBangType (b, ty) = (b, ) <$> dsType ty

-- | Desugar a @VarBangType@.
dsVarBangType :: DsMonad q => VarBangType -> q DVarBangType
dsVarBangType (n, b, ty) = (n, b, ) <$> dsType ty

-- | Desugar a @Foreign@.
dsForeign :: DsMonad q => Foreign -> q DForeign
dsForeign (ImportF cc safety str n ty) = DImportF cc safety str n <$> dsType ty
dsForeign (ExportF cc str n ty)        = DExportF cc str n <$> dsType ty

-- | Desugar a @Pragma@.
dsPragma :: DsMonad q => Pragma -> q DPragma
dsPragma (InlineP n inl rm phases)       = return $ DInlineP n inl rm phases
dsPragma (SpecialiseP n ty m_inl phases) = DSpecialiseP n <$> dsType ty
                                                          <*> pure m_inl
                                                          <*> pure phases
dsPragma (SpecialiseInstP ty)            = DSpecialiseInstP <$> dsType ty
#if __GLASGOW_HASKELL__ >= 807
dsPragma (RuleP str mtvbs rbs lhs rhs phases)
                                         = DRuleP str <$> mapM (mapM dsTvbUnit) mtvbs
                                                      <*> mapM dsRuleBndr rbs
                                                      <*> dsExp lhs
                                                      <*> dsExp rhs
                                                      <*> pure phases
#else
dsPragma (RuleP str rbs lhs rhs phases)  = DRuleP str Nothing
                                                      <$> mapM dsRuleBndr rbs
                                                      <*> dsExp lhs
                                                      <*> dsExp rhs
                                                      <*> pure phases
#endif
dsPragma (AnnP target exp)               = DAnnP target <$> dsExp exp
dsPragma (LineP n str)                   = return $ DLineP n str
#if __GLASGOW_HASKELL__ >= 801
dsPragma (CompleteP cls mty)             = return $ DCompleteP cls mty
#endif
#if __GLASGOW_HASKELL__ >= 903
dsPragma (OpaqueP n)                     = return $ DOpaqueP n
#endif

-- | Desugar a @RuleBndr@.
dsRuleBndr :: DsMonad q => RuleBndr -> q DRuleBndr
dsRuleBndr (RuleVar n)         = return $ DRuleVar n
dsRuleBndr (TypedRuleVar n ty) = DTypedRuleVar n <$> dsType ty

#if __GLASGOW_HASKELL__ >= 807
-- | Desugar a @TySynEqn@. (Available only with GHC 7.8+)
--
-- This requires a 'Name' as an argument since 'TySynEqn's did not have
-- this information prior to GHC 8.8.
dsTySynEqn :: DsMonad q => Name -> TySynEqn -> q DTySynEqn
dsTySynEqn _ (TySynEqn mtvbs lhs rhs) =
  DTySynEqn <$> mapM (mapM dsTvbUnit) mtvbs <*> dsType lhs <*> dsType rhs
#else
-- | Desugar a @TySynEqn@. (Available only with GHC 7.8+)
dsTySynEqn :: DsMonad q => Name -> TySynEqn -> q DTySynEqn
dsTySynEqn n (TySynEqn lhss rhs) = do
  lhss' <- mapM dsType lhss
  let lhs' = applyDType (DConT n) $ map DTANormal lhss'
  DTySynEqn Nothing lhs' <$> dsType rhs
#endif

-- | Desugar clauses to a function definition
dsClauses :: DsMonad q
          => MatchContext -- ^ The context in which the clauses arise
          -> [Clause]     -- ^ Clauses to desugar
          -> q [DClause]
dsClauses _ [] = return []
dsClauses mc (Clause pats (NormalB exp) where_decs : rest) = do
  -- this case is necessary to maintain the roundtrip property.
  rest' <- dsClauses mc rest
  exp' <- dsExp exp
  (where_decs', ip_binder) <- dsLetDecs where_decs
  let exp_with_wheres = maybeDLetE where_decs' (ip_binder exp')
  (pats', exp'') <- dsPatsOverExp pats exp_with_wheres
  return $ DClause pats' exp'' : rest'
dsClauses mc clauses@(Clause outer_pats _ _ : _) = do
  arg_names <- replicateM (length outer_pats) (newUniqueName "arg")
  let scrutinee = mkUnboxedTupleDExp (map DVarE arg_names)
  clause <- DClause (map DVarP arg_names) <$>
              (DCaseE scrutinee <$> foldrM (clause_to_dmatch scrutinee) [] clauses)
  return [clause]
  where
    clause_to_dmatch :: DsMonad q => DExp -> Clause -> [DMatch] -> q [DMatch]
    clause_to_dmatch scrutinee (Clause pats body where_decs) failure_matches = do
      let failure_exp = maybeDCaseE mc scrutinee failure_matches
      exp <- dsBody body where_decs failure_exp
      (pats', exp') <- dsPatsOverExp pats exp
      uni_pats <- fmap getAll $ concatMapM (fmap All . isUniversalPattern) pats'
      let match = DMatch (mkUnboxedTupleDPat pats') exp'
      if uni_pats
      then return [match]
      else return (match : failure_matches)

-- | The context of a pattern match. This is used to produce
-- @Non-exhaustive patterns in...@ messages that are tailored to specific
-- situations. Compare this to GHC's @HsMatchContext@ data type
-- (https://gitlab.haskell.org/ghc/ghc/-/blob/81cf52bb301592ff3d043d03eb9a0d547891a3e1/compiler/Language/Haskell/Syntax/Expr.hs#L1662-1695),
-- from which the @MatchContext@ data type takes inspiration.
data MatchContext
  = FunRhs Name
    -- ^ A pattern matching on an argument of a function binding
  | LetDecRhs Pat
    -- ^ A pattern in a @let@ declaration
  | RecUpd
    -- ^ A record update
  | MultiWayIfAlt
    -- ^ Guards in a multi-way if alternative
  | CaseAlt
    -- ^ Patterns and guards in a case alternative

-- | Construct an expression that throws an error when encountering a pattern
-- at runtime that is not covered by pattern matching.
mkErrorMatchExpr :: MatchContext -> DExp
mkErrorMatchExpr mc =
  DAppE (DVarE 'error) (DLitE (StringL ("Non-exhaustive patterns in " ++ pp_context)))
  where
    pp_context =
      case mc of
        FunRhs n      -> show n
        LetDecRhs pat -> pprint pat
        RecUpd        -> "record update"
        MultiWayIfAlt -> "multi-way if"
        CaseAlt       -> "case"

-- | Desugar a type
dsType :: DsMonad q => Type -> q DType
#if __GLASGOW_HASKELL__ >= 900
-- See Note [Gracefully handling linear types]
dsType (MulArrowT `AppT` _) = return DArrowT
dsType MulArrowT = fail "Cannot desugar exotic uses of linear types."
#endif
dsType (ForallT tvbs preds ty) =
  mkDForallConstrainedT <$> (DForallInvis <$> mapM dsTvbSpec tvbs)
                        <*> dsCxt preds <*> dsType ty
dsType (AppT t1 t2) = DAppT <$> dsType t1 <*> dsType t2
dsType (SigT ty ki) = DSigT <$> dsType ty <*> dsType ki
dsType (VarT name) = return $ DVarT name
dsType (ConT name) = return $ DConT name
-- The PromotedT case is identical to the ConT case above.
-- See Note [Desugaring promoted types].
dsType (PromotedT name) = return $ DConT name
dsType (TupleT n) = return $ DConT (tupleTypeName n)
dsType (UnboxedTupleT n) = return $ DConT (unboxedTupleTypeName n)
dsType ArrowT = return DArrowT
dsType ListT = return $ DConT ''[]
dsType (PromotedTupleT n) = return $ DConT (tupleDataName n)
dsType PromotedNilT = return $ DConT '[]
dsType PromotedConsT = return $ DConT '(:)
dsType StarT = return $ DConT typeKindName
dsType ConstraintT = return $ DConT ''Constraint
dsType (LitT lit) = return $ DLitT lit
dsType EqualityT = return $ DConT ''(~)
dsType (InfixT t1 n t2) = dsInfixT t1 n t2
dsType (UInfixT{}) = dsUInfixT
dsType (ParensT t) = dsType t
dsType WildCardT = return DWildCardT
#if __GLASGOW_HASKELL__ >= 801
dsType (UnboxedSumT arity) = return $ DConT (unboxedSumTypeName arity)
#endif
#if __GLASGOW_HASKELL__ >= 807
dsType (AppKindT t k) = DAppKindT <$> dsType t <*> dsType k
dsType (ImplicitParamT n t) = do
  t' <- dsType t
  return $ DConT ''IP `DAppT` DLitT (StrTyLit n) `DAppT` t'
#endif
#if __GLASGOW_HASKELL__ >= 809
dsType (ForallVisT tvbs ty) =
  DForallT <$> (DForallVis <$> mapM dsTvbUnit tvbs) <*> dsType ty
#endif
#if __GLASGOW_HASKELL__ >= 903
-- The PromotedInfixT case is identical to the InfixT case above.
-- See Note [Desugaring promoted types].
dsType (PromotedInfixT t1 n t2) = dsInfixT t1 n t2
dsType PromotedUInfixT{} = dsUInfixT
#endif

#if __GLASGOW_HASKELL__ >= 900
-- | Desugar a 'TyVarBndr'.
dsTvb :: DsMonad q => TyVarBndr_ flag -> q (DTyVarBndr flag)
dsTvb (PlainTV n flag)    = return $ DPlainTV n flag
dsTvb (KindedTV n flag k) = DKindedTV n flag <$> dsType k
#else
-- | Desugar a 'TyVarBndr' with a particular @flag@.
dsTvb :: DsMonad q => flag -> TyVarBndr -> q (DTyVarBndr flag)
dsTvb flag (PlainTV n)    = return $ DPlainTV n flag
dsTvb flag (KindedTV n k) = DKindedTV n flag <$> dsType k
#endif

{-
Note [Gracefully handling linear types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Per the README, th-desugar does not currently support linear types.
Unfortunately, we cannot simply reject all occurrences of
multiplicity-polymorphic function arrows (i.e., MulArrowT), as it is possible
for "non-linear" code to contain them when reified. For example, the type of a
Haskell98 data constructor such as `Just` will be reified as

  a #-> Maybe a

In terms of the TH AST, that is:

  MulArrowT `AppT` PromotedConT 'One `AppT` VarT a `AppT` (ConT ''Maybe `AppT` VarT a)

Therefore, in order to desugar these sorts of types, we have to do *something*
with MulArrowT. The approach that th-desugar takes is to pretend that all
multiplicity-polymorphic function arrows are actually ordinary function arrows
(->) when desugaring types. In other words, whenever th-desugar sees
(MulArrowT `AppT` m), for any particular value of `m`, it will turn it into
DArrowT.

This approach is enough to gracefully handle most uses of MulArrowT, as TH
reification always generates MulArrowT applied to some particular multiplicity
(as of GHC 9.0, at least). It's conceivable that some wily user could manually
construct a TH AST containing MulArrowT in a different position, but since this
situation is rare, we simply throw an error in such cases.

We adopt a similar stance in L.H.TH.Desugar.Reify when locally reifying the
types of data constructors: since th-desugar doesn't currently support linear
types, we pretend as if MulArrowT does not exist. As a result, the type of
`Just` would be locally reified as `a -> Maybe a`, not `a #-> Maybe a`.

Note [Desugaring promoted types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
ConT and PromotedT both contain Names as a payload, the only difference being
that PromotedT is intended to refer exclusively to promoted data constructor
Names, while ConT can refer to both type and data constructor Names alike.

When desugaring a PromotedT, we make the assumption that the TH quoting
mechanism produced the correct Name and wrap the name in a DConT. In other
words, we desugar ConT and PromotedT identically. This assumption about
PromotedT may not always be correct, however. Consider this example:

  data a :+: b = Inl a | Inr b
  data Exp a = ... | Exp :+: Exp

How should `PromotedT (mkName ":+:")` be desugared? Morally, it ought to be
desugared to a DConT that contains (:+:) the data constructor, not (:+:) the
type constructor. Deciding between the two is not always straightforward,
however. We could use the `lookupDataName` function to try and distinguish
between the two Names, but this may not necessarily work. This is because the
Name passed to `lookupDataName` could have its original module attached, which
may not be in scope.

Long story short: we make things simple (albeit slightly wrong) by desugaring
ConT and PromotedT identically. We'll wait for someone to complain about the
wrongness of this approach before researching a more accurate solution.

Note that the same considerations also apply to InfixT and PromotedInfixT,
which are also desugared identically.
-}

-- | Desugar an infix 'Type'.
dsInfixT :: DsMonad q => Type -> Name -> Type -> q DType
dsInfixT t1 n t2 = DAppT <$> (DAppT (DConT n) <$> dsType t1) <*> dsType t2

-- | We cannot desugar unresolved infix operators, so fail if we encounter one.
dsUInfixT :: Fail.MonadFail m => m a
dsUInfixT = fail "Cannot desugar unresolved infix operators."

-- | Desugar a 'TyVarBndrSpec'.
dsTvbSpec :: DsMonad q => TyVarBndrSpec -> q DTyVarBndrSpec
#if __GLASGOW_HASKELL__ >= 900
dsTvbSpec = dsTvb
#else
dsTvbSpec = dsTvb SpecifiedSpec
#endif

-- | Desugar a 'TyVarBndrUnit'.
dsTvbUnit :: DsMonad q => TyVarBndrUnit -> q DTyVarBndrUnit
#if __GLASGOW_HASKELL__ >= 900
dsTvbUnit = dsTvb
#else
dsTvbUnit = dsTvb ()
#endif

-- | Desugar a @Cxt@
dsCxt :: DsMonad q => Cxt -> q DCxt
dsCxt = concatMapM dsPred

#if __GLASGOW_HASKELL__ >= 801
-- | A backwards-compatible type synonym for the thing representing a single
-- derived class in a @deriving@ clause. (This is a @DerivClause@, @Pred@, or
-- @Name@ depending on the GHC version.)
type DerivingClause = DerivClause

-- | Desugar a @DerivingClause@.
dsDerivClause :: DsMonad q => DerivingClause -> q DDerivClause
dsDerivClause (DerivClause mds cxt) =
  DDerivClause <$> mapM dsDerivStrategy mds <*> dsCxt cxt
#else
type DerivingClause = Pred

dsDerivClause :: DsMonad q => DerivingClause -> q DDerivClause
dsDerivClause p = DDerivClause Nothing <$> dsPred p
#endif

#if __GLASGOW_HASKELL__ >= 801
-- | Desugar a @DerivStrategy@.
dsDerivStrategy :: DsMonad q => DerivStrategy -> q DDerivStrategy
dsDerivStrategy StockStrategy    = pure DStockStrategy
dsDerivStrategy AnyclassStrategy = pure DAnyclassStrategy
dsDerivStrategy NewtypeStrategy  = pure DNewtypeStrategy
#if __GLASGOW_HASKELL__ >= 805
dsDerivStrategy (ViaStrategy ty) = DViaStrategy <$> dsType ty
#endif
#endif

#if __GLASGOW_HASKELL__ >= 801
-- | Desugar a @PatSynDir@. (Available only with GHC 8.2+)
dsPatSynDir :: DsMonad q => Name -> PatSynDir -> q DPatSynDir
dsPatSynDir _ Unidir              = pure DUnidir
dsPatSynDir _ ImplBidir           = pure DImplBidir
dsPatSynDir n (ExplBidir clauses) = DExplBidir <$> dsClauses (FunRhs n) clauses
#endif

-- | Desugar a @Pred@, flattening any internal tuples
dsPred :: DsMonad q => Pred -> q DCxt
dsPred t
  | Just ts <- splitTuple_maybe t
  = concatMapM dsPred ts
dsPred (ForallT tvbs cxt p) = dsForallPred tvbs cxt p
dsPred (AppT t1 t2) = do
  [p1] <- dsPred t1   -- tuples can't be applied!
  (:[]) <$> DAppT p1 <$> dsType t2
dsPred (SigT ty ki) = do
  preds <- dsPred ty
  case preds of
    [p]   -> (:[]) <$> DSigT p <$> dsType ki
    other -> return other   -- just drop the kind signature on a tuple.
dsPred (VarT n) = return [DVarT n]
dsPred (ConT n) = return [DConT n]
dsPred t@(PromotedT _) =
  impossible $ "Promoted type seen as head of constraint: " ++ show t
dsPred (TupleT 0) = return [DConT (tupleTypeName 0)]
dsPred (TupleT _) =
  impossible "Internal error in th-desugar in detecting tuple constraints."
dsPred t@(UnboxedTupleT _) =
  impossible $ "Unboxed tuple seen as head of constraint: " ++ show t
dsPred ArrowT = impossible "Arrow seen as head of constraint."
dsPred ListT  = impossible "List seen as head of constraint."
dsPred (PromotedTupleT _) =
  impossible "Promoted tuple seen as head of constraint."
dsPred PromotedNilT  = impossible "Promoted nil seen as head of constraint."
dsPred PromotedConsT = impossible "Promoted cons seen as head of constraint."
dsPred StarT         = impossible "* seen as head of constraint."
dsPred ConstraintT =
  impossible "The kind `Constraint' seen as head of constraint."
dsPred t@(LitT _) =
  impossible $ "Type literal seen as head of constraint: " ++ show t
dsPred EqualityT = return [DConT ''(~)]
dsPred (InfixT t1 n t2) = (:[]) <$> dsInfixT t1 n t2
dsPred (UInfixT{}) = dsUInfixT
dsPred (ParensT t) = dsPred t
dsPred WildCardT = return [DWildCardT]
#if __GLASGOW_HASKELL__ >= 801
dsPred t@(UnboxedSumT {}) =
  impossible $ "Unboxed sum seen as head of constraint: " ++ show t
#endif
#if __GLASGOW_HASKELL__ >= 807
dsPred (AppKindT t k) = do
  [p] <- dsPred t
  (:[]) <$> (DAppKindT p <$> dsType k)
dsPred (ImplicitParamT n t) = do
  t' <- dsType t
  return [DConT ''IP `DAppT` DLitT (StrTyLit n) `DAppT` t']
#endif
#if __GLASGOW_HASKELL__ >= 809
dsPred t@(ForallVisT {}) =
  impossible $ "Visible dependent quantifier seen as head of constraint: " ++ show t
#endif
#if __GLASGOW_HASKELL__ >= 900
dsPred MulArrowT = impossible "Linear arrow seen as head of constraint."
#endif
#if __GLASGOW_HASKELL__ >= 903
dsPred t@PromotedInfixT{} =
  impossible $ "Promoted infix type seen as head of constraint: " ++ show t
dsPred PromotedUInfixT{} = dsUInfixT
#endif

-- | Desugar a quantified constraint.
dsForallPred :: DsMonad q => [TyVarBndrSpec] -> Cxt -> Pred -> q DCxt
dsForallPred tvbs cxt p = do
  ps' <- dsPred p
  case ps' of
    [p'] -> (:[]) <$> (mkDForallConstrainedT <$>
                         (DForallInvis <$> mapM dsTvbSpec tvbs) <*> dsCxt cxt <*> pure p')
    _    -> fail "Cannot desugar constraint tuples in the body of a quantified constraint"
              -- See GHC #15334.

-- | Like 'reify', but safer and desugared. Uses local declarations where
-- available.
dsReify :: DsMonad q => Name -> q (Maybe DInfo)
dsReify = traverse dsInfo <=< reifyWithLocals_maybe

-- | Like 'reifyType', but safer and desugared. Uses local declarations where
-- available.
dsReifyType :: DsMonad q => Name -> q (Maybe DType)
dsReifyType = traverse dsType <=< reifyTypeWithLocals_maybe

-- Given a list of `forall`ed type variable binders and a context, construct
-- a DType using DForallT and DConstrainedT as appropriate. The phrase
-- "as appropriate" is used because DConstrainedT will not be used if the
-- context is empty, per Note [Desugaring and sweetening ForallT].
mkDForallConstrainedT :: DForallTelescope -> DCxt -> DType -> DType
mkDForallConstrainedT tele ctxt ty =
  DForallT tele $ if null ctxt then ty else DConstrainedT ctxt ty

-- create a list of expressions in the same order as the fields in the first argument
-- but with the values as given in the second argument
-- if a field is missing from the second argument, use the corresponding expression
-- from the third argument
reorderFields :: DsMonad q => Name -> [VarStrictType] -> [FieldExp] -> [DExp] -> q [DExp]
reorderFields = reorderFields' dsExp

reorderFieldsPat :: DsMonad q => Name -> [VarStrictType] -> [FieldPat] -> PatM q [DPat]
reorderFieldsPat con_name field_decs field_pats =
  reorderFields' dsPat con_name field_decs field_pats (repeat DWildP)

reorderFields' :: (Applicative m, Fail.MonadFail m)
               => (a -> m da)
               -> Name -- ^ The name of the constructor (used for error reporting)
               -> [VarStrictType] -> [(Name, a)]
               -> [da] -> m [da]
reorderFields' ds_thing con_name field_names_types field_things deflts =
  check_valid_fields >> reorder field_names deflts
  where
    field_names = map (\(a, _, _) -> a) field_names_types

    check_valid_fields =
      forM_ field_things $ \(thing_name, _) ->
        unless (thing_name `elem` field_names) $
          fail $ "Constructor ‘" ++ nameBase con_name   ++ "‘ does not have field ‘"
                                 ++ nameBase thing_name ++ "‘"

    reorder [] _ = return []
    reorder (field_name : rest) (deflt : rest_deflt) = do
      rest' <- reorder rest rest_deflt
      case find (\(thing_name, _) -> thing_name == field_name) field_things of
        Just (_, thing) -> (: rest') <$> ds_thing thing
        Nothing -> return $ deflt : rest'
    reorder (_ : _) [] = error "Internal error in th-desugar."

-- mkTupleDExp, mkUnboxedTupleDExp, and friends construct tuples, avoiding the
-- use of 1-tuples. These are used to create auxiliary tuple values when
-- desugaring pattern-matching constructs to simpler forms.
-- See Note [Auxiliary tuples in pattern matching].

-- | Make a tuple 'DExp' from a list of 'DExp's. Avoids using a 1-tuple.
mkTupleDExp :: [DExp] -> DExp
mkTupleDExp [exp] = exp
mkTupleDExp exps = foldl DAppE (DConE $ tupleDataName (length exps)) exps

-- | Make an unboxed tuple 'DExp' from a list of 'DExp's. Avoids using a 1-tuple.
mkUnboxedTupleDExp :: [DExp] -> DExp
mkUnboxedTupleDExp [exp] = exp
mkUnboxedTupleDExp exps = foldl DAppE (DConE $ unboxedTupleDataName (length exps)) exps

-- | Make a tuple 'Exp' from a list of 'Exp's. Avoids using a 1-tuple.
mkTupleExp :: [Exp] -> Exp
mkTupleExp [exp] = exp
mkTupleExp exps = foldl AppE (ConE $ tupleDataName (length exps)) exps

-- | Make an unboxed tuple 'Exp' from a list of 'Exp's. Avoids using a 1-tuple.
mkUnboxedTupleExp :: [Exp] -> Exp
mkUnboxedTupleExp [exp] = exp
mkUnboxedTupleExp exps = foldl AppE (ConE $ unboxedTupleDataName (length exps)) exps

-- | Make a tuple 'DPat' from a list of 'DPat's. Avoids using a 1-tuple.
mkTupleDPat :: [DPat] -> DPat
mkTupleDPat [pat] = pat
mkTupleDPat pats = DConP (tupleDataName (length pats)) [] pats

-- | Make an unboxed tuple 'DPat' from a list of 'DPat's. Avoids using a 1-tuple.
mkUnboxedTupleDPat :: [DPat] -> DPat
mkUnboxedTupleDPat [pat] = pat
mkUnboxedTupleDPat pats = DConP (unboxedTupleDataName (length pats)) [] pats

-- | Is this pattern guaranteed to match?
isUniversalPattern :: DsMonad q => DPat -> q Bool
isUniversalPattern (DLitP {}) = return False
isUniversalPattern (DVarP {}) = return True
isUniversalPattern (DConP con_name _ pats) = do
  data_name <- dataConNameToDataName con_name
  (_tvbs, cons) <- getDataD "Internal error." data_name
  if length cons == 1
  then fmap and $ mapM isUniversalPattern pats
  else return False
isUniversalPattern (DTildeP {})  = return True
isUniversalPattern (DBangP pat)  = isUniversalPattern pat
isUniversalPattern (DSigP pat _) = isUniversalPattern pat
isUniversalPattern DWildP        = return True

-- | Apply one 'DExp' to a list of arguments
applyDExp :: DExp -> [DExp] -> DExp
applyDExp = foldl DAppE

-- | Apply one 'DType' to a list of arguments
applyDType :: DType -> [DTypeArg] -> DType
applyDType = foldl apply
  where
    apply :: DType -> DTypeArg -> DType
    apply f (DTANormal x) = f `DAppT` x
    apply f (DTyArg x)    = f `DAppKindT` x

-- | An argument to a type, either a normal type ('DTANormal') or a visible
-- kind application ('DTyArg').
--
-- 'DTypeArg' does not appear directly in the @th-desugar@ AST, but it is
-- useful when decomposing an application of a 'DType' to its arguments.
data DTypeArg
  = DTANormal DType
  | DTyArg DKind
  deriving (Eq, Show, Data, Generic)

-- | Desugar a 'TypeArg'.
dsTypeArg :: DsMonad q => TypeArg -> q DTypeArg
dsTypeArg (TANormal t) = DTANormal <$> dsType t
dsTypeArg (TyArg k)    = DTyArg    <$> dsType k

-- | Filter the normal type arguments from a list of 'DTypeArg's.
filterDTANormals :: [DTypeArg] -> [DType]
filterDTANormals = mapMaybe getDTANormal
  where
    getDTANormal :: DTypeArg -> Maybe DType
    getDTANormal (DTANormal t) = Just t
    getDTANormal (DTyArg {})   = Nothing

-- | Convert a 'DTyVarBndr' into a 'DType'
dTyVarBndrToDType :: DTyVarBndr flag -> DType
dTyVarBndrToDType (DPlainTV a _)    = DVarT a
dTyVarBndrToDType (DKindedTV a _ k) = DVarT a `DSigT` k

-- | Extract the underlying 'DType' or 'DKind' from a 'DTypeArg'. This forgets
-- information about whether a type is a normal argument or not, so use with
-- caution.
probablyWrongUnDTypeArg :: DTypeArg -> DType
probablyWrongUnDTypeArg (DTANormal t) = t
probablyWrongUnDTypeArg (DTyArg k)    = k

-- Take a data type name (which does not belong to a data family) and
-- apply it to its type variable binders to form a DType.
nonFamilyDataReturnType :: Name -> [DTyVarBndrUnit] -> DType
nonFamilyDataReturnType con_name =
  applyDType (DConT con_name) . map (DTANormal . dTyVarBndrToDType)

-- Take a data family name and apply it to its argument types to form a
-- data family instance DType.
dataFamInstReturnType :: Name -> [DTypeArg] -> DType
dataFamInstReturnType fam_name = applyDType (DConT fam_name)

-- Data family instance declarations did not come equipped with a list of bound
-- type variables until GHC 8.8 (and even then, it's optional whether the user
-- provides them or not). This means that there are situations where we must
-- reverse engineer this information ourselves from the list of type
-- arguments. We accomplish this by taking the free variables of the types
-- and performing a reverse topological sort on them to ensure that the
-- returned list is well scoped.
dataFamInstTvbs :: [DTypeArg] -> [DTyVarBndrUnit]
dataFamInstTvbs = toposortTyVarsOf . map probablyWrongUnDTypeArg

-- | Take a list of 'DType's, find their free variables, and sort them in
-- reverse topological order to ensure that they are well scoped. In other
-- words, the free variables are ordered such that:
--
-- 1. Whenever an explicit kind signature of the form @(A :: K)@ is
--    encountered, the free variables of @K@ will always appear to the left of
--    the free variables of @A@ in the returned result.
--
-- 2. The constraint in (1) notwithstanding, free variables will appear in
--    left-to-right order of their original appearance.
--
-- On older GHCs, this takes measures to avoid returning explicitly bound
-- kind variables, which was not possible before @TypeInType@.
toposortTyVarsOf :: [DType] -> [DTyVarBndrUnit]
toposortTyVarsOf tys =
  let freeVars :: [Name]
      freeVars = F.toList $ foldMap fvDType tys

      varKindSigs :: Map Name DKind
      varKindSigs = foldMap go_ty tys
        where
          go_ty :: DType -> Map Name DKind
          go_ty (DForallT tele t) = go_tele tele (go_ty t)
          go_ty (DConstrainedT ctxt t) = foldMap go_ty ctxt `mappend` go_ty t
          go_ty (DAppT t1 t2) = go_ty t1 `mappend` go_ty t2
          go_ty (DAppKindT t k) = go_ty t `mappend` go_ty k
          go_ty (DSigT t k) =
            let kSigs = go_ty k
            in case t of
                 DVarT n -> M.insert n k kSigs
                 _       -> go_ty t `mappend` kSigs
          go_ty (DVarT {}) = mempty
          go_ty (DConT {}) = mempty
          go_ty DArrowT    = mempty
          go_ty (DLitT {}) = mempty
          go_ty DWildCardT = mempty

          go_tele :: DForallTelescope -> Map Name DKind -> Map Name DKind
          go_tele (DForallVis   tvbs) = go_tvbs tvbs
          go_tele (DForallInvis tvbs) = go_tvbs tvbs

          go_tvbs :: [DTyVarBndr flag] -> Map Name DKind -> Map Name DKind
          go_tvbs tvbs m = foldr go_tvb m tvbs

          go_tvb :: DTyVarBndr flag -> Map Name DKind -> Map Name DKind
          go_tvb (DPlainTV n _)    m = M.delete n m
          go_tvb (DKindedTV n _ k) m = M.delete n m `mappend` go_ty k

      -- | Do a topological sort on a list of tyvars,
      --   so that binders occur before occurrences
      -- E.g. given  [ a::k, k::*, b::k ]
      -- it'll return a well-scoped list [ k::*, a::k, b::k ]
      --
      -- This is a deterministic sorting operation
      -- (that is, doesn't depend on Uniques).
      --
      -- It is also meant to be stable: that is, variables should not
      -- be reordered unnecessarily.
      scopedSort :: [Name] -> [Name]
      scopedSort = go [] []

      go :: [Name]     -- already sorted, in reverse order
         -> [Set Name] -- each set contains all the variables which must be placed
                       -- before the tv corresponding to the set; they are accumulations
                       -- of the fvs in the sorted tvs' kinds

                       -- This list is in 1-to-1 correspondence with the sorted tyvars
                       -- INVARIANT:
                       --   all (\tl -> all (`isSubsetOf` head tl) (tail tl)) (tails fv_list)
                       -- That is, each set in the list is a superset of all later sets.
         -> [Name]     -- yet to be sorted
         -> [Name]
      go acc _fv_list [] = reverse acc
      go acc  fv_list (tv:tvs)
        = go acc' fv_list' tvs
        where
          (acc', fv_list') = insert tv acc fv_list

      insert :: Name       -- var to insert
             -> [Name]     -- sorted list, in reverse order
             -> [Set Name] -- list of fvs, as above
             -> ([Name], [Set Name])   -- augmented lists
      insert tv []     []         = ([tv], [kindFVSet tv])
      insert tv (a:as) (fvs:fvss)
        | tv `S.member` fvs
        , (as', fvss') <- insert tv as fvss
        = (a:as', fvs `S.union` fv_tv : fvss')

        | otherwise
        = (tv:a:as, fvs `S.union` fv_tv : fvs : fvss)
        where
          fv_tv = kindFVSet tv

         -- lists not in correspondence
      insert _ _ _ = error "scopedSort"

      kindFVSet n =
        maybe S.empty (OS.toSet . fvDType)
                      (M.lookup n varKindSigs)
      ascribeWithKind n =
        maybe (DPlainTV n ()) (DKindedTV n ()) (M.lookup n varKindSigs)

  in map ascribeWithKind $
     scopedSort freeVars

dtvbName :: DTyVarBndr flag -> Name
dtvbName (DPlainTV n _)    = n
dtvbName (DKindedTV n _ _) = n

-- @mk_qual_do_name mb_mod orig_name@ will simply return @orig_name@ if
-- @mb_mod@ is Nothing. If @mb_mod@ is @Just mod_@, then a new 'Name' will be
-- returned that uses @mod_@ as the new module prefix. This is useful for
-- emulating the behavior of the @QualifiedDo@ extension, which adds module
-- prefixes to functions such as ('>>=') and ('>>').
mk_qual_do_name :: Maybe ModName -> Name -> Name
mk_qual_do_name mb_mod orig_name = case mb_mod of
  Nothing   -> orig_name
  Just mod_ -> Name (OccName (nameBase orig_name)) (NameQ mod_)

-- | Reconstruct an arrow 'DType' from its argument and result types.
ravelDType :: DFunArgs -> DType -> DType
ravelDType DFANil                 res = res
ravelDType (DFAForalls tele args) res = DForallT tele (ravelDType args res)
ravelDType (DFACxt cxt args)      res = DConstrainedT cxt (ravelDType args res)
ravelDType (DFAAnon t args)       res = DAppT (DAppT DArrowT t) (ravelDType args res)

-- | Decompose a function 'DType' into its arguments (the 'DFunArgs') and its
-- result type (the 'DType).
unravelDType :: DType -> (DFunArgs, DType)
unravelDType (DForallT tele ty) =
  let (args, res) = unravelDType ty in
  (DFAForalls tele args, res)
unravelDType (DConstrainedT cxt ty) =
  let (args, res) = unravelDType ty in
  (DFACxt cxt args, res)
unravelDType (DAppT (DAppT DArrowT t1) t2) =
  let (args, res) = unravelDType t2 in
  (DFAAnon t1 args, res)
unravelDType t = (DFANil, t)

-- | The list of arguments in a function 'DType'.
data DFunArgs
  = DFANil
    -- ^ No more arguments.
  | DFAForalls DForallTelescope DFunArgs
    -- ^ A series of @forall@ed type variables followed by a dot (if
    --   'ForallInvis') or an arrow (if 'ForallVis'). For example,
    --   the type variables @a1 ... an@ in @forall a1 ... an. r@.
  | DFACxt DCxt DFunArgs
    -- ^ A series of constraint arguments followed by @=>@. For example,
    --   the @(c1, ..., cn)@ in @(c1, ..., cn) => r@.
  | DFAAnon DType DFunArgs
    -- ^ An anonymous argument followed by an arrow. For example, the @a@
    --   in @a -> r@.
  deriving (Eq, Show, Data, Generic)

-- | A /visible/ function argument type (i.e., one that must be supplied
-- explicitly in the source code). This is in contrast to /invisible/
-- arguments (e.g., the @c@ in @c => r@), which are instantiated without
-- the need for explicit user input.
data DVisFunArg
  = DVisFADep DTyVarBndrUnit
    -- ^ A visible @forall@ (e.g., @forall a -> a@).
  | DVisFAAnon DType
    -- ^ An anonymous argument followed by an arrow (e.g., @a -> r@).
  deriving (Eq, Show, Data, Generic)

-- | Filter the visible function arguments from a list of 'DFunArgs'.
filterDVisFunArgs :: DFunArgs -> [DVisFunArg]
filterDVisFunArgs DFANil = []
filterDVisFunArgs (DFAForalls tele args) =
  case tele of
    DForallVis tvbs -> map DVisFADep tvbs ++ args'
    DForallInvis _  -> args'
  where
    args' = filterDVisFunArgs args
filterDVisFunArgs (DFACxt _ args) =
  filterDVisFunArgs args
filterDVisFunArgs (DFAAnon t args) =
  DVisFAAnon t:filterDVisFunArgs args

-- | Decompose an applied type into its individual components. For example, this:
--
-- @
-- Proxy \@Type Char
-- @
--
-- would be unfolded to this:
--
-- @
-- ('DConT' ''Proxy, ['DTyArg' ('DConT' ''Type), 'DTANormal' ('DConT' ''Char)])
-- @
unfoldDType :: DType -> (DType, [DTypeArg])
unfoldDType = go []
  where
    go :: [DTypeArg] -> DType -> (DType, [DTypeArg])
    go acc (DForallT _ ty)   = go acc ty
    go acc (DAppT ty1 ty2)   = go (DTANormal ty2:acc) ty1
    go acc (DAppKindT ty ki) = go (DTyArg ki:acc) ty
    go acc (DSigT ty _)      = go acc ty
    go acc ty                = (ty, acc)

-- | Extract the kind from a 'DTyVarBndr', if one is present.
extractTvbKind :: DTyVarBndr flag -> Maybe DKind
extractTvbKind (DPlainTV _ _)    = Nothing
extractTvbKind (DKindedTV _ _ k) = Just k

-- | Set the flag in a list of 'DTyVarBndr's. This is often useful in contexts
-- where one needs to re-use a list of 'DTyVarBndr's from one flag setting to
-- another flag setting. For example, in order to re-use the 'DTyVarBndr's bound
-- by a 'DDataD' in a 'DForallT', one can do the following:
--
-- @
-- case x of
--   'DDataD' _ _ _ tvbs _ _ _ ->
--     'DForallT' ('DForallInvis' ('changeDTVFlags' 'SpecifiedSpec' tvbs)) ...
-- @
changeDTVFlags :: newFlag -> [DTyVarBndr oldFlag] -> [DTyVarBndr newFlag]
changeDTVFlags new_flag = map (new_flag <$)

-- | Some functions in this module only use certain arguments on particular
-- versions of GHC. Other versions of GHC (that don't make use of those
-- arguments) might need to conjure up those arguments out of thin air at the
-- functions' call sites, so this function serves as a placeholder to use in
-- those situations. (In other words, this is a slightly more informative
-- version of 'undefined'.)
unusedArgument :: a
unusedArgument = error "Unused"

{-
Note [Desugaring and sweetening ForallT]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The ForallT constructor from template-haskell is tremendously awkward. Because
ForallT contains both a list of type variable binders and constraint arguments,
ForallT expressions can be ambiguous when one of these lists is empty. For
example, consider this expression with no constraints:

  ForallT [PlainTV a] [] (VarT a)

What should this desugar to in th-desugar, which must maintain a clear
separation between type variable binders and constraints? There are two
possibilities:

1. DForallT DForallInvis [DPlainTV a] (DVarT a)
   (i.e., forall a. a)
2. DForallT DForallInvis [DPlainTV a] (DConstrainedT [] (DVarT a))
   (i.e., forall a. () => a)

Template Haskell generally drops these empty lists when splicing Template
Haskell expressions, so we would like to do the same in th-desugar to mimic
TH's behavior as closely as possible. However, there are some situations where
dropping empty lists of `forall`ed type variable binders can change the
semantics of a program. For instance, contrast `foo :: forall. a -> a` (which
is an error) with `foo :: a -> a` (which is fine). Therefore, we try to
preserve empty `forall`s to the best of our ability.

Here is an informal specification of how th-desugar should handle different sorts
of ambiguity. First, a specification for desugaring.
Let `tvbs` and `ctxt` be non-empty:

* `ForallT tvbs [] ty` should desugar to `DForallT DForallInvis tvbs ty`.
* `ForallT [] ctxt ty` should desguar to `DForallT DForallInvis [] (DConstrainedT ctxt ty)`.
* `ForallT [] [] ty`   should desugar to `DForallT DForallInvis [] ty`.
* For all other cases, just straightforwardly desugar
  `ForallT tvbs ctxt ty` to `DForallT DForallInvis tvbs (DConstraintedT ctxt ty)`.

For sweetening:

* `DForallT DForallInvis tvbs (DConstrainedT ctxt ty)` should sweeten to `ForallT tvbs ctxt ty`.
* `DForallT DForallInvis []   (DConstrainedT ctxt ty)` should sweeten to `ForallT [] ctxt ty`.
* `DForallT DForallInvis tvbs (DConstrainedT [] ty)`   should sweeten to `ForallT tvbs [] ty`.
* `DForallT DForallInvis []   (DConstrainedT [] ty)`   should sweeten to `ForallT [] [] ty`.
* For all other cases, just straightforwardly sweeten
  `DForallT DForallInvis tvbs ty` to `ForallT tvbs [] ty` and
  `DConstrainedT ctxt ty` to `ForallT [] ctxt ty`.

Note [Auxiliary tuples in pattern matching]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
th-desugar simplifies the overall treatment of pattern matching in two
notable ways:

1. Lambda expressions only bind variables and do not directly perform pattern
   matching. For example, this:

     \True False -> ()

   Roughly desugars to:

     \x y -> case (x, y) of
               (True, False) -> ()
               _             -> error "Non-exhaustive patterns"
2. th-desugar does not have guards, as guards are desugared into pattern
   matches. For example, this:

     f x y | True <- x
           , False <- y
           = ()

  Roughly desugars to:

    f x y = case (x, y) of
              (True, False) -> ()
              _             -> error "Non-exhaustive patterns"

In both of these examples, there are multiple expressions being matched on
simultaneously. When desugaring these examples to `case` expressions, we need a
construct that allows us to group these patterns together. Auxiliary tuples are
one way to accomplish this.

While this use of tuples works well when the arguments have lifted types, such
as Bool, it doesn't work when the arguments have unlifted types, such as Int#.
Imagine desugaring this lambda expression, for instance:

  \27# 42# -> ()

The approach above would desugar this to:

  \x y -> case (x, y) of
            (27#, 42#) -> ()
            _          -> error "Non-exhaustive patterns"

This will not typecheck, however, as we are using _lifted_ tuples, which
require their arguments to have lifted types. If we want to support unlifted
types, we need a different approach.

One idea that seems tempting at first is to create an auxiliary `let`
expression, e.g.,

  \x y ->
    let aux 27# 42# = ()
     in aux x y

This avoids having to use lifted tuples, but it creates a new problem: type
inference. In the general case, auxiliary `let` expressions aren't enough to
handle GADT pattern matches, such as in this example:

  data T a where
    MkT :: Int -> T Int

  g :: T a -> T a -> a
  g = \(MkT x1) (MkT x2) -> x1 + x2

If you desugar `g` to use an auxiliary `let` expression:

  g :: T a -> T a -> a
  g = \t1 t2 ->
        let aux (MkT x1) (MkT x2) = x1 + x2
        in aux t1 t2

Then it will not typecheck. To make this work, you'd need to give `aux` a type
signature. Doing this in general is tantamount to performing type inference,
however, which is very challenging in a Template Haskell setting.

Another approach, which is what th-desugar currently uses, is to use auxiliary
_unboxed_ tuples. This is identical to the previous tuple approach, but with
slightly different syntax:

  \x y -> case (# x, y #) of
            (# 27#, 42# #) -> ()
            _              -> error "Non-exhaustive patterns"

Unboxed tuples can handle lifted and unlifted arguments alike, so it is capable
of handling all the examples above.

You might worry that this approach would require clients of th-desugar to
enable the UnboxedTuples extension in non-obvious places, but fortunately, this
is not the case. For one thing, all unboxed tuples produced by th-desugar would
be TH-generated, so we would bypass the need to enable UnboxedTuples to lex
unboxed tuple syntax. GHC's typechecker also imposes a requirement that
UnboxedTuples be enabled if a variable has an unboxed tuple type, but this
never happens in th-desugar by construction. It's possible that a future
version of GHC might be stricter about this, but it seems unlikely.

There are a couple of exceptions to the general rule that auxiliary binders
should be unboxed:

1. ParallelListComp is desugared using the `mzip` function, which returns a
   lifted pair. As a result, the variables bound in a parallel list
   comprehension must be lifted. This is a restriction which is inherited from
   GHC itself—https://gitlab.haskell.org/ghc/ghc/-/merge_requests/7270.

2. Match flattening desugars lazy patterns that bind multiple variables to code
   that extracts fields from tuples. For instance, this:

     data Pair a b = MkPair a b

     f :: Pair a b -> Pair b a
     f ~(MkPair x y) = MkPair y x

   Desugars to this (roughly) when match-flattened:

     f :: Pair a b -> Pair b a
     f p =
       let tuple = case p of
                     MkPair x y -> (x, y)

           x = case tuple of
                 (x, _) -> x

           y = case tuple of
                 (_, y) -> x

        in MkPair y x

   One could imagine using an unboxed tuple here instead, but since the
   intermediate `tuple` value would have an unboxed tuple this, this would
   require users of match flattening to enable UnboxedTuples. Fortunately,
   using unboxed tuples here isn't necessary, as GHC doesn't support binding
   variables with unlifted types in lazy patterns anyway.
-}

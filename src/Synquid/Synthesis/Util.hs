{-# LANGUAGE TemplateHaskell, FlexibleContexts #-}

module Synquid.Synthesis.Util where 

import Synquid.Logic
import Synquid.Type hiding (set)
import Synquid.Program
import Synquid.Error
import Synquid.Util
import Synquid.Pretty
import Synquid.Tokens
import Synquid.Solver.Monad
import Synquid.Solver.TypeConstraint
import qualified Synquid.Solver.Util as TCSolver (freshId, freshVar)

import Data.Maybe
import Data.List
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.Set as Set
import Data.Char
import Control.Monad.Logic
import Control.Monad.State
import Control.Monad.Reader
import Control.Lens
import Data.Key (mapWithKeyM)
import Debug.Trace

{- Types -}

-- | Choices for the type of terminating fixpoint operator
data FixpointStrategy =
    DisableFixpoint   -- ^ Do not use fixpoint
  | FirstArgument     -- ^ Fixpoint decreases the first well-founded argument
  | AllArguments      -- ^ Fixpoint decreases the lexicographical tuple of all well-founded argument in declaration order
  | Nonterminating    -- ^ Fixpoint without termination check

-- | Choices for the order of e-term enumeration
data PickSymbolStrategy = PickDepthFirst | PickInterleave

-- | Parameters of program exploration
data ExplorerParams = ExplorerParams {
  _eGuessDepth :: Int,                    -- ^ Maximum depth of application trees
  _scrutineeDepth :: Int,                 -- ^ Maximum depth of application trees inside match scrutinees
  _matchDepth :: Int,                     -- ^ Maximum nesting level of matches
  _auxDepth :: Int,                       -- ^ Maximum nesting level of auxiliary functions (lambdas used as arguments)
  _fixStrategy :: FixpointStrategy,       -- ^ How to generate terminating fixpoints
  _polyRecursion :: Bool,                 -- ^ Enable polymorphic recursion?
  _predPolyRecursion :: Bool,             -- ^ Enable recursion polymorphic in abstract predicates?
  _abduceScrutinees :: Bool,              -- ^ Should we match eagerly on all unfolded variables?
  _unfoldLocals :: Bool,                  -- ^ Unfold binders introduced by matching (to use them in match abduction)?
  _partialSolution :: Bool,               -- ^ Should implementations that only cover part of the input space be accepted?
  _incrementalChecking :: Bool,           -- ^ Solve subtyping constraints during the bottom-up phase
  _consistencyChecking :: Bool,           -- ^ Check consistency of function's type with the goal before exploring arguments?
  _splitMeasures :: Bool,                 -- ^ Split subtyping constraints between datatypes into constraints over each measure
  _context :: RProgram -> RProgram,       -- ^ Context in which subterm is currently being generated (used only for logging and symmetry reduction)
  _symmetryReduction :: Bool,             -- ^ Should partial applications be memoized to check for redundancy?
  _sourcePos :: SourcePos,                -- ^ Source position of the current goal
  _explorerLogLevel :: Int,               -- ^ How verbose logging is
  _shouldCut :: Bool,                     -- ^ Should cut the search upon synthesizing a functionally correct branch
  _numPrograms :: Int,                    -- ^ Number of programs to search for
  _resourceArgs :: ResourceArgs           -- ^ Arguments relevant to resource analysis
}

makeLenses ''ExplorerParams

type Requirements = Map Id [RType]

-- | State of program exploration
data ExplorerState = ExplorerState {
  _typingState :: TypingState,                     -- ^ Type-checking state
  _auxGoals :: [Goal],                             -- ^ Subterms to be synthesized independently
  _solvedAuxGoals :: Map Id RProgram,              -- Synthesized auxiliary goals, to be inserted into the main program
  _lambdaLets :: Map Id (Environment, UProgram),   -- ^ Local bindings to be checked upon use (in type checking mode)
  _requiredTypes :: Requirements,                  -- ^ All types that a variable is required to comply to (in repair mode)
  _symbolUseCount :: Map Id Int                    -- ^ Number of times each symbol has been used in the program so far
} deriving (Eq, Ord)

makeLenses ''ExplorerState

-- | Persistent state accross explorations
newtype PersistentState = PersistentState { _typeErrors :: [ErrorMessage] }

makeLenses ''PersistentState

-- | Computations that explore program space, parametrized by the the horn solver @s@
type Explorer s = StateT ExplorerState (
                    ReaderT (ExplorerParams, TypingParams, Reconstructor s) (
                    LogicT (StateT PersistentState s)))

-- | This type encapsulates the 'reconstructTopLevel' function of the type checker,
-- which the explorer calls for auxiliary goals
newtype Reconstructor s = Reconstructor (Goal -> Explorer s RProgram) 

type TypeExplorer s = Environment -> RType -> Explorer s RProgram


throwErrorWithDescription :: MonadHorn s => Doc -> Explorer s a
throwErrorWithDescription msg = do
  pos <- asks . view $ _1 . sourcePos
  throwError $ ErrorMessage TypeError pos msg

-- | Record type error and backtrack
throwError :: MonadHorn s => ErrorMessage -> Explorer s a
throwError e = do
  writeLog 2 $ text "TYPE ERROR:" <+> plain (emDescription e)
  lift . lift . lift $ typeErrors %= (e :)
  mzero

-- | Impose typing constraint @c@ on the programs
addConstraint c = typingState %= addTypingConstraint c

-- | When constant-time flag is set, add the appropriate constraint 
addCTConstraint :: MonadHorn s => Environment -> Id -> Explorer s ()
addCTConstraint env tag = do 
  checkCT <- asks . view $ _1 . resourceArgs . constantTime
  let c = ConstantRes env tag
  when checkCT $ addConstraint c

-- | Embed a type-constraint checker computation @f@ in the explorer; on type error, record the error and backtrack
runInSolver :: MonadHorn s => TCSolver s a -> Explorer s a
runInSolver f = do
  tParams <- asks . view $ _2
  tState <- use typingState
  res <- lift . lift . lift . lift $ runTCSolver tParams tState f 
  case res of
    Left err -> throwError err
    Right (res, st) -> do
      typingState .= st
      return res

freshId :: MonadHorn s => String -> Explorer s String
freshId = runInSolver . TCSolver.freshId

freshVar :: MonadHorn s => Environment -> String -> Explorer s String
freshVar env prefix = runInSolver $ TCSolver.freshVar env prefix

-- | Return the current valuation of @u@;
-- in case there are multiple solutions,
-- order them from weakest to strongest in terms of valuation of @u@ and split the computation
currentValuation :: MonadHorn s => Formula -> Explorer s Valuation
currentValuation u = do
  runInSolver solveAllCandidates
  cands <- use (typingState . candidates)
  let candGroups = groupBy (\c1 c2 -> val c1 == val c2) $ sortBy (\c1 c2 -> setCompare (val c1) (val c2)) cands
  msum $ map pickCandidiate candGroups
  where
    val c = valuation (solution c) u
    pickCandidiate cands' = do
      typingState . candidates .= cands'
      return $ val (head cands')

inContext ctx = local (over (_1 . context) (. ctx))

-- | Replace all bound type and predicate variables with fresh free variables
-- (if @top@ is @False@, instantiate with bottom refinements instead of top refinements)
instantiate :: MonadHorn s => Environment -> RSchema -> Bool -> [Id] -> Explorer s RType
instantiate env sch top argNames = do
  t <- instantiate' Map.empty Map.empty sch
  writeLog 3 (text "INSTANTIATE" <+> pretty sch $+$ text "INTO" <+> pretty t)
  return t
  where
    instantiate' subst pSubst t@(ForallT a sch) = do
      a' <- freshId "A"
      addConstraint $ WellFormed env (vartSafe a' ftrue) (show (text "Instantiate" <+> pretty t))
      instantiate' (Map.insert a (vartSafe a' (BoolLit top)) subst) pSubst sch
    instantiate' subst pSubst (ForallP (PredSig p argSorts _) sch) = do
      let argSorts' = map (sortSubstitute (asSortSubst subst)) argSorts
      fml <- if top
              then do
                p' <- freshId (map toUpper p)
                addConstraint $ WellFormedPredicate env argSorts' p'
                return $ Pred BoolS p' (zipWith Var argSorts' deBrujns)
              else return ffalse
      instantiate' subst (Map.insert p fml pSubst) sch
    instantiate' subst pSubst (Monotype t) = go subst pSubst argNames t
    go subst pSubst argNames (FunctionT x tArg tRes cost) = do
      x' <- case argNames of
              [] -> freshVar env "x"
              (argName : _) -> return argName
      liftM2 (\t r -> FunctionT x' t r cost) (go subst pSubst [] tArg) (go subst pSubst (drop 1 argNames) (renameVar (isBoundTV subst) x x' tArg tRes))
    go subst pSubst _ t = return $ typeSubstitutePred pSubst . typeSubstitute subst $ t
    isBoundTV subst a = (a `Map.member` subst) || (a `elem` (env ^. boundTypeVars))

-- | 'symbolType' @env x sch@: precise type of symbol @x@, which has a schema @sch@ in environment @env@;
-- if @x@ is a scalar variable, use "_v == x" as refinement;
-- if @sch@ is a polytype, return a fresh instance
symbolType :: MonadHorn s => Environment -> Id -> RSchema -> Explorer s RType
symbolType env x (Monotype t@(ScalarT b _ p))
    | isLiteral x = return t -- x is a literal of a primitive type, it's type is precise
    | isJust (lookupConstructor x env) = return t -- x is a constructor, it's type is precise
    | otherwise = return $ ScalarT b (varRefinement x (toSort b)) p -- x is a scalar variable or monomorphic scalar constant, use _v = x
symbolType env _ sch = freshInstance sch
  where
    freshInstance sch = if arity (toMonotype sch) == 0
      then instantiate env sch False [] -- Nullary polymorphic function: it is safe to instantiate it with bottom refinements, since nothing can force the refinements to be weaker
      else instantiate env sch True []

-- | Perform an exploration, and once it succeeds, do not backtrack (assuming flag is set)
cut :: MonadHorn s => Explorer s a -> Explorer s a
cut e = do 
  b <- asks . view $ _1 . shouldCut
  if b then once e else e

-- | Synthesize auxiliary goals accumulated in @auxGoals@ and store the result in @solvedAuxGoals@
generateAuxGoals :: MonadHorn s => Explorer s ()
generateAuxGoals = do
  goals <- use auxGoals
  unless (null goals) $ writeLog 3 $ text "Auxiliary goals are:" $+$ vsep (map pretty goals)
  case goals of
    [] -> return ()
    (g : gs) -> do
        auxGoals .= gs
        writeLog 2 $ text "PICK AUXILIARY GOAL" <+> pretty g
        Reconstructor reconstructTopLevel <- asks . view $ _3
        p <- reconstructTopLevel g
        solvedAuxGoals %= Map.insert (gName g) (etaContract p)
        generateAuxGoals
  where
    etaContract p = case etaContract' [] (content p) of
                      Nothing -> p
                      Just f -> Program f (typeOf p)
    etaContract' [] (PFix _ p)                                               = etaContract' [] (content p)
    etaContract' binders (PFun x p)                                          = etaContract' (x:binders) (content p)
    etaContract' (x:binders) (PApp pFun (Program (PSymbol y) _)) | x == y    =  etaContract' binders (content pFun)
    etaContract' [] f@(PSymbol _)                                            = Just f
    etaContract' binders p                                                   = Nothing

-- Variable formula with fresh variable id
freshPot :: MonadHorn s => Explorer s Potential 
freshPot = do 
  x <- freshId potentialPrefix
  (typingState . resourceVars) %= Set.insert x
  return $ Fml $ Var IntS x

freshMul :: MonadHorn s => Explorer s Potential
freshMul = do
  x <- freshId multiplicityPrefix
  (typingState . resourceVars) %= Set.insert x
  return $ Fml $ Var IntS x

-- | 'freshPotentials' @sch r@ : Replace potentials in schema @sch@ by unwrapping the foralls. If @r@, recursively replace potential annotations in the entire type. Otherwise, just replace top-level annotations.
freshPotentials :: MonadHorn s => RSchema -> Bool -> Explorer s RSchema
freshPotentials (Monotype t) replaceAll = do 
  t' <- freshPotentials' t replaceAll
  return $ Monotype t'
freshPotentials (ForallT x t) replaceAll = do 
  t' <- freshPotentials t replaceAll 
  return $ ForallT x t'
freshPotentials (ForallP x t) replaceAll = do
  t' <- freshPotentials t replaceAll
  return $ ForallP x t'

-- Replace potentials in a TypeSkeleton
freshPotentials' :: MonadHorn s => RType -> Bool -> Explorer s RType
-- TODO: probably don't need to bother traversing the type here, since annotations on type vars should be Infty as well
freshPotentials' t@(ScalarT base fml Infty) replaceAll = return t
freshPotentials' (ScalarT base fml (Fml pot)) replaceAll = do 
  pot' <- freshPot
  base' <- if replaceAll then freshMultiplicities base replaceAll else return base
  return $ ScalarT base' fml pot'
freshPotentials' t _ = return t

-- Replace potentials in a BaseType
freshMultiplicities :: MonadHorn s => BaseType Formula -> Bool -> Explorer s (BaseType Formula)
freshMultiplicities t@(TypeVarT s name Infty) _ = return t
freshMultiplicities (TypeVarT s name (Fml m)) _ = do 
  m' <- freshMul
  return $ TypeVarT s name m'
freshMultiplicities (DatatypeT name ts ps) replaceAll = do
  ts' <- mapM (`freshPotentials'` replaceAll) ts
  return $ DatatypeT name ts' ps
freshMultiplicities t _ = return t

addScrutineeToEnv :: (MonadHorn s, MonadSMT s) 
                  => Environment 
                  -> RProgram 
                  -> RType 
                  -> Explorer s (Formula, Environment)
addScrutineeToEnv env pScr tScr = do 
  checkres <- asks . view $ _1 . resourceArgs . checkRes
  (x, env') <- toVar (addScrutinee pScr env) pScr
  varName <- freshId "x"
  let tScr' = addPotential (typeMultiply pzero tScr) (fromMaybe pzero (topPotentialOf tScr))
  let env'' = addVariable varName tScr' env'
  if checkres
    then return (x, env'')
    else return (x, env')

-- | Given a name, schema, and environment, retrieve the variable type from the environment and split it into left and right types with fresh potential variables, generating constraints accordingly.
retrieveVarType :: (MonadHorn s, MonadSMT s) 
                => Id 
                -> RSchema 
                -> Environment 
                -> Explorer s (RType, Environment)
retrieveVarType name sch env = do 
  let (isVariable, tempenv) = removeSymbol name env
  let env' = if isVariable 
      then addPolyVariable name (schemaMultiply pzero sch) tempenv 
      else env
  t <- symbolType env name sch
  symbolUseCount %= Map.insertWith (+) name 1
  case Map.lookup name (env ^. shapeConstraints) of
    Nothing -> return ()
    Just sc -> addSubtypeConstraint env (refineBot env $ shape t) (refineTop env sc) False ""
  return (t, env')

-- | Generate subtyping constraint
addSubtypeConstraint :: (MonadHorn s, MonadSMT s) 
                     => Environment 
                     -> RType 
                     -> RType 
                     -> Bool 
                     -> Id 
                     -> Explorer s ()
addSubtypeConstraint env ltyp rtyp consistency tag = 
  let variant = if consistency then Consistency else Simple in
  addConstraint $ Subtype env (_symbols env) ltyp rtyp variant tag

-- | Generate nondeterministic subtyping constraint -- attempt to re-partition "free" potential between variables in context
checkNDSubtype :: (MonadHorn s, MonadSMT s) 
               => Environment 
               -> RType 
               -> RType 
               -> Id 
               -> Explorer s Environment
checkNDSubtype env ltyp@ScalarT{} rtyp@ScalarT{} tag = do 
  syms' <- freshFreePotential env
  addConstraint $ Subtype env syms' ltyp rtyp Nondeterministic tag
  return $ env { _symbols = syms' }
-- Should never be called with non-scalar contextual types
checkNDSubtype env ltyp rtyp@LetT{} tag = do 
  syms' <- freshFreePotential env
  addConstraint $ Subtype env syms' ltyp rtyp Nondeterministic tag
  return $ env { _symbols = syms' }
checkNDSubtype env ltyp@LetT{} rtyp tag = do 
  syms' <- freshFreePotential env
  addConstraint $ Subtype env syms' ltyp rtyp Nondeterministic tag
  return $ env { _symbols = syms' }
-- Do not re-partition potential when checking non-scalar types
checkNDSubtype env ltyp rtyp tag = do 
  addSubtypeConstraint env ltyp rtyp False tag
  return env

-- Split a context and generate sharing constraints
shareContext :: (MonadHorn s, MonadSMT s) 
             => Environment 
             -> String 
             -> Explorer s (Environment, Environment)
shareContext env label = do 
  let syms = _symbols env
  let scalars  = fromMaybe Map.empty $ Map.lookup 0 (_symbols env)
  scalars1 <- mapM (`freshPotentials` True) scalars
  scalars2 <- mapM (`freshPotentials` True) scalars
  let syms1 = Map.insert 0 scalars1 syms 
  let syms2 = Map.insert 0 scalars2 syms
  addConstraint $ SharedEnv env syms1 syms2 label
  return (env { _symbols = syms1 }, env { _symbols = syms2 })

-- | 'toVar' @p env@: a variable representing @p@ (can be @p@ itself or a fresh ghost)
toVar :: (MonadSMT s, MonadHorn s) => Environment -> RProgram -> Explorer s (Formula, Environment)
toVar env (Program (PSymbol name) t) = return (symbolAsFormula env name t, env)
toVar env (Program _ t) = do
  g <- freshId "G"
  return (Var (toSort $ baseTypeOf t) g, addLetBound g t env)

-- | Fresh top-level potential annotations for all scalar symbols in an environment
freshFreePotential :: MonadHorn s => Environment -> Explorer s SymbolMap
freshFreePotential env = do
  let freshen = mapM (`freshPotentials` False) 
  mapWithKeyM (\arity vars -> if arity == 0 then freshen vars else return vars) (_symbols env)

writeLog level msg = do
  maxLevel <- asks . view $ _1 . explorerLogLevel
  when (level <= maxLevel) $ traceShow (plain msg) $ return () 

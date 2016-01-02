{-# LANGUAGE DeriveDataTypeable, StandaloneDeriving #-}

module Main where

import Synquid.Logic
import Synquid.Program
import Synquid.Pretty
import Synquid.Parser (parseFromFile, parseProgram)
import Synquid.Resolver (resolveDecls)
import Synquid.SolverMonad
import Synquid.HornSolver
import Synquid.TypeConstraintSolver
import Synquid.Explorer
import Synquid.Synthesizer

import Control.Monad
import System.Exit
import System.Console.CmdArgs
import Data.Time.Calendar
import Data.Map (size, elems, keys)

programName = "synquid"
versionName = "0.2"
releaseDate = fromGregorian 2015 11 20

-- | Execute or test a Boogie program, according to command-line arguments
main = do
  (CommandLineArgs file 
                   appMax 
                   scrutineeMax 
                   matchMax 
                   fix 
                   hideScr 
                   explicitMatch
                   partial
                   incremental
                   consistency 
                   log_ 
                   useMemoization 
                   bfs
                   print_spec
                   print_spec_size
                   print_solution_size) <- cmdArgs cla
  let explorerParams = defaultExplorerParams {
    _eGuessDepth = appMax,
    _scrutineeDepth = scrutineeMax,
    _matchDepth = matchMax,
    _fixStrategy = fix,
    _hideScrutinees = hideScr,
    _abduceScrutinees = not explicitMatch,
    _partialSolution = partial,
    _incrementalChecking = incremental,
    _consistencyChecking = consistency,
    _useMemoization = useMemoization,
    _explorerLogLevel = log_
    }
  let solverParams = defaultHornSolverParams {
    optimalValuationsStrategy = if bfs then BFSValuations else MarcoValuations,
    solverLogLevel = log_
    }
  let synquidParams = defaultSynquidParams {
    showSpec = print_spec,
    showSpecSize = print_spec_size,
    showSolutionSize = print_solution_size
  }
  runOnFile synquidParams explorerParams solverParams file

{- Command line arguments -}

deriving instance Typeable FixpointStrategy
deriving instance Data FixpointStrategy
deriving instance Eq FixpointStrategy
deriving instance Show FixpointStrategy

data CommandLineArgs
    = CommandLineArgs {
        -- | Input
        file :: String,
        -- | Explorer params
        app_max :: Int,
        scrutinee_max :: Int,
        match_max :: Int,
        fix :: FixpointStrategy,
        hide_scrutinees :: Bool,
        explicit_match :: Bool,
        partial :: Bool,
        incremental :: Bool,
        consistency :: Bool,
        log_ :: Int,
        use_memoization :: Bool,
        -- | Solver params
        bfs_solver :: Bool,
        -- | Output        
        print_spec :: Bool,
        print_spec_size :: Bool,
        print_solution_size :: Bool
      }
  deriving (Data, Typeable, Show, Eq)

cla = CommandLineArgs {
  file            = ""              &= typFile &= argPos 0,
  app_max         = 3               &= help ("Maximum depth of an application term (default: 3)"),
  scrutinee_max   = 1               &= help ("Maximum depth of a match scrutinee (default: 0)"),
  match_max       = 2               &= help ("Maximum number of a matches (default: 2)"),
  fix             = AllArguments    &= help (unwords ["What should termination metric for fixpoints be derived from?", show AllArguments, show FirstArgument, show DisableFixpoint, "(default:", show AllArguments, ")"]),
  hide_scrutinees = False           &= help ("Hide scrutinized expressions from the environment (default: False)"),
  explicit_match  = False           &= help ("Do not abduce match scrutinees (default: False)"),
  partial         = False           &= help ("Generate best-effort partial solutions (default: False)"),
  incremental     = True            &= help ("Subtyping checks during bottom-up phase (default: True)"),
  consistency     = True            &= help ("Check incomplete application types for consistency (default: True)"),
  log_            = 0               &= help ("Logger verboseness level (default: 0)"),
  use_memoization = False           &= help ("Use memoization (default: False)"),
  bfs_solver      = False           &= help ("Use BFS instead of MARCO to solve second-order constraints (default: False)"),
  print_spec      = True            &= help ("Show specification of each synthesis goal (default: True)"),
  print_spec_size = False           &= help ("Show specification size (default: False)"),
  print_solution_size = False       &= help ("Show solution size (default: False)")
  } &= help "Synthesize goals specified in the input file" &= program programName &= summary (programName ++ " v" ++ versionName ++ ", " ++ showGregorian releaseDate)

-- | Parameters for template exploration
defaultExplorerParams = ExplorerParams {
  _eGuessDepth = 3,
  _scrutineeDepth = 1,
  _matchDepth = 2,
  _fixStrategy = AllArguments,
  _polyRecursion = True,
  _hideScrutinees = False,
  _abduceScrutinees = True,
  _partialSolution = False,
  _incrementalChecking = True,
  _consistencyChecking = True,
  _useMemoization = False,
  _context = id,
  _explorerLogLevel = 0
}

-- | Parameters for constraint solving
defaultHornSolverParams = HornSolverParams {
  pruneQuals = True,
  optimalValuationsStrategy = MarcoValuations,
  semanticPrune = True,
  agressivePrune = True,
  candidatePickStrategy = InitializedWeakCandidate,
  constraintPickStrategy = SmallSpaceConstraint,
  solverLogLevel = 0
}

-- | Parameters of the synthesis
data SynquidParams = SynquidParams {
  showSpec :: Bool,                            -- ^ Print specification for every synthesis goal 
  showSpecSize :: Bool,                        -- ^ Print specification size
  showSolutionSize :: Bool                     -- ^ Print solution size
}

defaultSynquidParams = SynquidParams {
  showSpec = True,
  showSpecSize = False,
  showSolutionSize = False
}

-- | Parse and resolve file, then synthesize the specified goals
runOnFile :: SynquidParams -> ExplorerParams -> HornSolverParams -> String -> IO ()
runOnFile synquidParams explorerParams solverParams file = do
  parseResult <- parseFromFile parseProgram file
  case parseResult of
    Left parseErr -> (putStr $ show parseErr) >> exitFailure
    -- Right ast -> print $ vsep $ map pretty ast
    Right decls -> case resolveDecls decls of
      Left resolutionError -> (putStr resolutionError) >> exitFailure
      Right (goals, cquals, tquals) -> mapM_ (synthesizeGoal cquals tquals) goals
  where
    synthesizeGoal cquals tquals goal = do
      when (showSpec synquidParams) $ 
        print (text (gName goal) <+> text "::" <+> pretty (gSpec goal))
      -- print empty
      -- print $ vMapDoc pretty pretty (allSymbols $ gEnvironment goal)
      mProg <- synthesize explorerParams solverParams goal cquals tquals
      case mProg of
        Left err -> print (linebreak <> err) >> exitFailure
        Right prog -> do
          print $ (text (gName goal) <+> text "=" </> pretty prog)
          when (showSolutionSize synquidParams) $ 
            print (parens (text "Size:" <+> pretty (programNodeCount prog)))
          when (showSpecSize synquidParams) $ print specSizeDoc
          where
            specSizeDoc = let allConstructors = concatMap _constructors $ elems $ _datatypes $ gEnvironment goal in
                parens (text "Spec size:" <+> pretty (typeNodeCount $ toMonotype $ gSpec goal)) $+$
                  parens (text "#measures:" <+> pretty (size $ _measures $ gEnvironment goal)) $+$
                  parens (text "#components:" <+>
                    pretty (length $ filter (not . flip elem allConstructors) $ keys $ allSymbols $ gEnvironment goal)) -- we only solve one goal
      print empty

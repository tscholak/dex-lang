import System.Console.Haskeline
import System.IO
import System.Exit
import Data.IORef
import Control.Concurrent
import Control.Concurrent.Chan
import Control.Monad
import Control.Monad.Except (throwError)
import Control.Monad.State.Strict
import Control.Monad.Reader
import Options.Applicative
import Data.Semigroup ((<>))
import qualified Data.Map.Strict as M

import Syntax
import PPrint
import Pass
import Type

import Parser
import Inference
import DeFunc
import Imp
import JIT
import Fresh
import ConcurrentUtil
import WebOutput

type DeclKey = Int
type Keyed a = (DeclKey, a)

data EvalMode = ReplMode | WebMode String | ScriptMode String
data CmdOpts = CmdOpts { programSource :: Maybe String
                       , webOutput     :: Bool}

fullPass = typePass   >+> checkTyped
       >+> deFuncPass >+> checkTyped
       >+> impPass    >+> checkImp
       >+> jitPass

parseFile :: MonadIO m => String -> m [(String, Except UDecl)]
parseFile fname = do
  source <- liftIO $ readFile fname
  return $ parseProg source

evalPrelude :: Monoid env => Pass env UDecl () -> StateT env IO ()
evalPrelude pass = do
  prog <- parseFile "prelude.cod"
  decls <- liftExceptIO $ mapM snd prog
  mapM_ (evalDecl . pass) decls

evalScript :: Monoid env => Pass env UDecl () -> String -> StateT env IO ()
evalScript pass fname = do
  evalPrelude pass
  prog <- parseFile fname
  mapM_ (uncurry $ evalPrint pass) prog

evalPrint :: Monoid env =>
               Pass env UDecl () -> String -> Except UDecl -> StateT env IO ()
evalPrint pass text decl = do
  decl' <- liftExceptIO decl
  result <- evalDecl (pass decl')
  liftIO $ putStrLn $ pprint (resultSource text <> result)

evalRepl :: Monoid env => Pass env UDecl () -> StateT env IO ()
evalRepl pass = do
  evalPrelude pass
  runInputT defaultSettings $ forever (replLoop pass)

replLoop :: Monoid env => Pass env UDecl () -> InputT (StateT env IO) ()
replLoop pass = do
  source <- getInputLine ">=> "
  case source of
    Nothing -> liftIO exitSuccess
    Just s -> lift $ evalPrint pass "" (parseTopDecl s)

evalWeb :: String -> IO ()
evalWeb fname = do
  env <- execStateT (evalPrelude fullPass) mempty
  runWeb fname fullPass env

runEnv :: (Monoid s, Monad m) => StateT s m a -> m a
runEnv m = evalStateT m mempty

opts :: ParserInfo CmdOpts
opts = info (p <**> helper) mempty
  where p = CmdOpts
            <$> (optional $ argument str (    metavar "FILE"
                                           <> help "Source program"))
            <*> switch (    long "web"
                         <> help "Whether to use web output instead of stdout" )

parseOpts :: IO EvalMode
parseOpts = do
  CmdOpts file web <- execParser opts
  return $ case file of
    Nothing -> ReplMode
    Just fname -> if web then WebMode    fname
                         else ScriptMode fname

main :: IO ()
main = do
  evalMode <- parseOpts
  case evalMode of
    ReplMode         -> runEnv $ evalRepl   fullPass
    ScriptMode fname -> runEnv $ evalScript fullPass fname
    WebMode    fname -> evalWeb fname

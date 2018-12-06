{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module Unison.Codebase.CommandLine2 where

import           Data.String                    ( fromString )
import qualified Unison.Util.ColorText         as CT
import           Control.Exception              ( finally )
import           Control.Monad.Trans            ( lift )
import           Data.Foldable                  ( traverse_ )
import           Data.IORef
import           Data.List                      ( isSuffixOf
                                                , sort
                                                , intercalate
                                                )
import           Data.Maybe                     ( listToMaybe
                                                , fromMaybe
                                                )
import qualified Data.Map                      as Map
import           Data.Map                       ( Map )
import qualified Data.Text                     as Text
import           Data.Text                      ( Text )
import           Control.Concurrent             ( forkIO
                                                , killThread
                                                )
import           Control.Concurrent.STM         ( atomically )
import           Control.Monad                  ( forever
                                                , when
                                                )
import           Control.Monad.IO.Class         ( MonadIO
                                                , liftIO
                                                )
import           Unison.Codebase                ( Codebase )
import qualified Unison.Codebase               as Codebase
import qualified Unison.Codebase.Branch        as Branch
import           Unison.Codebase.Branch         ( Branch )
import           Unison.Codebase.Editor         ( Output(..)
                                                , BranchName
                                                , Event(..)
                                                , Input(..)
                                                )
import qualified Unison.Codebase.Editor        as Editor
import qualified Unison.Codebase.Editor.Actions
                                               as Actions
import           Unison.Codebase.Runtime        ( Runtime )
import qualified Unison.Codebase.Runtime       as Runtime
import qualified Unison.Codebase.Watch         as Watch
import           Unison.Parser                  ( Ann )
import qualified Unison.Util.Relation          as R
import           Unison.Util.TQueue             ( TQueue )
import qualified Unison.Util.TQueue            as Q
import           Unison.Util.Monoid             ( intercalateMap )
import           Unison.Var                     ( Var )
import qualified System.Console.Haskeline      as Line

notifyUser :: Var v => Output v -> IO ()
notifyUser o = case o of
  DisplayConflicts branch -> do
    let terms    = R.dom $ Branch.termNamespace branch
        patterns = R.dom $ Branch.patternNamespace branch
        types    = R.dom $ Branch.typeNamespace branch
    when (not $ null terms) $ do
      putStrLn "🙅 The following terms have conflicts: "
      traverse_ (\x -> putStrLn ("  " ++ Text.unpack x)) terms
    when (not $ null patterns) $ do
      putStrLn "🙅 The following patterns have conflicts: "
      traverse_ (\x -> putStrLn ("  " ++ Text.unpack x)) patterns
    when (not $ null types) $ do
      putStrLn "🙅 The following types have conflicts: "
      traverse_ (\x -> putStrLn ("  " ++ Text.unpack x)) types
    -- TODO: Present conflicting TermEdits and TypeEdits
    -- if we ever allow users to edit hashes directly.
  ListOfBranches current branches -> putStrLn $ let
    go n = if n == current then "* " <> n
           else "  " <>  n
    in Text.unpack $ intercalateMap "\n" go (sort branches)
  _ -> putStrLn $ show o

allow :: FilePath -> Bool
allow = (||) <$> (".u" `isSuffixOf`) <*> (".uu" `isSuffixOf`)

-- TODO: Return all of these thread IDs so we can throw async exceptions at
-- them when we need to quit.

watchFileSystem :: TQueue Event -> FilePath -> IO (IO ())
watchFileSystem q dir = do
  (cancel, watcher) <- Watch.watchDirectory dir allow
  t <- forkIO . forever $ do
    (filePath, text) <- watcher
    atomically . Q.enqueue q $ UnisonFileChanged (Text.pack filePath) text
  pure (cancel >> killThread t)

watchBranchUpdates :: TQueue Event -> Codebase IO v a -> IO (IO ())
watchBranchUpdates q codebase = do
  (cancelExternalBranchUpdates, externalBranchUpdates) <-
    Codebase.branchUpdates codebase
  thread <- forkIO . forever $ do
    updatedBranches <- externalBranchUpdates
    atomically . Q.enqueue q . UnisonBranchChanged $ updatedBranches
  pure (cancelExternalBranchUpdates >> killThread thread)

warnNote :: String -> String
warnNote s = "⚠️  " <> s

type IsOptional = Bool

data InputPattern = InputPattern
  { patternName :: String
  , aliases :: [String]
  , args :: [(IsOptional, ArgumentType)]
  , help :: Text
  , parse :: [String] -> Either String Input
  }

data ArgumentType = ArgumentType
  { typeName :: String
  , suggestions :: forall m v a . Monad m
                => String
                -> Codebase m v a
                -> Branch
                -> m [Line.Completion]
  }

showPatternHelp :: InputPattern -> String
showPatternHelp i =
  CT.toANSI (CT.bold (fromString $ patternName i))
    <> (if not . null $ aliases i
         then " (or " <> intercalate ", " (aliases i) <> ")"
         else ""
       )
    <> "\n"
    <> Text.unpack (help i)
    -- showArgs args = intercalateMap " " g args
    -- g (isOptional, arg) =
    --   if isOptional then "[" <> typeName arg <> "]"
    --   else typeName arg

validInputs :: [InputPattern]
validInputs = validPatterns
 where
  commandNames = patternName <$> validPatterns
  commandMap   = Map.fromList (commandNames `zip` validPatterns)
  helpPattern  = InputPattern
    "help"
    ["?"]
    [(True, commandName)]
    "`help` shows general help and `help <cmd>` shows help for one command."
    (\case
      []    -> Left $ intercalateMap "\n\n" showPatternHelp validPatterns
      [cmd] -> case Map.lookup cmd commandMap of
        Nothing ->
          Left . warnNote $ "I don't know of that command. Try `help`."
        Just pat -> Left $ Text.unpack (help pat)
      _ -> Left $ warnNote "Use `help <cmd>` or `help`."
    )
  commandName =
    ArgumentType "command" $ \q _ _ -> pure $ autoComplete q commandNames
  branchArg = ArgumentType "branch" $ \q codebase _ -> do
    branches <- Codebase.branches codebase
    let bs = Text.unpack <$> branches
    pure $ autoComplete q bs
  quit = InputPattern
    "quit"
    ["exit"]
    []
    "Exits the Unison command line interface."
    (\case
      [] -> pure QuitI
      _  -> Left "Use `quit`, `exit`, or <Ctrl-D> to quit."
    )
  validPatterns
    = [ helpPattern
      , InputPattern
        "add"
        []
        []
        (  "`add` adds to the codebase all the definitions from "
        <> "the most recently typechecked file."
        )
        (\ws -> if not $ null ws
          then Left $ warnNote "`add` doesn't take any arguments."
          else pure AddI
        )
      , InputPattern
        "branch"
        []
        [(True, branchArg)]
        (  "`branch` lists all branches in the codebase.\n"
        <> "`branch foo` switches to the branch named 'foo', "
        <> "creating it first if it doesn't exist."
        )
        (\case
          []  -> pure ListBranchesI
          [b] -> pure . SwitchBranchI $ Text.pack b
          _ ->
            Left
              .  warnNote
              $  "Use `branch` to list all branches "
              <> "or `branch foo` to switch to or create the branch 'foo'."
        )
      , InputPattern
        "fork"
        []
        [(False, branchArg)]
        (  "`fork foo` creates the branch 'foo' "
        <> "as a fork of the current branch."
        )
        (\case
          [b] -> pure . ForkBranchI $ Text.pack b
          _ ->
            Left
              $  warnNote "Use `fork foo` to create the branch 'foo' "
              <> "from the current branch."
        )
      , InputPattern
        "merge"
        []
        [(False, branchArg)]
        ("`merge foo` merges the branch 'foo' into the current branch.")
        (\case
          [b] -> pure . MergeBranchI $ Text.pack b
          _ ->
            Left
              .  warnNote
              $  "Use `merge foo` to merge the branch 'foo' "
              <> " into the current branch."
        )
      , quit
      ]

completion :: String -> Line.Completion
completion s = Line.Completion s s True

autoComplete :: String -> [String] -> [Line.Completion]
autoComplete q ss = completion <$> Codebase.sortedApproximateMatches q ss

parseInput :: Map String InputPattern -> [String] -> Either String Input
parseInput patterns ss = case ss of
  [] -> Left ""
  command : args -> case Map.lookup command patterns of
    Just pat -> parse pat args
    Nothing ->
      Left
        $  "I don't know how to "
        <> command
        <> ". Type `help` or `?` to get help."

queueInput
  :: (MonadIO m, Line.MonadException m)
  => Map String InputPattern
  -> TQueue Input
  -> Codebase m v a
  -> Branch
  -> BranchName
  -> m ()
queueInput patterns q codebase branch branchName = Line.runInputT settings $ do
  line <- Line.getInputLine (Text.unpack branchName <> "> ")
  case line of
    Nothing -> liftIO . atomically $ Q.enqueue q QuitI
    Just l  -> case parseInput patterns $ words l of
      Left msg -> lift $ do
        liftIO (putStrLn msg)
        queueInput patterns q codebase branch branchName
      Right i -> liftIO . atomically $ Q.enqueue q i
 where
  settings    = Line.Settings tabComplete (Just ".unisonHistory") True
  tabComplete = Line.completeWordWithPrev Nothing " " $ \prev word ->
    -- User hasn't finished a command name, complete from command names
    if null prev then pure $ autoComplete word (Map.keys patterns)
    -- User has finished a command name; use completions for that command
    else case words $ reverse prev of
      h : t -> fromMaybe (pure []) $ do
        p            <- Map.lookup h patterns
        (_, argType) <- listToMaybe $ drop (length t) (args p)
        pure $ suggestions argType word codebase branch
      _ -> pure []

main
  :: forall v
   . Var v
  => FilePath
  -> BranchName
  -> Maybe FilePath
  -> IO (Runtime v)
  -> Codebase IO v Ann
  -> IO ()
main dir currentBranchName _initialFile startRuntime codebase = do
  currentBranch <- Codebase.getBranch codebase currentBranchName
  eventQueue    <- Q.newIO
  inputQueue    <- Q.newIO
  currentBranch <- case currentBranch of
    Nothing ->
      Codebase.mergeBranch codebase currentBranchName Codebase.builtinBranch
        <* (  putStrLn
           $  "☝️  I found no branch named '"
           <> Text.unpack currentBranchName
           <> "' so I've created it for you."
           )
    Just b -> pure b
  do
    runtime                  <- startRuntime
    branchRef                <- newIORef (currentBranch, currentBranchName)
    cancelFileSystemWatch    <- watchFileSystem eventQueue dir
    cancelWatchBranchUpdates <- watchBranchUpdates eventQueue codebase
    let patternMap =
          Map.fromList
            $   validInputs
            >>= (\p -> [(patternName p, p)] ++ ((, p) <$> aliases p))
    -- todo: need to do something fancy here to ensure that the
    -- line reader gets the latest branch, since the IORef isn't updated
    -- right away
    inputReader <- forkIO . forever $ do
      (branch, branchName) <- readIORef branchRef
      queueInput patternMap inputQueue codebase branch branchName
    let awaitInput = Q.raceIO (Q.peek eventQueue) (Q.peek inputQueue) >>= \case
          Right _ -> Right <$> atomically (Q.dequeue inputQueue)
          Left  _ -> Left <$> atomically (Q.dequeue eventQueue)
        cleanup = do
          killThread inputReader
          Runtime.terminate runtime
          cancelFileSystemWatch
          cancelWatchBranchUpdates
    (`finally` cleanup)
      $ Editor.commandLine awaitInput
                           runtime
                           (curry $ writeIORef branchRef)
                           notifyUser
                           codebase
      $ Actions.startLoop currentBranch currentBranchName

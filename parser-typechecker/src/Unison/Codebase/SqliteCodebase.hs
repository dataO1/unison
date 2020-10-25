{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

module Unison.Codebase.SqliteCodebase where

-- initCodebase :: Branch.Cache IO -> FilePath -> IO (Codebase IO Symbol Ann)

import Control.Monad (filterM, (>=>))
import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.Extra (ifM, unlessM)
import Control.Monad.Reader (ReaderT (runReaderT))
import Control.Monad.Trans.Maybe (MaybeT)
import Data.Bifunctor (Bifunctor (first), second)
import Data.Foldable (traverse_)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Word (Word64)
import Database.SQLite.Simple (Connection)
import qualified Database.SQLite.Simple as Sqlite
import System.FilePath ((</>))
import qualified U.Codebase.Reference as C.Reference
import qualified U.Codebase.Sqlite.ObjectType as OT
import U.Codebase.Sqlite.Operations (EDB)
import qualified U.Codebase.Sqlite.Operations as Ops
import qualified U.Util.Monoid as Monoid
import qualified Unison.Builtin as Builtins
import Unison.Codebase (CodebasePath)
import qualified Unison.Codebase as Codebase1
import Unison.Codebase.Branch (Branch)
import qualified Unison.Codebase.Branch as Branch
import qualified Unison.Codebase.Reflog as Reflog
import Unison.Codebase.ShortBranchHash (ShortBranchHash)
import qualified Unison.Codebase.SqliteCodebase.Conversions as Cv
import Unison.Codebase.SyncMode (SyncMode)
import qualified Unison.ConstructorType as CT
import Unison.DataDeclaration (Decl)
import Unison.Hash (Hash)
import Unison.Parser (Ann)
import Unison.Prelude (MaybeT (runMaybeT), fromMaybe, traceM)
import Unison.Reference (Reference)
import qualified Unison.Reference as Reference
import qualified Unison.Referent as Referent
import Unison.ShortHash (ShortHash)
import qualified Unison.ShortHash as SH
import qualified Unison.ShortHash as ShortHash
import Unison.Symbol (Symbol)
import Unison.Term (Term)
import qualified Unison.Term as Term
import Unison.Type (Type)
import qualified Unison.Type as Type
import qualified Unison.UnisonFile as UF
import UnliftIO (MonadIO, catchIO)
import UnliftIO.STM
import Data.Foldable (Foldable(toList))

-- 1) buffer up the component
-- 2) in the event that the component is complete, then what?
--  * can write component provided all of its dependency components are complete.
--    if dependency not complete,
--    register yourself to be written when that dependency is complete

-- an entry for a single hash
data BufferEntry a = BufferEntry
  { -- First, you are waiting for the cycle to fill up with all elements
    -- Then, you check: are all dependencies of the cycle in the db?
    --   If yes: write yourself to database and trigger check of dependents
    --   If no: just wait, do nothing
    beComponentTargetSize :: Maybe Word64,
    beComponent :: Map Reference.Pos a,
    beMissingDependencies :: Set Hash,
    beWaitingDependents :: Set Hash
  }
  deriving (Show)

type TermBufferEntry = BufferEntry (Term Symbol Ann, Type Symbol Ann)

type DeclBufferEntry = BufferEntry (Decl Symbol Ann)

sqliteCodebase :: CodebasePath -> IO (IO (), Codebase1.Codebase IO Symbol Ann)
sqliteCodebase root = do
  conn :: Sqlite.Connection <- Sqlite.open $ root </> "v2" </> "unison.sqlite3"
  termBuffer :: TVar (Map Hash TermBufferEntry) <- newTVarIO Map.empty
  declBuffer :: TVar (Map Hash DeclBufferEntry) <- newTVarIO Map.empty
  let getRootBranch :: IO (Either Codebase1.GetRootBranchError (Branch IO))
      putRootBranch :: Branch IO -> IO ()
      rootBranchUpdates :: IO (IO (), IO (Set Branch.Hash))
      getBranchForHash :: Branch.Hash -> IO (Maybe (Branch IO))
      dependentsImpl :: Reference -> IO (Set Reference.Id)
      syncFromDirectory :: Codebase1.CodebasePath -> SyncMode -> Branch IO -> IO ()
      syncToDirectory :: Codebase1.CodebasePath -> SyncMode -> Branch IO -> IO ()
      watches :: UF.WatchKind -> IO [Reference.Id]
      getWatch :: UF.WatchKind -> Reference.Id -> IO (Maybe (Term Symbol Ann))
      putWatch :: UF.WatchKind -> Reference.Id -> Term Symbol Ann -> IO ()
      termsOfTypeImpl :: Reference -> IO (Set Referent.Id)
      termsMentioningTypeImpl :: Reference -> IO (Set Referent.Id)
      branchHashesByPrefix :: ShortBranchHash -> IO (Set Branch.Hash)

      getTerm :: Reference.Id -> IO (Maybe (Term Symbol Ann))
      getTerm (Reference.Id h1@(Cv.hash1to2 -> h2) i _n) =
        runDB' conn do
          term2 <- Ops.loadTermByReference (C.Reference.Id h2 i)
          Cv.term2to1 h1 getCycleLen getDeclType term2

      getCycleLen :: EDB m => Hash -> m Reference.Size
      getCycleLen = Ops.getCycleLen . Cv.hash1to2

      getDeclType :: EDB m => C.Reference.Reference -> m CT.ConstructorType
      getDeclType = \case
        C.Reference.ReferenceBuiltin t ->
          let err =
                error $
                  "I don't know about the builtin type ##"
                    ++ show t
                    ++ ", but I've been asked for it's ConstructorType."
           in pure . fromMaybe err $
                Map.lookup (Reference.Builtin t) Builtins.builtinConstructorType
        C.Reference.ReferenceDerived i -> getDeclTypeById i

      getDeclTypeById :: EDB m => C.Reference.Id -> m CT.ConstructorType
      getDeclTypeById = fmap Cv.decltype2to1 . Ops.getDeclTypeByReference

      getTypeOfTermImpl :: Reference.Id -> IO (Maybe (Type Symbol Ann))
      getTypeOfTermImpl (Reference.Id (Cv.hash1to2 -> h2) i _n) =
        runDB' conn do
          type2 <- Ops.loadTypeOfTermByTermReference (C.Reference.Id h2 i)
          Cv.ttype2to1 getCycleLen type2

      getTypeDeclaration :: Reference.Id -> IO (Maybe (Decl Symbol Ann))
      getTypeDeclaration (Reference.Id h1@(Cv.hash1to2 -> h2) i _n) =
        runDB' conn do
          decl2 <- Ops.loadDeclByReference (C.Reference.Id h2 i)
          Cv.decl2to1 h1 getCycleLen decl2

      putTerm :: Reference.Id -> Term Symbol Ann -> Type Symbol Ann -> IO ()
      putTerm _r@(Reference.Id h@(Cv.hash1to2 -> h2) i n) tm tp =
        runDB conn $
          unlessM
            (Ops.objectExistsForHash h2)
            ( withBuffer termBuffer h \(BufferEntry size comp missing waiting) -> do
                let size' = Just n
                pure $
                  ifM
                    ((==) <$> size <*> size')
                    (pure ())
                    (error $ "targetSize for term " ++ show h ++ " was " ++ show size ++ ", but now " ++ show size')
                let comp' = Map.insert i (tm, tp) comp
                missingTerms' <-
                  filterM
                    (fmap not . Ops.objectExistsForHash . Cv.hash1to2)
                    [h | Reference.Derived h _i _n <- Set.toList $ Term.termDependencies tm]
                missingTypes' <-
                  filterM (fmap not . Ops.objectExistsForHash . Cv.hash1to2) $
                    [h | Reference.Derived h _i _n <- Set.toList $ Term.typeDependencies tm]
                      ++ [h | Reference.Derived h _i _n <- Set.toList $ Type.dependencies tp]
                let missing' = missing <> Set.fromList (missingTerms' <> missingTypes')
                traverse (addBufferDependent h termBuffer) missingTerms'
                traverse (addBufferDependent h declBuffer) missingTypes'
                putBuffer termBuffer h (BufferEntry size' comp' missing' waiting)
                tryFlushTermBuffer h
            )

      -- data BufferEntry a = BufferEntry
      --   { -- First, you are waiting for the cycle to fill up with all elements
      --     -- Then, you check: are all dependencies of the cycle in the db?
      --     --   If yes: write yourself to database and trigger check of dependents
      --     --   If no: just wait, do nothing
      --     beComponentTargetSize :: Maybe Word64,
      --     beComponent :: Map Reference.Pos a,
      --     beMissingDependencies :: Set Hash,
      --     beWaitingDependents :: Set Hash
      --   }
      putBuffer :: (MonadIO m, Show a) => TVar (Map Hash (BufferEntry a)) -> Hash -> BufferEntry a -> m ()
      putBuffer tv h e = do
        traceM $ "putBuffer " ++ show h ++ " " ++ show e
        atomically $ modifyTVar tv (Map.insert h e)

      withBuffer :: MonadIO m => TVar (Map Hash (BufferEntry a)) -> Hash -> (BufferEntry a -> m b) -> m b
      withBuffer tv h f =
        Map.lookup h <$> readTVarIO tv >>= \case
          Just e -> f e
          Nothing -> f (BufferEntry Nothing Map.empty Set.empty Set.empty)

      removeBuffer :: MonadIO m => TVar (Map Hash (BufferEntry a)) -> Hash -> m ()
      removeBuffer tv h = atomically $ modifyTVar tv (Map.delete h)

      addBufferDependent :: (MonadIO m, Show a) => Hash -> TVar (Map Hash (BufferEntry a)) -> Hash -> m ()
      addBufferDependent dependent tv dependency = withBuffer tv dependency \be -> do
        putBuffer tv dependency be {beWaitingDependents = Set.insert dependent $ beWaitingDependents be}
      tryFlushTermBuffer :: EDB m => Hash -> m ()
      tryFlushTermBuffer h@(Cv.hash1to2 -> h2) =
        -- skip if it has already been flushed
        unlessM (Ops.objectExistsForHash h2) $
          withBuffer
            termBuffer
            h
            \(BufferEntry size comp (Set.toList -> missing) waiting) -> do
              missing' <-
                filterM
                  (fmap not . Ops.objectExistsForHash . Cv.hash1to2)
                  missing
              if null missing' && size == Just (fromIntegral (length comp))
                then do
                  Ops.saveTermComponent h2 $
                    first (Cv.term1to2 h) . second Cv.ttype1to2 <$> toList comp
                  removeBuffer termBuffer h
                  traverse_ tryFlushTermBuffer waiting
                else -- update

                  putBuffer termBuffer h $
                    BufferEntry size comp (Set.fromList missing') waiting

      -- isMissingDependencies <- allM
      putTypeDeclaration :: Reference.Id -> Decl Symbol Ann -> IO ()
      putTypeDeclaration = error "todo"

      getRootBranch = error "todo"
      putRootBranch = error "todo"
      rootBranchUpdates = error "todo"
      getBranchForHash = error "todo"
      dependentsImpl = error "todo"
      syncFromDirectory = error "todo"
      syncToDirectory = error "todo"
      watches = error "todo"
      getWatch = error "todo"
      putWatch = error "todo"

      getReflog :: IO [Reflog.Entry]
      getReflog =
        ( do
            contents <- TextIO.readFile (reflogPath root)
            let lines = Text.lines contents
            let entries = parseEntry <$> lines
            pure entries
        )
          `catchIO` const (pure [])
        where
          parseEntry t = fromMaybe (err t) (Reflog.fromText t)
          err t =
            error $
              "I couldn't understand this line in " ++ reflogPath root ++ "\n\n"
                ++ Text.unpack t

      appendReflog :: Text -> Branch IO -> Branch IO -> IO ()
      appendReflog reason old new =
        let t =
              Reflog.toText $
                Reflog.Entry (Branch.headHash old) (Branch.headHash new) reason
         in TextIO.appendFile (reflogPath root) (t <> "\n")

      reflogPath :: CodebasePath -> FilePath
      reflogPath root = root </> "reflog"

      termsOfTypeImpl = error "todo"
      termsMentioningTypeImpl = error "todo"

      hashLength :: IO Int
      hashLength = pure 10

      branchHashLength :: IO Int
      branchHashLength = pure 10

      defnReferencesByPrefix :: OT.ObjectType -> ShortHash -> IO (Set Reference.Id)
      defnReferencesByPrefix _ (ShortHash.Builtin _) = pure mempty
      defnReferencesByPrefix ot (ShortHash.ShortHash prefix (fmap Cv.shortHashSuffix1to2 -> cycle) _cid) =
        Monoid.fromMaybe <$> runDB' conn do
          refs <- do
            Ops.componentReferencesByPrefix ot prefix cycle
              >>= traverse (C.Reference.idH Ops.loadHashByObjectId)
              >>= pure . Set.fromList

          Set.fromList <$> traverse (Cv.referenceid2to1 getCycleLen) (Set.toList refs)

      termReferencesByPrefix :: ShortHash -> IO (Set Reference.Id)
      termReferencesByPrefix = defnReferencesByPrefix OT.TermComponent

      declReferencesByPrefix :: ShortHash -> IO (Set Reference.Id)
      declReferencesByPrefix = defnReferencesByPrefix OT.DeclComponent

      referentsByPrefix :: ShortHash -> IO (Set Referent.Id)
      referentsByPrefix SH.Builtin {} = pure mempty
      referentsByPrefix (SH.ShortHash prefix (fmap Cv.shortHashSuffix1to2 -> cycle) cid) = runDB conn do
        termReferents <-
          Ops.termReferentsByPrefix prefix cycle
            >>= traverse (Cv.referentid2to1 getCycleLen getDeclType)
        declReferents' <- Ops.declReferentsByPrefix prefix cycle (read . Text.unpack <$> cid)
        let declReferents =
              [ Referent.Con' (Reference.Id (Cv.hash2to1 h) pos len) (fromIntegral cid) (Cv.decltype2to1 ct)
                | (h, pos, len, ct, cids) <- declReferents',
                  cid <- cids
              ]
        pure . Set.fromList $ termReferents <> declReferents

      branchHashesByPrefix = error "todo"
  let finalizer = Sqlite.close conn
  pure $
    ( finalizer,
      Codebase1.Codebase
        getTerm
        getTypeOfTermImpl
        getTypeDeclaration
        putTerm
        putTypeDeclaration
        getRootBranch
        putRootBranch
        rootBranchUpdates
        getBranchForHash
        dependentsImpl
        syncFromDirectory
        syncToDirectory
        watches
        getWatch
        putWatch
        getReflog
        appendReflog
        termsOfTypeImpl
        termsMentioningTypeImpl
        hashLength
        termReferencesByPrefix
        declReferencesByPrefix
        referentsByPrefix
        branchHashLength
        branchHashesByPrefix
    )

-- x :: DB m => MaybeT m (Term Symbol) -> MaybeT m (Term Symbol Ann)
-- x = error "not implemented"

runDB' :: Connection -> MaybeT (ReaderT Connection (ExceptT Ops.Error IO)) a -> IO (Maybe a)
runDB' conn = runDB conn . runMaybeT

runDB :: Connection -> ReaderT Connection (ExceptT Ops.Error IO) a -> IO a
runDB conn = (runExceptT >=> err) . flip runReaderT conn
  where
    err = \case Left err -> error $ show err; Right a -> pure a
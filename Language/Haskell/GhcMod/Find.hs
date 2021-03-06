{-# LANGUAGE CPP, BangPatterns #-}

module Language.Haskell.GhcMod.Find
#ifndef SPEC
  (
    Symbol
  , SymbolDb
  , loadSymbolDb
  , lookupSymbol
  , dumpSymbol
  , findSymbol
  , lookupSym
  )
#endif
  where

import Config (cProjectVersion,cTargetPlatformString)
import Control.Applicative ((<$>))
import Control.Exception (handle, SomeException(..))
import Control.Monad (when, void)
import CoreMonad (liftIO)
import Data.Function (on)
import Data.List (groupBy, sort)
import Data.List.Split (splitOn)
import Data.Maybe (fromMaybe)
import DynFlags (DynFlags(..), systemPackageConfig)
import Exception (ghandle, handleIO)
import qualified GHC as G
import Language.Haskell.GhcMod.Convert
import Language.Haskell.GhcMod.Monad
import Language.Haskell.GhcMod.Utils
import Language.Haskell.GhcMod.Types
import Name (getOccString)
import System.Directory (doesDirectoryExist, getAppUserDataDirectory, doesFileExist, getModificationTime)
import System.FilePath ((</>), takeDirectory)
import System.IO
import System.Environment

#ifndef MIN_VERSION_containers
#define MIN_VERSION_containers(x,y,z) 1
#endif

#if MIN_VERSION_containers(0,5,0)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
#else
import Data.Map (Map)
import qualified Data.Map as M
#endif

----------------------------------------------------------------

-- | Type of function and operation names.
type Symbol = String
-- | Database from 'Symbol' to \['ModuleString'\].
newtype SymbolDb = SymbolDb (Map Symbol [ModuleString])

----------------------------------------------------------------

symbolCache :: String
symbolCache = "ghc-mod.cache"

packageCache :: String
packageCache = "package.cache"

packageConfDir :: String
packageConfDir = "package.conf.d"

----------------------------------------------------------------

-- | Looking up 'SymbolDb' with 'Symbol' to \['ModuleString'\]
--   which will be concatenated. 'loadSymbolDb' is called internally.
findSymbol :: IOish m => Symbol -> GhcModT m String
findSymbol sym = liftIO loadSymbolDb >>= lookupSymbol sym

-- | Looking up 'SymbolDb' with 'Symbol' to \['ModuleString'\]
--   which will be concatenated.
lookupSymbol :: IOish m => Symbol -> SymbolDb -> GhcModT m String
lookupSymbol sym db = convert' $ lookupSym sym db

lookupSym :: Symbol -> SymbolDb -> [ModuleString]
lookupSym sym (SymbolDb db) = fromMaybe [] $ M.lookup sym db

---------------------------------------------------------------

-- | Loading a file and creates 'SymbolDb'.
loadSymbolDb :: IO SymbolDb
loadSymbolDb = SymbolDb <$> readSymbolDb

ghcModExecutable :: IO FilePath
#ifndef SPEC
ghcModExecutable = do
    dir <- getExecutablePath'
    return $ dir </> "ghc-mod"
#else
ghcModExecutable = return "dist/build/ghc-mod/ghc-mod"
#endif
 where
    getExecutablePath' :: IO FilePath
# if __GLASGOW_HASKELL__ >= 706
    getExecutablePath' = takeDirectory <$> getExecutablePath
# else
    getExecutablePath' = return ""
# endif

readSymbolDb :: IO (Map Symbol [ModuleString])
readSymbolDb = handle (\(SomeException _) -> return M.empty) $ do
    ghcMod <- ghcModExecutable
    file <- chop <$> readProcess' ghcMod ["dumpsym"]
    M.fromAscList . map conv . lines <$> readFile file
  where
    conv :: String -> (Symbol,[ModuleString])
    conv = read
    chop "" = ""
    chop xs = init xs

----------------------------------------------------------------
-- used 'ghc-mod dumpsym'

getPath :: IOish m => GhcModT m (Maybe String)
getPath = do
    df <- G.getSessionDynFlags
    stack <- cradlePkgDbStack . gmCradle <$> ask
    case filter (GlobalDb /=) stack of
        []  -> return Nothing
        u:_ -> liftIO $ resolvePackageDb df u

-- | Dumping a set of ('Symbol',\['ModuleString'\]) to a file
--   if the file does not exist or is invalid.
--   The file name is printed.
dumpSymbol :: IOish m => GhcModT m String
dumpSymbol = do
    mdir <- getPath
    ret <- case mdir of
        Nothing  -> return ""
        Just dir -> do
            let cache = dir </> symbolCache
                pkgdb = dir </> packageCache
            ghandle (\(SomeException _) -> return "") $ do
                create <- liftIO $ needToCreate cache pkgdb
                when create $ do
                    sm <- getSymbol
                    void . liftIO $ withFile cache WriteMode $ \hdl ->
                        mapM (hPrint hdl) sm
                return cache
    return $ ret ++ "\n"

needToCreate :: FilePath -> FilePath -> IO Bool
needToCreate file1 file2 = do
    exist <- doesFileExist file1
    if not exist then
        return True
      else do
        m1 <- getModificationTime file1
        m2 <- getModificationTime file2
        return $ m1 <= m2 -- including equal just in case

-- | Browsing all functions in all system/user modules.
getSymbol :: IOish m => GhcModT m [(Symbol,[ModuleString])]
getSymbol = do
    ms <- G.packageDbModules True
    let ns = map (G.moduleNameString . G.moduleName) ms
    is <- mapM G.getModuleInfo ms
    let symbols = concatMap toNameModule (zip is ns)
    return $ uniquefy symbols

toNameModule :: (Maybe G.ModuleInfo,ModuleString) -> [(Symbol,ModuleString)]
toNameModule (Nothing,_)  = []
toNameModule (Just inf,mdlname) = map (\name -> (getOccString name, mdlname)) names
  where
    names = G.modInfoExports inf

uniquefy :: [(Symbol,ModuleString)] -> [(Symbol,[ModuleString])]
uniquefy = map tieup . groupBy ((==) `on` fst) . sort
  where
    tieup x = (head (map fst x), map snd x)

--- Copied from ghc module `Packages' unfortunately it's not exported :/
resolvePackageDb :: DynFlags -> GhcPkgDb -> IO (Maybe FilePath)
resolvePackageDb df GlobalDb         = return $ Just (systemPackageConfig df)
resolvePackageDb _  (PackageDb name) = return $ Just name
resolvePackageDb _  UserDb           = handleIO (\_ -> return Nothing) $ do
    appdir <- getAppUserDataDirectory "ghc"
    let dir = appdir </> (target_arch ++ '-':target_os ++ '-':cProjectVersion)
        pkgconf = dir </> packageConfDir
    exist <- doesDirectoryExist pkgconf
    return $ if exist then Just pkgconf else Nothing
  where
    [target_arch,_,target_os] = splitOn "-" cTargetPlatformString

module Language.Haskell.GhcMod.Debug (debugInfo, debug) where

import Control.Applicative
import Control.Exception.IOChoice
import Control.Monad
import Data.List (intercalate)
import Data.Maybe
import GHC
import GhcMonad (liftIO)
import Language.Haskell.GhcMod.CabalApi
import Language.Haskell.GhcMod.GHCApi
import Language.Haskell.GhcMod.Types
import Prelude

----------------------------------------------------------------

-- | Obtaining debug information.
debugInfo :: Options
          -> Cradle
          -> GHCVersion
          -> FilePath   -- ^ A target file.
          -> IO String
debugInfo opt cradle ver fileName = unlines <$> withGHC fileName (debug opt cradle ver fileName)

-- | Obtaining debug information.
debug :: Options
      -> Cradle
      -> GHCVersion
      -> FilePath     -- ^ A target file.
      -> Ghc [String]
debug opt cradle ver fileName = do
    CompilerOptions gopts incDir pkgs <-
        if cabal then
            liftIO (fromCabalFile ||> return simpleCompilerOption)
          else
            return simpleCompilerOption
    [fast] <- do
        void $ initializeFlagsWithCradle opt cradle gopts True
        setTargetFiles [fileName]
        pure . canCheckFast <$> depanal [] False
    return [
        "GHC version:         " ++ ver
      , "Current directory:   " ++ currentDir
      , "Cabal file:          " ++ cabalFile
      , "GHC options:         " ++ unwords gopts
      , "Include directories: " ++ unwords incDir
      , "Dependent packages:  " ++ intercalate ", " pkgs
      , "Fast check:          " ++ if fast then "Yes" else "No"
      ]
  where
    currentDir = cradleCurrentDir cradle
    mCabalFile = cradleCabalFile cradle
    cabal = isJust mCabalFile
    cabalFile = fromMaybe "" mCabalFile
    origGopts = ghcOpts opt
    simpleCompilerOption = CompilerOptions origGopts [] []
    fromCabalFile = parseCabalFile file >>= getCompilerOptions origGopts cradle
      where
        file = fromJust mCabalFile

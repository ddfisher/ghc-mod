{-# LANGUAGE TupleSections, FlexibleInstances, TypeSynonymInstances, CPP #-}
{-# LANGUAGE Rank2Types #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Language.Haskell.GhcMod.Info (
    infoExpr
  , info
  , typeExpr
  , typeOf
  ) where

import Control.Applicative ((<$>))
import Control.Monad (void)
import CoreUtils (exprType)
import Data.Function (on)
import Data.Generics hiding (typeOf)
import Data.List (sortBy)
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Ord as O
import Data.Time.Clock (getCurrentTime)
import GHC
import GHC.SYB.Utils (Stage(TypeChecker), everythingStaged)
import HscTypes (ms_imps)
import Language.Haskell.GhcMod.Doc (showUnqualifiedPage, showUnqualifiedOneLine, showQualifiedPage)
import Language.Haskell.GhcMod.GHCApi
import Language.Haskell.GhcMod.GHCChoice ((||>), goNext)
import qualified Language.Haskell.GhcMod.Gap as Gap
import Language.Haskell.GhcMod.Gap (HasType(..))
import Language.Haskell.GhcMod.Types
import Outputable (ppr)
import TcHsSyn (hsPatType)

----------------------------------------------------------------

data Cmd = Info | Type deriving Eq

----------------------------------------------------------------

-- | Obtaining information of a target expression. (GHCi's info:)
infoExpr :: Options
         -> Cradle
         -> FilePath     -- ^ A target file.
         -> ModuleString -- ^ A module name.
         -> Expression   -- ^ A Haskell expression.
         -> IO String
infoExpr opt cradle file modstr expr = (++ "\n") <$> withGHCDummyFile (info opt cradle file modstr expr)

-- | Obtaining information of a target expression. (GHCi's info:)
info :: Options
     -> Cradle
     -> FilePath     -- ^ A target file.
     -> ModuleString -- ^ A module name.
     -> Expression   -- ^ A Haskell expression.
     -> Ghc String
info opt cradle file modstr expr =
    inModuleContext Info opt cradle file modstr exprToInfo "Cannot show info"
  where
    exprToInfo = do
        dflag <- getSessionDynFlags
        sdoc <- Gap.infoThing expr
        return $ showUnqualifiedPage dflag sdoc

----------------------------------------------------------------

instance HasType (LHsExpr Id) where
    getType tcm e = do
        hs_env <- getSession
        mbe <- Gap.liftIO $ Gap.deSugar tcm e hs_env
        return $ (getLoc e, ) <$> CoreUtils.exprType <$> mbe

instance HasType (LPat Id) where
    getType _ (L spn pat) = return $ Just (spn, hsPatType pat)

----------------------------------------------------------------

-- | Obtaining type of a target expression. (GHCi's type:)
typeExpr :: Options
         -> Cradle
         -> FilePath     -- ^ A target file.
         -> ModuleString -- ^ A odule name.
         -> Int          -- ^ Line number.
         -> Int          -- ^ Column number.
         -> IO String
typeExpr opt cradle file modstr lineNo colNo = withGHCDummyFile $ typeOf opt cradle file modstr lineNo colNo

-- | Obtaining type of a target expression. (GHCi's type:)
typeOf :: Options
       -> Cradle
       -> FilePath     -- ^ A target file.
       -> ModuleString -- ^ A odule name.
       -> Int          -- ^ Line number.
       -> Int          -- ^ Column number.
       -> Ghc String
typeOf opt cradle file modstr lineNo colNo =
    inModuleContext Type opt cradle file modstr exprToType errmsg
  where
    exprToType = do
      modSum <- getModSummary $ mkModuleName modstr
      p <- parseModule modSum
      tcm@TypecheckedModule{tm_typechecked_source = tcs} <- typecheckModule p
      let bs = listifySpans tcs (lineNo, colNo) :: [LHsBind Id]
          es = listifySpans tcs (lineNo, colNo) :: [LHsExpr Id]
          ps = listifySpans tcs (lineNo, colNo) :: [LPat Id]
      bts <- mapM (getType tcm) bs
      ets <- mapM (getType tcm) es
      pts <- mapM (getType tcm) ps
      dflag <- getSessionDynFlags
      let sss = map (toTup dflag) $ sortBy (cmp `on` fst) $ catMaybes $ concat [ets, bts, pts]
      return $ convert opt sss

    toTup :: DynFlags -> (SrcSpan, Type) -> ((Int,Int,Int,Int),String)
    toTup dflag (spn, typ) = (fourInts spn, pretty dflag typ)

    fourInts :: SrcSpan -> (Int,Int,Int,Int)
    fourInts = fromMaybe (0,0,0,0) . Gap.getSrcSpan

    cmp a b
      | a `isSubspanOf` b = O.LT
      | b `isSubspanOf` a = O.GT
      | otherwise = O.EQ

    errmsg = convert opt ([] :: [((Int,Int,Int,Int),String)])

listifySpans :: Typeable a => TypecheckedSource -> (Int, Int) -> [Located a]
listifySpans tcs lc = listifyStaged TypeChecker p tcs
  where
    p (L spn _) = isGoodSrcSpan spn && spn `spans` lc

listifyStaged :: Typeable r => Stage -> (r -> Bool) -> GenericQ [r]
listifyStaged s p = everythingStaged s (++) [] ([] `mkQ` (\x -> [x | p x]))

pretty :: DynFlags -> Type -> String
pretty dflag = showUnqualifiedOneLine dflag . Gap.typeForUser

----------------------------------------------------------------

inModuleContext :: Cmd -> Options -> Cradle -> FilePath -> ModuleString -> Ghc String -> String -> Ghc String
inModuleContext _ opt cradle file modstr action errmsg =
    valid ||> invalid ||> return errmsg
  where
    valid = do
        void $ initializeFlagsWithCradle opt cradle ["-w:"] False
        setTargetFiles [file]
        void $ load LoadAllTargets
        doif setContextFromTarget action
    invalid = do
        void $ initializeFlagsWithCradle opt cradle ["-w:"] False
        setTargetBuffer
        void $ load LoadAllTargets
        doif setContextFromTarget action
    setTargetBuffer = do
        modgraph <- depanal [mkModuleName modstr] True
        dflag <- getSessionDynFlags
        let imports = concatMap (map (showQualifiedPage dflag . ppr . unLoc)) $
                      map ms_imps modgraph ++ map ms_srcimps modgraph
            moddef = "module " ++ sanitize modstr ++ " where"
            header = moddef : imports
        importsBuf <- Gap.toStringBuffer header
        clkTime <- Gap.liftIO getCurrentTime
        setTargets [Gap.mkTarget (TargetModule $ mkModuleName modstr)
                                 True
                                 (Just (importsBuf, clkTime))]
    doif m t = m >>= \ok -> if ok then t else goNext
    sanitize = fromMaybe "SomeModule" . listToMaybe . words

setContextFromTarget :: Ghc Bool
setContextFromTarget = depanal [] False >>= Gap.setCtx

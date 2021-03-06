{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

{- |
Module           : $Header$
Description      :
License          : BSD3
Stability        : provisional
Point-of-contact : huffman
-}
module SAWScript.ImportAIG
  ( readAIGexpect
  , readAIG
  , loadAIG
  , verifyAIGCompatible
  , AIGNetwork
  ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
import Control.Lens
#endif
import Control.Exception
import Control.Monad
import Control.Monad.State.Strict
import Control.Monad.Trans.Except
import qualified Data.Vector as V
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import qualified Data.AIG as AIG
import qualified Data.ABC.GIA as ABC

import Verifier.SAW.Prelude
import Verifier.SAW.Recognizer
import Verifier.SAW.SharedTerm hiding (scNot, scAnd, scOr)

type TypeParser = StateT (V.Vector Term) (ExceptT String IO)

type AIGNetwork = ABC.Network ABC.Lit ABC.GIA

throwTP :: String -> TypeParser a
throwTP = lift . throwE

runTypeParser :: V.Vector Term
              -> TypeParser a
              -> ExceptT String IO (a, V.Vector Term)
runTypeParser v m = runStateT m v

bitblastSharedTerm :: SharedContext
                   -> Term -- ^ Term for input variable
                   -> Term -- ^ Term for type.
                   -> TypeParser ()
bitblastSharedTerm _ v (asBoolType -> Just ()) = do
  modify (`V.snoc` v)
bitblastSharedTerm sc v (asBitvectorType -> Just w) = do
  inputs <- liftIO $ do
    atFn <- scApplyPrelude_at sc
    wt <- scNat sc w
    boolType <- scPrelude_Bool sc
    V.generateM (fromIntegral w) $ \i -> do
      atFn wt boolType v =<< scNat sc (fromIntegral i)
  modify (V.++ inputs)
bitblastSharedTerm _ _ tp = throwTP $ show $
  text "Could not parse AIG input type:" <$$>
  indent 2 (scPrettyTermDoc defaultPPOpts tp)

parseAIGResultType :: SharedContext
                   -> Term -- ^ Term for type
                   -> TypeParser Term
parseAIGResultType _ (asBoolType -> Just ()) = do
  outputs <- get
  when (V.length outputs == 0) $ do
    throwTP "Not enough output bits for Bool result."
  put (V.drop 1 outputs)
  -- Return remaining as a vector.
  return (outputs V.! 0)
parseAIGResultType sc (asBitvectorType -> Just w) = do
  outputs <- get
  when (fromIntegral (V.length outputs) < w) $ do
    throwTP "Not enough output bits for type."
  let (base,remaining) = V.splitAt (fromIntegral w) outputs
  put remaining
  -- Return remaining as a vector.
  liftIO $ do
    boolType <- scPrelude_Bool sc
    scVector sc boolType (V.toList base)
parseAIGResultType _ _ = throwTP "Could not parse AIG output type."


-- |
networkAsSharedTerms
    :: AIG.IsAIG l g
    => g x
    -> SharedContext
    -> V.Vector Term -- ^ Input terms for AIG
    -> V.Vector (l x) -- ^ Outputs
    -> IO (V.Vector Term)
networkAsSharedTerms ntk sc inputTerms outputLits = do
  -- Get evaluator
  scNot <- scApplyPrelude_not sc
  scAnd <- scApplyPrelude_and sc
  scOr <- scApplyPrelude_or sc
  scImpl <- scApplyPrelude_implies sc
  scFalse <- scApplyPrelude_False sc

  -- Left is nonnegated, Right is negated
  let viewAnd inj _ (Left x)  (Left y)  = fmap inj $ scAnd x y
      viewAnd _ inj (Left x)  (Right y) = fmap inj $ scImpl x y
      viewAnd _ inj (Right x) (Left y)  = fmap inj $ scImpl y x
      viewAnd _ inj (Right x) (Right y) = fmap inj $ scOr x y

  let viewFinish (Left x)  = return x
      viewFinish (Right x) = scNot x

  let viewFn (AIG.And x y)    = viewAnd Left  Right x y
      viewFn (AIG.NotAnd x y) = viewAnd Right Left  x y
      viewFn (AIG.Input i)    = return (Left (inputTerms V.! i))
      viewFn (AIG.NotInput i) = return (Right (inputTerms V.! i))
      viewFn (AIG.FalseLit)   = return (Left scFalse)
      viewFn (AIG.TrueLit)    = return (Right scFalse)
  evalFn <- AIG.abstractEvaluateAIG ntk viewFn
  traverse (viewFinish <=< evalFn) outputLits

-- | Create vector for each input literal from expected types.
bitblastVarsAsInputLits :: SharedContext -> [Term] -> ExceptT String IO (V.Vector Term)
bitblastVarsAsInputLits sc args = do
  let n = length args
  let mkLocalVar :: Int -> Term -> IO Term
      mkLocalVar i _tp = scLocalVar sc idx
          -- Earlier arguments have a higher deBruijn index.
          where idx = (n - i - 1)
  inputs <- liftIO $ zipWithM mkLocalVar [0..] args
  fmap snd $ runTypeParser V.empty $ do
    zipWithM_ (bitblastSharedTerm sc) inputs args

withReadAiger :: FilePath
              -> (forall g l. ABC.IsAIG l g => AIG.Network l g -> IO (Either String a))
              -> IO (Either String a)
withReadAiger path action = do
   mntk <- try (AIG.aigerNetwork ABC.proxy path)
   case mntk of
      Left e -> return (Left (show (e :: IOException)))
      Right ntk -> action ntk

translateNetwork :: AIG.IsAIG l g
                 => SharedContext    -- ^ Context to build in term.
                 -> g x              -- ^ Network to bitblast
                 -> [l x]            -- ^ Outputs for network.
                 -> [(String, Term)] -- ^ Expected types
                 -> Term             -- ^ Expected output type.
                 -> ExceptT String IO Term
translateNetwork sc ntk outputLits args resultType = do
  --lift $ putStrLn "inputTerms"
  inputTerms <- bitblastVarsAsInputLits sc (snd <$> args)
  -- Check number of inputs to network matches expected inputs.
  do let expectedInputCount = V.length inputTerms
     aigCount <- liftIO $ AIG.inputCount ntk
     unless (expectedInputCount == aigCount) $ do
       throwE $ "AIG has " ++ show aigCount
                  ++ " inputs, while expected type has "
                  ++ show expectedInputCount ++ " inputs."
  --lift $ putStrLn "Output vars"
  -- Get outputs as SAWCore terms.
  outputVars <- liftIO $
    networkAsSharedTerms ntk sc inputTerms (V.fromList outputLits)
  --lift $ putStrLn "Type parser"
   -- Join output lits into result type.
  (res,rargs) <- runTypeParser outputVars $ parseAIGResultType sc resultType
  unless (V.null rargs) $
    throwE "AIG contains more outputs than expected."
  lift $ scLambdaList sc args res

readAIGexpect
        :: SharedContext -- ^ Context to build in term.
        -> FilePath      -- ^ Path to AIG
        -> Term          -- ^ Expected type of term.
        -> IO (Either String Term)
readAIGexpect sc path aigType =
  withReadAiger path $ \(AIG.Network ntk outputLits) -> do
    --putStrLn "Network outputs"
    let (args,resultType) = asPiList aigType
    runExceptT $
      translateNetwork sc ntk outputLits args resultType

loadAIG :: FilePath -> IO (Either String AIGNetwork)
loadAIG f = do
   mntk <- try (AIG.aigerNetwork ABC.proxy f)
   case mntk of
      Left e -> return (Left (show (e :: IOException)))
      Right ntk -> return $ Right ntk

readAIG :: SharedContext -> FilePath -> IO (Either String Term)
readAIG sc f =
  withReadAiger f $ \(AIG.Network ntk outputLits) -> do
    inputs <- AIG.inputCount ntk
    inLen <- scNat sc (fromIntegral inputs)
    outLen <- scNat sc (fromIntegral (length outputLits))
    boolType <- scBoolType sc
    inType <- scVecType sc inLen boolType
    outType <- scVecType sc outLen boolType
    runExceptT $
      translateNetwork sc ntk outputLits [("x", inType)] outType

-- | Check that the input and output counts of the given
--   AIGNetworks are equal.
verifyAIGCompatible :: AIGNetwork -> AIGNetwork -> IO ()
verifyAIGCompatible x y = do
   inx <- AIG.networkInputCount x
   iny <- AIG.networkInputCount y
   let outx = AIG.networkOutputCount x
   let outy = AIG.networkOutputCount y
   when (inx /= iny) $ do
       fail $ unwords ["AIG input counts do not match:", show inx, show iny]
   when (outx /= outy) $ do
       fail $ unwords ["AIG output counts do not match:", show outx, show outy]

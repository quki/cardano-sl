{-# LANGUAGE Rank2Types #-}

-- | This module defines methods which operate on SscLocalData.

module Pos.Ssc.GodTossing.LocalData.Logic
       (
         -- * 'Inv|Req|Data' processing.
         sscIsDataUseful
       , sscProcessCommitment
       , sscProcessOpening
       , sscProcessShares
       , sscProcessCertificate

         -- * Garbage collection worker
       , localOnNewSlot

         -- * Instances
         -- ** instance SscLocalDataClass
       ) where

import           Universum

import           Control.Lens                       ((+=), (.=))
import           Control.Monad.Except               (MonadError (throwError), runExceptT)
import           Control.Monad.Morph                (hoist)
import qualified Crypto.Random                      as Rand
import qualified Data.HashMap.Strict                as HM
import           Formatting                         (int, sformat, (%))
import           Serokell.Util                      (magnify')
import           System.Wlog                        (WithLogger, logWarning)

import           Pos.Binary.Class                   (biSize)
import           Pos.Binary.GodTossing              ()
import           Pos.Core                           (BlockVersionData (..), EpochIndex,
                                                     HasConfiguration, SlotId (..),
                                                     StakeholderId, VssCertificate,
                                                     mkVssCertificatesMapSingleton)
import           Pos.DB                             (MonadDBRead,
                                                     MonadGState (gsAdoptedBVData))
import           Pos.Lrc.Types                      (RichmenStakes)
import           Pos.Slotting                       (MonadSlots (getCurrentSlot))
import           Pos.Ssc.Class.LocalData            (LocalQuery, LocalUpdate,
                                                     SscLocalDataClass (..))
import           Pos.Ssc.Extra                      (MonadSscMem, sscRunGlobalQuery,
                                                     sscRunLocalQuery, sscRunLocalSTM)
import           Pos.Ssc.GodTossing.Configuration   (HasGtConfiguration)
import           Pos.Ssc.Core                       (SscPayload (..), InnerSharesMap,
                                                     Opening, SignedCommitment,
                                                     isCommitmentIdx, isOpeningIdx,
                                                     isSharesIdx, mkCommitmentsMap)
import           Pos.Ssc.GodTossing.Toss            (GtTag (..), PureToss, TossT,
                                                     evalPureTossWithLogger, evalTossT,
                                                     execTossT, hasCertificateToss,
                                                     hasCommitmentToss, hasOpeningToss,
                                                     hasSharesToss, isGoodSlotForTag,
                                                     normalizeToss, refreshToss,
                                                     supplyPureTossEnv, tmCertificates,
                                                     tmCommitments, tmOpenings, tmShares,
                                                     verifyAndApplySscPayload)
import           Pos.Ssc.Types                      (SscLocalData (..),
                                                     SscGlobalState, ldEpoch,
                                                     ldModifier, ldSize)
import           Pos.Ssc.VerifyError                (SscVerifyError (..))
import           Pos.Ssc.RichmenComponent           (getRichmenSsc)

----------------------------------------------------------------------------
-- Methods from type class
----------------------------------------------------------------------------

instance (HasGtConfiguration, HasConfiguration) => SscLocalDataClass where
    sscGetLocalPayloadQ = getLocalPayload
    sscNormalizeU = normalize
    sscNewLocalData =
        SscLocalData mempty . siEpoch . fromMaybe slot0 <$> getCurrentSlot <*>
        pure 1
      where
        slot0 = SlotId 0 minBound

getLocalPayload :: HasConfiguration => SlotId -> LocalQuery SscPayload
getLocalPayload SlotId {..} = do
    expectedEpoch <- view ldEpoch
    let warningMsg = sformat warningFmt siEpoch expectedEpoch
    isExpected <-
        if expectedEpoch == siEpoch then pure True
        else False <$ logWarning warningMsg
    magnify' ldModifier $
        getPayload isExpected <*> getCertificates isExpected
  where
    warningFmt = "getLocalPayload: unexpected epoch ("%int%", stored one is "%int%")"
    getPayload True
        | isCommitmentIdx siSlot = CommitmentsPayload <$> view tmCommitments
        | isOpeningIdx siSlot = OpeningsPayload <$> view tmOpenings
        | isSharesIdx siSlot = SharesPayload <$> view tmShares
    getPayload _ = pure CertificatesPayload
    getCertificates isExpected
        | isExpected = view tmCertificates
        | otherwise = pure mempty

normalize
    :: (HasGtConfiguration, HasConfiguration)
    => (EpochIndex, RichmenStakes)
    -> BlockVersionData
    -> SscGlobalState
    -> LocalUpdate ()
normalize (epoch, stake) bvd gs = do
    oldModifier <- use ldModifier
    let multiRichmen = HM.fromList [(epoch, stake)]
    newModifier <-
        evalPureTossWithLogger gs $ supplyPureTossEnv (multiRichmen, bvd) $
        execTossT mempty $ normalizeToss epoch oldModifier
    ldModifier .= newModifier
    ldEpoch .= epoch
    ldSize .= biSize newModifier

----------------------------------------------------------------------------
-- Data processing/retrieval
----------------------------------------------------------------------------

----------------------------------------------------------------------------
---- Inv processing
----------------------------------------------------------------------------

-- | Check whether SSC data with given tag and public key can be added
-- to current local data.
sscIsDataUseful
    :: ( WithLogger m
       , MonadIO m
       , MonadSlots ctx m
       , MonadSscMem ctx m
       , Rand.MonadRandom m
       , HasConfiguration
       , HasGtConfiguration
       )
    => GtTag -> StakeholderId -> m Bool
sscIsDataUseful tag id =
    ifM
        (maybe False (isGoodSlotForTag tag . siSlot) <$> getCurrentSlot)
        (evalTossInMem $ sscIsDataUsefulDo tag)
        (pure False)
  where
    sscIsDataUsefulDo CommitmentMsg     = not <$> hasCommitmentToss id
    sscIsDataUsefulDo OpeningMsg        = not <$> hasOpeningToss id
    sscIsDataUsefulDo SharesMsg         = not <$> hasSharesToss id
    sscIsDataUsefulDo VssCertificateMsg = not <$> hasCertificateToss id
    evalTossInMem
        :: ( WithLogger m
           , MonadIO m
           , MonadSscMem ctx m
           , Rand.MonadRandom m
           )
        => TossT PureToss a -> m a
    evalTossInMem action = do
        gs <- sscRunGlobalQuery ask
        ld <- sscRunLocalQuery ask
        let modifier = ld ^. ldModifier
        evalPureTossWithLogger gs $ evalTossT modifier action

----------------------------------------------------------------------------
---- Data processing
----------------------------------------------------------------------------

type GtDataProcessingMode ctx m =
    ( WithLogger m
    , MonadIO m           -- STM at least
    , Rand.MonadRandom m  -- for crypto
    , MonadDBRead m       -- to get richmen
    , MonadGState m       -- to get block size limit
    , MonadSlots ctx m
    , MonadSscMem ctx m
    , MonadError SscVerifyError m
    , HasConfiguration
    , HasGtConfiguration
    )

-- | Process 'SignedCommitment' received from network, checking it against
-- current state (global + local) and adding to local state if it's valid.
sscProcessCommitment
    :: forall ctx m.
       GtDataProcessingMode ctx m
    => SignedCommitment -> m ()
sscProcessCommitment comm =
    sscProcessData CommitmentMsg $
    CommitmentsPayload (mkCommitmentsMap [comm]) mempty

-- | Process 'Opening' received from network, checking it against
-- current state (global + local) and adding to local state if it's valid.
sscProcessOpening
    :: GtDataProcessingMode ctx m
    => StakeholderId -> Opening -> m ()
sscProcessOpening id opening =
    sscProcessData OpeningMsg $
    OpeningsPayload (HM.fromList [(id, opening)]) mempty

-- | Process 'InnerSharesMap' received from network, checking it against
-- current state (global + local) and adding to local state if it's valid.
sscProcessShares
    :: GtDataProcessingMode ctx m
    => StakeholderId -> InnerSharesMap -> m ()
sscProcessShares id shares =
    sscProcessData SharesMsg $ SharesPayload (HM.fromList [(id, shares)]) mempty

-- | Process 'VssCertificate' received from network, checking it against
-- current state (global + local) and adding to local state if it's valid.
sscProcessCertificate
    :: GtDataProcessingMode ctx m
    => VssCertificate -> m ()
sscProcessCertificate cert =
    sscProcessData VssCertificateMsg $
    CertificatesPayload (mkVssCertificatesMapSingleton cert)

sscProcessData
    :: forall ctx m.
       GtDataProcessingMode ctx m
    => GtTag -> SscPayload -> m ()
sscProcessData tag payload =
    generalizeExceptT $ do
        getCurrentSlot >>= checkSlot
        ld <- sscRunLocalQuery ask
        bvd <- gsAdoptedBVData
        let epoch = ld ^. ldEpoch
        seed <- Rand.drgNew
        getRichmenSsc epoch >>= \case
            Nothing -> throwError $ TossUnknownRichmen epoch
            Just richmen -> do
                gs <- sscRunGlobalQuery ask
                ExceptT $
                    sscRunLocalSTM $
                    executeMonadBaseRandom seed $
                    sscProcessDataDo (epoch, richmen) bvd gs payload
  where
    generalizeExceptT action = either throwError pure =<< runExceptT action
    checkSlot Nothing = throwError CurrentSlotUnknown
    checkSlot (Just si@SlotId {..})
        | isGoodSlotForTag tag siSlot = pass
        | CommitmentMsg <- tag = throwError $ NotCommitmentPhase si
        | OpeningMsg <- tag = throwError $ NotOpeningPhase si
        | SharesMsg <- tag = throwError $ NotSharesPhase si
        | otherwise = pass
    -- (... MonadPseudoRandom) a -> (... n) a
    executeMonadBaseRandom seed = hoist $ hoist (pure . fst . Rand.withDRG seed)

sscProcessDataDo
    :: (HasGtConfiguration, HasConfiguration, MonadState SscLocalData m,
        WithLogger m, Rand.MonadRandom m)
    => (EpochIndex, RichmenStakes)
    -> BlockVersionData
    -> SscGlobalState
    -> SscPayload
    -> m (Either SscVerifyError ())
sscProcessDataDo richmenData bvd gs payload =
    runExceptT $ do
        storedEpoch <- use ldEpoch
        let givenEpoch = fst richmenData
        let multiRichmen = HM.fromList [richmenData]
        unless (storedEpoch == givenEpoch) $
            throwError $ DifferentEpoches storedEpoch givenEpoch
        -- TODO: This is a rather arbitrary limit, we should revisit it (see CSL-1664)
        let maxMemPoolSize = bvdMaxBlockSize bvd * 2
        curSize <- use ldSize
        let exhausted = curSize >= maxMemPoolSize
        -- If our mempool is exhausted we drop some data from it.
        oldTM <-
            if | not exhausted -> use ldModifier
               | otherwise ->
                   evalPureTossWithLogger gs .
                   supplyPureTossEnv (multiRichmen, bvd) .
                   execTossT mempty . refreshToss givenEpoch =<<
                   use ldModifier
        newTM <-
            ExceptT $
            evalPureTossWithLogger gs $
            supplyPureTossEnv (multiRichmen, bvd) $
            runExceptT $
            execTossT oldTM $ verifyAndApplySscPayload (Left storedEpoch) payload
        ldModifier .= newTM
        -- If mempool was exhausted, it's easier to recompute total size.
        -- Otherwise (most common case) we don't want to spend time on it and
        -- just add size of new data.
        -- Note that if data is invalid, all this computation will be
        -- discarded.
        if | exhausted -> ldSize .= biSize newTM
           | otherwise -> ldSize += biSize payload

----------------------------------------------------------------------------
-- Clean-up
----------------------------------------------------------------------------

-- | Clean-up some data when new slot starts.
-- This function is only needed for garbage collection, it doesn't affect
-- validity of local data.
-- Currently it does nothing, but maybe later we'll decide to do clean-up.
localOnNewSlot
    :: MonadSscMem ctx m
    => SlotId -> m ()
localOnNewSlot _ = pass
-- unless (isCommitmentIdx slotIdx) $ gtLocalCommitments .= mempty
-- unless (isOpeningIdx slotIdx) $ gtLocalOpenings .= mempty
-- unless (isSharesIdx slotIdx) $ gtLocalShares .= mempty

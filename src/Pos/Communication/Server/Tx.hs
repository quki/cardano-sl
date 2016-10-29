{-# LANGUAGE FlexibleContexts #-}

-- | Server which handles transactions.

module Pos.Communication.Server.Tx
       ( txListeners
       ) where

import           Control.TimeWarp.Logging (logInfo)
import           Formatting               (build, sformat, (%))
import           Pos.DHT                  (ListenerDHT (..))
import           Universum

import           Control.TimeWarp.Rpc     (BinaryP, MonadDialog)
import           Pos.Communication.Types  (ResponseMode, SendTx (..), SendTxs (..))
import           Pos.State                (processTx)
import           Pos.WorkMode             (WorkMode)

-- | Listeners for requests related to blocks processing.
txListeners :: (MonadDialog BinaryP m, WorkMode m) => [ListenerDHT m]
txListeners =
    [ ListenerDHT handleTx
    , ListenerDHT handleTxs
    ]

handleTx
    :: ResponseMode m
    => SendTx -> m ()
handleTx (SendTx tx) =
    whenM (processTx tx) $
    logInfo (sformat ("Transaction has been added to storage: "%build) tx)

handleTxs
    :: ResponseMode m
    => SendTxs -> m ()
handleTxs (SendTxs txs) = mapM_ (handleTx . SendTx) txs

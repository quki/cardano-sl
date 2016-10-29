{-# LANGUAGE DeriveGeneric #-}
-- | Types used for communication about system start.

module Pos.Communication.Types.SysStart
       ( SysStartRequest (..)
       , SysStartResponse (..)
       , sysStartMessageNames
       ) where

import           Data.Binary          (Binary)
import           Data.MessagePack     (MessagePack)
import           Universum

import           Control.TimeWarp.Rpc (Message (..), MessageName)
import           Pos.Types            (Timestamp)

sysStartMessageNames :: [MessageName]
sysStartMessageNames = [ sysStartReqMessageName, sysStartRespMessageName ]

data SysStartRequest = SysStartRequest
    deriving (Generic)

data SysStartResponse = SysStartResponse !(Maybe Timestamp)
    deriving (Generic)

instance Binary SysStartRequest
instance Binary SysStartResponse

instance MessagePack SysStartRequest
instance MessagePack SysStartResponse

sysStartReqMessageName :: MessageName
sysStartReqMessageName = "SysStartRequest"

sysStartRespMessageName :: MessageName
sysStartRespMessageName = "SysStartResponse"

instance Message SysStartRequest where
    messageName _ = sysStartReqMessageName

instance Message SysStartResponse where
    messageName _ = sysStartRespMessageName

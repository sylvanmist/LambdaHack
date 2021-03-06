{-# LANGUAGE FlexibleContexts #-}
-- | Semantics of client commands.
module Game.LambdaHack.Client.HandleResponseClient
  ( handleResponseAI, handleResponseUI
  ) where

import Game.LambdaHack.Atomic
import Game.LambdaHack.Client.AI
import Game.LambdaHack.Client.HandleAtomicClient
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.ProtocolClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.Response

storeUndo :: MonadClient m => CmdAtomic -> m ()
storeUndo _atomic =
  maybe (return ()) (\a -> modifyClient $ \cli -> cli {sundo = a : sundo cli})
    Nothing   -- TODO: undoCmdAtomic atomic

handleResponseAI :: (MonadAtomic m, MonadClientWriteRequest RequestAI m)
                 => ResponseAI -> m ()
handleResponseAI cmd = case cmd of
  RespUpdAtomicAI cmdA -> do
    cmds <- cmdAtomicFilterCli cmdA
    mapM_ (\c -> cmdAtomicSemCli c
                 >> execUpdAtomic c) cmds
    mapM_ (storeUndo . UpdAtomic) cmds
  RespQueryAI aid -> do
    cmdC <- queryAI aid
    sendRequest cmdC
  RespPingAI -> do
    pong <- pongAI
    sendRequest pong

handleResponseUI :: ( MonadClientUI m
                    , MonadAtomic m
                    , MonadClientWriteRequest RequestUI m )
                 => ResponseUI -> m ()
handleResponseUI cmd = case cmd of
  RespUpdAtomicUI cmdA -> do
    cmds <- cmdAtomicFilterCli cmdA
    let handle c = do
          oldState <- getState
          oldStateClient <- getClient
          cmdAtomicSemCli c
          execUpdAtomic c
          displayRespUpdAtomicUI False oldState oldStateClient c
    mapM_ handle cmds
    mapM_ (storeUndo . UpdAtomic) cmds  -- TODO: only store cmdA?
  RespSfxAtomicUI sfx -> do
    displayRespSfxAtomicUI False sfx
    storeUndo $ SfxAtomic sfx
  RespQueryUI -> do
    cmdH <- queryUI
    sendRequest cmdH
  RespPingUI -> do
    pong <- pongUI
    sendRequest pong

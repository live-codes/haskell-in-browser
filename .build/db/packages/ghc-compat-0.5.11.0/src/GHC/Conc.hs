module GHC.Conc(
  threadStatus,
  ensureIOManagerIsRunning,
  ThreadId(..),
  ) where
import Control.Concurrent
import GHC.Exts

ensureIOManagerIsRunning :: IO ()
ensureIOManagerIsRunning = return ()

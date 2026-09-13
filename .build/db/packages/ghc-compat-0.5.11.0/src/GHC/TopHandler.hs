module GHC.TopHandler(
  runIO,
  ) where
import Control.Exception

-- XXX 
runIO :: IO a -> IO a
runIO main = main
  -- catch main topHandler

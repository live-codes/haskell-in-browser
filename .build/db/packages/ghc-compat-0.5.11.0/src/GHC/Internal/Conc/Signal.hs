module GHC.Internal.Conc.Signal (
  Signal,
  HandlerFun,
  setHandler,
  ) where
import Data.Dynamic
import Data.Word
import Foreign.C.Types
import Foreign.ForeignPtr

type Signal = CInt

type HandlerFun = ForeignPtr Word8 -> IO ()

setHandler :: Signal -> Maybe (HandlerFun, Dynamic)
           -> IO (Maybe (HandlerFun, Dynamic))
setHandler sig handler = error "setHandler"

  

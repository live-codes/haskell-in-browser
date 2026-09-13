module GHC.Fingerprint (
  Fingerprint(..), fingerprint0,
) where

import Data.Word.Word64
import Numeric (showHex)

data Fingerprint = Fingerprint {-# UNPACK #-} !Word64 {-# UNPACK #-} !Word64
  deriving ( Eq  -- ^ @since base-4.4.0.0
           , Ord -- ^ @since base-4.4.0.0
           )

-- | @since base-4.7.0.0
instance Show Fingerprint where
  show (Fingerprint w1 w2) = hex16 w1 ++ hex16 w2
    where
      -- Formats a 64 bit number as 16 digits hex.
      hex16 :: Word64 -> String
      hex16 i = let hex = showHex i ""
                 in replicate (16 - length hex) '0' ++ hex

fingerprint0 :: Fingerprint
fingerprint0 = Fingerprint 0 0

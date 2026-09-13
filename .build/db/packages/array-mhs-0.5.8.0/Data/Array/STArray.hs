module Data.Array.STArray(
  STArray(..),
  newSTArray,
  boundsSTArray,
  numElementsSTArray,
  readSTArray,
  writeSTArray,
  freezeSTArray,
  thawSTArray,
  unsafeReadSTArray,
  unsafeWriteSTArray,
  unsafeFreezeSTArray,
  unsafeThawSTArray,
  ) where
import Control.Monad.ST
import Control.Monad.ST_Type
import Mhs.Array
import Data.Array.IOArray

newtype STArray s i a = STArray (IOArray i a)

newSTArray :: Ix i => (i,i) -> e -> ST s (STArray s i e)
newSTArray lu e = ST (STArray <$> newIOArray lu e)

boundsSTArray :: STArray s i e -> (i,i)
boundsSTArray (STArray a) = boundsIOArray a

numElementsSTArray :: forall s i e . STArray s i e -> Int
numElementsSTArray (STArray a) = numElementsIOArray a

readSTArray :: Ix i => STArray s i e -> i -> ST s e
readSTArray (STArray a) i = ST (readIOArray a i)

unsafeReadSTArray :: STArray s i e -> Int -> ST s e
unsafeReadSTArray (STArray a) i = ST (unsafeReadIOArray a i)

writeSTArray :: Ix i => STArray s i e -> i -> e -> ST s ()
writeSTArray (STArray a) i e = ST (writeIOArray a i e)

unsafeWriteSTArray :: STArray s i e -> Int -> e -> ST s ()
unsafeWriteSTArray (STArray a) i e = ST (unsafeWriteIOArray a i e)

----------------------------------------------------------------------
-- Moving between mutable and immutable

freezeSTArray :: STArray s i e -> ST s (Array i e)
freezeSTArray (STArray a) = ST (freezeIOArray a)

unsafeFreezeSTArray :: STArray s i e -> ST s (Array i e)
unsafeFreezeSTArray (STArray a) = ST (unsafeFreezeIOArray a)

thawSTArray :: Array i e -> ST s (STArray s i e)
thawSTArray a = ST (STArray <$> thawIOArray a)

unsafeThawSTArray :: Array i e -> ST s (STArray s i e)
unsafeThawSTArray a = ST (STArray <$> unsafeThawIOArray a)

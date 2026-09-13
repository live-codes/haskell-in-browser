module Data.Array.IOArray(
  IOArray(..),
  newIOArray,
  boundsIOArray,
  numElementsIOArray,
  readIOArray,
  writeIOArray,
  freezeIOArray,
  thawIOArray,
  unsafeReadIOArray,
  unsafeWriteIOArray,
  unsafeFreezeIOArray,
  unsafeThawIOArray,
  ) where
import Control.Monad.ST
import Control.Monad.ST_Type
import Data.Ix
import Mhs.Array
import Mhs.MutArr

data IOArray i a
   = IOArray (i, i)          -- bounds
             !Int            -- = rangeSize (l, u)
             (MutIOArr a)    -- elements

newIOArray :: Ix i => (i,i) -> e -> IO (IOArray i e)
newIOArray lu a = IOArray lu n <$> newMutIOArr n a
  where n = safeRangeSize lu

boundsIOArray :: IOArray i e -> (i,i)
boundsIOArray (IOArray lu _ _) = lu

numElementsIOArray :: IOArray i e -> Int
numElementsIOArray (IOArray _ n _) = n

readIOArray :: Ix i => IOArray i e -> i -> IO e
readIOArray arr@(IOArray lu n _) i = unsafeReadIOArray arr (safeIndex lu n i)

unsafeReadIOArray :: IOArray i e -> Int -> IO e
unsafeReadIOArray (IOArray _ _ arr) i = unsafeReadMutIOArr arr i

writeIOArray :: Ix i => IOArray i e -> i -> e -> IO ()
writeIOArray arr@(IOArray lu n _) i e = unsafeWriteIOArray arr (safeIndex lu n i) e

unsafeWriteIOArray :: IOArray i e -> Int -> e -> IO ()
unsafeWriteIOArray (IOArray _ _ arr) i e = unsafeWriteMutIOArr arr i e

----------------------------------------------------------------------
-- Moving between mutable and immutable

freezeIOArray :: IOArray i e -> IO (Array i e)
freezeIOArray (IOArray lu n arr) = Array lu n <$> copyMutIOArr arr

unsafeFreezeIOArray :: IOArray i e -> IO (Array i e)
unsafeFreezeIOArray (IOArray lu n arr) = return $ Array lu n arr

thawIOArray :: Array i e -> IO (IOArray i e)
thawIOArray (Array lu n arr) = IOArray lu n <$> copyMutIOArr arr

unsafeThawIOArray :: Array i e -> IO (IOArray i e)
unsafeThawIOArray (Array lu n arr) = return $ IOArray lu n arr

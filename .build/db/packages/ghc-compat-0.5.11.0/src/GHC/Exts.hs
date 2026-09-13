module GHC.Exts(
  TYPE,
  --
  build, augment,
  inline,
  --
  Int(I#), Int#, (==#), (<#),
  isTrue#,
--  pattern I#,
  --
  ST, unsafeIOToST,
  --
  State#, stToState, stateToST,
  -- array stuff
  SmallArray#, SmallMutableArray#,
  cloneSmallMutableArray#, copySmallArray#,
  copySmallMutableArray#, getSizeofSmallMutableArray#,
  indexSmallArray#, newSmallArray#, readSmallArray#,
  reallyUnsafePtrEquality#, sizeofSmallArray#,
  tagToEnum#, thawSmallArray#, unsafeCoerce#,
  unsafeFreezeSmallArray#, unsafeThawSmallArray#,
  writeSmallArray#, shrinkSmallMutableArray#,
  --
  Array#, MutableArray#,
  --
  IO,
  pattern IO,
  --
  ThreadId(ThreadId),
  fork#, forkOn#,
  forkOS,
  --
  SPEC(..),
  Proxy#, proxy#,
  ) where
import qualified Control.Monad.ST_Type as ST
import GHC.Internal.Types
import Data.Proxy

data TYPE     -- this is nothing like TYPE in GHC, but allows imports to be unaltered

-----

build :: forall a. (forall b. (a -> b -> b) -> b -> b) -> [a]
build g = g (:) []

augment :: forall a. (forall b. (a->b->b) -> b -> b) -> [a] -> [a]
augment g xs = g (:) xs

-----

unsafeIOToST :: IO a -> ST s a
unsafeIOToST = ST.ST

inline :: a -> a
inline x = x

-- Fake unboxed Int
type Int# = Int
pattern I# :: Int# -> Int
pattern I# i = i

(==#) :: Int# -> Int# -> Int#
x ==# y = if x == y then 1 else 0

(<#) :: Int# -> Int# -> Int#
x <# y = if x < y then 1 else 0

isTrue# :: Int# -> Bool
isTrue# x = x /= 0

-------------------------------------

unsafePerformST :: ST s a -> a
unsafePerformST = unsafePerformIO . ST.unST

data State# a = StateToken

stToState :: ST s a -> State# s -> (# State# s, a #)
stToState st s = unsafePerformST $ do a <- st; return (# s, a #)

stToStateUnit :: ST s () -> State# s -> State# s
stToStateUnit st s = unsafePerformST $ do st; return s

stateToST :: (State# s -> (# State# s, a #)) -> ST s a
stateToST f =
  case f StateToken of
    (# _, a #) -> pure a

-------------------------------------

import Control.Monad(forM_)
import Control.Monad.ST
import qualified Mhs.Arr as A
import qualified Mhs.MutArr as MA
import System.IO.Unsafe(unsafePerformIO)
import Unsafe.Coerce(unsafeCoerce)

-- XXX Make a primitive
subMutSTArr :: forall s a . MA.MutSTArr s a -> Int -> Int -> ST s (MA.MutSTArr s a)
subMutSTArr ma o l = do
  r <- MA.newMutSTArr l undefined
  forM_ [0..l-1] $ \ i -> do
    a <- MA.unsafeReadMutSTArr ma (o+i)
    MA.unsafeWriteMutSTArr r i a
  return r


type SmallArray# a = A.Arr a

type SmallMutableArray# s a = MA.MutSTArr s a

cloneSmallMutableArray# :: SmallMutableArray# d a -> Int# -> Int# -> State# d -> (# State# d, SmallMutableArray# d a #)
cloneSmallMutableArray# ma o l = stToState $ subMutSTArr ma o l

copySmallMutableArray# :: SmallMutableArray# d a -> Int# -> SmallMutableArray# d a -> Int# -> Int# -> State# d -> State# d
copySmallMutableArray# sa soff da doff l = stToStateUnit $
  forM_ [0..l-1] $ \ i -> do
    a <- MA.unsafeReadMutSTArr sa (soff+i)
    MA.unsafeWriteMutSTArr da (doff+i) a

copySmallArray# :: SmallArray# a -> Int# -> SmallMutableArray# d a -> Int# -> Int# -> State# d -> State# d
copySmallArray# sa soff da doff l = stToStateUnit $
  forM_ [0..l-1] $ \ i -> do
    let a = A.unsafeReadArr sa (soff+i)
    MA.unsafeWriteMutSTArr da (doff+i) a

getSizeofSmallMutableArray# :: SmallMutableArray# d a -> State# d -> (# State# d, Int# #)
getSizeofSmallMutableArray# ma = stToState $ MA.sizeMutSTArr ma

indexSmallArray# :: SmallArray# a -> Int# -> (# a #)
indexSmallArray# a i = (# A.unsafeReadArr a i #)

newSmallArray# :: Int# -> a -> State# d -> (# State# d, SmallMutableArray# d a #)
newSmallArray# n a = stToState $ MA.newMutSTArr n a

readSmallArray# :: SmallMutableArray# d a -> Int# -> State# d -> (# State# d, a #)
readSmallArray# a i = stToState $ MA.unsafeReadMutSTArr a i

sizeofSmallArray# :: SmallArray# a -> Int#
sizeofSmallArray# a = A.sizeArr a

thawSmallArray# :: SmallArray# a -> Int# -> Int# -> State# d -> (# State# d, SmallMutableArray# d a #)
thawSmallArray# a o l = stToState $ do
  ma <- A.unsafeThawSTArr a
  subMutSTArr ma o l

unsafeFreezeSmallArray# :: SmallMutableArray# d a -> State# d -> (# State# d, SmallArray# a #)
unsafeFreezeSmallArray# a = stToState $ A.unsafeFreezeMutSTArr a

unsafeThawSmallArray# :: SmallArray# a -> State# d -> (# State# d, SmallMutableArray# d a #)
unsafeThawSmallArray# a = stToState $ A.unsafeThawSTArr a

writeSmallArray# :: SmallMutableArray# d a -> Int# -> a -> State# d -> State# d
writeSmallArray# ma i a = stToStateUnit $ MA.unsafeWriteMutSTArr ma i a

shrinkSmallMutableArray# :: SmallMutableArray# d a -> Int# -> State# d -> State# d
shrinkSmallMutableArray# ma n = stToStateUnit $ MA.shrinkMutSTArr ma n

-- XXX should have a primitive
reallyUnsafePtrEquality# :: a -> b -> Int#
reallyUnsafePtrEquality# _ _ = 0

-- XXX hard to implement
-- tagToEnum# :: Int# -> a
tagToEnum# :: Int# -> Bool
tagToEnum = (0 /=)

unsafeCoerce# :: a -> b
unsafeCoerce# = unsafeCoerce

-------------------------------

ioToState :: IO a -> State# RealWorld -> (# State# RealWorld, a #)
ioToState st s = unsafePerformIO $ do a <- st; return (# s, a #)

ioToStateUnit :: IO () -> State# RealWorld -> State# RealWorld
ioToStateUnit st s = unsafePerformIO $ do st; return s

stateToIO :: (State# RealWorld -> (# State# RealWorld, a #)) -> IO a
stateToIO f =
  case f StateToken of
    (# _, a #) -> pure a

pattern IO :: (State# RealWorld -> (# State# RealWorld, a #)) -> IO a
pattern IO x <- (ioToState -> x)
  where IO x = stateToIO x

-------------------------------

import Control.Concurrent(ThreadId, forkIO)

type ThreadId# = ThreadId
pattern ThreadId :: ThreadId# -> ThreadId
pattern ThreadId a = a

fork# :: (State# RealWorld -> (# State# RealWorld, a #))
      -> State# RealWorld -> (# State# RealWorld, ThreadId# #)
fork# sio = ioToState (forkIO (stateToIO sio >> pure ()))

forkOn# :: Int#
        -> (State# RealWorld -> (# State# RealWorld, a #))
        -> State# RealWorld
        -> (# State# RealWorld, ThreadId# #)
forkOn# _ = fork#

-- XXX Until mhs gets this
forkOS :: IO () -> IO ThreadId
forkOS = forkIO

-------------------------------

data Array# a
data MutableArray# s a

type Proxy# = Proxy
proxy# :: Proxy# a
proxy# = Proxy

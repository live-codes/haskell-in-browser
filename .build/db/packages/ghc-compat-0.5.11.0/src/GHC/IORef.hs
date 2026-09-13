module GHC.IORef where
import Data.IORef

primAtomic :: IO a -> IO a
primAtomic = _primitive "IO.atomic"

atomicModifyIORef2Lazy :: IORef a -> (a -> (a, b)) -> IO (a, (a, b))
atomicModifyIORef2Lazy r f = primAtomic $  do
  a <- readIORef r
  let ab = f a
  writeIORef r (fst ab)
  return (a, ab)

atomicModifyIORef2 :: IORef a -> (a -> (a, b)) -> IO (a, (a, b))
atomicModifyIORef2 ref f = do
  r@(_old, (_new, _res)) <- atomicModifyIORef2Lazy ref f
  return r

atomicModifyIORefLazy_ :: IORef a -> (a -> a) -> IO (a, a)
atomicModifyIORefLazy_ r f = primAtomic $ do
  a <- readIORef r
  let a' = f a
  writeIORef r a'
  return (a, a')

atomicModifyIORefP :: IORef a -> (a -> (a, b)) -> IO b
atomicModifyIORefP ref f = do
  (_old, (_,r)) <- atomicModifyIORef2 ref f
  pure r

atomicModifyIORef'_ :: IORef a -> (a -> a) -> IO (a, a)
atomicModifyIORef'_ ref f = do
  (old, new) <- atomicModifyIORefLazy_ ref f
  new `seq` return (old, new)

atomicSwapIORef :: IORef a -> a -> IO a
atomicSwapIORef ref new =
  atomicModifyIORef ref $ \ old -> (new, old)

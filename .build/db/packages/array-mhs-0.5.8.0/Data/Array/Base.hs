-- Copyright 2001 The University of Glasgow
-- Copyright 2023 Lennart Augustsson
-- See LICENSE file for full license.
module Data.Array.Base where
import Control.Monad.ST
import Data.Bits
import Data.Coerce
import Data.Int
import Data.Ix
import Data.Word
import Foreign.Ptr
import Foreign.StablePtr
import qualified Mhs.Array as Arr
import Mhs.MutUArr
import Mhs.UArr
import Text.Read(expectP, parens, Read(..))
import Text.Show(appPrec)
import Text.ParserCombinators.ReadPrec(prec, ReadPrec, step)
import Text.Read.Lex(Lexeme(Ident))
import Unsafe.Coerce

import Data.Array.IOArray
import Data.Array.STArray

--------------------------

class IArray a e where
  bounds           :: Ix i => a i e -> (i,i)
  numElements      :: Ix i => a i e -> Int
  unsafeArray      :: Ix i => (i,i) -> [(Int, e)] -> a i e
  unsafeAt         :: Ix i => a i e -> Int -> e
  unsafeReplace    :: Ix i => a i e -> [(Int, e)] -> a i e
  unsafeAccum      :: Ix i => (e -> e' -> e) -> a i e -> [(Int, e')] -> a i e
  unsafeAccumArray :: Ix i => (e -> e' -> e) -> e -> (i,i) -> [(Int, e')] -> a i e

  unsafeReplace arr ies = runST (unsafeReplaceST arr ies >>= unsafeFreeze)
  unsafeAccum f arr ies = runST (unsafeAccumST f arr ies >>= unsafeFreeze)
  unsafeAccumArray f e lu ies = runST (unsafeAccumArrayST f e lu ies >>= unsafeFreeze)

safeRangeSize :: Ix i => (i, i) -> Int
safeRangeSize (l,u) = let r = rangeSize (l, u)
                      in if r < 0 then error "Negative range size"
                                  else r

safeIndex :: Ix i => (i, i) -> Int -> i -> Int
safeIndex (l,u) n i = let i' = index (l,u) i
                      in if (0 <= i') && (i' < n)
                         then i'
                         else error ("Error in array index; " ++ show i' ++
                                     " not in range [0.." ++ show n ++ ")")

unsafeReplaceST :: (IArray a e, Ix i) => a i e -> [(Int, e)] -> ST s (STArray s i e)
unsafeReplaceST arr ies = do
  marr <- thaw arr
  sequence_ [unsafeWrite marr i e | (i, e) <- ies]
  return marr

unsafeAccumST :: (IArray a e, Ix i) => (e -> e' -> e) -> a i e -> [(Int, e')] -> ST s (STArray s i e)
unsafeAccumST f arr ies = do
  marr <- thaw arr
  sequence_ [do old <- unsafeRead marr i
                unsafeWrite marr i (f old new)
            | (i, new) <- ies]
  return marr

unsafeAccumArrayST :: Ix i => (e -> e' -> e) -> e -> (i,i) -> [(Int, e')] -> ST s (STArray s i e)
unsafeAccumArrayST f e (l,u) ies = do
  marr <- newArray (l,u) e
  sequence_ [do old <- unsafeRead marr i
                unsafeWrite marr i (f old new)
            | (i, new) <- ies]
  return marr

array   :: (IArray a e, Ix i)
        => (i,i)        -- ^ bounds of the array: (lowest,highest)
        -> [(i, e)]     -- ^ list of associations
        -> a i e
array (l,u) ies =
  let n = safeRangeSize (l,u)
  in unsafeArray (l,u)
                 [(safeIndex (l,u) n i, e) | (i, e) <- ies]

listArray :: (IArray a e, Ix i) => (i,i) -> [e] -> a i e
listArray (l,u) es =
  let n = safeRangeSize (l,u)
  in unsafeArray (l,u) (zip [0 .. n - 1] es)

genArray :: (IArray a e, Ix i) => (i,i) -> (i -> e) -> a i e
genArray (l,u) f = listArray (l,u) $ map f $ range (l,u)

listArrayST :: Ix i => (i,i) -> [e] -> ST s (STArray s i e)
listArrayST = newListArray

listUArrayST :: (MArray (STUArray s) e (ST s), Ix i)
             => (i,i) -> [e] -> ST s (STUArray s i e)
listUArrayST = newListArray

(!) :: (IArray a e, Ix i) => a i e -> i -> e
(!) arr i = case bounds arr of
              (l,u) -> unsafeAt arr $ safeIndex (l,u) (numElements arr) i

(!?) :: (IArray a e, Ix i) => a i e -> i -> Maybe e
(!?) arr i = let b = bounds arr in
             if inRange b i
             then Just $ unsafeAt arr $ unsafeIndex b i
             else Nothing

indices :: (IArray a e, Ix i) => a i e -> [i]
indices arr = case bounds arr of (l,u) -> range (l,u)

elems :: (IArray a e, Ix i) => a i e -> [e]
elems arr = [unsafeAt arr i | i <- [0 .. numElements arr - 1]]

assocs :: (IArray a e, Ix i) => a i e -> [(i, e)]
assocs arr = case bounds arr of
  (l,u) -> [(i, arr ! i) | i <- range (l,u)]

accumArray :: (IArray a e, Ix i)
           => (e -> e' -> e)     -- ^ An accumulating function
           -> e                  -- ^ A default element
           -> (i,i)              -- ^ The bounds of the array
           -> [(i, e')]          -- ^ List of associations
           -> a i e              -- ^ Returns: the array
accumArray f initialValue (l,u) ies =
  let n = safeRangeSize (l, u)
  in unsafeAccumArray f initialValue (l,u)
                      [(safeIndex (l,u) n i, e) | (i, e) <- ies]

(//) :: (IArray a e, Ix i) => a i e -> [(i, e)] -> a i e
arr // ies = case bounds arr of
  (l,u) -> unsafeReplace arr [ (safeIndex (l,u) (numElements arr) i, e)
                             | (i, e) <- ies]

accum :: (IArray a e, Ix i) => (e -> e' -> e) -> a i e -> [(i, e')] -> a i e
accum f arr ies = case bounds arr of
  (l,u) -> let n = numElements arr
           in unsafeAccum f arr [(safeIndex (l,u) n i, e) | (i, e) <- ies]

amap :: (IArray a e', IArray a e, Ix i) => (e' -> e) -> a i e' -> a i e
amap f arr = case bounds arr of
  (l,u) -> let n = numElements arr
           in unsafeArray (l,u) [ (i, f (unsafeAt arr i))
                                | i <- [0 .. n - 1]]

ixmap :: (IArray a e, Ix i, Ix j) => (i,i) -> (i -> j) -> a j e -> a i e
ixmap (l,u) f arr =
  array (l,u) [(i, arr ! f i) | i <- range (l,u)]

foldrArray :: (IArray a e, Ix i) => (e -> b -> b) -> b -> a i e -> b
foldrArray f z = \a ->
  let !n = numElements a
      go i | i >= n = z
           | otherwise = f (unsafeAt a i) (go (i+1))
  in go 0

foldlArray' :: (IArray a e, Ix i) => (b -> e -> b) -> b -> a i e -> b
foldlArray' f z0 = \a ->
  let !n = numElements a
      go !z i | i >= n = z
              | otherwise = go (f z (unsafeAt a i)) (i+1)
  in go z0 0

foldlArray :: (IArray a e, Ix i) => (b -> e -> b) -> b -> a i e -> b
foldlArray f z = \a ->
  let !n = numElements a
      go i | i < 0 = z
           | otherwise = f (go (i-1)) (unsafeAt a i)
  in go (n-1)

foldrArray' :: (IArray a e, Ix i) => (e -> b -> b) -> b -> a i e -> b
foldrArray' f z0 = \a ->
  let !n = numElements a
      go i !z | i < 0 = z
              | otherwise = go (i-1) (f (unsafeAt a i) z)
  in go (n-1) z0

traverseArray_
    :: (IArray a e, Ix i, Applicative f) => (e -> f b) -> a i e -> f ()
traverseArray_ f = foldrArray (\x z -> f x *> z) (pure ())

forArray_ :: (IArray a e, Ix i, Applicative f) => a i e -> (e -> f b) -> f ()
forArray_ = flip traverseArray_

foldlArrayM'
     :: (IArray a e, Ix i, Monad m) => (b -> e -> m b) -> b -> a i e -> m b
foldlArrayM' f z0 = \a ->
  let !n = numElements a
      go !z i | i >= n = pure z
              | otherwise = do
                  z' <- f z (unsafeAt a i)
                  go z' (i+1)
  in go z0 0

foldrArrayM'
    :: (IArray a e, Ix i, Monad m) => (e -> b -> m b) -> b -> a i e -> m b
foldrArrayM' f z0 = \a ->
  let !n = numElements a
      go i !z | i < 0 = pure z
              | otherwise = do
                  z' <- f (unsafeAt a i) z
                  go (i-1) z'
  in go (n-1) z0

instance IArray Arr.Array e where
  bounds           = Arr.bounds
  numElements      = Arr.numElements
  unsafeArray      = Arr.unsafeArray
  unsafeAt         = Arr.unsafeAt
  unsafeReplace    = Arr.unsafeReplace
  unsafeAccum      = Arr.unsafeAccum
--    unsafeAccumArray = Arr.unsafeAccumArray

unsafeArrayUArray :: (MArray (STUArray s) e (ST s), Ix i)
                  => (i,i) -> [(Int, e)] -> e -> ST s (UArray i e)
unsafeArrayUArray (l,u) ies default_elem = do
  marr <- newArray (l,u) default_elem
  sequence_ [unsafeWrite marr i e | (i, e) <- ies]
  unsafeFreezeSTUArray marr

unsafeFreezeSTUArray :: STUArray s i e -> ST s (UArray i e)
unsafeFreezeSTUArray (STUArray lu n a) =
  UArray lu n <$> unsafeFreezeMutSTUArr a

unsafeReplaceUArray :: (MArray (STUArray s) e (ST s), Ix i)
                    => UArray i e -> [(Int, e)] -> ST s (UArray i e)
unsafeReplaceUArray arr ies = do
  marr <- thawSTUArray arr
  sequence_ [unsafeWrite marr i e | (i, e) <- ies]
  unsafeFreezeSTUArray marr

unsafeAccumUArray :: (MArray (STUArray s) e (ST s), Ix i)
                  => (e -> e' -> e) -> UArray i e -> [(Int, e')] -> ST s (UArray i e)
unsafeAccumUArray f arr ies = do
  marr <- thawSTUArray arr
  sequence_ [do old <- unsafeRead marr i
                unsafeWrite marr i (f old new)
            | (i, new) <- ies]
  unsafeFreezeSTUArray marr

unsafeAccumArrayUArray :: (MArray (STUArray s) e (ST s), Ix i)
                       => (e -> e' -> e) -> e -> (i,i) -> [(Int, e')] -> ST s (UArray i e)
unsafeAccumArrayUArray f initialValue (l,u) ies = do
  marr <- newArray (l,u) initialValue
  sequence_ [do old <- unsafeRead marr i
                unsafeWrite marr i (f old new)
            | (i, new) <- ies]
  unsafeFreezeSTUArray marr

eqUArray :: (IArray UArray e, Ix i, Eq e) => UArray i e -> UArray i e -> Bool
eqUArray arr1@(UArray lu1 n1 _) arr2@(UArray lu2 n2 _) =
  if n1 == 0 then n2 == 0 else
  lu1 == lu2 &&
  and [unsafeAt arr1 i == unsafeAt arr2 i | i <- [0 .. n1 - 1]]

cmpUArray :: (IArray UArray e, Ix i, Ord e) => UArray i e -> UArray i e -> Ordering
cmpUArray arr1 arr2 = compare (assocs arr1) (assocs arr2)

-----------------------------------------------------------------------------
-- Showing and Reading IArrays

showsIArray :: (IArray a e, Ix i, Show i, Show e) => Int -> a i e -> ShowS
showsIArray p a =
  showParen (p > appPrec) $
  showString "array " .
  shows (bounds a) .
  showChar ' ' .
  shows (assocs a)

readIArray :: (IArray a e, Ix i, Read i, Read e) => ReadPrec (a i e)
readIArray = parens $ prec appPrec $
  do expectP (Ident "array")
     theBounds <- step readPrec
     vals   <- step readPrec
     return (array theBounds vals)

-----------------------------------------------------------------------------
-- Flat unboxed arrays: instances

data UArray i e = UArray (i, i) !Int (UArr e)

instance IArray UArray Bool where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies False)
  unsafeAt (UArray _ _ a) i = error "XXX unimplemented" -- unsafeReadUArr a q .&. 1

instance IArray UArray Char where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies '\0')
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Int where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Word where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray (Ptr a) where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies nullPtr)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray (FunPtr a) where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies (castPtrToFunPtr nullPtr))
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Float where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Double where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray (StablePtr a) where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies (castPtrToStablePtr nullPtr))
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Int8 where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Int16 where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Int32 where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Int64 where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Word8 where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Word16 where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Word32 where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance IArray UArray Word64 where
  bounds (UArray lu _ _) = lu
  numElements (UArray _ n _) = n
  unsafeArray lu ies = runST (unsafeArrayUArray lu ies 0)
  unsafeAt (UArray _ _ a) i = unsafeReadUArr a i
  unsafeReplace arr ies = runST (unsafeReplaceUArray arr ies)
  unsafeAccum f arr ies = runST (unsafeAccumUArray f arr ies)
  unsafeAccumArray f initialValue lu ies = runST (unsafeAccumArrayUArray f initialValue lu ies)

instance (Ix ix, Eq e, IArray UArray e) => Eq (UArray ix e) where
  (==) = eqUArray

instance (Ix ix, Ord e, IArray UArray e) => Ord (UArray ix e) where
  compare = cmpUArray

instance (Ix ix, Show ix, Show e, IArray UArray e) => Show (UArray ix e) where
  showsPrec = showsIArray

instance (Ix ix, Read ix, Read e, IArray UArray e) => Read (UArray ix e) where
  readPrec = readIArray

-----------------------------------------------------------------------------
-- Mutable arrays

arrEleBottom :: a
arrEleBottom = error "MArray: undefined array element"

class (Monad m) => MArray a e m where
  getBounds       :: Ix i => a i e -> m (i,i)
  getNumElements  :: Ix i => a i e -> m Int
  newArray        :: Ix i => (i,i) -> e -> m (a i e)
  newArray_       :: Ix i => (i,i) -> m (a i e)
  unsafeNewArray_ :: Ix i => (i,i) -> m (a i e)
  unsafeRead      :: Ix i => a i e -> Int -> m e
  unsafeWrite     :: Ix i => a i e -> Int -> e -> m ()

  newArray (l,u) initialValue = do
      let n = safeRangeSize (l,u)
      marr <- unsafeNewArray_ (l,u)
      sequence_ [unsafeWrite marr i initialValue | i <- [0 .. n - 1]]
      return marr
  unsafeNewArray_ (l,u) = newArray (l,u) arrEleBottom
  newArray_ (l,u) = newArray (l,u) arrEleBottom

instance MArray IOArray e IO where
  getBounds   = return . boundsIOArray
  getNumElements = return . numElementsIOArray
  newArray    = newIOArray
  unsafeRead  = unsafeReadIOArray
  unsafeWrite = unsafeWriteIOArray

newListArray :: (MArray a e m, Ix i) => (i,i) -> [e] -> m (a i e)
newListArray (l,u) es = do
  marr <- newArray_ (l,u)
  let n = safeRangeSize (l,u)
      f x k i
          | i == n    = return ()
          | otherwise = unsafeWrite marr i x >> k (i+1)
  foldr f (\ !_i -> return ()) es 0
  -- The bang above is important for GHC for unbox the Int.
  return marr

newGenArray :: (MArray a e m, Ix i) => (i,i) -> (i -> m e) -> m (a i e)
newGenArray bnds f = do
  let n = safeRangeSize bnds
  marr <- unsafeNewArray_ bnds
  let g ix k i
          | i == n    = return ()
          | otherwise = do
              x <- f ix
              unsafeWrite marr i x
              k (i+1)
  foldr g (\ !_i -> return ()) (range bnds) 0
  -- The bang above is important for GHC for unbox the Int.
  return marr

readArray :: (MArray a e m, Ix i) => a i e -> i -> m e
readArray marr i = do
  (l,u) <- getBounds marr
  n <- getNumElements marr
  unsafeRead marr (safeIndex (l,u) n i)

writeArray :: (MArray a e m, Ix i) => a i e -> i -> e -> m ()
writeArray marr i e = do
  (l,u) <- getBounds marr
  n <- getNumElements marr
  unsafeWrite marr (safeIndex (l,u) n i) e

modifyArray :: (MArray a e m, Ix i) => a i e -> i -> (e -> e) -> m ()
modifyArray marr i f = do
  (l,u) <- getBounds marr
  n <- getNumElements marr
  let idx = safeIndex (l,u) n i
  x <- unsafeRead marr idx
  unsafeWrite marr idx (f x)

modifyArray' :: (MArray a e m, Ix i) => a i e -> i -> (e -> e) -> m ()
modifyArray' marr i f = do
  (l,u) <- getBounds marr
  n <- getNumElements marr
  let idx = safeIndex (l,u) n i
  x <- unsafeRead marr idx
  let !x' = f x
  unsafeWrite marr idx x'

getElems :: (MArray a e m, Ix i) => a i e -> m [e]
getElems marr = do
  (_l, _u) <- getBounds marr
  n <- getNumElements marr
  sequence [unsafeRead marr i | i <- [0 .. n - 1]]

getAssocs :: (MArray a e m, Ix i) => a i e -> m [(i, e)]
getAssocs marr = do
  (l,u) <- getBounds marr
  n <- getNumElements marr
  sequence [ do e <- unsafeRead marr (safeIndex (l,u) n i); return (i,e)
           | i <- range (l,u)]

mapArray :: (MArray a e' m, MArray a e m, Ix i) => (e' -> e) -> a i e' -> m (a i e)
mapArray f marr = do
  (l,u) <- getBounds marr
  n <- getNumElements marr
  marr' <- newArray_ (l,u)
  sequence_ [do e <- unsafeRead marr i
                unsafeWrite marr' i (f e)
            | i <- [0 .. n - 1]]
  return marr'

mapIndices :: (MArray a e m, Ix i, Ix j) => (i,i) -> (i -> j) -> a j e -> m (a i e)
mapIndices (l',u') f marr = do
    marr' <- newArray_ (l',u')
    n' <- getNumElements marr'
    sequence_ [do e <- readArray marr (f i')
                  unsafeWrite marr' (safeIndex (l',u') n' i') e
              | i' <- range (l',u')]
    return marr'

foldlMArray' :: (MArray a e m, Ix i) => (b -> e -> b) -> b -> a i e -> m b
foldlMArray' f = foldlMArrayM' (\z x -> pure (f z x))

foldrMArray' :: (MArray a e m, Ix i) => (e -> b -> b) -> b -> a i e -> m b
foldrMArray' f = foldrMArrayM' (\x z -> pure (f x z))

foldlMArrayM' :: (MArray a e m, Ix i) => (b -> e -> m b) -> b -> a i e -> m b
foldlMArrayM' f z0 = \a -> do
    !n <- getNumElements a
    let go !z i | i >= n = pure z
                | otherwise = do
                    x <- unsafeRead a i
                    z' <- f z x
                    go z' (i+1)
    go z0 0

foldrMArrayM' :: (MArray a e m, Ix i) => (e -> b -> m b) -> b -> a i e -> m b
foldrMArrayM' f z0 = \a -> do
    !n <- getNumElements a
    let go i !z | i < 0 = pure z
                | otherwise = do
                    x <- unsafeRead a i
                    z' <- f x z
                    go (i-1) z'
    go (n-1) z0

mapMArrayM_ :: (MArray a e m, Ix i) => (e -> m b) -> a i e -> m ()
mapMArrayM_ f = \a -> do
    !n <- getNumElements a
    let go i | i >= n = pure ()
             | otherwise = do
                 x <- unsafeRead a i
                 _ <- f x
                 go (i+1)
    go 0

forMArrayM_ :: (MArray a e m, Ix i) => a i e -> (e -> m b) -> m ()
forMArrayM_ = flip mapMArrayM_

-----------------------------------------------------------------------------
-- Polymorphic non-strict mutable arrays (ST monad)

instance MArray (STArray s) e (ST s) where
    getBounds      = return . boundsSTArray
    getNumElements = return . numElementsSTArray
    newArray       = newSTArray
    unsafeRead     = unsafeReadSTArray
    unsafeWrite    = unsafeWriteSTArray

{-
instance MArray (STArray s) e (Lazy.ST s) where
    getBounds arr       = strictToLazyST (return $! ArrST.boundsSTArray arr)
    getNumElements arr  = strictToLazyST (return $! ArrST.numElementsSTArray arr)
    newArray (l,u) e    = strictToLazyST (ArrST.newSTArray (l,u) e)
    unsafeRead arr i    = strictToLazyST (ArrST.unsafeReadSTArray arr i)
    unsafeWrite arr i e = strictToLazyST (ArrST.unsafeWriteSTArray arr i e)
-}

data STUArray s i e = STUArray (i,i) !Int (MutSTUArr s e)

instance Eq (STUArray s i e) where
  STUArray _ _ (MutSTUArr (MutIOUArr bs1)) == STUArray _ _ (MutSTUArr (MutIOUArr bs2)) =
    sameByteString bs1 bs2

instance MArray (STUArray s) Bool (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  newArray lu initialValue = STUArray lu n . cast <$> newMutSTUArrB (if initialValue then 0xff else 0) n'
    where n = safeRangeSize lu
          n' = (n `divUp` _wordSize) * (_wordSize `div` 8)
          cast :: MutSTUArr s Word8 -> MutSTUArr s Bool
          cast = coerce
  unsafeNewArray_ lu = STUArray lu n . cast <$> newMutSTUArr n'
    where n = safeRangeSize lu
          n' = n `divUp` _wordSize
          cast :: MutSTUArr s Word -> MutSTUArr s Bool
          cast = coerce
  newArray_ arrBounds = newArray arrBounds False
  unsafeRead (STUArray _ _ a) i = do
    let (q, r) = quotRem i _wordSize
        cast :: MutSTUArr s Bool -> MutSTUArr s Word
        cast = coerce
    w <- unsafeReadMutSTUArr (cast a) q
    return $! (w .&. (1 `unsafeShiftL` r)) /= 0
  unsafeWrite (STUArray _ _ a) i e = do
    let (q, r) = quotRem i _wordSize
        cast :: MutSTUArr s Bool -> MutSTUArr s Word
        cast = coerce
    w <- unsafeReadMutSTUArr (cast a) q
    let w' = if e then w .|. b else w .&. complement b
        b = 1 `unsafeShiftL` r
    unsafeWriteMutSTUArr (cast a) q w'

divUp :: Int -> Int -> Int
divUp x y = (x + (y-1)) `quot` y

instance MArray (STUArray s) Char (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu '\0'
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Int (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Word (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) (Ptr a) (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu nullPtr
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) (FunPtr a) (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu nullFunPtr
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Float (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Double (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) (StablePtr a) (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu (castPtrToStablePtr nullPtr)
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Int8 (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Int16 (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Int32 (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Int64 (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Word8 (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Word16 (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Word32 (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

instance MArray (STUArray s) Word64 (ST s) where
  getBounds (STUArray lu _ _) = return lu
  getNumElements (STUArray _ n _) = return n
  unsafeNewArray_ lu = STUArray lu n <$> newMutSTUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (STUArray _ _ a) i = unsafeReadMutSTUArr a i
  unsafeWrite (STUArray _ _ a) i e = unsafeWriteMutSTUArr a i e

-----------------------------------------------------------------------------
-- Freezing

-- | Converts a mutable array (any instance of 'MArray') to an
-- immutable array (any instance of 'IArray') by taking a complete
-- copy of it.
freeze :: (Ix i, MArray a e m, IArray b e) => a i e -> m (b i e)
freeze marr = do
  (l,u) <- getBounds marr
  n <- getNumElements marr
  es <- mapM (unsafeRead marr) [0 .. n - 1]
  -- The old array and index might not be well-behaved, so we need to
  -- use the safe array creation function here.
  return (listArray (l,u) es)

freezeSTUArray :: STUArray s i e -> ST s (UArray i e)
freezeSTUArray (STUArray lu n a) = UArray lu n . copyUArr <$> unsafeFreezeMutSTUArr a

unsafeFreeze :: (Ix i, MArray a e m, IArray b e) => a i e -> m (b i e)
unsafeFreeze = freeze

-----------------------------------------------------------------------------
-- Thawing

thaw :: (Ix i, IArray a e, MArray b e m) => a i e -> m (b i e)
thaw arr = case bounds arr of
  (l,u) -> do
    marr <- newArray_ (l,u)
    let n = safeRangeSize (l,u)
    sequence_ [ unsafeWrite marr i (unsafeAt arr i)
              | i <- [0 .. n - 1]]
    return marr

thawSTUArray :: UArray i e -> ST s (STUArray s i e)
thawSTUArray (UArray lu n a) = STUArray lu n <$> unsafeThawSTUArr (copyUArr a)

unsafeThaw :: (Ix i, IArray a e, MArray b e m) => a i e -> m (b i e)
unsafeThaw = thaw

-- | Casts an 'STUArray' with one element type into one with a
-- different element type.  All the elements of the resulting array
-- are undefined (unless you know what you\'re doing...).

castSTUArray :: STUArray s ix a -> ST s (STUArray s ix b)
castSTUArray a = return (unsafeCoerce a)

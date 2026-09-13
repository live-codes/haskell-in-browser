{-# LANGUAGE
    FlexibleInstances
  , MultiParamTypeClasses
  , RoleAnnotations
 #-}

{-# OPTIONS_HADDOCK not-home #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Array.IO.Internal
-- Copyright   :  (c) The University of Glasgow 2001-2012
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  non-portable (uses Data.Array.Base)
--
-- Mutable boxed and unboxed arrays in the IO monad.
--
-- = WARNING
--
-- This module is considered __internal__.
--
-- The Package Versioning Policy __does not apply__.
--
-- The contents of this module may change __in any way whatsoever__
-- and __without any warning__ between minor versions of this package.
--
-- Authors importing this module are expected to track development
-- closely.
--
-----------------------------------------------------------------------------

module Data.Array.IO.Internals (
    IOArray(..),         -- instance of: Eq, Typeable
    IOUArray(..),        -- instance of: Eq, Typeable
    castIOUArray,        -- :: IOUArray ix a -> IO (IOUArray ix b)
    unsafeThawIOUArray,
    unsafeFreezeIOUArray
  ) where
import Data.Bits
import Data.Coerce
import Data.Int
import Data.Word
import Foreign.Ptr
import Foreign.StablePtr
import Data.Array.Base
import Mhs.MutUArr
import Mhs.UArr
import Unsafe.Coerce
import Data.Array.IOArray

data IOUArray i e = IOUArray (i,i) !Int (MutIOUArr e)

{-
instance Eq (IOUArray i e) where
    IOUArray s1 == IOUArray s2  =  s1 == s2
-}

instance MArray IOUArray Bool IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  newArray lu initialValue = IOUArray lu n . cast <$> newMutIOUArrB (if initialValue then 0xff else 0) n'
    where n = safeRangeSize lu
          n' = (n `divUp` _wordSize) * (_wordSize `div` 8)
          cast :: MutIOUArr Word8 -> MutIOUArr Bool
          cast = coerce
  unsafeNewArray_ lu = IOUArray lu n . cast <$> newMutIOUArr n'
    where n = safeRangeSize lu
          n' = n `divUp` _wordSize
          cast :: MutIOUArr Word -> MutIOUArr Bool
          cast = coerce
  newArray_ arrBounds = newArray arrBounds False
  unsafeRead (IOUArray _ _ a) i = do
    let (q, r) = quotRem i _wordSize
        cast :: MutIOUArr Bool -> MutIOUArr Word
        cast = coerce
    w <- unsafeReadMutIOUArr (cast a) q
    return $! (w .&. (1 `unsafeShiftL` r)) /= 0
  unsafeWrite (IOUArray _ _ a) i e = do
    let (q, r) = quotRem i _wordSize
        cast :: MutIOUArr Bool -> MutIOUArr Word
        cast = coerce
    w <- unsafeReadMutIOUArr (cast a) q
    let w' = if e then w .|. b else w .&. complement b
        b = 1 `unsafeShiftL` r
    unsafeWriteMutIOUArr (cast a) q w'

instance MArray IOUArray Char IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu '\0'
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Int IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Word IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray (Ptr a) IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu nullPtr
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray (FunPtr a) IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu (castPtrToFunPtr nullPtr)
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Float IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Double IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray (StablePtr a) IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu (castPtrToStablePtr nullPtr)
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Int8 IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Int16 IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Int32 IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Int64 IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Word8 IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Word16 IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Word32 IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

instance MArray IOUArray Word64 IO where
  getBounds (IOUArray lu _ _) = return lu
  getNumElements (IOUArray _ n _) = return n
  unsafeNewArray_ lu = IOUArray lu n <$> newMutIOUArr n where n = safeRangeSize lu
  newArray_ lu = newArray lu 0
  unsafeRead (IOUArray _ _ a) i = unsafeReadMutIOUArr a i
  unsafeWrite (IOUArray _ _ a) i e = unsafeWriteMutIOUArr a i e

-- | Casts an 'IOUArray' with one element type into one with a
-- different element type.  All the elements of the resulting array
-- are undefined (unless you know what you\'re doing...).
castIOUArray :: IOUArray ix a -> IO (IOUArray ix b)
castIOUArray a = return (unsafeCoerce a)

unsafeThawIOUArray :: UArray ix e -> IO (IOUArray ix e)
unsafeThawIOUArray (UArray lu n a) = IOUArray lu n <$> unsafeThawIOUArr a

thawIOUArray :: UArray ix e -> IO (IOUArray ix e)
thawIOUArray (UArray lu n a) = IOUArray lu n <$> unsafeThawIOUArr (copyUArr a)

unsafeFreezeIOUArray :: IOUArray ix e -> IO (UArray ix e)
unsafeFreezeIOUArray (IOUArray lu n a) = UArray lu n <$> unsafeFreezeMutIOUArr a

freezeIOUArray :: IOUArray ix e -> IO (UArray ix e)
freezeIOUArray (IOUArray lu n a) = UArray lu n . copyUArr <$> unsafeFreezeMutIOUArr a

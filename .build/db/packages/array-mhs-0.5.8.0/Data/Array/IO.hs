{-# LANGUAGE MagicHash, Trustworthy, UnliftedFFITypes #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Array.IO
-- Copyright   :  (c) The University of Glasgow 2001
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  non-portable (uses Data.Array.MArray)
--
-- Mutable boxed and unboxed arrays in the IO monad.
--
-----------------------------------------------------------------------------

module Data.Array.IO (
    -- * @IO@ arrays with boxed elements
    IOArray,             -- instance of: Eq, Typeable

    -- * @IO@ arrays with unboxed elements
    IOUArray,            -- instance of: Eq, Typeable

    -- * Overloaded mutable array interface
    module Data.Array.MArray,

    -- * Doing I\/O with @IOUArray@s
    hGetArray,           -- :: Handle -> IOUArray Int Word8 -> Int -> IO Int
    hPutArray,           -- :: Handle -> IOUArray Int Word8 -> Int -> IO ()
  ) where

import Data.Array.Base
import Data.Array.IOArray
import Data.Array.IO.Internals
import Data.Array.MArray
import Foreign
import Foreign.C
import Mhs.MutUArr(withMutIOUArr)
import System.IO
import System.IO.Error

-- ---------------------------------------------------------------------------
-- hGetArray

-- | Reads a number of 'Word8's from the specified 'Handle' directly
-- into an array.
hGetArray
        :: Handle               -- ^ Handle to read from
        -> IOUArray Int Word8   -- ^ Array in which to place the values
        -> Int                  -- ^ Number of 'Word8's to read
        -> IO Int
                -- ^ Returns: the number of 'Word8's actually
                -- read, which might be smaller than the number requested
                -- if the end of file was reached.

hGetArray handle (IOUArray _lu n arr) count
  | count == 0              = return 0
  | count < 0 || count > n  = illegalBufferSize handle "hGetArray" count
  | otherwise = withMutIOUArr arr $ \ p -> hGetBuf handle p count


-- ---------------------------------------------------------------------------
-- hPutArray

-- | Writes an array of 'Word8' to the specified 'Handle'.
hPutArray
        :: Handle                       -- ^ Handle to write to
        -> IOUArray Int Word8           -- ^ Array to write from
        -> Int                          -- ^ Number of 'Word8's to write
        -> IO ()

hPutArray handle (IOUArray _lu n arr) count
  | count == 0              = return ()
  | count < 0 || count > n  = illegalBufferSize handle "hPutArray" count
  | otherwise = withMutIOUArr arr $ \ p -> hPutBuf handle p count

-- ---------------------------------------------------------------------------
-- Internal Utils

illegalBufferSize :: Handle -> String -> Int -> IO a
illegalBufferSize handle fn sz =
        ioException (ioeSetErrorString
                     (mkIOError InvalidArgument fn (Just handle) Nothing)
                     ("illegal buffer size " ++ showsPrec 9 (sz::Int) []))

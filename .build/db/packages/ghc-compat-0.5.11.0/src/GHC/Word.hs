module GHC.Word where
import Data.Word

type Word# = Word
pattern W# :: Word# -> Word
pattern W# x = x

type Word8# = Word8
pattern W8# :: Word8# -> Word8
pattern W8# x = x

type Word16# = Word16
pattern W16# :: Word16# -> Word16
pattern W16# x = x

type Word32# = Word32
pattern W32# :: Word32# -> Word32
pattern W32# x = x

type Word64# = Word64
pattern W64# :: Word64# -> Word64
pattern W64# x = x

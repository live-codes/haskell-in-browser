module GHC.Float where
import Data.Word

castDoubleToWord64 :: Double -> Word64
castDoubleToWord64 = _primitive "fromDbl"

castFloatToWord32 :: Float -> Word32
castFloatToWord32 = _primitive "fromFlt"

castWord32ToFloat :: Word32 -> Float
castWord32ToFloat = _primitive "toFlt"

castWord64ToDouble :: Word64 -> Double
castWord64ToDouble = _primitive "toDbl"

double2Float :: Double -> Float
double2Float = _primitive "dtof"

double2Int :: Double -> Int
double2Int = _primitive "dtoi"

float2Double :: Float -> Double
float2Double = _primitive "ftod"

float2Int :: Float -> Int
float2Int = _primitive "ftoi"

int2Double :: Int -> Double
int2Double = _primitive "itod"

int2Float :: Int -> Float
int2Float = _primitive "itof"

word2Double :: Word -> Double
word2Double = _primitive "utod"

word2Float :: Word -> Float
word2Float = _primitive "utof"


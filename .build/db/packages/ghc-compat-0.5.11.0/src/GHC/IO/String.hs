module GHC.IO.String where
import Control.Exception
import GHC.Foreign
import GHC.IO.Encoding.Types

-- | Determines whether a character can be accurately encoded in a
-- 'Foreign.C.String.CString'.
--
-- Pretty much anyone who uses this function is in a state of sin because
-- whether or not a character is encodable will, in general, depend on the
-- context in which it occurs.
charIsRepresentable :: TextEncoding -> Char -> IO Bool
-- We force enc explicitly because `catch` is lazy in its
-- first argument. We would probably like to force c as well,
-- but unfortunately worker/wrapper produces very bad code for
-- that.
--
-- TODO If this function is performance-critical, it would probably
-- pay to use a single-character specialization of withCString. That
-- would allow worker/wrapper to actually eliminate Char boxes, and
-- would also get rid of the completely unnecessary cons allocation.
charIsRepresentable !enc c =
  withCString enc [c]
              (\cstr -> do str <- peekCString enc cstr
                           case str of
                             [ch] | ch == c -> pure True
                             _ -> pure False)
    `catch`
       \(_ :: IOException) -> pure False

-- Copyright   :  (c) The University of Glasgow 2015

module GHC.Stack (
    CallStack, HasCallStack, callStack, emptyCallStack, freezeCallStack,
    fromCallSiteList, getCallStack, popCallStack,
    pushCallStack, withFrozenCallStack,
    prettyCallStackLines, prettyCallStack,

    SrcLoc(..), prettySrcLoc,
  ) where
import Control.Error(errorWithoutStackTrace)
import Data.List(intercalate)

-- Fake call stacks.  They are always empty.
class HasCallStack
instance HasCallStack

callStack :: HasCallStack => CallStack
callStack = EmptyCallStack

----------------------------------

data CallStack
  = EmptyCallStack
  | PushCallStack [Char] SrcLoc CallStack
  | FreezeCallStack CallStack

getCallStack :: CallStack -> [([Char], SrcLoc)]
getCallStack stk = case stk of
  EmptyCallStack            -> []
  PushCallStack fn loc stk' -> (fn,loc) : getCallStack stk'
  FreezeCallStack stk'      -> getCallStack stk'

fromCallSiteList :: [([Char], SrcLoc)] -> CallStack
fromCallSiteList ((fn,loc):cs) = PushCallStack fn loc (fromCallSiteList cs)
fromCallSiteList []            = EmptyCallStack

pushCallStack :: ([Char], SrcLoc) -> CallStack -> CallStack
pushCallStack (fn, loc) stk = case stk of
  FreezeCallStack _ -> stk
  _                 -> PushCallStack fn loc stk

emptyCallStack :: CallStack
emptyCallStack = EmptyCallStack

freezeCallStack :: CallStack -> CallStack
freezeCallStack stk = FreezeCallStack stk

data SrcLoc = SrcLoc
  { srcLocPackage   :: [Char]
  , srcLocModule    :: [Char]
  , srcLocFile      :: [Char]
  , srcLocStartLine :: Int
  , srcLocStartCol  :: Int
  , srcLocEndLine   :: Int
  , srcLocEndCol    :: Int
  } deriving (Eq, Show)

popCallStack :: CallStack -> CallStack
popCallStack stk = case stk of
  EmptyCallStack         -> errorWithoutStackTrace "popCallStack: empty stack"
  PushCallStack _ _ stk' -> stk'
  FreezeCallStack _      -> stk

withFrozenCallStack :: HasCallStack
                    => ( HasCallStack => a )
                    -> a
withFrozenCallStack do_this = do_this
--  let ?callStack = freezeCallStack (popCallStack callStack)
--  in do_this

prettySrcLoc :: SrcLoc -> String
prettySrcLoc SrcLoc {..}
  = foldr (++) ""
      [ srcLocFile, ":"
      , show srcLocStartLine, ":"
      , show srcLocStartCol, " in "
      , srcLocPackage, ":", srcLocModule
      ]

prettyCallStack :: CallStack -> String
prettyCallStack = intercalate "\n" . prettyCallStackLines

prettyCallStackLines :: CallStack -> [String]
prettyCallStackLines cs = case getCallStack cs of
  []  -> []
  stk -> "CallStack (from HasCallStack):"
       : map (("  " ++) . prettyCallSite) stk
  where
    prettyCallSite (f, loc) = f ++ ", called at " ++ prettySrcLoc loc

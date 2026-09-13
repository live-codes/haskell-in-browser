module GHC.ST(
  ST(ST),
  pattern ST,
  ) where
import Control.Monad.ST(ST)
import GHC.Exts(State#, stToState, stateToST)

pattern ST :: (State# s -> (# State# s, a #)) -> ST s a
pattern ST x <- (stToState -> x)
  where ST x = stateToST x

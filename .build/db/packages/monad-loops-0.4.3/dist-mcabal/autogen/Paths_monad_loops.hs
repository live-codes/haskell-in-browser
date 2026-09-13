module Paths_monad_loops where
import Data.Version
version :: Version; version = makeVersion [0,4,3]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/monad-loops-0.4.3/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

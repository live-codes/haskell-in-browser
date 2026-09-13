module Paths_fingertree where
import Data.Version
version :: Version; version = makeVersion [0,1,6,3]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/fingertree-0.1.6.3/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

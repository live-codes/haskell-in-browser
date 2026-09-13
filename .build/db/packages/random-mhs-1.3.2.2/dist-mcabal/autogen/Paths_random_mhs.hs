module Paths_random_mhs where
import Data.Version
version :: Version; version = makeVersion [1,3,2,2]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/random-mhs-1.3.2.2/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

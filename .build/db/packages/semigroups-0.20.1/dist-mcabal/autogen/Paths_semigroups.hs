module Paths_semigroups where
import Data.Version
version :: Version; version = makeVersion [0,20,1]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/semigroups-0.20.1/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

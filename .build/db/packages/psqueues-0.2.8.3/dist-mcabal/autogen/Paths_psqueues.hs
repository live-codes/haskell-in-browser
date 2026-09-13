module Paths_psqueues where
import Data.Version
version :: Version; version = makeVersion [0,2,8,3]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/psqueues-0.2.8.3/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

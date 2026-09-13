module Paths_time where
import Data.Version
version :: Version; version = makeVersion [1,15]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/time-1.15/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

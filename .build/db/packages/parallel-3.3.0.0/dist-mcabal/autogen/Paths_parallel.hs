module Paths_parallel where
import Data.Version
version :: Version; version = makeVersion [3,3,0,0]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/parallel-3.3.0.0/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

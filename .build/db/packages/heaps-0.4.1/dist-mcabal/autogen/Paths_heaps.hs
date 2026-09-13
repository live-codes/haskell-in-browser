module Paths_heaps where
import Data.Version
version :: Version; version = makeVersion [0,4,1]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/heaps-0.4.1/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

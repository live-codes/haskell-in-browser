module Paths_unordered_containers where
import Data.Version
version :: Version; version = makeVersion [0,2,21]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/unordered-containers-0.2.21/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

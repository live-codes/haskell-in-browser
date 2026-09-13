module Paths_containers where
import Data.Version
version :: Version; version = makeVersion [0,8]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/containers-0.8/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

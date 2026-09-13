module Paths_async where
import Data.Version
version :: Version; version = makeVersion [2,2,6]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/async-2.2.6/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

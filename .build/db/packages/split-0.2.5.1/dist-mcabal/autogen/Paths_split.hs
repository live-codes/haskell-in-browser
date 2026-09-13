module Paths_split where
import Data.Version
version :: Version; version = makeVersion [0,2,5,1]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/split-0.2.5.1/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

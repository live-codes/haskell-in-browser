module Paths_array_mhs where
import Data.Version
version :: Version; version = makeVersion [0,5,8,0]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/array-mhs-0.5.8.0/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

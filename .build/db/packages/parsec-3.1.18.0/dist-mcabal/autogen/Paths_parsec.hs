module Paths_parsec where
import Data.Version
version :: Version; version = makeVersion [3,1,18,0]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/parsec-3.1.18.0/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

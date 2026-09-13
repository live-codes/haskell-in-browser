module Paths_transformers where
import Data.Version
version :: Version; version = makeVersion [0,6,2,0]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/transformers-0.6.2.0/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

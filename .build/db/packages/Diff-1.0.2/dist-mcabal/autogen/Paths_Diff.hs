module Paths_Diff where
import Data.Version
version :: Version; version = makeVersion [1,0,2]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/Diff-1.0.2/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

module Paths_filepath where
import Data.Version
version :: Version; version = makeVersion [1,5,5,0]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/filepath-1.5.5.0/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

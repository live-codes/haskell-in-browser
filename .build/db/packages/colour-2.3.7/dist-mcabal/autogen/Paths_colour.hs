module Paths_colour where
import Data.Version
version :: Version; version = makeVersion [2,3,7]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/colour-2.3.7/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

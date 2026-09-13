module Paths_edit_distance where
import Data.Version
version :: Version; version = makeVersion [0,2,2,1]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/edit-distance-0.2.2.1/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

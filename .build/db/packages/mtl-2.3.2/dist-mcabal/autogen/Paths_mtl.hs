module Paths_mtl where
import Data.Version
version :: Version; version = makeVersion [2,3,2]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/mtl-2.3.2/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

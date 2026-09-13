module Paths_splitmix where
import Data.Version
version :: Version; version = makeVersion [0,1,3,2]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/splitmix-0.1.3.2/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

module Paths_numbers where
import Data.Version
version :: Version; version = makeVersion [3000,2,0,2]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/numbers-3000.2.0.2/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

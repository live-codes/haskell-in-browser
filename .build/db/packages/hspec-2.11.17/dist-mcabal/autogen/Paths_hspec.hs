module Paths_hspec where
import Data.Version
version :: Version; version = makeVersion [2,11,17]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/hspec-2.11.17/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

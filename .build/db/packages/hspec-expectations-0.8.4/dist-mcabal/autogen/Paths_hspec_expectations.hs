module Paths_hspec_expectations where
import Data.Version
version :: Version; version = makeVersion [0,8,4]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/hspec-expectations-0.8.4/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

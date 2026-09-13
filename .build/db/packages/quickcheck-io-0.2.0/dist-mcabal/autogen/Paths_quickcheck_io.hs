module Paths_quickcheck_io where
import Data.Version
version :: Version; version = makeVersion [0,2,0]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/quickcheck-io-0.2.0/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

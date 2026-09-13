module Paths_data_ordlist where
import Data.Version
version :: Version; version = makeVersion [0,4,7,0]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/data-ordlist-0.4.7.0/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

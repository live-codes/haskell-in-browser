module Paths_os_string where
import Data.Version
version :: Version; version = makeVersion [2,0,10]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/os-string-2.0.10/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

module Paths_tagsoup where
import Data.Version
version :: Version; version = makeVersion [0,14,8]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/tagsoup-0.14.8/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

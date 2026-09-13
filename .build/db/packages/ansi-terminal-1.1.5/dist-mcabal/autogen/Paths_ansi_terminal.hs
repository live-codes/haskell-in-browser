module Paths_ansi_terminal where
import Data.Version
version :: Version; version = makeVersion [1,1,5]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/ansi-terminal-1.1.5/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

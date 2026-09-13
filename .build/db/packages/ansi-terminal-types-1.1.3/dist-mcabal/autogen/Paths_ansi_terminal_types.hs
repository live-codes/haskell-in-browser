module Paths_ansi_terminal_types where
import Data.Version
version :: Version; version = makeVersion [1,1,3]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/ansi-terminal-types-1.1.3/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

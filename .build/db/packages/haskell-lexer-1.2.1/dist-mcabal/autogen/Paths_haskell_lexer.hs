module Paths_haskell_lexer where
import Data.Version
version :: Version; version = makeVersion [1,2,1]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/haskell-lexer-1.2.1/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

module Paths_ghc_compat where
import Data.Version
version :: Version; version = makeVersion [0,5,11,0]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/ghc-compat-0.5.11.0/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

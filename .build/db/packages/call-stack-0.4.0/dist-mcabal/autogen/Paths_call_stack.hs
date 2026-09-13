module Paths_call_stack where
import Data.Version
version :: Version; version = makeVersion [0,4,0]
getDataDir :: IO FilePath; getDataDir = return "/db/mhs-0.16.6.0/packages/call-stack-0.4.0/data"
getDataFileName :: FilePath -> IO FilePath; getDataFileName name = fmap (++ '/' : name) getDataDir

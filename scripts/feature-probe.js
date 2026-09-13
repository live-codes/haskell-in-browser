'use strict';

/**
 * Probe which language features MicroHs accepts, by compiling+running a small
 * program per feature through the REPL (one process each).
 *
 *   node scripts/feature-probe.js
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const RUNNER = path.join(__dirname, 'node-repl-run.js');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'mhs-feat-'));

const HDR = 'module Main where\n';

const features = [
  ['ADT + deriving (Show, Eq)', 'data Colour = Red | Green deriving (Show, Eq)\nmain :: IO ()\nmain = print (Red == Red)\n'],
  ['typeclass + instance', 'class Greet a where greet :: a -> String\ndata P = P\ninstance Greet P where greet _ = "hi"\nmain :: IO ()\nmain = putStrLn (greet P)\n'],
  ['higher-kinded / Functor', 'mine :: Functor f => f Int -> f Int\nmine = fmap (+1)\nmain :: IO ()\nmain = print (mine (Just 1))\n'],
  ['Foldable/Traversable', 'main :: IO ()\nmain = print (traverse (\\x -> Just (x + 1)) [1, 2, 3])\n'],
  ['GADTs', 'data Expr a where\n  I :: Int -> Expr Int\n  B :: Bool -> Expr Bool\nevalI :: Expr Int -> Int\nevalI (I n) = n\nmain :: IO ()\nmain = print (evalI (I 7))\n'],
  ['RankNTypes', 'apply :: (forall a. a -> a) -> (Int, Bool)\napply f = (f 1, f True)\nmain :: IO ()\nmain = print (apply id)\n'],
  ['TypeApplications', 'main :: IO ()\nmain = print (read @Int "42")\n'],
  ['OverloadedStrings + Data.Text', 'import qualified Data.Text.IO as TIO\nmain :: IO ()\nmain = TIO.putStrLn "hello text"\n'],
  ['PatternSynonyms', 'pattern Zero :: Int\npattern Zero = 0\nmain :: IO ()\nmain = print (Zero == (0 :: Int))\n'],
  ['LambdaCase', 'f :: Maybe Int -> Int\nf = \\case\n  Just n -> n\n  Nothing -> 0\nmain :: IO ()\nmain = print (f (Just 3))\n'],
  ['MultiWayIf', 'main :: IO ()\nmain = print (if\n  | 1 > 2 -> "a"\n  | otherwise -> "b")\n'],
  ['DeriveFunctor', 'data Box a = Box a deriving (Functor, Show)\nmain :: IO ()\nmain = print (fmap (+1) (Box 1))\n'],
  ['Record dot syntax', 'data R = R { a :: Int, b :: Int }\nmain :: IO ()\nmain = print ((R { a = 1, b = 2 }).a)\n'],
  ['MultiParamTypeClasses + FunDeps', 'class Conv a b | a -> b where conv :: a -> b\ninstance Conv Int Bool where conv = (> 0)\nmain :: IO ()\nmain = print (conv (1 :: Int) :: Bool)\n'],
  ['ExistentialQuantification', 'data Any = forall a. Show a => MkAny a\nmain :: IO ()\nmain = print (case MkAny (3 :: Int) of MkAny v -> show v)\n'],
  ['list comprehension + laziness', 'main :: IO ()\nmain = print (take 5 [x * x | x <- [1 ..]])\n'],
  ['case / guards / where', 'f :: Int -> String\nf n\n  | n < 0 = "neg"\n  | otherwise = go n\n  where\n    go 0 = "zero"\n    go _ = "pos"\nmain :: IO ()\nmain = print (map f [-1, 0, 5])\n'],
  ['deriving (Eq, Ord, Enum, Bounded)', 'data D = A | B | C deriving (Eq, Ord, Enum, Bounded, Show)\nmain :: IO ()\nmain = print ([minBound .. maxBound] :: [D])\n'],
  ['DeriveGeneric', 'data P = P { x :: Int } deriving (Generic)\nmain :: IO ()\nmain = putStrLn "ok"\n'],
  ['TypeFamilies (expect fail)', 'type family F a\ntype instance F Int = Bool\nmain :: IO ()\nmain = putStrLn "ok"\n'],
  ['Template Haskell (expect fail)', 'main :: IO ()\nmain = print $( [| 1 + 1 |] )\n'],
  ['GeneralisedNewtypeDeriving', 'newtype Age = Age Int deriving (Num, Show, Eq)\nmain :: IO ()\nmain = print (Age 3 + Age 4)\n'],
  ['StandaloneDeriving', 'data T = T Int\nderiving instance Show T\nmain :: IO ()\nmain = print (T 5)\n'],
  ['ST + STRef (mutable state)', 'import Control.Monad.ST\nimport Data.STRef\nmain :: IO ()\nmain = print (runST (do\n  r <- newSTRef (0 :: Int)\n  mapM_ (\\i -> modifySTRef r (+ i)) [1 .. 10]\n  readSTRef r))\n'],
  ['ApplicativeDo (expect fail)', 'data Pair a = Pair a a\ninstance Functor Pair where fmap f (Pair a b) = Pair (f a) (f b)\ninstance Applicative Pair where\n  pure x = Pair x x\n  Pair f g <*> Pair a b = Pair (f a) (g b)\nmain :: IO ()\nmain = print (case do { x <- Pair 1 2; y <- Pair 3 4; pure (x + y) } of Pair p _ -> p)\n'],
  ['Data.Map (expect fail)', 'import qualified Data.Map as M\nmain :: IO ()\nmain = print (M.fromList [(1 :: Int, "a")])\n'],
];

let available = 0;
const rows = [];

for (const [name, body] of features) {
  const file = path.join(TMP, 'Main.hs');
  fs.writeFileSync(file, HDR + body);
  const proc = spawnSync(process.execPath, [RUNNER, '--file', file], {
    encoding: 'utf8',
    timeout: 90000,
  });
  let r;
  try {
    r = JSON.parse(proc.stdout.trim().split('\n').pop());
  } catch (err) {
    r = { output: null, error: 'unparseable: ' + proc.stdout + proc.stderr, exitCode: -1 };
  }
  const ok = !r.error;
  if (ok) available++;
  rows.push({ name, ok, output: r.output, error: r.error });
  console.log((ok ? 'OK   ' : 'FAIL ') + name + (ok ? '  -> ' + JSON.stringify(r.output) : ''));
  if (!ok) console.log('       ' + String(r.error).split('\n')[0]);
}

console.log(`\n${available}/${features.length} feature programs compiled and ran`);
fs.rmSync(TMP, { recursive: true, force: true });
process.exit(0);

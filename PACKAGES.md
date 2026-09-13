# Package support in the Haskell playground

What a user can and cannot import, and why. Written against the GHC boot libraries, since those
are what someone coming from `ghc` reasonably expects to be there without installing anything.

Three things make this list stable to reason about:

- the wasm embeds **`base`** (which in MicroHs is much larger than GHC's `base` — see below) plus
  `canvhs`;
- everything else is a MicroHs package, **lazily loaded** on first import — so shipping more
  costs nothing at boot;
- what ships is decided purely by which `.pkg` files are in `public/pkgs/packages/`.

The runtime enforces this list: an import that cannot be satisfied is reported from
`scripts/module-support.json` (via the manifest) with a reason, not as a bare
`Module not found`. See "When you hit a missing module" at the end, and
[BUILD.md](BUILD.md) for the mechanics of actually building and shipping a package.

## GHC boot libraries, one by one

The authoritative list is [`ghc/ghc/libraries/`](https://github.com/ghc/ghc/tree/master/libraries).

| boot library | here | notes |
| --- | --- | --- |
| `base` | **embedded** | MicroHs folds in `bytestring`, `text`, `deepseq`, `directory`, `stm`, `process`, plus `hashable` and `integer-logarithms` |
| `array` | shipped | as `array-mhs-0.5.8.0`, MicroHs's fork |
| `containers` | shipped | `Data.Map/Set/Sequence/IntMap/IntSet/Tree/Graph` |
| `transformers`, `mtl` | shipped | `Control.Monad.State/Reader/Writer/Except/RWS` |
| `exceptions` | shipped | |
| `filepath`, `os-string` | shipped | |
| `time` | shipped | |
| `parsec` | shipped | `Text.Parsec`, `Text.ParserCombinators.Parsec`, `Text.Parsec.String` |
| `pretty` | shipped | `Text.PrettyPrint` (+ `HughesPJ`) |
| `xhtml` | shipped | `Text.XHtml`; needs `semigroups` |
| `binary` | **built but withheld** | compiles, but `Data.Binary.Get` / `decode` loops forever — see below |
| `bytestring`, `text`, `deepseq`, `directory`, `stm`, `process` | embedded | inside MicroHs's `base` (no download) |
| `Cabal` | not applicable | a build tool |
| `hpc`, `haskeline`, `terminfo` | not applicable | coverage tooling, interactive line editing, terminal database |
| `template-haskell` | **impossible** | MicroHs has no Template Haskell. `ghc-compat` provides the *types* (`Language.Haskell.TH.Syntax`, `.Quote`), which do import |
| `ghc-bignum`, `ghc-boot(-th)`, `ghc-compact`, `ghc-experimental`, `ghc-heap`, `ghc-internal`, `ghc-platform`, `ghc-prim`, `ghci`, `integer-gmp`, `libffi-clib`, `semaphore-compat`, `file-io` | not applicable | GHC implementation internals (MicroHs uses its own runtime and `imath` for bignums) |
| `unix`, `Win32` | **impossible** | platform-specific; there is no POSIX or Win32 in a browser tab |
| `process` | embedded, **non-functional** | `System.Process` imports, but a browser cannot spawn processes |
| `directory` | embedded, **limited** | works against the compiler's in-memory FS only |

Two notes on the "not applicable" rows: they are not gaps a user will notice, because they have
no meaning outside GHC or outside a desktop OS. `Cabal`, `hpc`, `haskeline` and `terminfo` are
build/terminal tooling; the `ghc-*` packages are the compiler's own internals. Shipping them
would make them look available and then fail confusingly, which is worse than a clear "not
available here".

## Also shipped (not boot libraries, but commonly wanted)

`random` (`System.Random`), `splitmix`, `unordered-containers`, `async`, and the test frameworks
`HUnit`, `QuickCheck` and `hspec` (with `hspec-core`, `hspec-expectations`, `hspec-discover`,
`quickcheck-io`, `call-stack`) and their dependencies (`ansi-terminal`, `ansi-terminal-types`,
`colour`, `haskell-lexer`, `ghc-compat`).

**`canvhs`** is embedded in the wasm bundle rather than shipped as a `.pkg`: HTML5 graphics
(`Graphics.CanvHs` — a Gloss/Shine-style `Picture`/`Color` API, with `Graphics.CanvHs.Demo`'s
`demo1`–`demo7`) and sound (`Audio.AudHs.Sound`, `Audio.AudHs.FFI`; canvhs's umbrella `Audio.AudHs`
is not compiled into this build). Because it has no module maps to derive from, its modules are
listed by hand under `embedded` in `scripts/module-support.json` — verify candidates with
`node scripts/node-repl-run.js --probe-imports Graphics.CanvHs,...`.

Then the batch this document used to list as "worth adding next", now all shipped: `fgl`
(`Data.Graph.Inductive`, 28 modules), `fingertree`, `heaps`, `psqueues`, `tagsoup`,
`edit-distance`, `Diff`, `data-ordlist`, `dlist`, `split`, `monad-loops`, `prettyprinter`
(14 modules), `numbers` and `parallel`. Three of them are not installable from the snapshot and
are pinned to git in the build script: `fgl`, `dlist` (the `mhs` branch of a fork) and
`prettyprinter` (a monorepo subdirectory). `Control.Parallel` works, but a browser tab has one
thread, so `par` is correctness-only.

Every one of these is verified by *running* it, not just importing it — the evidence is in
`FINDINGS.md`.

## Still unpackaged

MicroHs's [`Makefile.packages`](https://github.com/augustss/MicroHs/blob/master/Makefile.packages)
is the list of packages it is known to compile. Everything a course or a contest reaches for is
shipped above; what is left is ecosystem plumbing and narrow tooling, worth adding only when
something asks for it by name:

- type-class plumbing other libraries depend on: `newtype`, `void`, `these`, `assoc`,
  `indexed-traversable`, `transformers-compat`, `mmorph`, `base-orphans`, `comonad`,
  `contravariant`, `distributive`, `data-default`/`-class`, `foldable1-classes-compat`,
  `bifunctor-classes-compat`;
- support and glue: `StateVar`, `unliftio-core`, `vault`, `simple-affine-space`, `PSQueue`,
  `polyparse`, `granite`, `nanospec`, `character-ps`, `time-units`, `cpu`, `timeit`, `tardis`,
  `bimap`, `byteable`, `bytestring-builder`, `casing`, `composition`;
- irrelevant in a browser tab: `optparse-applicative` (there is no argv), `terminfo` (no
  terminal), `xml` (use `tagsoup` or `xhtml`), `js-jquery`/`js-flot`/`js-dgtable`.

Being on that list is a claim about MicroHs, not about this playground: none of them is built or
verified here.

## Deliberately **not** supported

| module(s) | reason |
| --- | --- |
| `Language.Haskell.TH` | no Template Haskell in MicroHs (only the types, via `ghc-compat`) |
| `GHC.*` (other than what `ghc-compat` provides) | GHC internals are not exposed |
| `System.Posix.*`, `System.Win32.*` | platform-specific |
| `Network.*` | networking is not available here |
| `Data.Binary` | built, compiles, but `Data.Binary.Get` / `decode` hangs (below) |
| `Text.Megaparsec` | not in MicroHs's known-to-compile list |
| `Data.Vector`, `Control.Lens`, `Data.Aeson` | not in MicroHs's known-to-compile list; `aeson` needs Template Haskell/generics |

An earlier revision of `FINDINGS.md` claimed `vector` and `aeson` would build. They are not in
MicroHs's verified list, so that was wrong — they are unverified, not merely unpackaged.

### Why `binary` is built but not shipped

It compiles and `Data.Binary.Put` works — `BL.length (runPut (putWord16be 258))` is `2` — but
**`Data.Binary.Get` never returns**: both `runGet getWord16be (BL.pack [1,2])` and the round trip
through `runPut` hang, `:main` times out, and the REPL stays stuck until the page is reloaded.

A hang is the worst failure mode this playground has — there is no interrupt on the main thread,
so it freezes the result iframe. An accurate "not available, here is why" is strictly better than
a landmine, so the package is excluded from the shipped set *and* from the build's default
`PACKAGES`. Its `.pkg` is still in the committed build DB, and `PACKAGES='binary'` rebuilds it
(there is a pinned case in the script), so this stays a small decision to reverse — and it becomes
worth reversing if the worker engine (which can kill a runaway) ever becomes reliable.

See [BUILD.md](BUILD.md) for the packaging mechanics, including why a package may rebuild on every
run.

## When you hit a missing module

1. Check whether it is a MicroHs limitation or just unpackaged — MicroHs may simply not compile
   it (that is the case for `megaparsec`, `vector`, `lens`, `aeson`).
2. If it compiles and works, package it — [BUILD.md](BUILD.md) has the step-by-step, including the
   incremental Docker run that rebuilds only the new package.
3. If it compiles but misbehaves, or can never work, add a rule to
   `scripts/module-support.json` and regenerate the manifest (`node scripts/build-manifest.js`),
   so the failure is explained rather than mysterious.
4. Run `node scripts/test-manifest.js` — it asserts the classification of the modules listed
   above, so this document and the runtime cannot drift apart silently.

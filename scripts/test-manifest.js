'use strict';

/**
 * Checks the lazy-loading classification in public/packages.js against the real
 * manifest (public/pkgs/index.json): which modules need a package, which come from
 * the embedded base, and which cannot be provided here at all.
 *
 *   node scripts/test-manifest.js
 *
 * Run after a rebuild that regenerates the manifest, so "unavailable" does not
 * silently drift into a bare "Module not found".
 */

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
globalThis.fetch = () => Promise.reject(new Error('fetch is not used by this test'));
require(path.join(root, 'public', 'packages.js'));
const P = globalThis.mhsPackages;

const manifestPath = path.join(root, 'public', 'pkgs', 'index.json');
if (!fs.existsSync(manifestPath)) {
  console.error('missing ' + manifestPath + ' — run: node scripts/build-manifest.js');
  process.exit(1);
}
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

// module, expected kind, and (for 'package') the package that should provide it
const cases = [
  ['Data.Map', 'package', 'containers-0.8.pkg'],
  ['Data.Set', 'package', 'containers-0.8.pkg'],
  ['Control.Monad.State', 'package', 'mtl-2.3.2.pkg'],
  ['Test.Hspec', 'package', 'hspec-2.11.17.pkg'],
  ['System.Random', 'package', 'random-mhs-1.3.2.2.pkg'],
  // the GHC boot-library gap that was closed: parsec, pretty, xhtml
  ['Text.Parsec', 'package', 'parsec-3.1.18.0.pkg'],
  ['Text.Parsec.Expr', 'package', 'parsec-3.1.18.0.pkg'],
  ['Text.PrettyPrint', 'package', 'pretty-1.1.3.6.pkg'],
  ['Text.PrettyPrint.HughesPJ', 'package', 'pretty-1.1.3.6.pkg'],
  ['Text.XHtml', 'package', 'xhtml-3000.2.2.1.pkg'],
  ['Data.List', 'embedded'],
  ['Data.Text', 'embedded'],
  ['Data.ByteString', 'embedded'],
  // provided by ghc-compat, so they must win over the broader GHC/TH rules
  ['GHC.Stack', 'package', 'ghc-compat-0.5.11.0.pkg'],
  ['Language.Haskell.TH.Syntax', 'package', 'ghc-compat-0.5.11.0.pkg'],
  ['Language.Haskell.TH.Quote', 'package', 'ghc-compat-0.5.11.0.pkg'],
  // known limits, each with its own reason
  ['Data.Aeson', 'unavailable'],
  ['Data.Aeson.Types', 'unavailable'],
  ['Control.Lens.Operators', 'unavailable'],
  ['Data.Vector.Unboxed', 'unavailable'],
  ['Language.Haskell.TH', 'unavailable'],
  ['GHC.Prim', 'unavailable'],
  ['System.Posix.Process', 'unavailable'],
  ['Network.Socket', 'unavailable'],
  // nothing known about it
  ['No.Such.Module', 'unknown'],
  // built, then deliberately withheld: compiles but its reader hangs
  ['Data.Binary', 'unavailable'],
  ['Data.Binary.Get', 'unavailable'],
];

let pass = 0;
let fail = 0;
function check(label, ok, detail) {
  if (ok) pass++;
  else fail++;
  console.log((ok ? 'PASS  ' : 'FAIL  ') + label + (ok || !detail ? '' : '   ' + detail));
}

for (const [mod, kind, pkg] of cases) {
  const got = P.classifyModule(mod, manifest);
  const ok = got.kind === kind && (!pkg || got.pkg === pkg);
  check(
    mod.padEnd(30) + got.kind.padEnd(12) + (got.pkg || got.reason || ''),
    ok,
    'expected ' + kind + (pkg ? '/' + pkg : ''),
  );
}

// every unavailable module must carry a non-empty reason
for (const mod of ['Data.Aeson', 'GHC.Prim', 'Language.Haskell.TH', 'System.Posix.Process']) {
  const got = P.classifyModule(mod, manifest);
  check(
    'reason for ' + mod,
    typeof got.reason === 'string' && got.reason.length > 0,
    'reason missing',
  );
}

// imports: satisfied, unsatisfied, and commented-out
const satisfied = P.analyzeImports(
  'module Main where\nimport Data.Map\nimport Data.List\nmain = pure ()\n',
  manifest,
);
check(
  'imports: Data.Map + Data.List resolve',
  satisfied.missing.length === 0 && satisfied.packages.includes('containers-0.8.pkg'),
  JSON.stringify(satisfied),
);

const unsatisfied = P.analyzeImports(
  'import Data.Map\nimport Data.Aeson\nmain = pure ()\n',
  manifest,
);
check(
  'imports: Data.Aeson reported missing, Data.Map still resolved',
  unsatisfied.missing.length === 1 &&
    unsatisfied.missing[0].module === 'Data.Aeson' &&
    unsatisfied.packages.includes('containers-0.8.pkg'),
  JSON.stringify(unsatisfied),
);

// the newly added boot libraries must resolve, with their transitive deps
const bootExtras = P.analyzeImports(
  'module Main where\nimport Text.Parsec\nimport Text.PrettyPrint\nimport Text.XHtml\nmain = pure ()\n',
  manifest,
);
check(
  'imports: parsec + pretty + xhtml all resolve',
  bootExtras.missing.length === 0 &&
    ['parsec-3.1.18.0.pkg', 'pretty-1.1.3.6.pkg', 'xhtml-3000.2.2.1.pkg'].every((p) =>
      bootExtras.packages.includes(p),
    ),
  JSON.stringify(bootExtras),
);

const commented = P.analyzeImports(
  '-- import Data.Aeson\n{- import Data.Vector -}\nmodule Main where\nimport Data.List -- import Control.Lens\nmain = pure ()\n',
  manifest,
);
check(
  'imports: commented-out imports ignored',
  commented.missing.length === 0,
  JSON.stringify(commented.missing),
);

const message = P.explainMissing(unsatisfied.missing, manifest);
check(
  'message: names the module and a reason',
  /Data.Aeson/.test(message) && /not bundled/.test(message),
  message,
);
check('explainMissing: null when nothing is missing', P.explainMissing([], manifest) === null);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);

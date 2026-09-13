/**
 * stdin for Haskell programs.
 *
 * The MicroHs web build has no usable fd 0: `getLine` throws
 * `Handle(stdin): end of file`, and the REPL's own input queue (`_set_input_char`)
 * belongs to the REPL — characters sent while a program runs are read by the REPL
 * afterwards, not by the program. So stdin has to arrive as *source*:
 *
 *   1. `lcInput` / `lcInputLines` / `lcInputWords` — pure bindings, no imports needed.
 *   2. Prelude's `getLine`, `readLn`, `getContents` and `interact` are shadowed by
 *      equivalents that consume the same input, so ordinary programs work unchanged.
 *      A top-level definition in Main shadows the imported one, which is what makes
 *      this possible without touching the compiler.
 *
 * The shadowing needs `Data.IORef` and `System.IO.Unsafe`, so the imports are hoisted
 * to the top of the module (they cannot appear after declarations).
 */

const IMPORTS = ['import Data.IORef', 'import System.IO.Unsafe (unsafePerformIO)'];

/** Names we shadow; skipped if the program defines them itself. */
const SHADOWED = ['getLine', 'readLn', 'getContents', 'interact'];

const ESCAPES = { '\\': '\\\\', '"': '\\"', '\n': '\\n', '\r': '\\r', '\t': '\\t' };

/** Escape text as a Haskell string literal. */
export function toHaskellString(text) {
  let out = '';
  for (const ch of String(text)) {
    if (ESCAPES[ch]) {
      out += ESCAPES[ch];
      continue;
    }
    const code = ch.codePointAt(0);
    if (code < 0x20 || code === 0x7f) {
      // Numeric escape; `\&` keeps a following digit from joining the number.
      out += '\\' + code + '\\&';
      continue;
    }
    out += ch;
  }
  return out;
}

/** Does the program define this name at the top level? */
function definesName(source, name) {
  return new RegExp('^' + name + '\\s*(::|=)', 'm').test(source);
}

/**
 * Where new import lines can legally go: after the module header if there is one,
 * otherwise after any leading pragmas and comments (which must come first).
 */
function importInsertAt(lines) {
  const header = lines.findIndex((l) => /^module\s+[A-Z][A-Za-z0-9_.']*\s*(\(.*)?\bwhere\b/.test(l));
  if (header !== -1) return header + 1;

  let i = 0;
  while (i < lines.length) {
    const line = lines[i].trim();
    const isLeading =
      line === '' ||
      line.startsWith('--') ||
      line.startsWith('{-#') ||
      line.startsWith('{-') ||
      line.startsWith('#');
    if (!isLeading) break;
    if (line.startsWith('{-') && !line.includes('-}')) {
      // Block comment: skip to its end.
      while (i < lines.length && !lines[i].includes('-}')) i++;
      i++;
      continue;
    }
    i++;
  }
  return i;
}

function shimSource(input, source) {
  const parts = [];
  const add = (name, text) => {
    if (!definesName(source, name)) parts.push(text);
  };

  add(
    'lcInput',
    [
      '-- stdin, injected by @live-codes/browser-haskell (this build has no fd 0)',
      'lcInput :: String',
      'lcInput = "' + toHaskellString(input) + '"',
    ].join('\n'),
  );
  add('lcInputLines', 'lcInputLines :: [String]\nlcInputLines = lines lcInput');
  add('lcInputWords', 'lcInputWords :: [String]\nlcInputWords = words lcInput');

  if (definesName(source, 'lcInput')) {
    // The program provides its own input; nothing to shadow it with.
    return parts.join('\n\n');
  }

  parts.push(
    [
      '{-# NOINLINE lcStdinRef #-}',
      'lcStdinRef :: IORef String',
      'lcStdinRef = unsafePerformIO (newIORef lcInput)',
      '',
      'lcReadAll :: IO String',
      'lcReadAll = do',
      '  s <- readIORef lcStdinRef',
      '  writeIORef lcStdinRef ""',
      '  return s',
    ].join('\n'),
  );

  add(
    'getLine',
    [
      'getLine :: IO String',
      'getLine = do',
      '  s <- readIORef lcStdinRef',
      '  case s of',
      '    [] -> return ""',
      '    _  -> do',
      '      let (l, rest) = break (== \'\\n\') s',
      '      writeIORef lcStdinRef (drop 1 rest)',
      '      return l',
    ].join('\n'),
  );
  add('readLn', 'readLn :: Read a => IO a\nreadLn = getLine >>= return . read');
  add('getContents', 'getContents :: IO String\ngetContents = lcReadAll');
  add('interact', 'interact :: (String -> String) -> IO ()\ninteract f = getContents >>= putStr . f');

  return parts.join('\n\n');
}

/**
 * Append stdin support to a program. Imports are hoisted; definitions are appended
 * (order does not matter in Haskell). A program with no stdin is left untouched.
 * @param {string} source
 * @param {string} input
 * @returns {string}
 */
export function injectStdin(source, input) {
  const code = String(source == null ? '' : source);
  const text = String(input == null ? '' : input);
  if (!text) return code;

  // Drop a trailing newline the editor may have added, so line counting stays sane.
  const lines = code.replace(/\s*$/, '').split('\n');
  const at = importInsertAt(lines);
  const hoisted = IMPORTS.filter((line) => !new RegExp('^' + line.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*$', 'm').test(code));
  const withImports = hoisted.length
    ? lines.slice(0, at).concat(['']).concat(hoisted).concat('').concat(lines.slice(at))
    : lines;

  return withImports.join('\n') + '\n\n' + shimSource(text, code) + '\n';
}

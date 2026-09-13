/** Where the runtime assets live. */
export interface AssetOptions {
  /**
   * Root URL for the assets: `mhs/mhs-embed.js` (+ its `.wasm`) and `pkgs/index.json`
   * (+ `pkgs/packages/*.pkg`). Defaults to the directory this module was loaded from.
   */
  baseUrl?: string;
  /** Full URL of `mhs-embed.js`; overrides `baseUrl` for the compiler bundle. */
  wasmUrl?: string;
  /** Directory holding `index.json` and `packages/`; overrides `baseUrl`. */
  packagesUrl?: string;
}

export interface HaskellOptions extends AssetOptions {
  /**
   * Extra packages by module name, for packages that are not in the bundled set:
   * `{ 'My.Module': 'https://example.com/my-pkg.pkg' }`.
   *
   * The `.pkg` must be built by the same MicroHs version as the bundled compiler, and
   * any MicroHs dependencies it has must be mapped here too.
   */
  importmap?: Record<string, string>;
  /** Per-run timeout in milliseconds. Default 60000. */
  timeout?: number;
  /** Receives diagnostic messages from the compiler and the package loader. */
  onLog?: (message: string) => void;
}

export interface RunOptions {
  /** The Haskell program, as a `Main` module. */
  code: string;
  /**
   * Text the program can read: as `lcInput` / `lcInputLines` / `lcInputWords`, and
   * through `getLine`, `readLn`, `getContents` and `interact`, which are shadowed to
   * read this text. (The web build of MicroHs has no usable stdin.)
   */
  stdin?: string;
  /** Overrides the instance timeout for this run. */
  timeout?: number;
}

export interface RunResult {
  /** What the program wrote to stdout. */
  stdout: string;
  /** What the program wrote to stderr. */
  stderr: string;
  /** Compile errors and runtime exceptions, or `null` when the program ran cleanly. */
  error: string | null;
  /** stdout, stderr and diagnostics together, in the order they were produced. */
  output: string;
  /** `0` on success, `1` on error, `124` if the run timed out. */
  exitCode: number;
  /** MicroHs package files loaded for this run. */
  packages: string[];
  /** Wall-clock time for the run, in milliseconds. */
  durationMs: number;
}

export interface HaskellInstance {
  run(options: RunOptions): Promise<RunResult>;
  /**
   * Release this instance. The wasm module stays in memory (browsers cannot unload
   * one), so use a single instance per page or worker.
   */
  dispose(): void;
}

/**
 * Boot MicroHs and return an instance. Booting takes ~1-2s and is worth doing once.
 */
export declare function createHaskell(options?: HaskellOptions): Promise<HaskellInstance>;

declare const _default: {
  createHaskell: typeof createHaskell;
};

export default _default;

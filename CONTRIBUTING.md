# Contributing

Thanks for helping improve nvim-pele-mermaid. Please keep changes small, tested, and focused.

## Setup

You need Neovim 0.11+, Bun, **resvg**, ImageMagick (`magick`), and the other runtime requirements listed in the [README](README.md#install). Clone the repository and install the locked JavaScript dependencies:

```sh
bun install --frozen-lockfile
```

This is the same command the plugin's `build.lua` hook runs for users. If a change needs a dependency change, update `bun.lock` in the same pull request and explain why.

Rust is **not** needed to develop or test the plugin. It is only needed to rebuild the demo video, GIF, and poster under `preview/` (see [Demo media](#demo-media)).

## Tests

Run the full suite from the repository root:

```sh
scripts/test.sh
```

The script requires `bun`, `nvim`, `resvg`, and `magick` on `PATH`. It runs `bun install --frozen-lockfile`, then the existing suites, which you can also run individually:

```sh
bun test tests/renderer.test.js tests/fonts.test.js
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/run.lua
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/theme.lua
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/runtime.lua
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/worker.lua
nvim --headless -u NONE --cmd 'set rtp+=.' -l tests/rasterizer.lua
```

`tests/run.lua` runs every `*_spec.lua` regression specification at controlled lifecycle boundaries. The worker and rasterizer suites are integration tests that generate real artifacts; **resvg is required** for them (`tests/rasterizer.lua` asserts it is present), as are the installed JavaScript dependencies.

`tests/installed.lua` is a separate, optional check against an installed copy of the plugin. It requires a lazy.nvim setup in which `nvim-pele-mermaid` is registered. Run it from a terminal with:

```sh
nvim --headless -c 'luafile tests/installed.lua'
```

It exercises actual image.nvim objects, the reading view, live previews, and exports.

Add or update a test with every behavior change or bug fix. Prefer extending the matching `tests/*_spec.lua` file and, for a new spec, add it to the list in `tests/run.lua`.

## Manual terminal-graphics checks

Headless tests do not prove that graphics are visible. For any change that touches rendering, image placement, the reading view, previews, the inspector, or terminal detection, also check in a real Kitty-graphics terminal (Tern, Kitty, or Ghostty):

1. Open a Markdown file with several `mermaid` fences, such as [`examples/mermaid-samples.md`](examples/mermaid-samples.md) or [`preview/architecture.md`](preview/architecture.md).
2. Toggle the reading view (`:MermaidToggle`) and back. Diagrams appear in place, prose is intact, and the cursor returns to the matching source position.
3. Open `:MermaidPreview` and `:MermaidSplit`. Edit a fence: the preview regenerates, and incomplete syntax keeps the last valid diagram and reports a diagnostic.
4. Open `:MermaidInspect`, zoom and pan, and close it. Resize the window or split and confirm images are cleared and redrawn without leftovers.
5. Run `:checkhealth pele_mermaid`.

Say in the pull request which terminal and Neovim version you tested with.

## Pull requests

- Keep each pull request focused on one change; split unrelated work.
- A maintainer reviews every pull request. Expect questions and requests for changes.
- Match the existing code style and patterns rather than introducing a second convention.
- Update the README when user-visible behavior, options, or requirements change.
- Do not bump the version in `package.json` or edit `CHANGELOG.md` for a routine change. Maintainers do that when releasing; describe the user-visible effect in the pull request description.

## Error handling

- Let unexpected errors propagate within a module. Do not wrap code in broad `pcall` or catch-all handlers that return a fallback "instead of throwing".
- Recover or diagnose at the owner of the failure: the code that can decide what to do about it (for example the render worker or a command) catches the specific, expected failure and reports it. Inner helpers just throw or return their error to that owner.
- Report user-facing failures with `vim.notify("pele_mermaid: ...", level)`, as existing code does, and say what the user can do next.
- Rendering must never rewrite the user's Markdown source. `:MermaidFix` is the only command that intentionally edits text.
- When a render fails or a fence is incomplete, the owner keeps the last valid preview and surfaces a diagnostic.
- Do not swallow errors silently. Write diagnostics through `lua/pele_mermaid/log.lua`, which logs only when `vim.g.pele_mermaid_debug = true`.
- Check external tools and dependencies at execution and health-check boundaries, not while reading configuration, and surface the problem in `:checkhealth pele_mermaid`.

## Demo media

The Rust project in `preview/` rebuilds the demo video, GIF, and poster in `assets/`. It is development-only: installing the plugin never builds or runs it, and ordinary contributions do not need it.

```sh
cargo run --locked --release --manifest-path preview/Cargo.toml -- all
```

It requires Rust, FFmpeg development libraries, and the `ffmpeg` CLI with `libx264`. `-- inspect` checks all frames and saves storyboard keyframes under `preview/target/inspection`; `-- mp4`, `-- gif`, and `-- poster` build individual outputs. The 24-second intro uses [`preview/architecture.md`](preview/architecture.md) as its source document and actual Pele SVGs with the bundled Maple Mono fonts.

## Licensing

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE). The bundled Maple Mono fonts in `assets/fonts/` are licensed separately under the [SIL Open Font License](assets/fonts/LICENSE.txt) and are not relicensed by contributions.

## Releases (maintainers)

Versions follow [Semantic Versioning](https://semver.org/) with 0.x rules: while the major version is 0, a breaking change requires a **minor** bump (`0.1.x` to `0.2.0`) with migration notes in `CHANGELOG.md`, and a backward-compatible change or fix is a **patch** bump (`0.1.0` to `0.1.1`).

1. In a pull request, bump `version` in `package.json` and add the matching `## X.Y.Z` entry to `CHANGELOG.md`. Merge it once CI is green.
2. On the merged commit, create and push an annotated tag whose name is `v` plus the `package.json` version:

   ```sh
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

3. The tag pipeline (`.github/workflows/release.yml`) verifies that the tag matches the `package.json` version, runs the test workflow, and then publishes the GitHub release.

Contributors do not tag or bump versions.

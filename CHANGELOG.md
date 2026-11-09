# Changelog

Notable changes are recorded here. Versions follow [Semantic Versioning](https://semver.org/). During 0.x development, breaking changes require a minor version bump and migration notes; patch releases remain backward-compatible.

## 0.1.0

Initial public release.

- Preview Mermaid fences in a Markdown reading view that preserves surrounding prose and leaves source text unchanged.
- Open the focused diagram in a floating preview or a live side split that follows the source cursor.
- Regenerate previews after edits, retaining the last valid diagram while syntax is incomplete.
- Navigate diagrams, zoom and pan in the inspector, copy PNGs, repair supported syntax mistakes, and export SVG or PNG files.
- Remove private image-placement files cleanly after repeated renders, including same-inode hard-link replacements.
- Render with Pele, editor-derived colors or explicit themes, and bundled Maple Mono NF fonts.
- Install from the `v0.1.0` Git tag using the frozen Bun dependency build hook.

Requires Neovim 0.11+, Bun for installation, image.nvim, ImageMagick, a supported SVG rasterizer, and a Kitty-graphics-compatible terminal. Code is MIT-licensed; bundled fonts retain the SIL Open Font License.

# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

Rolling changes are listed newest first by date.

### Changed

- Switched the MathJax dependency from `mathjax-full@3` to `@mathjax/src@4`; the daemon now loads MathJax 4 ES modules, uses promise-based conversion, and checks for a v4 `@mathjax/src` package in `:checkhealth`.
- Render cache keys now include the MathJax 4 renderer version so images rendered with MathJax 3 are not reused after upgrade.
- Added live per-buffer density controls with `:LatexPreview density [N|reset]` and `:LatexPreview display-density [N|reset]`, backed by buffer-local `b:latex_preview_density` and `b:latex_preview_display_density`.
- Preamble extraction is now root-aware for multi-file projects: chapter buffers can use a root declared with `% !TEX root = ...`, vimtex's root metadata, or an unambiguous parent `.tex` file that reaches the chapter through `\input`, `\include`, or `\subfile`.
- Reused live hover render files for unchanged equations instead of rerendering every time, reducing repeated SVG/PNG writes while navigating back to the same math.
- Bounded reusable live-render temp files with the existing `snacks.max_cache_files`, `snacks.max_cache_bytes`, and `snacks.cache_grace_ms` settings, trimming whole render groups (`.svg`, `.png`, and matching `.info`) oldest-first.
- Stopped routing Snacks image metadata into latex-preview's render cache; Snacks `.info` files now stay in Snacks' own cache, and stale `.info` files are removed by `:LatexPreview clear`.

### Fixed

- Added support for LaTeX's common `\bm{...}` command by mapping it to MathJax's `\boldsymbol{...}` support.
- Disabled MathJax 4 inline SVG line breaking in the daemon so each preview still rasterizes from a single SVG.

### Documentation

- Documented the MathJax 4 install command and the `mathjax-full@3` to `@mathjax/src@4` upgrade path.

## 2026-05-01

### Added

- Added hover previews for referenced equations under `\ref`, `\eqref`, `\autoref`, `\cref`, `\Cref`, `\vref`, and `\Vref`.
- Added mixed source/math hover previews for labeled theorem, lemma, proposition, and definition environments.
- Added hover previews for citation commands such as `\cite`, `\citet`, `\citep`, `\parencite`, and `\textcite`, resolving entries from local `.bib` files.
- Added runtime toggles for referenced-equation previews:
  - `:LatexPreview refs`
  - `:LatexPreview refs-on`
  - `:LatexPreview refs-off`
- Added runtime toggles for citation previews:
  - `:LatexPreview cites`
  - `:LatexPreview cites-on`
  - `:LatexPreview cites-off`
- Added runtime toggles for theorem-like reference previews:
  - `:LatexPreview thms`
  - `:LatexPreview thms-on`
  - `:LatexPreview thms-off`
- Added default toggle keymaps when `setup_keymap = true`:
  - `<leader>ir` toggles referenced-equation previews.
  - `<leader>it` toggles theorem-like reference previews.
  - `<leader>ic` toggles citation previews.
- Added `references`, `theorem_references`, and `citations` configuration sections.

### Changed

- Display equations now use LaTeX display style by default via `render.display_math_style = "display"`.
- Physical source line breaks inside display equations are treated as spaces unless the equation uses an explicit multiline math environment such as `align`, `aligned`, `gather`, or `multline`.
- Render cache version was bumped so older cached images do not preserve previous newline behavior.
- Hover targeting now checks, in order: math under cursor, supported equation reference, supported theorem-like reference, supported citation command.
- Theorem-like previews now show source text with inline/display math rendered in place instead of compiling the whole block into a screenshot.
- Theorem-like mixed previews now conceal the TeX math source and force inline math to at least 12px.
- Inline math inside theorem-like mixed previews is rendered without terminal-cell padding.

### Fixed

- Fixed multi-label reference hovers so `\ref{a,b}` / `\cref{a,b}` preview the label under the cursor instead of always previewing the first label.
- Fixed `\declaretheorem[name=...]{env}` detection so custom theorem-like environments are recognized by their environment name.
- Fixed `alignat`, `flalign`, and `eqnarray` discovery in the regex parser, including stripping `alignat`'s required column-count argument from rendered math.
- Fixed mixed theorem-preview async validation to check the original source window instead of whichever window is current when rendering finishes.
- Fixed reused text and mixed theorem popups to refresh their source buffer/window, close keymaps, and autocmds.
- Fixed mixed theorem preview reuse to include the extracted preamble hash, preventing stale math images after macro changes.
- Fixed Snacks image-cache trimming so an over-limit cache schedules a retry after the grace period instead of staying over limit until another filesystem event.
- Fixed request-level `pad_to_cells = true` so it can override a global `render.pad_to_cells = false`.
- Fixed Treesitter math-environment handling so `\begin{...}...\end{...}` wrappers are stripped before sending equations to MathJax.
- Fixed escaped `$` parsing by counting consecutive preceding backslashes.
- Fixed `%` comment stripping by counting consecutive preceding backslashes.
- Fixed numeric buffer cache cleanup by clearing parse and preamble caches on `BufWipeout`.
- Fixed popup placement near the bottom/right edge by accounting for popup dimensions.
- Fixed theorem-like previews to render math with the existing MathJax equation pipeline, avoiding document-class-specific LaTeX block compilation failures.
- Avoided mutating current hover state before a pending render succeeds.
- Avoided deleting cached render files from hover cleanup paths.
- Added cleanup for stale temporary render directories.
- Changed exit cleanup to empty the Snacks image cache directory instead of only deleting `.info` metadata files.
- Added grouped Snacks image-cache trimming with `snacks.max_cache_files`, `snacks.max_cache_bytes`, and `snacks.cache_grace_ms`.
- Extended `:LatexPreview clear` to remove stale theorem-preview `.tex`, `.pdf`, `.log`, and `.aux` artifacts from older cache entries.
- Added warnings when `render.pad_to_cells = true` but ImageMagick is unavailable.
- Improved `:checkhealth latex-preview` detection for nvm-managed global `mathjax-full`.
- Made daemon command resolution respect later `setup({ daemon = { cmd = ... } })` changes.
- Narrowed Snacks document-render autocmd removal to avoid deleting unrelated future `snacks.image` FileType handlers.
- Fixed live-render temporary files accumulating in the per-PID temp directory (`stdpath("run")/latex-preview/<pid>/`) when the cursor moved during a render: superseded in-flight renders now delete their SVG/PNG immediately instead of waiting for `VimLeavePre`.
- Fixed render-error paths leaving partial SVG/PNG files behind when the daemon, rasterizer, or pad-to-cells step fails on a non-cached render.
- Fixed `render.lua`'s buffer-modified check using the wrong buffer when `req.buf` was omitted: the request now snaps to the active buffer once at entry instead of re-reading the global `vim.bo.modified` from a later async context.
- Deduplicated the `mathjax-full` candidate-path list. The daemon script (`scripts/mathjax-daemon.mjs`) is now the single source of truth and exposes the list via a new `--list-paths` mode; `:checkhealth latex-preview` reads from there instead of mirroring the list in Lua.
- Daemon boot now defers the `npm root -g` probe until the cheaper candidates miss, saving a process spawn on every successful boot.

### Documentation

- Updated README and Vim help with reference/citation preview usage, toggles, keymaps, and limitations.
- Documented display-style rendering and source newline behavior.

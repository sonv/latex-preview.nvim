# latex-preview.nvim

Preview LaTeX math while you write in Neovim. Open a floating window at the
cursor, edit the source, and watch the equation update. The same preview
can show referenced equations, theorem statements, and BibTeX entries.

MathJax runs in a persistent Node.js process, with custom macros collected
from your project. [snacks.nvim](https://github.com/folke/snacks.nvim)
handles image placement in the terminal. No LaTeX compilation is needed
for previews.

https://github.com/user-attachments/assets/e3509a2d-eaf1-4c1c-afde-d3f3ab90c7da

More demos: [Equation editing](https://youtu.be/Naqs8XSB0ko) ·
[Reference demo](https://youtu.be/VaEr1X8wXLw)

[Install](#install) · [Usage](#usage) · [Configuration](#configuration) ·
[Macros and projects](#macros-and-projects) · [Performance](#performance) ·
[Troubleshooting](#troubleshooting)

## Requirements

- Neovim 0.10+.
- [snacks.nvim](https://github.com/folke/snacks.nvim), with `image.enabled = true`.
- A terminal supported by Snacks' Kitty graphics backend. **I have tested
  this plugin in Kitty.** Other terminals depend on Snacks' support. See its
  [terminal compatibility notes](https://github.com/folke/snacks.nvim/blob/main/docs/image.md).
- Node.js 18+ and MathJax 4's `@mathjax/src` package.
- `rsvg-convert` from librsvg, recommended for reliable SVG rasterization.
  ImageMagick is a fallback, but some MathJax SVGs may render incorrectly
  without librsvg.

Treesitter parsers for `latex` and `markdown_inline` improve equation
lookup. They are optional. The plugin uses a regex fallback when they are
unavailable.

## Install

Install the rendering tools first. ImageMagick is included below for
Snacks' other image formats and as a fallback rasterizer.

```sh
# macOS
brew install node imagemagick librsvg
npm install -g @mathjax/src@4
```

```sh
# Debian / Ubuntu, with Node.js 18+ available
sudo apt install nodejs npm imagemagick librsvg2-bin
npm install -g @mathjax/src@4
```

Use your usual npm global-install prefix. If MathJax is installed elsewhere,
set `LATEX_PREVIEW_MATHJAX_PATH` to the directory containing its
`package.json`. Older installations of `mathjax-full@3` are no longer used.

Add this to your lazy.nvim configuration:

```lua
{
  "sonv/latex-preview.nvim",
  dependencies = {
    { "folke/snacks.nvim", opts = { image = { enabled = true } } },
  },
  ft = { "tex", "latex", "markdown", "rmd", "quarto" },
  opts = {
    setup_keymap = true,             -- <leader>ih: inspect here
    hover = { auto_open = false },   -- open previews with the keymap
    cache = true,                   -- reuse saved-buffer renders across sessions
    cache_dir = "aux",              -- <buffer-directory>/aux/latex-preview-cache/
  },
}
```

If you already configure Snacks, merge `image.enabled = true` into that
configuration. For another plugin manager, install `sonv/latex-preview.nvim`
and `folke/snacks.nvim`, then call `require("latex-preview").setup({...})`.

Run `:checkhealth latex-preview`, open a supported file, place the cursor
inside an equation, and press `<leader>ih`.

## Usage

The preview follows the target under the cursor while it is open. You can
move and edit within an equation, or jump directly to another supported
target. Moving to ordinary text or leaving the buffer closes the popup.
Press `<leader>ih` again to close it manually.

To open previews automatically as you move, set
`hover = { auto_open = true }` or run `:LatexPreview auto-on`. When
`hover.auto_open` is omitted, the plugin follows Snacks' `image.doc.float`
setting. With automatic hover enabled, cursor movement can reopen a
preview you closed manually.

When `setup_keymap = true`, these normal-mode mappings are installed:

| Key | Action |
|---|---|
| `<leader>ih` | Show or close the preview in supported filetypes |
| `<leader>iH` | Toggle automatic hover |
| `<leader>ir` | Toggle referenced-equation previews |
| `<leader>it` | Toggle theorem-reference previews |
| `<leader>ic` | Toggle citation previews |

### References and citations

The plugin checks for a math expression first, then a referenced equation,
a theorem reference, and finally a citation. Reference and citation
previews are enabled by default.

- **Equations:** `\ref`, `\eqref`, `\autoref`, `\cref`, `\Cref`, `\vref`,
  and `\Vref` look up a matching `\label` in the current buffer.
- **Theorems:** the same commands preview labeled `theorem`, `lemma`,
  `proposition`, and `definition` blocks. Common aliases such as `thm`
  and `lem` are recognized, including declarations with `\newtheorem`.
  The body is shown as source text with its math rendered in place.
- **Citations:** commands containing `cite`, such as `\cite`, `\citet`,
  `\citep`, `\parencite`, and `\textcite`, show the matching BibTeX entry.
  Local `.bib` files must be listed with `\bibliography` or
  `\addbibresource` in the current buffer. Unsaved edits in loaded
  bibliography buffers are included. For multiple keys, the key
  under the cursor is selected when possible, otherwise the first is used.

Target lookup is local and static. It does not search other chapters for
labels, inherit bibliography declarations from the root file, expand
generated labels, or resolve advanced bibliography inheritance.

### Commands

All commands start with `:LatexPreview`.

| Subcommand | Action |
|---|---|
| No argument, or `toggle` | Show or close the preview |
| `show` / `close` | Show or close explicitly |
| `auto` / `auto-on` / `auto-off` | Toggle, enable, or disable automatic hover |
| `refs` / `refs-on` / `refs-off` | Toggle, enable, or disable equation references |
| `thms` / `thms-on` / `thms-off` | Toggle, enable, or disable theorem references |
| `cites` / `cites-on` / `cites-off` | Toggle, enable, or disable citations |
| `density [N\|reset]` | Show, set, or reset the current buffer's density |
| `display-density [N\|reset]` | Show, set, or reset its display-equation density |
| `clear` | Clear the persistent cache directory used by the current buffer |
| `stop` | Stop the daemon, which restarts on the next render |
| `status` | Show daemon, popup, feature, and terminal-support state |
| `debug` | Open a scratch buffer with the detected equations and extracted preamble |

## Configuration

The installation example enables keymaps and persistent caching. Both
are off in the plugin defaults. Most other settings can be left alone.

```lua
require("latex-preview").setup({
  setup_keymap = true,
  keymap = "<leader>ih",       -- or { "<leader>ih", "K" }
  hover = {
    auto_open = false,        -- true: automatic, omitted: follow Snacks
    toggle_keymap = "<leader>iH",
  },
  popup = {
    live_update_delay_ms = 300,
    max_width = nil,          -- terminal cells, nil: nearly full editor width
    max_height = nil,         -- terminal cells, nil: nearly full editor height
  },
  render = {
    font_size = 12,
    display_font_size = 12,
    display_math_style = "display", -- or "text" for compact display equations
    density = 300,
    pad_to_cells = true,
    svg_to_png = "auto",      -- prefer rsvg-convert, fall back to ImageMagick
  },
  references = { enabled = true, toggle_keymap = "<leader>ir" },
  theorem_references = { enabled = true, toggle_keymap = "<leader>it" },
  citations = { enabled = true, toggle_keymap = "<leader>ic" },
})
```

The foreground color follows the `Normal` highlight. Override it with
`render.fg = "#RRGGBB"` or a function returning a color. Window styling,
such as borders and padding, comes from Snacks' `image.doc` configuration.

See [config.lua](lua/latex-preview/config.lua) for every option and its
default, including supported filetypes, daemon startup limits, macro
extraction, and cache limits.

### Preview size and update delay

Higher density produces larger previews. You can adjust it for the
current buffer without changing your configuration:

```vim
:LatexPreview density 300
:LatexPreview display-density 600
:LatexPreview display-density reset
```

The equivalent buffer variables are `vim.b.latex_preview_density` and
`vim.b.latex_preview_display_density`.

Live editing waits for `popup.live_update_delay_ms` after text changes.
Lower the default of 300 ms if you prefer earlier updates. Display math
uses LaTeX display style. Source line breaks are treated as spaces. Use
`align`, `aligned`, `gather`, or `multline` for multiple rendered lines.

### Caching and Snacks integration

Renders are reused by content, preamble, and rendering settings. With
`cache = true`, unmodified buffers write persistent files to `cache_dir`.
Modified buffers, and all renders with `cache = false`, use reusable
session files under `stdpath("run")/latex-preview/<pid>/`. These temporary
files are removed on normal exit.

`cache_dir` accepts `"aux"`, a fixed absolute path, or a function taking a
buffer number and returning a path. `"aux"` uses
`<buffer-directory>/aux/latex-preview-cache/`, with a global cache fallback
for unnamed buffers. `:LatexPreview clear` clears that persistent directory,
which may be shared by several buffers.

The plugin uses Snacks' image placement backend. By default,
`snacks.disable_document_images = true` disables Snacks' own document
image renderer globally to avoid overlapping previews. Set it to `false`
if you want to keep that renderer active.

The default `snacks.clean_info_on_exit = true` empties the **shared Snacks
image cache** on exit. Set it to `false` to preserve that cache. Despite
the option name, it removes images as well as metadata. The settings
`snacks.max_cache_files = 100`, `snacks.max_cache_bytes = 50 * 1024 * 1024`,
and `snacks.cache_grace_ms = 5000` also bound Snacks cache groups and
reusable session renders. They do not limit the persistent project cache.
Session images used by an open preview are retained until it closes, even
when this temporarily exceeds the limit.
Set either limit to `0` to disable that limit.

### Lua API

To manage your own mappings, leave `setup_keymap = false` and call the
public API:

```lua
vim.keymap.set("n", "<leader>m", function()
  require("latex-preview").toggle()
end)

-- Other entry points:
require("latex-preview").hover() -- show, returns false if no target is found
require("latex-preview").close()
require("latex-preview").set_auto_hover(true)
```

## Macros and projects

The plugin extracts common definitions such as `\newcommand`,
`\renewcommand`, `\providecommand`, `\DeclareMathOperator`,
`\NewDocumentCommand`, `\def`, and `\let`. It reads definitions before
`\begin{document}` in the root preamble, plus definitions from the current
chapter when editing an included file.

The root is resolved in this order:

1. A `% !TEX root = ...` comment in the current file.
2. Vimtex's root metadata, when available.
3. An unambiguous parent `.tex` file containing `\begin{document}` that
   reaches the current file through `\input`, `\include`, or `\subfile`.
4. The current file if no root is found.

The root can have any filename. For an explicit choice, add this to a
chapter file:

```tex
% !TEX root = ../paper.tex
```

With `extract.scan_sty = true`, local `.sty` and `.tex` files referenced
from the root preamble through `\usepackage`, `\RequirePackage`, `\input`,
or `\include` are scanned too. The search checks the root directory and
up to `extract.sty_search_depth` parent directories, four by default.
Edits to the buffer, root preamble, or scanned macro files invalidate the
extraction cache.

Definitions are normalized for MathJax. In particular, `\providecommand`
is rewritten as `\newcommand`, and `\edef` as `\def`. These are controlled
by `extract.rewrite_providecommand` and `extract.rewrite_edef`.

### Rendering limits

Previews support MathJax's TeX math features, including common AMS math,
matrices, aligned equations, font commands, colors, and compatible custom
macros. This is not a full TeX engine. General TikZ drawings, arbitrary
LaTeX packages, and macros depending on document state may not render as
they do in your compiled document. Use your usual LaTeX build to verify
the final output.

## Performance

Measured on Apple Silicon with Neovim 0.12.5, Node 26.0.0, MathJax 4.1.2,
`rsvg-convert`, 300 DPI, and padding to 10 × 20 pixel terminal cells:

| Completed PNG, warm daemon | Before optimization | After optimization |
|---|---:|---:|
| Inline equation | 46.73 ms | 18.74 ms |
| Equation using a custom macro | 46.53 ms | 19.22 ms |
| Display equation | 49.32 ms | 20.35 ms |
| Cached PNG | 0.03 ms | 0.03 ms |

These are means over 40 different equations per workload and 100 cache
hits. They include daemon communication, SVG output, rasterization, and
padding. They exclude target lookup, the typing debounce, and Snacks image
placement. The first PNG also pays daemon startup, measured at roughly
0.35 seconds in the updated run. Timings vary with hardware and equations.

The daemon reuses MathJax font data while giving each request a fresh TeX
parser, so definitions do not leak between buffers. It skips unused SVG
output when processing the preamble. With `rsvg-convert`, terminal-cell
padding happens during rasterization, avoiding an extra ImageMagick
process and PNG decode/encode.

The daemon-only benchmark measured about 0.9–1.2 ms per warm request,
down from 19–20 ms on the same machine. Rasterization accounts for most
of the remaining PNG time.

Without Treesitter, an uncached regex scan of 4,000 lines (285 KB,
2,667 equations) fell from 21.48 ms to 4.80 ms. Unchanged buffers reuse
parsed results.

Run the benchmarks from the repository root:

```sh
nvim --headless -u NONE -i NONE -l bench/render_bench.lua
node tests/daemon_bench.mjs
nvim --headless -u NONE -i NONE -l bench/parse_extract_bench.lua
```

## Troubleshooting

**Start with `:checkhealth latex-preview`.** It checks Snacks, terminal
support, Node.js, MathJax, the rasterizer, and optional Treesitter parsers.
For image transport issues, also run `:checkhealth snacks`.

**No popup appears.** Check `:LatexPreview status` and confirm that the
cursor is on a supported target. A false terminal-support result means
Snacks is not reporting the placeholder support expected by the plugin.
Check your terminal and multiplexer settings against Snacks' compatibility
notes linked above.

**A custom macro is missing.** Run `:LatexPreview debug` on the equation
and inspect the extracted preamble. Definitions after `\begin{document}`
are not collected. For chapter files, check the resolved root with an
explicit `% !TEX root` comment. If the definition is present, it may use
TeX features MathJax does not support. Changes to extracted definitions
normally invalidate renders automatically.

**An equation reports a render error.** Read `:messages` for the error.
Try `rsvg-convert` if ImageMagick produces a blank or corrupt image.
Unsupported TeX commands still need a normal LaTeX build.

**The daemon fails to start or keeps restarting.** Check that
`@mathjax/src@4` is installed and visible to the Node.js used by Neovim.
For a nonstandard installation, set `LATEX_PREVIEW_MATHJAX_PATH` to the
package directory. Run `:LatexPreview stop` before trying again.

**The first preview is slower.** It includes Node.js and MathJax startup.
Subsequent previews reuse that process. See the measurements above for
what render timings include.

## Acknowledgements

This project was inspired by Overleaf's preview tooltips. I used Claude
for the initial implementation and ChatGPT/Codex to help audit and optimize
it. MathJax provides the math renderer, and snacks.nvim provides terminal
image placement.

## License

[MIT](LICENSE)

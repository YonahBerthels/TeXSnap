# TeXSnap

A Mathpix-style menu bar app for macOS: snip part of the screen and get LaTeX for the formula, table or
passage of math text in it, rendered next to the snip and copied to the clipboard.

- **⌃⌘M** snips a region anywhere (Space switches to window selection, Esc cancels). The result appears in a
  small pop-up next to the pointer, with one-click copy buttons; it closes by itself (Settings can switch to
  the full window instead).
- The history is searchable (by LaTeX or kind), and pinned snips stay at the top and are never trimmed.
- **Left-click** the √x icon in the menu bar for the window; **right-click** for the menu
  (convert a clipboard image, open an image file, copy a recent snip, settings).
- Copies math as LaTeX, `$…$`, `\[…\]`, an equation environment or MathML (for Word); tables as LaTeX,
  Markdown, TSV/CSV or HTML; text as LaTeX or Markdown.
- Recognizes with **Claude** (your Claude Code login or an Anthropic API key) or with a **local model that runs
  offline** on Apple Silicon.

## Requirements

- macOS 14 or later.
- The Xcode command line tools, to build: `xcode-select --install`.
- For recognition, at least one of:
  - **Claude Code**, logged in (TeXSnap finds the `claude` command itself);
  - an **Anthropic API key**, entered in TeXSnap's Settings (stored in your login keychain);
  - the **offline model** (Apple Silicon only, see below).

## Build and install

```sh
git clone https://github.com/YonahBerthels/TeXSnap.git
cd TeXSnap
scripts/build-app.sh --install      # builds build/TeXSnap.app and copies it to /Applications
open /Applications/TeXSnap.app
```

The first snip asks for **Screen Recording** permission (System Settings › Privacy & Security ›
Screen & System Audio Recording); turn TeXSnap on there, then quit and reopen it.

TeXSnap has no Dock icon. If the √x icon does not show up in a full menu bar on a Mac with a notch, hold ⌘ and
drag another menu bar icon out of the way, or check System Settings › Menu Bar.

## Offline model (optional)

A fine-tuned PaddleOCR-VL (0.9B parameters, ≈1 GB) that transcribes on your Mac without a network connection:
about 0.4 s per snip on an M-series Mac once loaded. It needs an Apple Silicon Mac and
[uv](https://docs.astral.sh/uv/) (`curl -LsSf https://astral.sh/uv/install.sh | sh`).

```sh
scripts/install-model.sh
```

This downloads the model from this repository's release, checks it, sets up a small Python environment for it
in `~/Library/Application Support/TeXSnap/LocalModel` (≈1.6 GB in total) and tests it. Then open Settings
and choose **Engine › On this Mac (offline)**. The model loads on the first snip and unloads after two idle
minutes. Double-check still uses Claude when it is set up.

It is less accurate than Claude, mostly on tables with cells merged across rows, handwriting and unusual
layouts. When you correct one of its results (by editing it, or with Double-check), TeXSnap keeps the image and
the corrected LaTeX in `~/Library/Application Support/TeXSnap/Corrections`, ready to train the next version on
(Settings › Offline model training; nothing leaves your Mac). Details and how it was trained: [ml/README.md](ml/README.md) and [ml/MODEL_CARD.md](ml/MODEL_CARD.md).

## Privacy

- With a Claude engine, each snip's image is sent to Anthropic (through Claude Code or the API). With the offline
  model nothing leaves your Mac.
- An API key is stored in your login keychain, never in a file. The snip history stays in
  `~/Library/Application Support/TeXSnap`.

## Development

```sh
swift build                           # compile
node --test Tests/latexkit.test.js    # LaTeX normalization, validation and conversion (Resources/web/latexkit.js)
python3 Tests/mock_api_test.py        # the API engine against a local mock server (no key needed)
```

The app binary also has a command line mode (`TeXSnap --help` for `--recognize`, `--render-preview` and more),
which the tests and the training tools use.

## License and credits

TeXSnap is released under the [MIT License](LICENSE). It bundles [KaTeX](https://katex.org) (MIT); the offline
model is a fine-tuned [PaddleOCR-VL](https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6) and is distributed
separately under Apache 2.0. See [CREDITS.md](CREDITS.md) for everything TeXSnap builds on, including the
training data.

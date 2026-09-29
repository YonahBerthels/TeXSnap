# TeXSnap local model

An offline recognizer for TeXSnap: PaddleOCR-VL 1.6 (0.9B parameters) fine-tuned with LoRA on
synthetic screenshots, so it answers in the same `<kind>…</kind><latex>…</latex>` format as Claude
and the app's parsing, validation and preview work unchanged.

All commands run from this folder with the venv's Python (`uv venv --python 3.12 .venv` and
`uv pip install --python .venv/bin/python 'mlx-vlm[train]' torch torchvision pyarrow`).

## Pipeline

1. **Sources** (`data/src/`, not in git)
   - `formulas_raw.txt`: 1M arXiv formulas from `OleehyO/latex-formulas` (raw_formulas parquet, one JSON string per line).
   - `abstracts_math.txt`: 120k arXiv abstracts with inline math, streamed from `gfissore/arxiv-abstracts-2021`
     through `gen/pick_abstracts.py`.
2. **Filter formulas**: `node filter_formulas.js data/src/formulas_raw.txt data/formulas.jsonl` keeps the ones KaTeX
   (so the app) renders, without custom macros, normalized with LatexKit (≈430k).
3. **Build a dataset**: `.venv/bin/python gen/build.py --out data/ds1 --train 20000 --val 400`
   - `gen/content.py` makes formulas, synthetic tables and text (paragraphs, displays, lists, theorems, headings).
   - `gen/validate.js` normalizes each target with LatexKit and drops what the app would flag.
   - `gen/render.py` renders 150 samples per pdflatex run in one of ten font setups, rasterizes with Ghostscript and
     turns each page into a screenshot (zoom level, dark mode, tints, padding, JPEG, blur).
   - `gen/sheet.py <split> out.png` makes a contact sheet for eyeballing.
4. **Train**: `train.py` is `mlx_vlm.lora` with the vision encoder frozen (mlx-vlm misses PaddleOCR-VL's `visual`
   and would otherwise train all 445M vision weights):

       .venv/bin/python train.py --model-path OpenGryd/PaddleOCR-VL-1.6-MLX-16bit --dataset data/ds1 --split train \
         --epochs 1 --batch-size 1 --gradient-accumulation-steps 4 --learning-rate 1e-4 --lora-rank 16 \
         --lora-alpha 32 --train-on-completions --max-seq-length 3072 --steps-per-save 2000 \
         --output-path runs/r1/adapters.safetensors

   About 3 samples/s on an M4 Pro, peak ≈ 10 GB.
5. **Evaluate**: `bench.py texsnap --adapter runs/r1 [--data DIR] --tag NAME`, then `node score.js results/NAME.jsonl`.
   The score compares rendered MathML/HTML, so `a ^ { 2 }` and `a^2` count as equal.
   Test sets: `Tests/fixtures` (38 hand-made), `data/ds1/validation` (held out), and `data/webtest`
   (held-out samples rendered by KaTeX in WebKit via `gen/make_web_test.py`: web-page and chat-answer screenshots,
   a look the training data does not have).
6. **Install**: `.venv/bin/python install_local.py runs/r1/adapters.safetensors` fuses the adapter, quantizes to
   8-bit (≈1 GB), smoke-tests it and installs it to `~/Library/Application Support/TeXSnap/LocalModel`.
   Then choose *On this Mac (offline)* in TeXSnap's Settings.
7. **Learn from real use**: TeXSnap saves corrections of the offline model (edits and Double-check fixes) to
   `~/Library/Application Support/TeXSnap/Corrections` in this same dataset format. Mix them into the next run,
   repeated so a few hundred real examples weigh against thousands of synthetic ones (`DIR*5` = each row five
   times), and continue from the installed adapter:

       .venv/bin/python gen/mix.py --out data/ds3 --add data/ds1/train:6000 \
         --add "$HOME/Library/Application Support/TeXSnap/Corrections*5"
       .venv/bin/python train.py --adapter-path runs/r1-8000 --dataset data/ds3 ...   # as in step 4

   Evaluate on both test sets before installing (step 5): corrections are few, so watch for regressions.
8. **Share**: zip the installed `model/` folder as `texsnap-model-vN/` together with `MODEL_CARD.md` (as README.md)
   and the base model's Apache-2.0 `LICENSE`, attach it to a GitHub release, and update `TAG`, `ASSET` and
   `SHA256` in `scripts/install-model.sh`, which is what other people run (it needs only
   `requirements-serve.txt`, not the training environment).

## In the app

`Sources/TeXSnap/Recognition/LocalEngine.swift` starts `serve.py` (JSON lines over stdin/stdout) on the first
local snip and stops it after two idle minutes. Auto-repair is skipped for the local engine; Double-check uses
Claude when an API key or Claude Code is available.

## Results (September 2026)

Similarity of the rendered output to the reference (1.0 = renders the same), `score.js`:

| Model | Tests/fixtures (38) | webtest (80, KaTeX) | Time per snip |
|---|---|---|---|
| PaddleOCR-VL 1.6, zero-shot, task prompts | 0.81 | 0.82 | 0.37 s |
| r1, step 2000 | 0.93 | 0.95 | |
| **r1, step 8000 (installed, 8-bit)** | **0.945** | **0.967** | **0.4 s** (warm), 2.3 GB peak |
| r2 (r1-8000 + 6k table-heavy samples) | 0.944 | 0.942 | |

r2 improved fixture tables a little but lost on the KaTeX set, so r1 step 8000 is installed.
Known weak spots: `\multirow` tables, column alignment letters, and web-style (KaTeX) screenshots, which
the training data does not include yet — rendering part of it with KaTeX is the most promising next step.

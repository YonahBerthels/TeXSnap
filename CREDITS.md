# Credits

TeXSnap's own code is MIT licensed (see [LICENSE](LICENSE)). It builds on the work below; thank you to everyone
involved.

## Included in the app

| Project | Used for | License |
|---|---|---|
| [KaTeX](https://katex.org) (Khan Academy and contributors) | Rendering previews, validating LaTeX, MathML output; bundled in `Resources/web/katex` with its fonts | MIT (`Resources/web/katex/LICENSE`) |

## The offline model

The model is distributed separately, as a [GitHub release](https://github.com/YonahBerthels/TeXSnap/releases/tag/model-v1),
under the Apache License 2.0 like the model it is based on. Its model card (`ml/MODEL_CARD.md`) describes the changes.

| Project | Used for | License |
|---|---|---|
| [PaddleOCR-VL 1.6](https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6) (PaddlePaddle / Baidu) | The base model that was fine-tuned | Apache 2.0 |
| [PaddleOCR-VL-1.6-MLX-16bit](https://huggingface.co/OpenGryd/PaddleOCR-VL-1.6-MLX-16bit) (OpenGryd) | The MLX conversion that training started from | Apache 2.0 |
| [MLX](https://github.com/ml-explore/mlx) (Apple) | Running the model on Apple Silicon | MIT |
| [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) (Prince Canuma and contributors) | Loading, fine-tuning (LoRA), quantizing and serving the model | MIT |
| [Transformers](https://github.com/huggingface/transformers) (Hugging Face) | Tokenizer and image processor | Apache 2.0 |

## Training data

Used to generate the synthetic training images; not redistributed in this repository.

| Dataset | Used for | License |
|---|---|---|
| [latex-formulas](https://huggingface.co/datasets/OleehyO/latex-formulas) (OleehyO) | Formulas, collected from arXiv papers | OpenRAIL |
| [arxiv-abstracts-2021](https://huggingface.co/datasets/gfissore/arxiv-abstracts-2021) (gfissore) | Prose with inline math for text snips | CC0 1.0 |

The formulas and abstracts were written by the authors of the arXiv papers they come from.

## Tools

Used during development and training, not distributed: [TeX Live](https://tug.org/texlive/) and its fonts (rendering
training images), [Ghostscript](https://www.ghostscript.com) (rasterizing them), [Pillow](https://python-pillow.org),
[Hugging Face Datasets](https://github.com/huggingface/datasets) and [uv](https://docs.astral.sh/uv/).

## Recognition with Claude

The Claude engines send snips to [Claude](https://www.anthropic.com/claude) by Anthropic, through
[Claude Code](https://claude.com/claude-code) or the Anthropic API, under your own account and Anthropic's terms.

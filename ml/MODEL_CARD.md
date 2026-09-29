# TeXSnap local model v1

Offline screenshot-to-LaTeX model for [TeXSnap](../README.md). It reads a cropped screenshot of a formula,
table or passage of mathematical text and answers in TeXSnap's format:

    <kind>math|table|text|none</kind>
    <latex>
    ...
    </latex>

- **Base model:** [PaddlePaddle/PaddleOCR-VL-1.6](https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6)
  (0.9B parameters), via the MLX conversion
  [OpenGryd/PaddleOCR-VL-1.6-MLX-16bit](https://huggingface.co/OpenGryd/PaddleOCR-VL-1.6-MLX-16bit).
- **Fine-tuning:** LoRA (rank 16) on the language model, vision encoder frozen, 8,000 synthetic screenshots
  rendered with pdflatex in ten font setups; adapter fused and quantized to 8-bit (MLX, ≈1 GB).
- **Training text sources:** formulas from [OleehyO/latex-formulas](https://huggingface.co/datasets/OleehyO/latex-formulas),
  prose from [gfissore/arxiv-abstracts-2021](https://huggingface.co/datasets/gfissore/arxiv-abstracts-2021),
  and generated tables. No images from real documents or users.
- **Runs on:** Apple Silicon Macs with [mlx-vlm](https://github.com/Blaizzy/mlx-vlm) (see `ml/requirements-serve.txt`).
  About 0.4 s per snip on an M4 Pro once loaded, 2.3 GB peak memory.
- **Accuracy:** similarity of the rendered output to the reference 0.945 on TeXSnap's 38 test images and 0.967 on
  80 KaTeX-rendered held-out screenshots (1.0 = renders identically). Weakest on tables with `\multirow`, column
  alignment letters, handwriting and unusual layouts.

## License

The base model is licensed under the Apache License 2.0 (see `LICENSE`), and so is this fine-tuned model.
Modifications: LoRA fine-tuning for TeXSnap's output format and 8-bit quantization.

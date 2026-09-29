#!/usr/bin/env python3
"""Fuses a trained LoRA adapter into the base model, quantizes it, and installs it for the app.

Usage: .venv/bin/python install_local.py runs/r1/adapters.safetensors [--bits 8] [--out DIR] [--name NAME]
Installs to ~/Library/Application Support/TeXSnap/LocalModel (model/, serve.py, runtime.json),
which LocalEngine.swift reads. Also usable with --out elsewhere to build a model for benchmarking only.
"""
import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = "OpenGryd/PaddleOCR-VL-1.6-MLX-16bit"
DEFAULT_OUT = Path.home() / "Library" / "Application Support" / "TeXSnap" / "LocalModel"


def fuse_and_save(adapter, bits, model_dir: Path):
    import mlx.core as mx
    from mlx.utils import tree_unflatten
    from mlx_vlm import load
    from mlx_vlm.utils import get_model_path, save_config, save_weights, skip_multimodal_module

    adapter = str(Path(adapter).parent if Path(adapter).is_file() else Path(adapter))
    model, processor = load(BASE, adapter_path=adapter, trust_remote_code=True)
    fused = [(name, module.fuse()) for name, module in model.named_modules() if hasattr(module, "fuse")]
    if not fused:
        sys.exit("no LoRA layers found in the adapter")
    model.update_modules(tree_unflatten(fused))
    print(f"fused {len(fused)} LoRA layers")

    base_path = get_model_path(BASE)
    config = json.load(open(base_path / "config.json"))
    config.pop("lora", None)
    if bits:
        from mlx_vlm.quant_utils import quantize_model

        predicate = getattr(model, "quant_predicate", None)

        def quant_predicate(path, module):
            if skip_multimodal_module(path):
                return False
            return predicate(path, module) if predicate else True

        config.setdefault("vision_config", {})
        model, config = quantize_model(model, config, 64, bits, mode="affine", quant_predicate=quant_predicate)
        print(f"quantized to {bits}-bit")
    mx.eval(model.parameters())

    if model_dir.exists():
        shutil.rmtree(model_dir)
    model_dir.mkdir(parents=True)
    save_weights(model_dir, model, donate_weights=True)
    for pattern in ("*.py", "*.json", "*.jinja", "*.txt", "*.model"):
        for f in glob.glob(str(base_path / pattern)):
            if Path(f).name != "model.safetensors.index.json":
                shutil.copyfile(f, model_dir / Path(f).name)  # contents only: the HF cache is read-only
    if hasattr(processor, "save_pretrained"):
        processor.save_pretrained(model_dir)
    save_config(config, config_path=model_dir / "config.json")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("adapter")
    ap.add_argument("--bits", type=int, default=8, help="0 keeps 16-bit weights")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--name", default=None)
    args = ap.parse_args()

    out = args.out.expanduser()
    staging = out.with_name(out.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    fuse_and_save(args.adapter, args.bits, staging / "model")
    shutil.copy(HERE / "serve.py", staging / "serve.py")
    name = args.name or f"TeXSnap local ({Path(args.adapter).parent.name}, {args.bits or 16}-bit)"
    runtime = {"python": str(Path(sys.executable).absolute()), "server": str(out / "serve.py"),
               "model": str(out / "model"), "name": name}
    (staging / "runtime.json").write_text(json.dumps(runtime, indent=2) + "\n")

    # Smoke test before replacing a working install.
    probe = json.dumps({"id": 1, "image": str(HERE.parent / "Tests" / "fixtures" / "quadratic.png"),
                        "prompt": "Transcribe this image into LaTeX.", "max_tokens": 200})
    result = subprocess.run([sys.executable, str(staging / "serve.py"), str(staging / "model")],
                            input=probe + "\n", capture_output=True, text=True, timeout=300,
                            env={**os.environ, "HF_HUB_OFFLINE": "1"})
    done = [json.loads(l) for l in result.stdout.splitlines() if '"done"' in l]
    if not done:
        sys.exit("smoke test failed:\n" + result.stdout[-800:] + result.stderr[-1500:])
    print("smoke test:", done[0]["text"].replace("\n", " "), f"({done[0]['seconds']} s)")

    if out.exists():
        shutil.rmtree(out)
    staging.rename(out)
    print(f"installed {name} to {out}")


if __name__ == "__main__":
    main()

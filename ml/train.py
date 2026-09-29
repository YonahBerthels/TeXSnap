#!/usr/bin/env python3
"""mlx_vlm.lora with the vision encoder frozen.

mlx-vlm freezes towers by name, and PaddleOCR-VL calls its encoder `visual`, which is not on its list,
so plain `mlx_vlm.lora` silently trains all 445M vision weights. Same arguments as mlx_vlm.lora.
"""
import runpy
import sys

import mlx_vlm.trainer.utils as tu

_freeze_model = tu.freeze_model


def freeze_model(model):
    _freeze_model(model)
    if hasattr(model, "visual"):
        model.visual.freeze()


tu.freeze_model = freeze_model
sys.argv[0] = "mlx_vlm.lora"
runpy.run_module("mlx_vlm.lora", run_name="__main__")

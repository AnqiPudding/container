#
# Image Comparer node - compares two images side by side with a hover slider.
# Inspired by rgthree's Image Comparer, rewritten for ComfyUI V3 API / Nodes 2.0.
#

import os
import json
import random
import time
import numpy as np #type: ignore
import folder_paths #type: ignore
from PIL import Image #type: ignore
from PIL.PngImagePlugin import PngInfo #type: ignore

from comfy_api.latest import io #type: ignore
from ..core import CATEGORY

_PREFIX_APPEND = "_imgcmp_" + ''.join(random.choice("abcdefghijklmnopqrstupvxyz") for _ in range(5))
_COMPRESS_LEVEL = 1


def _save_images_to_temp(image_tensor, metadata=None):
    # Save image tensor to temp folder and return metadata list for UI.
    results = []
    if image_tensor is None:
        return results

    output_dir = folder_paths.get_temp_directory()
    filename_prefix = "EclipseCompare" + _PREFIX_APPEND
    full_output_folder, filename, counter, subfolder, _ = folder_paths.get_save_image_path(
        filename_prefix, output_dir, image_tensor.shape[2], image_tensor.shape[1])

    for batch_number, image in enumerate(image_tensor):
        i = 255. * image.cpu().numpy()
        img = Image.fromarray(np.clip(i, 0, 255).astype(np.uint8))

        filename_with_batch_num = filename.replace("%batch_num%", str(batch_number))
        timestamp = int(time.time() * 1000) % 100000000
        file = f"{filename_with_batch_num}_{counter:05}_{timestamp}_.png"
        img.save(os.path.join(full_output_folder, file), pnginfo=metadata, compress_level=_COMPRESS_LEVEL)

        results.append({
            "filename": file,
            "subfolder": subfolder,
            "type": "temp"
        })
        counter += 1

    return results


class RvImage_ImageComparer(io.ComfyNode):

    @classmethod
    def define_schema(cls):
        return io.Schema(
            node_id="Image Comparer [Eclipse]",
            display_name="Image Comparer",
            description="Compares two images with a hover slider or click mode. Connect image_a and image_b to compare, or connect a single batch to auto-split.",
            category=CATEGORY.MAIN.value + CATEGORY.IMAGE.value,
            is_output_node=True,
            inputs=[
                io.Image.Input("image_a", optional=True, tooltip="First image (left side). If only this is provided with a batch, the first two images are compared."),
                io.Image.Input("image_b", optional=True, tooltip="Second image (right side)."),
            ],
            outputs=[
                io.Image.Output("image", tooltip="Returns the side selected as default (right-click → 'Default output: A/B'). Defaults to image_b (the new/result image), falling back to image_a if empty."),
            ],
            hidden=[io.Hidden.unique_id, io.Hidden.prompt, io.Hidden.extra_pnginfo],
        )

    @classmethod
    def execute(cls, image_a=None, image_b=None):
        prompt = cls.hidden.prompt
        extra_pnginfo = cls.hidden.extra_pnginfo
        unique_id = cls.hidden.unique_id
        metadata = PngInfo()
        if prompt is not None:
            metadata.add_text("prompt", json.dumps(prompt))
        if extra_pnginfo is not None:
            for x in extra_pnginfo:
                metadata.add_text(x, json.dumps(extra_pnginfo[x]))

        ui_data = {"a_images": [], "b_images": []}

        if image_a is not None and len(image_a) > 0:
            ui_data["a_images"] = _save_images_to_temp(image_a, metadata)

        if image_b is not None and len(image_b) > 0:
            ui_data["b_images"] = _save_images_to_temp(image_b, metadata)

        # Default output side ("a" or "b") — read from node properties set via right-click menu.
        # Convention: image_b is typically the new/result image, image_a the original.
        # Defaults to "b" so downstream nodes receive the latest result. User can flip via right-click.
        default_side = "b"
        try:
            workflow = (extra_pnginfo or {}).get("workflow") if isinstance(extra_pnginfo, dict) else None
            if workflow:
                uid_str = str(unique_id)
                for n in workflow.get("nodes", []):
                    if str(n.get("id")) == uid_str:
                        prop = (n.get("properties") or {}).get("default_output")
                        if prop in ("a", "b"):
                            default_side = prop
                        break
        except Exception:
            pass

        a_ok = image_a is not None and len(image_a) > 0
        b_ok = image_b is not None and len(image_b) > 0
        if default_side == "a":
            output_image = image_a if a_ok else image_b
        else:
            output_image = image_b if b_ok else image_a

        return io.NodeOutput(output_image, ui=ui_data)

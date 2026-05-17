# Fast Muter - Virtual node for toggling mute on connected nodes.
# Based on rgthree-comfy by rgthree (https://github.com/rgthree/rgthree-comfy).
# All behavior is handled by the frontend JavaScript (eclipse-mode-nodes.js).

from comfy_api.latest import io #type: ignore
from ..core import CATEGORY

class RvTools_FastMuter(io.ComfyNode):
    @classmethod
    def define_schema(cls):
        return io.Schema(
            node_id="Fast Muter [Eclipse]",
            display_name="Fast Muter",
            category=CATEGORY.MAIN.value + CATEGORY.TOOLS.value,
            inputs=[],
            outputs=[
                io.AnyType.Output("oc", tooltip="Optional connection to other mode nodes."),
            ],
            description="Toggle-mute connected nodes on the canvas.",
        )

    @classmethod
    def execute(cls, **kwargs):
        return io.NodeOutput(None)

from comfy_api.latest import io #type: ignore
from ..core import CATEGORY
from ..core.common import RESOLUTION_PRESETS, RESOLUTION_MAP

MAX_RESOLUTION = 32768

class RvSettings_Image_Resolution(io.ComfyNode):
    @classmethod
    def define_schema(cls):
        return io.Schema(
            node_id="Image Resolution [Eclipse]",
            display_name="Image Resolution",
            category=CATEGORY.MAIN.value + CATEGORY.SETTINGS.value,
            inputs=[
                io.Combo.Input("resolution", options=RESOLUTION_PRESETS, default="1024x1024 (1:1)", tooltip="Select a preset resolution or 'Custom' to enter custom dimensions."),
                io.Int.Input("width", default=1024, min=16, max=MAX_RESOLUTION, step=8, tooltip="Custom width (used when 'Custom' is selected)."),
                io.Int.Input("height", default=1024, min=16, max=MAX_RESOLUTION, step=8, tooltip="Custom height (used when 'Custom' is selected)."),
            ],
            outputs=[
                io.Int.Output("width"),
                io.Int.Output("height"),
            ],
        )

    @classmethod
    def execute(cls, resolution, width, height):
        # Return custom width/height if "Custom" selected, otherwise use preset values.
        if resolution == "Custom":
            return io.NodeOutput(width, height)
        
        preset_width, preset_height = RESOLUTION_MAP.get(resolution, (1024, 1024))
        return io.NodeOutput(preset_width, preset_height)
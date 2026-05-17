#

from comfy_api.latest import io  # type: ignore
from ..core import CATEGORY


class RvTools_ShowText(io.ComfyNode):
    @classmethod
    def define_schema(cls):
        return io.Schema(
            node_id="Show Text [Eclipse]",
            display_name="Show Text",
            category=CATEGORY.MAIN.value + CATEGORY.TEXT.value,
            description="Lightweight text display — shows incoming STRING in a read-only "
                        "multiline widget and passes it through. Smaller and simpler than "
                        "Show Any (no image/mask/JSON handling).",
            inputs=[
                io.String.Input("text", force_input=True,
                    tooltip="Text to display."),
            ],
            outputs=[],
            hidden=[io.Hidden.unique_id, io.Hidden.extra_pnginfo],
            is_output_node=True,
            is_input_list=True,
        )

    @classmethod
    def execute(cls, text):
        unique_id = cls.hidden.unique_id
        extra_pnginfo = cls.hidden.extra_pnginfo

        # Persist displayed text into workflow metadata so it survives reload.
        if unique_id is not None and extra_pnginfo is not None:
            uid = unique_id[0] if isinstance(unique_id, list) else unique_id
            pnginfo = extra_pnginfo[0] if isinstance(extra_pnginfo, list) else extra_pnginfo
            if isinstance(pnginfo, dict) and "workflow" in pnginfo:
                node = next(
                    (x for x in pnginfo["workflow"].get("nodes", [])
                     if str(x.get("id")) == str(uid)),
                    None,
                )
                if node is not None:
                    node["widgets_values"] = [text]

        return io.NodeOutput(ui={"text": text})

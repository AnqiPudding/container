from comfy_api.latest import io #type: ignore
from ..core import CATEGORY, purge_vram
from ..core.logger import log

_LOG_PREFIX = "IfAElseB"

class RvRouter_IfElse(io.ComfyNode):
    @classmethod
    def define_schema(cls):
        return io.Schema(
            node_id="IF A Else B [Eclipse]",
            display_name="IF A Else B",
            category=CATEGORY.MAIN.value + CATEGORY.ROUTER.value,
            inputs=[
                io.AnyType.Input("on_true", tooltip="Value to return if boolean is True."),
                io.AnyType.Input("on_false", tooltip="Value to return if boolean is False."),
                io.Boolean.Input("boolean", force_input=True, tooltip="Condition to select on_true or on_false."),
                io.Boolean.Input("Purge_VRAM", default=False, tooltip="If True, purges VRAM before switching."),
            ],
            outputs=[
                io.AnyType.Output("output"),
            ],
            hidden=[io.Hidden.unique_id],
        )

    @classmethod
    def execute(cls, on_true, on_false, boolean=True, Purge_VRAM=False):
        tag = f"{_LOG_PREFIX} #{cls.hidden.unique_id}"
        if Purge_VRAM:
            purge_vram()
        # Robust boolean handling: when a non-bool value is connected (e.g. AnyType),
        # treat None as False and any non-None value as True.
        # This avoids Python truthiness pitfalls where 0, "", [] are falsy but valid data.
        if not isinstance(boolean, bool):
            boolean = boolean is not None
        log.debug(tag, f"boolean={boolean}, passing {'on_true' if boolean else 'on_false'}")
        if boolean:
            return io.NodeOutput(on_true)
        else:
            return io.NodeOutput(on_false)

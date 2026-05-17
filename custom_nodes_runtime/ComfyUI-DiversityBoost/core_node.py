"""DiversityBoost node — HF attenuation + DCT composition push."""

import time

from comfy_api.latest import io

from .core import build_diversity_fn


class DiversityBoostCoreV3(io.ComfyNode):
    """Restore composition diversity for distilled diffusion models.

    Single post-cfg hook at step 0: first attenuates HF amplitude
    (Butterworth LPF), then applies a random low-frequency DCT spatial
    field to the blurred result.  Push runs AFTER cleanup so its signal
    cannot be erased by downstream processing.
    """

    @classmethod
    def define_schema(cls) -> io.Schema:
        return io.Schema(
            node_id="DiversityBoostCoreV3",
            display_name="Diversity Boost (V3)",
            category="sampling",
            description="Restore composition diversity for distilled models. "
                        "HF attenuation + DCT composition push at step 0.",
            inputs=[
                io.Model.Input("model"),
                io.Float.Input("strength", default=2.0, min=0.0, max=2.0, step=0.05,
                               tooltip="Composition push amplitude. "
                                       "0 = cleanup only. 1.0 = moderate. 2.0 = strong."),
                io.Float.Input("clamp", default=0.5, min=0.1, max=3.0, step=0.1,
                               tooltip="Safety clamp for DCT field values."),
                io.Combo.Input("noise_type",
                               options=["pink", "white", "blue"],
                               default="pink",
                               tooltip="Frequency spectrum of random DCT coefficients. "
                                       "pink = stronger composition push (recommended)."),
                io.Float.Input("dc_preserve", default=0.0, min=0.0, max=1.0, step=0.1,
                               tooltip="DC amplitude preservation (1.0 = keep, 0.0 = zero). "
                                       "Only affects step 0; step 1+ always preserves full DC."),
                io.Boolean.Input("energy_compensate", default=False,
                                 tooltip="Rescale output energy to match original."),
                io.Float.Input("hf_factor", default=1.0, min=0.0, max=1.0, step=0.05,
                               tooltip="High-frequency attenuation [0, 1]. "
                                       "1.0 = full attenuation. Only used in polynomial mode."),
                io.Float.Input("lf_factor", default=0.3, min=0.0, max=1.0, step=0.05,
                               tooltip="Low-frequency amplification [0, 1]. "
                                       "1.0 = +50% boost. Only used in polynomial mode."),
                io.Float.Input("transition", default=2.0, min=0.5, max=4.0, step=0.1,
                               tooltip="Polynomial transition shape. "
                                       "0.5 = steep, 1.0 = linear, 2.0 = smooth, 4.0 = very smooth."),
                io.Combo.Input("schedule",
                               options=["flat", "linear", "cosine"],
                               default="linear",
                               tooltip="Timestep schedule. "
                                       "flat = step 0 only. linear/cosine = progressive decay."),
            ],
            outputs=[
                io.Model.Output(display_name="model"),
            ],
        )

    @classmethod
    def fingerprint_inputs(cls, **kwargs):
        return time.time()

    @classmethod
    def execute(cls, model, strength, clamp, noise_type,
                dc_preserve, energy_compensate,
                hf_factor, lf_factor, transition, schedule) -> io.NodeOutput:
        m = model.clone()

        m.set_model_sampler_post_cfg_function(
            build_diversity_fn(
                strength=strength,
                clamp_val=clamp,
                noise_type=noise_type,
                dc_preserve=dc_preserve,
                energy_compensate=energy_compensate,
                mode="polynomial",
                hf_factor=hf_factor,
                lf_factor=lf_factor,
                transition=transition,
                schedule=schedule,
            ),
        )

        return io.NodeOutput(m)

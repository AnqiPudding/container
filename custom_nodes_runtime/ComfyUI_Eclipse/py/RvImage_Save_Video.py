# Save Video [Eclipse]
#
# Eclipse-flavoured replacement for ComfyUI's built-in SaveVideo with two
# improvements:
#   1. Accepts an IMAGE batch + optional AUDIO + fps directly (built-in needs a
#      VIDEO type) so the node can be wired straight from any generator.
#   2. Adds a `trim_mode` widget that aligns video and audio durations before
#      writing the file (built-in just muxes whatever it gets).
#
# Container/codec match the built-in: mp4 / h264. crf is exposed for quality.

import os
import json
import math
from fractions import Fraction
from typing import Optional

import av  # type: ignore
import torch  # type: ignore
import folder_paths  # type: ignore
from comfy.cli_args import args  # type: ignore

from comfy_api.latest import io  # type: ignore

from ..core import CATEGORY
from ..core.logger import log

_LOG_PREFIX = "SaveVideo"


def _frames_for_audio(audio, fps: float) -> Optional[int]:
    try:
        wf = audio.get("waveform")
        sr = int(audio.get("sample_rate", 0))
        if wf is None or sr <= 0:
            return None
        if wf.ndim == 3:
            wf = wf[0]
        return max(1, int(math.floor((wf.shape[-1] / float(sr)) * float(fps))))
    except Exception:
        return None


def _audio_samples_for_video(num_frames: int, fps: float, sample_rate: int) -> int:
    return max(1, int(round(num_frames * sample_rate / float(fps))))


def _encode(images, fps: float, audio, output_path: str, codec: str, crf: int, metadata) -> None:
    height = int(images.shape[-3])
    width = int(images.shape[-2])

    container = av.open(output_path, mode="w")
    if metadata:
        for k, v in metadata.items():
            try:
                container.metadata[k] = json.dumps(v) if not isinstance(v, str) else v
            except Exception:
                pass

    enc_w = width - (width % 2)
    enc_h = height - (height % 2)

    vstream = container.add_stream(codec, rate=Fraction(round(fps * 1000), 1000))
    vstream.width = enc_w
    vstream.height = enc_h
    vstream.pix_fmt = "yuv420p"
    vstream.options = {"crf": str(crf), "preset": "veryfast", "movflags": "+faststart"}

    astream = None
    if audio is not None and isinstance(audio, dict) and "waveform" in audio and "sample_rate" in audio:
        try:
            sample_rate = int(audio["sample_rate"])
            waveform = audio["waveform"]
            if waveform.ndim == 3:
                waveform = waveform[0]
            channels = int(waveform.shape[0])
            astream = container.add_stream("aac", rate=sample_rate)
            astream.layout = "stereo" if channels >= 2 else "mono"
        except Exception as e:
            log.warning(_LOG_PREFIX, f"Audio stream init failed, skipping audio: {e}")
            astream = None

    for frame in images:
        arr = torch.clamp(frame[..., :3] * 255.0, min=0, max=255).to(
            device=torch.device("cpu"), dtype=torch.uint8
        ).numpy()
        if arr.shape[0] != enc_h or arr.shape[1] != enc_w:
            arr = arr[:enc_h, :enc_w, :]
        vframe = av.VideoFrame.from_ndarray(arr, format="rgb24")
        for packet in vstream.encode(vframe):
            container.mux(packet)
    for packet in vstream.encode():
        container.mux(packet)

    if astream is not None:
        try:
            wf = audio["waveform"]
            if wf.ndim == 3:
                wf = wf[0]
            sample_rate = int(audio["sample_rate"])
            np_audio = wf.detach().to(device=torch.device("cpu"), dtype=torch.float32).contiguous().numpy()
            aframe = av.AudioFrame.from_ndarray(
                np_audio,
                format="fltp",
                layout="stereo" if np_audio.shape[0] >= 2 else "mono",
            )
            aframe.sample_rate = sample_rate
            for packet in astream.encode(aframe):
                container.mux(packet)
            for packet in astream.encode():
                container.mux(packet)
        except Exception as e:
            log.warning(_LOG_PREFIX, f"Audio encode failed (video still saved): {e}")

    container.close()


class RvImage_Save_Video(io.ComfyNode):
    @classmethod
    def define_schema(cls):
        return io.Schema(
            node_id="Save Video [Eclipse]",
            display_name="Save Video",
            category=CATEGORY.MAIN.value + CATEGORY.VIDEO.value,
            description=(
                "Saves an IMAGE batch (+ optional AUDIO) to an mp4 in the output folder. "
                "`trim_mode` aligns video/audio length before writing: "
                "`video_to_audio` shortens the frame batch to the audio duration, "
                "`audio_to_video` shortens the audio to the frame batch length, "
                "`shortest` clips both sides to the shorter duration."
            ),
            inputs=[
                io.Image.Input("images", tooltip="Batch of frames to save."),
                io.Float.Input(
                    "fps", default=24.0, min=1.0, max=240.0, step=0.01,
                    tooltip="Output video frame rate.",
                ),
                io.String.Input(
                    "filename_prefix", default="video/ComfyUI_Eclipse",
                    tooltip="Filename prefix in the output directory.",
                ),
                io.Combo.Input("format", options=["mp4"], default="mp4",
                               tooltip="Output container format."),
                io.Combo.Input("codec", options=["h264"], default="h264",
                               tooltip="Output video codec."),
                io.Int.Input(
                    "crf", default=19, min=0, max=51, step=1,
                    tooltip="Quality factor (lower = higher quality, larger file). 18–23 is a good range.",
                ),
                io.Combo.Input(
                    "trim_mode",
                    options=["none", "video_to_audio", "audio_to_video", "shortest"],
                    default="video_to_audio",
                    tooltip=(
                        "Align frame batch and audio duration before saving. "
                        "Ignored when no audio is connected."
                    ),
                ),
                io.Audio.Input("audio", optional=True, tooltip="Optional audio track to mux."),
            ],
            hidden=[io.Hidden.prompt, io.Hidden.extra_pnginfo],
            is_output_node=True,
        )

    @classmethod
    def execute(cls, images, fps: float, filename_prefix: str, format: str, codec: str,
                crf: int, trim_mode: str, audio: Optional[dict] = None) -> io.NodeOutput:
        if images is None or not hasattr(images, "shape") or images.shape[0] == 0:
            return io.NodeOutput(ui={"eclipse_video": []})

        num_frames = int(images.shape[0])

        # ---- trim alignment ----
        if audio is not None and trim_mode != "none":
            try:
                wf = audio.get("waveform")
                sr = int(audio.get("sample_rate", 0))
                if wf is not None and sr > 0:
                    if wf.ndim == 3:
                        wf_ch = wf[0]
                    else:
                        wf_ch = wf
                    audio_samples = int(wf_ch.shape[-1])
                    audio_frames = max(1, int(math.floor((audio_samples / float(sr)) * float(fps))))
                    target_video_frames = num_frames
                    target_audio_samples = audio_samples

                    if trim_mode == "video_to_audio":
                        target_video_frames = min(num_frames, audio_frames)
                    elif trim_mode == "audio_to_video":
                        target_audio_samples = min(audio_samples, _audio_samples_for_video(num_frames, fps, sr))
                    elif trim_mode == "shortest":
                        target_video_frames = min(num_frames, audio_frames)
                        target_audio_samples = min(audio_samples, _audio_samples_for_video(target_video_frames, fps, sr))

                    if target_video_frames < num_frames:
                        images = images[:target_video_frames]
                        num_frames = target_video_frames
                    if target_audio_samples < audio_samples:
                        new_wf = wf[..., :target_audio_samples] if wf.ndim == 3 else wf_ch[..., :target_audio_samples]
                        audio = {"waveform": new_wf if new_wf.ndim == 3 else new_wf.unsqueeze(0),
                                 "sample_rate": sr}
            except Exception as e:
                log.warning(_LOG_PREFIX, f"Trim alignment failed, saving as-is: {e}")

        height = int(images.shape[-3])
        width = int(images.shape[-2])

        full_output_folder, filename, counter, subfolder, _ = folder_paths.get_save_image_path(
            filename_prefix, folder_paths.get_output_directory(), width, height
        )
        file = f"{filename}_{counter:05}_.mp4"
        out_path = os.path.join(full_output_folder, file)

        metadata = None
        if not args.disable_metadata:
            metadata = {}
            if cls.hidden.extra_pnginfo is not None:
                metadata.update(cls.hidden.extra_pnginfo)
            if cls.hidden.prompt is not None:
                metadata["prompt"] = cls.hidden.prompt

        try:
            _encode(images, fps, audio, out_path, codec=codec, crf=int(crf), metadata=metadata)
        except Exception as e:
            log.error(_LOG_PREFIX, f"Failed to save video: {e}")
            return io.NodeOutput(ui={"eclipse_video": []})

        result = {
            "filename": file,
            "subfolder": subfolder,
            "type": "output",
            "format": "video/mp4",
            "frame_rate": float(fps),
        }
        # Custom ui key so the frontend does NOT auto-create a fixed-size preview
        # widget. The JS extension (eclipse-save-video.js) reads this key from
        # onExecuted and renders a resizable DOM <video> instead.
        return io.NodeOutput(ui={"eclipse_video": [result]})

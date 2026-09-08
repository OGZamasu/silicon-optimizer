"""Video on your own hardware, through Silicon Optimizer.

A model-aware node may be a paired NVIDIA machine or a loopback Apple Silicon
adapter such as Phosphene. ``get_status`` asks the app whether any exact video
model is actually available right now — an offline or disabled runtime is an
honest UNAVAILABLE, not a render that fails five minutes in.
"""

from __future__ import annotations

import time
from typing import Any

from tools.base_tool import (
    BaseTool,
    Determinism,
    ExecutionMode,
    ResourceProfile,
    RetryPolicy,
    ToolResult,
    ToolRuntime,
    ToolStability,
    ToolStatus,
    ToolTier,
)
from tools.silicon import _client


class SiliconVideo(BaseTool):
    name = "silicon_video"
    version = "0.1.0"
    tier = ToolTier.GENERATE
    capability = "video_generation"
    provider = _client.PROVIDER
    stability = ToolStability.BETA
    execution_mode = ExecutionMode.SYNC
    determinism = Determinism.STOCHASTIC
    # A GPU on one of the user's own machines, reached through the node contract.
    runtime = ToolRuntime.LOCAL_GPU

    dependencies: list[str] = []
    install_instructions = (
        "Open Silicon Optimizer and enable a model-aware video node: either pair an "
        "NVIDIA machine from the Swarm tab or run the local Phosphene adapter on the Mac."
    )

    capabilities = ["text_to_video", "image_to_video", "offline_generation"]
    supports = {
        "text_to_video": True,
        "image_to_video": True,
        "offline": True,  # your network, not the internet
        "audio": False,
    }
    best_for = [
        "every clip where the budget is zero",
        "material that must stay on your own machines",
        "iterating on a shot without a per-second meter running",
    ]
    not_good_for = [
        "a setup with no ready model-aware video node",
        "clip lengths outside the selected model's advertised choices",
    ]

    input_schema = {
        "type": "object",
        "required": ["prompt"],
        "properties": {
            "prompt": {"type": "string"},
            "operation": {"type": "string", "enum": ["text_to_video", "image_to_video"], "default": "text_to_video"},
            "reference_image_path": {"type": "string", "description": "The still to animate, for image_to_video."},
            "duration_seconds": {"type": "integer", "description": "Omit to take the node's model default."},
            "resolution": {"type": "string", "description": "e.g. 1280x720. Omit for the model default."},
            "model": {"type": "string", "description": "An id from the app's Video tab. Omit for its current choice."},
            "output_path": {"type": "string"},
        },
    }

    resource_profile = ResourceProfile(cpu_cores=1, ram_mb=256, vram_mb=0, disk_mb=200, network_required=True)
    retry_policy = RetryPolicy(max_retries=0)
    idempotency_key_fields = ["prompt", "operation", "reference_image_path", "duration_seconds", "resolution", "model"]
    side_effects = ["renders on the paired node; writes the clip to the app's output folder, and to output_path when given"]
    user_visible_verification = ["Play the clip — the app's Video tab also lists it"]

    def get_status(self) -> ToolStatus:
        if not _client.is_running():
            return ToolStatus.UNAVAILABLE
        try:
            models = _client.get("/video/models")
        except (_client.SiliconUnavailable, _client.SiliconError):
            return ToolStatus.UNAVAILABLE
        return ToolStatus.AVAILABLE if any(m.get("available") for m in models) else ToolStatus.UNAVAILABLE

    def estimate_cost(self, inputs: dict[str, Any]) -> float:
        return 0.0

    def estimate_runtime(self, inputs: dict[str, Any]) -> float:
        # The node reports typical durations per model; four minutes is the safe middle.
        return 240.0

    @staticmethod
    def request_body(inputs: dict[str, Any]) -> dict[str, Any]:
        """The app's VideoGenerateRequest, from OpenMontage's input names."""
        image = inputs.get("reference_image_path") if inputs.get("operation", "text_to_video") == "image_to_video" else None
        return _client.drop_none({
            "prompt": inputs["prompt"],
            "modelID": inputs.get("model"),
            "seconds": inputs.get("duration_seconds"),
            "resolution": inputs.get("resolution"),
            "imagePath": image,
        })

    def execute(self, inputs: dict[str, Any]) -> ToolResult:
        prompt = (inputs.get("prompt") or "").strip()
        if not prompt:
            return ToolResult(success=False, error="prompt is required")
        operation = inputs.get("operation", "text_to_video")
        if operation == "image_to_video" and not inputs.get("reference_image_path"):
            return ToolResult(success=False, error="image_to_video needs reference_image_path")

        started = time.time()
        try:
            answer = _client.post("/video/generate", self.request_body(inputs), _client.VIDEO_TIMEOUT_SECONDS)
        except _client.SiliconUnavailable as exc:
            return ToolResult(success=False, error=f"{exc} {self.install_instructions}")
        except _client.SiliconError as exc:
            return ToolResult(success=False, error=str(exc))

        output = _client.deliver(answer["file"], inputs.get("output_path"))
        return ToolResult(
            success=True,
            data={
                "provider": self.provider,
                "model": answer.get("model"),
                "node": answer.get("node"),
                "prompt": prompt,
                "operation": operation,
                "output": output,
                "output_path": output,
                "format": "mp4",
                "elapsed_seconds": answer.get("elapsedSeconds"),
            },
            artifacts=[output],
            cost_usd=0.0,
            duration_seconds=round(time.time() - started, 2),
            model=answer.get("model"),
        )

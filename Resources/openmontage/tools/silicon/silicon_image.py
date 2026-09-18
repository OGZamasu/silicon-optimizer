"""Images on this Mac, through Silicon Optimizer."""

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


class SiliconImage(BaseTool):
    name = "silicon_image"
    version = "0.1.0"
    tier = ToolTier.GENERATE
    capability = "image_generation"
    provider = _client.PROVIDER
    stability = ToolStability.BETA
    execution_mode = ExecutionMode.SYNC
    determinism = Determinism.SEEDED
    # This provider deliberately sets localOnly on every request: its privacy claim is an
    # enforced routing constraint, not guidance that an automatic scheduler may ignore.
    runtime = ToolRuntime.LOCAL

    dependencies: list[str] = []
    install_instructions = (
        "Open Silicon Optimizer on this Mac. Images need its one optional install — "
        "Settings shows a button for it — and any model from its Images tab works here."
    )

    capabilities = ["text_to_image", "image_to_image", "offline_generation"]
    supports = {
        "negative_prompt": False,  # FLUX-family models take none; the key is accepted and ignored
        "seed": True,
        "image_to_image": True,
        "offline": True,
    }
    best_for = [
        "every image where the budget is zero",
        "private material that must not leave this Mac",
        "iterating: no queue, no meter, re-render until it is right",
    ]
    not_good_for = [
        "a Mac with under 16 GB of memory running a large model",
        "photoreal video frames — use silicon_video for motion",
    ]

    input_schema = {
        "type": "object",
        "required": ["prompt"],
        "properties": {
            "prompt": {"type": "string"},
            "negative_prompt": {"type": "string", "description": "Accepted for compatibility; FLUX-family models ignore it."},
            "width": {"type": "integer", "default": 1024},
            "height": {"type": "integer", "default": 1024},
            "steps": {"type": "integer", "description": "Omit to take the model's own default."},
            "seed": {"type": "integer"},
            "model": {"type": "string", "description": "An id from the app's Images tab. Omit for its current choice."},
            "reference_image_path": {"type": "string", "description": "Start from this image instead of noise."},
            "reference_strength": {"type": "number", "minimum": 0, "maximum": 1, "description": "How closely to follow the reference. 0.6 is a good start."},
            "output_path": {"type": "string"},
        },
    }

    resource_profile = ResourceProfile(cpu_cores=4, ram_mb=8192, vram_mb=0, disk_mb=50, network_required=False)
    retry_policy = RetryPolicy(max_retries=0)
    idempotency_key_fields = ["prompt", "width", "height", "steps", "seed", "model"]
    side_effects = ["writes an image to the app's output folder, and to output_path when given"]
    user_visible_verification = ["Open the image — the app's Images tab also lists it"]

    def get_status(self) -> ToolStatus:
        return ToolStatus.AVAILABLE if _client.is_running() else ToolStatus.UNAVAILABLE

    def estimate_cost(self, inputs: dict[str, Any]) -> float:
        return 0.0

    def estimate_runtime(self, inputs: dict[str, Any]) -> float:
        # Seconds on this Mac. The enforced localOnly request may still need to load a model;
        # the app's Images tab shows the same progress.
        return 60.0

    @staticmethod
    def request_body(inputs: dict[str, Any]) -> dict[str, Any]:
        """The app's ImageRequest, from OpenMontage's input names."""
        return _client.drop_none({
            "prompt": inputs["prompt"],
            "modelID": inputs.get("model"),
            "width": inputs.get("width"),
            "height": inputs.get("height"),
            "steps": inputs.get("steps"),
            "seed": inputs.get("seed"),
            "initImagePath": inputs.get("reference_image_path"),
            "initImageInfluence": inputs.get("reference_strength"),
            "localOnly": True,
        })

    def execute(self, inputs: dict[str, Any]) -> ToolResult:
        prompt = (inputs.get("prompt") or "").strip()
        if not prompt:
            return ToolResult(success=False, error="prompt is required")

        started = time.time()
        try:
            answer = _client.post("/image/generate", self.request_body(inputs), _client.IMAGE_TIMEOUT_SECONDS)
        except _client.SiliconUnavailable as exc:
            return ToolResult(success=False, error=f"{exc} {self.install_instructions}")
        except _client.SiliconError as exc:
            return ToolResult(success=False, error=str(exc))

        output = _client.deliver(answer["path"], inputs.get("output_path"))
        return ToolResult(
            success=True,
            data={
                "provider": self.provider,
                "model": answer.get("model"),
                "prompt": prompt,
                "output": output,
                "outputs": [output],
                "output_path": output,
                "images_generated": 1,
                "elapsed_seconds": answer.get("elapsedSeconds"),
                "execution_destination": "this Mac",
                # The app warns instead of refusing when a render is predicted to be
                # tight on memory; pass that through so the agent can plan around it.
                "warning": answer.get("warning"),
            },
            artifacts=[output],
            cost_usd=0.0,
            duration_seconds=round(time.time() - started, 2),
            seed=inputs.get("seed"),
            model=answer.get("model"),
        )

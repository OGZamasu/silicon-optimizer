"""Face tracking: your expressions, as numbers, for anything that can wear them.

MediaPipe's Face Landmarker reads 52 ARKit-named blendshapes and a head transform
from the camera. That is the same vocabulary Apple's ARKit produces and the same one
every serious VTuber tool already speaks, so the numbers here go two places at once:

  * JSON on localhost, which the app's own overlay reads to move a 2D character; and
  * the VMC protocol over OSC, which VSeeFace, VTube Studio, Warudo, Inochi2D and
    anything else in that family accept — so a properly rigged Live2D or VRM model
    can be driven by this without the app pretending to be a rigging engine.

Usage:
    tracker.py --model face_landmarker.task --camera 0 --port 8792
               [--osc-host 127.0.0.1 --osc-port 39539] [--mirror]
"""

import argparse
import json
import math
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "tracking": False,
    "stage": "starting",
    "fps": 0.0,
    # Head rotation in degrees and translation in normalized units.
    "yaw": 0.0, "pitch": 0.0, "roll": 0.0,
    "x": 0.0, "y": 0.0, "z": 0.0,
    # The handful of expressions a 2D avatar actually needs, pre-mixed.
    "mouthOpen": 0.0, "smile": 0.0, "blink": 0.0,
    "blinkLeft": 0.0, "blinkRight": 0.0, "browRaise": 0.0,
    # Everything MediaPipe gives, for anyone who wants the full set.
    "blendshapes": {},
    # Upper body, when body tracking is on: how far the shoulders lean and turn,
    # and where the hands are. A VTuber that only has a face is half a puppet.
    "body": False,
    "lean": 0.0, "shoulderTilt": 0.0, "bodyTurn": 0.0,
    "leftHand": None, "rightHand": None,
    "error": None,
}
LOCK = threading.Lock()


def log(message):
    STATE["stage"] = message
    print(f"stage: {message}", flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path.split("?")[0] not in ("/", "/state"):
            self.send_error(404)
            return
        with LOCK:
            body = json.dumps(STATE).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        # The overlay is served by the app on a different port; without this the
        # browser refuses to read tracking at all.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)


def euler_from_matrix(matrix):
    """Head rotation in degrees from MediaPipe's 4x4 face transform."""
    rotation = matrix[:3, :3]
    sy = math.sqrt(rotation[0, 0] ** 2 + rotation[1, 0] ** 2)
    if sy > 1e-6:
        pitch = math.atan2(rotation[2, 1], rotation[2, 2])
        yaw = math.atan2(-rotation[2, 0], sy)
        roll = math.atan2(rotation[1, 0], rotation[0, 0])
    else:
        pitch = math.atan2(-rotation[1, 2], rotation[1, 1])
        yaw = math.atan2(-rotation[2, 0], sy)
        roll = 0.0
    return math.degrees(yaw), math.degrees(pitch), math.degrees(roll)


def quaternion(yaw_deg, pitch_deg, roll_deg):
    """VMC carries bone rotation as a quaternion, so convert once, here."""
    yaw, pitch, roll = (math.radians(a) for a in (yaw_deg, pitch_deg, roll_deg))
    cy, sy = math.cos(yaw * 0.5), math.sin(yaw * 0.5)
    cp, sp = math.cos(pitch * 0.5), math.sin(pitch * 0.5)
    cr, sr = math.cos(roll * 0.5), math.sin(roll * 0.5)
    return (
        sp * cy * cr - cp * sy * sr,   # x
        cp * sy * cr + sp * cy * sr,   # y
        cp * cy * sr - sp * sy * cr,   # z
        cp * cy * cr + sp * sy * sr,   # w
    )


class Smoother:
    """Tracking is jittery frame to frame; a light exponential filter is the
    difference between a character that looks alive and one that vibrates."""

    def __init__(self, factor=0.45):
        self.factor = factor
        self.values = {}

    def __call__(self, key, value):
        previous = self.values.get(key, value)
        smoothed = previous + (value - previous) * self.factor
        self.values[key] = smoothed
        return smoothed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    # A camera index, or a video file: recorded performances are a real workflow,
    # and it is the only way to test the pipeline without a camera attached.
    parser.add_argument("--camera", default="0")
    parser.add_argument("--port", type=int, default=8792)
    parser.add_argument("--osc-host", default="")
    parser.add_argument("--osc-port", type=int, default=39539)
    parser.add_argument("--mirror", action="store_true")
    parser.add_argument("--smoothing", type=float, default=0.45)
    parser.add_argument("--pose-model", default="")
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    arguments = parser.parse_args()

    log("Loading the tracker")
    import cv2
    import mediapipe as mp
    import numpy as np
    from mediapipe.tasks import python as mp_python
    from mediapipe.tasks.python import vision

    landmarker = vision.FaceLandmarker.create_from_options(
        vision.FaceLandmarkerOptions(
            base_options=mp_python.BaseOptions(model_asset_path=arguments.model),
            running_mode=vision.RunningMode.VIDEO,
            output_face_blendshapes=True,
            output_facial_transformation_matrixes=True,
            num_faces=1,
        )
    )

    pose_landmarker = None
    if arguments.pose_model:
        pose_landmarker = vision.PoseLandmarker.create_from_options(
            vision.PoseLandmarkerOptions(
                base_options=mp_python.BaseOptions(model_asset_path=arguments.pose_model),
                running_mode=vision.RunningMode.VIDEO,
                num_poses=1,
                output_segmentation_masks=False,
            )
        )
        log("Body tracking on")

    sender = None
    if arguments.osc_host:
        from pythonosc.udp_client import SimpleUDPClient

        sender = SimpleUDPClient(arguments.osc_host, arguments.osc_port)
        log(f"Sending VMC to {arguments.osc_host}:{arguments.osc_port}")

    source = int(arguments.camera) if arguments.camera.isdigit() else arguments.camera
    log("Opening the camera" if isinstance(source, int) else "Opening the video")
    capture = cv2.VideoCapture(source)
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, arguments.width)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, arguments.height)
    if not capture.isOpened():
        print("fatal: camera unavailable", flush=True)
        return 2

    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"ready: http://127.0.0.1:{arguments.port}/state", flush=True)
    log("Tracking")

    smoother = Smoother(max(0.05, min(1.0, arguments.smoothing)))
    frames, window_started = 0, time.time()
    started = time.time()

    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                if not isinstance(source, int):
                    # A file has an end; loop it so a recorded performance repeats
                    # instead of freezing the character on its last frame.
                    capture.set(cv2.CAP_PROP_POS_FRAMES, 0)
                    continue
                time.sleep(0.03)
                continue
            if arguments.mirror:
                frame = cv2.flip(frame, 1)

            image = mp.Image(
                image_format=mp.ImageFormat.SRGB,
                data=cv2.cvtColor(frame, cv2.COLOR_BGR2RGB),
            )
            timestamp = int((time.time() - started) * 1000)
            result = landmarker.detect_for_video(image, timestamp)

            if result.face_blendshapes:
                scores = {c.category_name: c.score for c in result.face_blendshapes[0]}
                yaw = pitch = roll = 0.0
                x = y = z = 0.0
                if result.facial_transformation_matrixes:
                    matrix = np.array(result.facial_transformation_matrixes[0])
                    yaw, pitch, roll = euler_from_matrix(matrix)
                    x, y, z = (float(v) for v in matrix[:3, 3])

                blink_left = scores.get("eyeBlinkLeft", 0.0)
                blink_right = scores.get("eyeBlinkRight", 0.0)
                with LOCK:
                    STATE.update(
                        tracking=True,
                        yaw=round(smoother("yaw", yaw), 2),
                        pitch=round(smoother("pitch", pitch), 2),
                        roll=round(smoother("roll", roll), 2),
                        x=round(smoother("x", x), 3),
                        y=round(smoother("y", y), 3),
                        z=round(smoother("z", z), 3),
                        mouthOpen=round(smoother("jaw", scores.get("jawOpen", 0.0)), 3),
                        smile=round(smoother("smile", max(
                            scores.get("mouthSmileLeft", 0.0),
                            scores.get("mouthSmileRight", 0.0),
                        )), 3),
                        blinkLeft=round(smoother("blinkL", blink_left), 3),
                        blinkRight=round(smoother("blinkR", blink_right), 3),
                        blink=round(smoother("blink", max(blink_left, blink_right)), 3),
                        browRaise=round(smoother("brow", max(
                            scores.get("browInnerUp", 0.0),
                            scores.get("browOuterUpLeft", 0.0),
                            scores.get("browOuterUpRight", 0.0),
                        )), 3),
                        blendshapes={k: round(v, 3) for k, v in scores.items()},
                        error=None,
                    )

                if pose_landmarker is not None:
                    read_body(pose_landmarker, image, timestamp, smoother)

                if sender is not None:
                    send_vmc(sender, scores, STATE)
            else:
                with LOCK:
                    STATE["tracking"] = False

            frames += 1
            elapsed = time.time() - window_started
            if elapsed >= 1.0:
                with LOCK:
                    STATE["fps"] = round(frames / elapsed, 1)
                print(f"fps: {STATE['fps']}", flush=True)
                frames, window_started = 0, time.time()
    except KeyboardInterrupt:
        pass
    finally:
        capture.release()
        server.shutdown()
    return 0


def body_from_landmarks(points):
    """Shoulders and hands, reduced to the few numbers a puppet actually uses.

    MediaPipe gives 33 body landmarks; a 2D character needs three of them — how far
    the shoulders tilt, how much the body leans, how far it has turned — plus where
    the hands are for anyone rigging arms. Sending 33 raw points would be honest and
    useless. Kept apart from the detector so the arithmetic can be checked against
    known geometry rather than against whatever the camera happened to see.
    """
    left, right = points[11], points[12]           # shoulders
    hips_left, hips_right = points[23], points[24]

    # Tilt: one shoulder higher than the other, in degrees. Positive when the
    # character's right shoulder (screen left) is the higher one.
    tilt = math.degrees(math.atan2(right.y - left.y, abs(right.x - left.x) + 1e-6))
    # Turn: shoulders sit at different depths as the body rotates away from camera.
    turn = max(-1.0, min(1.0, (right.z - left.z) * 2))
    # Lean: shoulder centre offset from hip centre.
    lean = ((left.x + right.x) / 2) - ((hips_left.x + hips_right.x) / 2)

    return {
        "shoulderTilt": tilt,
        "bodyTurn": turn,
        "lean": lean * 4,
        "leftHand": [points[15].x, points[15].y],
        "rightHand": [points[16].x, points[16].y],
    }


def read_body(pose_landmarker, image, timestamp, smoother):
    result = pose_landmarker.detect_for_video(image, timestamp)
    if not result.pose_landmarks:
        with LOCK:
            STATE["body"] = False
        return

    values = body_from_landmarks(result.pose_landmarks[0])
    with LOCK:
        STATE.update(
            body=True,
            shoulderTilt=round(smoother("tilt", values["shoulderTilt"]), 2),
            bodyTurn=round(smoother("turn", values["bodyTurn"]), 3),
            lean=round(smoother("lean", values["lean"]), 3),
            leftHand=[round(v, 3) for v in values["leftHand"]],
            rightHand=[round(v, 3) for v in values["rightHand"]],
        )


def send_vmc(sender, scores, state):
    """One frame of VMC: the head bone, every blendshape, then Apply.

    Receivers expect the whole set followed by a single Apply — sending values
    without it leaves the model frozen on whatever it had.
    """
    qx, qy, qz, qw = quaternion(state["yaw"], state["pitch"], state["roll"])
    sender.send_message("/VMC/Ext/Root/Pos", ["root", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0])
    sender.send_message("/VMC/Ext/Bone/Pos", ["Head", 0.0, 0.0, 0.0, qx, qy, qz, qw])
    if state.get("body"):
        # Spine and chest carry the lean and turn; a receiver with a rigged model
        # does the rest. Half the tilt goes to each so neither joint does something
        # a neck cannot.
        sx, sy, sz, sw = quaternion(
            state["bodyTurn"] * 20, 0.0, state["shoulderTilt"] * 0.5
        )
        sender.send_message("/VMC/Ext/Bone/Pos", ["Spine", 0.0, 0.0, 0.0, sx, sy, sz, sw])
        cx, cy, cz, cw = quaternion(
            state["bodyTurn"] * 10, 0.0, state["shoulderTilt"] * 0.5
        )
        sender.send_message("/VMC/Ext/Bone/Pos", ["Chest", 0.0, 0.0, 0.0, cx, cy, cz, cw])
    for name, value in scores.items():
        # ARKit names pass straight through: that is what perfect-sync receivers want.
        sender.send_message("/VMC/Ext/Blend/Val", [name, float(value)])
    # A few classic VRM names too, for models rigged before perfect sync existed.
    sender.send_message("/VMC/Ext/Blend/Val", ["A", float(scores.get("jawOpen", 0.0))])
    sender.send_message("/VMC/Ext/Blend/Val", [
        "Blink",
        float(max(scores.get("eyeBlinkLeft", 0.0), scores.get("eyeBlinkRight", 0.0))),
    ])
    sender.send_message("/VMC/Ext/Blend/Val", [
        "Joy",
        float(max(scores.get("mouthSmileLeft", 0.0), scores.get("mouthSmileRight", 0.0))),
    ])
    sender.send_message("/VMC/Ext/Blend/Apply", [])
    sender.send_message("/VMC/Ext/OK", [1])


if __name__ == "__main__":
    sys.exit(main())

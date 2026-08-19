"""Live face camera: a headless driver for Deep-Live-Cam.

Deep-Live-Cam ships a desktop UI; this runs the same pipeline with no window so
Silicon Optimizer can own the controls and OBS can take the picture. It imports
the project's own modules — its face analyser, its swapper, its safety check —
rather than reimplementing any of it, and runs as a separate process under its
own environment, which is also what keeps the app's licence and the project's
(AGPL-3.0) from tangling.

Frames go out as MJPEG on localhost. That is the one format every capture tool
already understands: OBS takes it as a Browser Source, and OBS's own Virtual
Camera then carries it into Zoom, Discord or anything else that wants a webcam.

Usage:
    facecam.py --repo PATH --source FACE.png --camera 0 --port 8791 [--mirror]
               [--mouth-mask] [--many-faces] [--opacity 1.0]
"""

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "running": False,
    "stage": "starting",
    "fps": 0.0,
    "faces": 0,
    "error": None,
    "source": "",
}
LATEST = {"jpeg": None}
LOCK = threading.Lock()


def log(message):
    print(f"stage: {message}", flush=True)


def publish(stage=None, **fields):
    if stage:
        STATE["stage"] = stage
        log(stage)
    STATE.update(fields)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # The app watches our stdout; the HTTP access log is noise.

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/status":
            body = json.dumps(STATE).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif path == "/stream":
            self.stream()
        elif path in ("/", "/index.html"):
            self.page()
        else:
            self.send_error(404)

    def page(self):
        # A browser source needs a page, not a bare stream. Black background and
        # object-fit: contain so the camera fills the scene without distortion.
        body = (
            "<!doctype html><html><head><meta charset='utf-8'>"
            "<title>Silicon Optimizer — Face camera</title>"
            "<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}"
            "img{width:100%;height:100%;object-fit:contain;display:block}</style>"
            "</head><body><img src='/stream'></body></html>"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def stream(self):
        self.send_response(200)
        self.send_header(
            "Content-Type", "multipart/x-mixed-replace; boundary=frame"
        )
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            while STATE["running"]:
                with LOCK:
                    jpeg = LATEST["jpeg"]
                if jpeg is None:
                    time.sleep(0.03)
                    continue
                self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n")
                self.wfile.write(f"Content-Length: {len(jpeg)}\r\n\r\n".encode())
                self.wfile.write(jpeg)
                self.wfile.write(b"\r\n")
                time.sleep(1 / 60)
        except (BrokenPipeError, ConnectionResetError):
            pass  # A viewer closing mid-frame is routine.


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--port", type=int, default=8791)
    parser.add_argument("--mirror", action="store_true")
    parser.add_argument("--mouth-mask", action="store_true")
    parser.add_argument("--many-faces", action="store_true")
    parser.add_argument("--opacity", type=float, default=1.0)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    arguments = parser.parse_args()

    sys.path.insert(0, arguments.repo)
    os.chdir(arguments.repo)  # The project resolves its models relative to itself.

    publish("Loading the face engine")
    import cv2
    import modules.globals
    from modules.processors.frame import face_swapper
    from modules.face_analyser import get_one_face

    modules.globals.execution_providers = [
        "CoreMLExecutionProvider",
        "CPUExecutionProvider",
    ]
    modules.globals.many_faces = arguments.many_faces
    modules.globals.mouth_mask = arguments.mouth_mask
    modules.globals.opacity = max(0.0, min(1.0, arguments.opacity))
    modules.globals.headless = True
    modules.globals.nsfw_filter = True

    # The project's own content check, on the face being used. Left in place
    # deliberately: it is part of what the upstream ships, and switching it off
    # to save a second of startup is not our call to make.
    publish("Checking the source image")
    try:
        from modules.predicter import predict_image

        if predict_image(arguments.source):
            publish(error="This image was refused by the content check.")
            STATE["running"] = False
            print("fatal: source image refused by content check", flush=True)
            return 2
    except Exception as failure:  # noqa: BLE001 - never fail closed on a checker bug
        print(f"note: content check unavailable ({failure})", flush=True)

    publish("Reading the face")
    source_image = cv2.imread(arguments.source)
    if source_image is None:
        publish(error="That portrait could not be read.")
        print("fatal: unreadable source", flush=True)
        return 2
    source_face = get_one_face(source_image)
    if source_face is None:
        publish(error="No face found in that portrait.")
        print("fatal: no face in source", flush=True)
        return 2

    publish("Opening the camera")
    capture = cv2.VideoCapture(arguments.camera)
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, arguments.width)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, arguments.height)
    if not capture.isOpened():
        publish(error="The camera could not be opened.")
        print("fatal: camera unavailable", flush=True)
        return 2

    STATE["running"] = True
    STATE["source"] = os.path.basename(arguments.source)
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    publish(f"Live on port {arguments.port}")
    print(f"ready: http://127.0.0.1:{arguments.port}/", flush=True)

    frames = 0
    window_started = time.time()
    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                time.sleep(0.05)
                continue
            if arguments.mirror:
                frame = cv2.flip(frame, 1)
            try:
                frame = face_swapper.process_frame(source_face, frame)
            except Exception as failure:  # noqa: BLE001 - a bad frame is not fatal
                STATE["error"] = str(failure)[:200]

            ok, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
            if ok:
                with LOCK:
                    LATEST["jpeg"] = buffer.tobytes()

            frames += 1
            elapsed = time.time() - window_started
            if elapsed >= 1.0:
                STATE["fps"] = round(frames / elapsed, 1)
                print(f"fps: {STATE['fps']}", flush=True)
                frames, window_started = 0, time.time()
    except KeyboardInterrupt:
        pass
    finally:
        STATE["running"] = False
        capture.release()
        server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""An MCP server for driving and looking at a native macOS app.

Testing this app kept coming down to the same three questions — what is on screen,
where is that control, and what happens when I press it — and answering them through
ad-hoc shell pipelines was slow and wrong often enough to be worse than useless. A
verified endpoint and a verified runtime both passed while the button a person presses
did nothing, twice.

So: screenshots come back as images, the accessibility tree comes back as text, and
clicking is a tool call. Everything here drives the real app through the same APIs the
system uses, so what it reports is what a person would see.

Tools:
    windows      — what the app has on screen, with bounds
    screenshot   — a picture of a window (or the screen), returned as an image
    dump         — the accessibility tree, optionally filtered
    find         — paths of elements whose text matches
    click        — press an element by path, or click a point
    type         — type into whatever has focus
    key          — press a key (escape, return, tab…)
    pick         — choose an item from a pop-up button
"""

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from mcp.server.mcpserver import Image, MCPServer

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
CACHE = Path.home() / ".cache" / "silicon-ui-mcp"
CACHE.mkdir(parents=True, exist_ok=True)

server = MCPServer(
    name="mac-ui",
    instructions="Drive and inspect a native macOS app: see its windows, "
                 "screenshot them, read the accessibility tree, click, type.",
)


def build(name: str) -> Path:
    """Compile one of the Swift helpers on first use, then reuse it."""
    source = SCRIPTS / f"{name}.swift"
    binary = CACHE / name
    if binary.exists() and binary.stat().st_mtime >= source.stat().st_mtime:
        return binary
    result = subprocess.run(
        ["swiftc", "-O", str(source), "-o", str(binary)],
        capture_output=True, text=True, timeout=300,
    )
    if result.returncode != 0:
        raise RuntimeError(f"could not build {name}: {result.stderr[:400]}")
    return binary


def driver(app: str, *arguments: str, timeout: int = 60) -> str:
    result = subprocess.run(
        [str(build("uidriver")), app, *arguments],
        capture_output=True, text=True, timeout=timeout,
    )
    return (result.stdout + result.stderr).strip()


def window_list(app: str) -> list[dict]:
    result = subprocess.run(
        [str(build("winbounds")), app], capture_output=True, text=True, timeout=30
    )
    windows = []
    for line in result.stdout.strip().splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        windows.append({
            "id": int(parts[0]),
            "x": float(parts[1].split("=")[1]),
            "y": float(parts[2].split("=")[1]),
            "width": float(parts[3].split("=")[1]),
            "height": float(parts[4].split("=")[1]),
        })
    return windows


@server.tool()
def windows(app: str = "Silicon Optimizer") -> str:
    """List the app's on-screen windows with their bounds."""
    found = window_list(app)
    if not found:
        return (f"{app} has no windows on screen. For a menu-bar app, open one first "
                f"— click its menu bar icon, then the item you want.")
    return json.dumps(found, indent=2)


@server.tool()
def screenshot(app: str = "Silicon Optimizer", window_index: int = 0) -> Image:
    """A picture of the app's window. This is the ground truth: what a person sees.

    Use it whenever a check depends on what is displayed — an error message, a
    rendered result, whether a control looks enabled.
    """
    found = window_list(app)
    path = Path(tempfile.mkdtemp()) / "shot.png"
    if found and 0 <= window_index < len(found):
        subprocess.run(
            ["screencapture", "-x", "-o", f"-l{found[window_index]['id']}", str(path)],
            capture_output=True, timeout=60,
        )
    else:
        subprocess.run(["screencapture", "-x", "-o", str(path)],
                       capture_output=True, timeout=60)
    return Image(path=str(path))


@server.tool()
def dump(app: str = "Silicon Optimizer", contains: str = "") -> str:
    """The accessibility tree: every element with its path, role and text.

    Paths are what click/pick take. Filter with `contains` to keep it readable.
    """
    output = driver(app, "dump", contains) if contains else driver(app, "dump")
    return output or f"no accessibility tree for {app} (is a window open?)"


@server.tool()
def find(app: str = "Silicon Optimizer", text: str = "") -> str:
    """Paths of elements whose role or text contains `text` — the quick way to a path."""
    lines = driver(app, "dump", text).splitlines()
    return "\n".join(lines[:40]) if lines else f"nothing matching {text!r}"


@server.tool()
def click(
    app: str = "Silicon Optimizer",
    path: str = "",
    x: float | None = None,
    y: float | None = None,
    real_mouse: bool = False,
) -> str:
    """Press an element by accessibility path, or click a screen point.

    `real_mouse` posts an actual mouse event rather than an accessibility press.
    Some SwiftUI controls only update their binding for a real click, so reach for
    it when a press appears to do nothing.
    """
    if x is not None and y is not None:
        subprocess.run([str(build("clicker")), str(x), str(y)],
                       capture_output=True, timeout=30)
        return f"clicked {x},{y}"
    if not path:
        return "give me a path, or x and y"
    if real_mouse:
        position = driver(app, "pos", path).split()
        if len(position) < 2:
            return f"could not locate {path}"
        subprocess.run([str(build("clicker")), position[0], position[1]],
                       capture_output=True, timeout=30)
        return f"clicked {path} at {position[0]},{position[1]}"
    return driver(app, "press", path)


@server.tool()
def type_text(text: str, app: str = "Silicon Optimizer", path: str = "") -> str:
    """Type text. With `path`, click that element first so it takes the keystrokes.

    Typing is real key events, which is what makes a SwiftUI field's binding update —
    setting its value through accessibility alone can leave the app unaware.
    """
    if path:
        position = driver(app, "pos", path).split()
        if len(position) >= 2:
            subprocess.run([str(build("clicker")), position[0], position[1]],
                           capture_output=True, timeout=30)
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.run(
        ["osascript", "-e", f'tell application "System Events" to keystroke "{escaped}"'],
        capture_output=True, timeout=60,
    )
    return f"typed {len(text)} characters"


@server.tool()
def key(name: str) -> str:
    """Press a key: escape, return, tab, delete, space, or up/down/left/right."""
    codes = {
        "escape": 53, "return": 36, "enter": 36, "tab": 48, "delete": 51,
        "space": 49, "left": 123, "right": 124, "down": 125, "up": 126,
    }
    code = codes.get(name.lower())
    if code is None:
        return f"unknown key {name!r}; known: {', '.join(sorted(codes))}"
    subprocess.run(["osascript", "-e",
                    f'tell application "System Events" to key code {code}'],
                   capture_output=True, timeout=30)
    return f"pressed {name}"


@server.tool()
def pick(path: str, item: str, app: str = "Silicon Optimizer") -> str:
    """Choose an item from a pop-up button by its visible title.

    On failure it says which items the menu actually offered, and closes the menu —
    an open menu blocks every later query.
    """
    return driver(app, "pick", path, item, timeout=90)


if __name__ == "__main__":
    server.run()

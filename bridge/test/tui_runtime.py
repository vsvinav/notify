"""Exercise the original TUI with no model call or changes to real sessions."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import time
import uuid

repository = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="notify-tui-", dir=repository / ".build") as temporary:
    root = Path(temporary)
    project = root / "project"
    extension = project / ".github/extensions/notify"
    extension.mkdir(parents=True)
    ipc = root / "ipc"
    result_file = project / "result.json"
    session_id = str(uuid.uuid4())
    (root / "home").mkdir()
    (root / "home/settings.json").write_text(json.dumps({
        "extensions": {"disabledExtensions": ["project:notify"]}
    }))
    (extension / "extension.mjs").write_text(f"""
import {{ joinSession }} from "@github/copilot-sdk/extension";
import {{ writeFile }} from "node:fs/promises";
import {{ Bridge }} from {json.dumps((repository / 'bridge/dist/connection.js').as_uri())};
import {{ attachCopilot }} from {json.dumps((repository / 'bridge/dist/attachment.js').as_uri())};
process.stderr.write("PROBE before join\\n");
const session = await joinSession({{ onPermissionRequest: () => ({{ kind: "no-result" }}) }});
process.stderr.write("PROBE joined\\n");
const bridge = new Bridge("copilot", process.cwd(), {json.dumps(str(ipc / 'connection.json'))}, session.sessionId, false);
const attached = attachCopilot(session, bridge);
await bridge.start();
await attached.recover();
process.stderr.write("PROBE recovered\\n");
setImmediate(async () => {{ try {{
  const response = await session.rpc.ui.elicitation({{
    message: "Notify original-terminal probe",
    requestedSchema: {{ type: "object", properties: {{ "0": {{ type: "string", enum: ["A", "B"] }} }}, required: ["0"] }}
  }});
  await writeFile({json.dumps(str(result_file))}, JSON.stringify({{ sessionID: session.sessionId, response }}));
}} catch (error) {{
  await writeFile({json.dumps(str(result_file))}, JSON.stringify({{ error: String(error) }}));
}} }});
""")
    native = subprocess.Popen([str(repository / ".build/debug/NotifyTransportChecks"), str(ipc)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    provider = socket.socket()
    provider.bind(("127.0.0.1", 0))
    pid = None
    output = b""
    try:
        assert select.select([native.stdout], [], [], 5)[0], "Native transport did not start"
        assert native.stdout.readline().strip() == b"ready"
        pid, terminal = pty.fork()
        if pid == 0:
            os.chdir(project)
            env = dict(os.environ, COPILOT_HOME=str(root / "home"), TERM="xterm-256color",
                       NODE_TLS_REJECT_UNAUTHORIZED="1", COPILOT_MODEL="gpt-4",
                       COPILOT_PROVIDER_BASE_URL=f"http://127.0.0.1:{provider.getsockname()[1]}/v1")
            os.execvpe(shutil.which("copilot"), ["copilot", "--experimental", "--session-id", session_id], env)
        fcntl.ioctl(terminal, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 120, 0, 0))
        deadline = time.monotonic() + 35
        trusted_at = None
        enabled = False
        opened_manager = False
        closed_manager = False
        approved = False
        while time.monotonic() < deadline and not result_file.exists():
            if select.select([terminal], [], [], .1)[0]:
                try:
                    chunk = os.read(terminal, 65536)
                except OSError:
                    break
                output += chunk
                for query, answer in [(b"\x1b[6n", b"\x1b[1;1R"), (b"\x1b[c", b"\x1b[?1;2c"),
                                      (b"\x1b[>c", b"\x1b[>0;276;0c"), (b"\x1b[?u", b"\x1b[?0u")]:
                    if query in chunk:
                        os.write(terminal, answer)
            text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output.decode("utf-8", "replace"))
            if trusted_at is None and "Confirm folder trust" in text:
                os.write(terminal, b"\r")  # Trust only this disposable fixture, not future sessions.
                trusted_at = time.monotonic()
            if trusted_at and not opened_manager and time.monotonic() - trusted_at > 1:
                os.write(terminal, b"/extensions manage\r")
                opened_manager = True
            if opened_manager and not enabled and "notify" in text and ("disabled" in text.lower()):
                os.write(terminal, b" ")
                enabled = True
            if enabled and not closed_manager and "Loading extensions" in text:
                os.write(terminal, b"\x1b")
                closed_manager = True
            if not approved and "handle permission requests" in text and "notify" in text:
                os.write(terminal, b"\r")
                approved = True
        if not result_file.exists():
            for log in sorted((root / "home/logs").glob("*.log"))[-3:]:
                print(log.name, log.read_text()[-3500:])
        assert result_file.exists(), "TUI probe did not finish:\n" + text[-3000:]
        result = json.loads(result_file.read_text())
        assert result == {"sessionID": session_id, "response": {"action": "accept", "content": {"0": "B"}}}, result
        assert enabled and approved
        assert "Restarting..." not in text, "Attaching must not restart the existing terminal"
        print("PASS: enabled Notify in an already-running original TUI; native reply returned to the same session.")
    finally:
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if os.waitpid(pid, os.WNOHANG)[0]:
                        break
                    time.sleep(.1)
                else:
                    os.kill(pid, signal.SIGKILL)
                    os.waitpid(pid, 0)
            except ProcessLookupError:
                pass
            os.close(terminal)
        native.terminate()
        native.wait(timeout=5)
        provider.close()

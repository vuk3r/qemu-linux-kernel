#!/usr/bin/env python3
"""Run on Linux: python3 data/tests/smoke.py. Requires a completed build."""
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time

project = Path(__file__).resolve().parents[2]
log_dir = project / "log"
log_dir.mkdir(exist_ok=True)
log = log_dir / "smoke-6.8.9-test.log"
with tempfile.TemporaryDirectory(prefix=".pwnkernel-smoke-", dir=Path.home()) as tmp:
    share = Path(tmp)
    share.chmod(0o755)
    guest_share = f"/mnt/wsl/{share.name}"
    guest_d4vicl_share = f"/home/d4vicl/{share.name}"
    (share / "host-proof.txt").write_text("from-wsl\n")
    subprocess.run(["gcc", "-static", "-O2", "-Wall", "-Wextra",
                    str(project / "data/tests/ctf_access.c"), "-o", str(share / "ctf-access")], check=True)
    env = dict(os.environ, BOOT_USER="ctf", D4VICL_SHARE=str(Path.home()))
    env.pop("WSL_SHARE", None)
    proc = subprocess.Popen(["bash", "./launch.sh"], cwd=project, env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    transcript = bytearray()
    sent = passed = False
    try:
        deadline = time.monotonic() + 120
        with log.open("wb") as output:
            while time.monotonic() < deadline:
                for key, _ in selector.select(timeout=1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError("QEMU exited before the smoke test completed")
                    output.write(chunk)
                    output.flush()
                    transcript.extend(chunk)
                if not sent and b"$ " in transcript and b"Welcome to pwn-kernel" in transcript:
                    command = (
                        f"id; uname -r; "
                        f"test -f {guest_d4vicl_share}/host-proof.txt && "
                        f"printf 'from-ctf-d4vicl\\n' > {guest_d4vicl_share}/d4vicl-proof.txt && "
                        f"{guest_share}/ctf-access {guest_share}\n"
                    )
                    proc.stdin.write(command.encode())
                    proc.stdin.flush()
                    sent = True
                if b"CTF_ACCESS_PASS:" in transcript:
                    passed = True
                    break
                if b"Kernel panic" in transcript or b"FAIL:" in transcript:
                    raise RuntimeError(f"Guest test failed; see {log}")
            if not passed:
                raise TimeoutError(f"Guest test timed out; see {log}")
        assert (share / "guest-proof.txt").read_text() == "from-ctf\n"
        assert (share / "d4vicl-proof.txt").read_text() == "from-ctf-d4vicl\n"
        assert b"6.8.9" in transcript
        print("PASS: Linux 6.8.9, ctf/sudo, module interfaces, and both WSL shares mounted read/write")
    finally:
        selector.close()
        if proc.poll() is None:
            proc.stdin.write(b"\x01x")  # QEMU serial escape: exit the test VM.
            proc.stdin.flush()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

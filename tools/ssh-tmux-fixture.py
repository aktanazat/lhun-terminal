#!/usr/bin/env python3
"""A disposable, loopback-only SSH host for Lhûn's simulator and host-tool tests."""

import argparse
from contextlib import suppress
import os
from pathlib import Path
import pwd
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import quote, urlencode


PREFIX = "lhun-test-fixture-"
SESSION = PREFIX + "shell"
OTHER_SESSION = "fixture-outside-prefix"
MARKER = "fixture-screen"
HOST = "127.0.0.1"


class Fixture:
    def __init__(self, root):
        self.root = root
        self.user = pwd.getpwuid(os.getuid()).pw_name
        self.sshd = os.path.abspath(shutil.which("sshd"))
        self.tmux = os.path.abspath(shutil.which("tmux"))
        self.home = root / "home"
        self.home.mkdir()
        self.env = {
            "HOME": str(self.home), "TMUX_TMPDIR": str(root), "SHELL": "/bin/sh",
            "PATH": f"{Path(self.tmux).parent}:/usr/bin:/bin:/usr/sbin:/sbin",
        }
        self.listener = socket.create_server((HOST, 0))
        self.listener.settimeout(0.2)
        self.port = self.listener.getsockname()[1]
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.clients = []
        self.thread = None

    def start(self, authorized_key):
        host_key = self.root / "host"
        client_key = self.root / "client"
        for key in (host_key, client_key):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key], check=True)
        self.host_public = " ".join(host_key.with_suffix(".pub").read_text().split()[:2])
        keys = client_key.with_suffix(".pub").read_text()
        if authorized_key:
            subprocess.run(["ssh-keygen", "-lf", authorized_key], stdout=subprocess.DEVNULL, check=True)
            fields = authorized_key.read_text().split()
            if len(fields) < 2 or not fields[0].startswith(("ssh-", "ecdsa-", "sk-")):
                raise ValueError("--authorize needs an OpenSSH public key, without options")
            keys += " ".join(fields[:2]) + "\n"
        (self.root / "authorized_keys").write_text(keys)
        (self.root / "known_hosts").write_text(f"[{HOST}]:{self.port} {self.host_public}\n")
        (self.root / "ssh_config").write_text(f"""Host fixture
    HostName {HOST}
    Port {self.port}
    User {self.user}
    IdentityFile {client_key}
    IdentitiesOnly yes
    IdentityAgent none
    UserKnownHostsFile {self.root / 'known_hosts'}
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking yes
    BatchMode yes
    ConnectTimeout 3
""")
        remote = self.root / "remote"
        env = shlex.join([f"{key}={value}" for key, value in self.env.items()])
        remote.write_text(f"""#!/bin/sh
cd {shlex.quote(str(self.home))} || exit 1
if [ -n "${{SSH_ORIGINAL_COMMAND:-}}" ]; then
    exec /usr/bin/env -i {env} TERM="${{TERM:-dumb}}" /bin/bash -c "$SSH_ORIGINAL_COMMAND"
fi
exec /usr/bin/env -i {env} TERM="${{TERM:-dumb}}" /bin/bash --noprofile --norc
""")
        remote.chmod(0o700)
        # OpenSSH's StrictModes rejects /tmp even though mkdtemp owns this private 0700 directory.
        config = self.root / "sshd_config"
        config.write_text(f"""HostKey {host_key}
AuthorizedKeysFile {self.root / 'authorized_keys'}
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowUsers {self.user}
PermitRootLogin no
PermitUserRC no
DisableForwarding yes
LoginGraceTime 5
LogLevel ERROR
ForceCommand exec {remote}
""")
        subprocess.run([self.sshd, "-t", "-f", config], check=True)
        self.local_tmux(
            "new-session", "-d", "-s", SESSION, "-n", "shell", "-x", "80", "-y", "24",
            f"printf '%s\\n' {MARKER}; exec /bin/sh",
            ";", "new-session", "-d", "-s", OTHER_SESSION, ";", "set-option", "-g", "exit-empty", "off",
            check=True,
        )
        self.thread = threading.Thread(target=self.accept, args=(config,))
        self.thread.start()

    def local_tmux(self, *args, **kwargs):
        return subprocess.run(
            [self.tmux, "-f", "/dev/null", *args], env=self.env, cwd=self.home, **kwargs,
        )

    def accept(self, config):
        with (self.root / "sshd.log").open("wb") as log:
            while not self.stop.is_set():
                with self.lock:
                    for client in self.clients[:]:
                        connection, process = client
                        if process.poll() is not None:
                            connection.close()
                            self.clients.remove(client)
                try:
                    connection, _ = self.listener.accept()
                except socket.timeout:
                    continue
                with self.lock:
                    try:
                        process = subprocess.Popen(
                            [self.sshd, "-i", "-e", "-f", config],
                            stdin=connection, stdout=connection, stderr=log,
                        )
                    except BaseException:
                        connection.close()
                        raise
                    self.clients.append((connection, process))

    def drop_connections(self):
        with self.lock:
            for connection, _ in self.clients:
                with suppress(OSError):
                    connection.shutdown(socket.SHUT_RDWR)

    def close(self):
        self.stop.set()
        if self.thread:
            self.thread.join()
        self.listener.close()
        self.drop_connections()
        for connection, process in self.clients:
            connection.close()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        self.local_tmux("kill-server", stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def ssh(self, *args):
        return ["ssh", "-F", str(self.root / "ssh_config"), *args]

    def run(self, command):
        return subprocess.check_output(self.ssh("fixture", command), text=True, timeout=15).strip()

    def pairing_url(self):
        query = urlencode({
            "role": "server", "name": "Lhun fixture", "address": HOST, "port": self.port,
            "user": self.user, "key": self.host_public,
        }, quote_via=quote)
        return "lhun://pair?" + query


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def read_until(stream, marker, timeout=5):
    deadline = time.monotonic() + timeout
    output = bytearray()
    while marker not in output:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([stream], [], [], remaining)[0]:
            raise RuntimeError(f"Timed out waiting for {marker!r}: {output!r}")
        chunk = os.read(stream.fileno(), 4096)
        if not chunk:
            raise RuntimeError(f"SSH closed before showing {marker!r}: {output!r}")
        output.extend(chunk)


def check(fixture):
    require(fixture.run('printf "%s" "$HOME"') == str(fixture.home), "Wrong remote HOME")
    names = "tmux list-sessions -F '#{session_name}'"
    require(set(fixture.run(names).splitlines()) == {SESSION, OTHER_SESSION}, "Wrong tmux sessions")
    tmux_socket = fixture.run("tmux display-message -p '#{socket_path}'")
    require(fixture.root.resolve() in Path(tmux_socket).resolve().parents, "Wrong tmux socket")
    target = f"-t ={SESSION}:0"
    pane = f"tmux display-message -p {target} '#{{pane_id}}'"
    capture = f"tmux capture-pane -p -S -600 {target}"
    before = fixture.run(pane)
    print("PASS: pinned SSH reaches only the seeded tmux server and disposable HOME")

    with subprocess.Popen(
        fixture.ssh("-tt", "fixture", f"tmux attach-session -t ={SESSION}"),
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env={**os.environ, "TERM": "xterm"},
    ) as client:
        try:
            read_until(client.stdout, MARKER.encode())
            fixture.drop_connections()
            require(client.wait(timeout=5) == 255, "The attached SSH transport did not disconnect")
        finally:
            if client.poll() is None:
                client.kill()
    require(fixture.run(pane) == before and MARKER in fixture.run(capture), "The original pane did not survive")
    print("PASS: dropping an attached SSH transport leaves the same pane available on reconnect")

    tool = Path(__file__).resolve().with_name("sessions") / "lhun-sessions"
    sessions = shlex.join([sys.executable, str(tool)])
    fixture.run(f"{sessions} save --test {PREFIX}")
    state = fixture.home / ".local/state/lhun/sessions"
    require((state / SESSION / "session.json").is_file(), "The session was not saved")
    require(not (state / OTHER_SESSION).exists(), "Save touched a session outside the test prefix")
    fixture.run(f"tmux kill-session -t ={SESSION}")
    require(fixture.run(names) == OTHER_SESSION, "The original session was not removed")
    fixture.run(f"{sessions} restore --test {PREFIX}")
    screen = fixture.run(capture)
    require(fixture.run(pane) != before, "Restore did not create a new pane")
    require(MARKER in screen and "restored after restart, screen saved at" in screen,
            "The saved screen did not return")
    print("PASS: lhun-sessions restores the saved screen and excludes sessions outside the test prefix")


def serve(fixture):
    # Signal handlers set flags only; socket operations happen back in the main loop.
    stopped = drop = False

    def stop_handler(*_):
        nonlocal stopped
        stopped = True

    def drop_handler(*_):
        nonlocal drop
        drop = True

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    signal.signal(signal.SIGUSR1, drop_handler)
    print(f"SSH:  {shlex.join(fixture.ssh('fixture'))}")
    print(f"Pair: {fixture.pairing_url()}")
    print(f"Drop: kill -USR1 {os.getpid()}", flush=True)
    while not stopped and fixture.thread.is_alive():
        if drop:
            drop = False
            fixture.drop_connections()
        time.sleep(0.1)
    if not stopped:
        raise RuntimeError("SSH listener stopped unexpectedly")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("serve", "check"))
    parser.add_argument("--authorize", type=Path, metavar="PUBLIC_KEY",
                        help="also allow this disposable simulator's OpenSSH public key")
    args = parser.parse_args()
    if os.getuid() == 0:
        parser.error("run this fixture as a normal user, not root")
    for command in ("ssh", "sshd", "ssh-keygen", "tmux"):
        if not shutil.which(command):
            parser.error(f"{command} must be on PATH")
    with tempfile.TemporaryDirectory(prefix="lhun-fixture-", dir="/tmp") as directory:
        fixture = Fixture(Path(directory))
        try:
            fixture.start(args.authorize)
            (check if args.mode == "check" else serve)(fixture)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            log = fixture.root / "sshd.log"
            if log.exists():
                print(log.read_text(), end="", file=sys.stderr)
            sys.exit(f"Fixture failed: {error}")
        finally:
            fixture.close()


if __name__ == "__main__":
    main()

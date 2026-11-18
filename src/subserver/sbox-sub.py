#!/usr/bin/env python3
"""sbox-sub — Sing-Box 订阅服务（标准库实现，无第三方依赖）

路由：
    GET /health                 健康检查
    GET /<token>/auto           按 User-Agent 返回合适的订阅
    GET /<token>/singbox        sing-box 1.12+ 客户端配置（JSON）
    GET /<token>/mihomo         mihomo / Clash 配置（YAML）
    GET /<token>/v2ray          Base64 节点链接（v2rayN / Shadowrocket）
    GET /<token>/links          明文节点链接
可选：配置 SUB_USER / SUB_PASS 后启用 HTTP Basic 认证。
"""

from __future__ import annotations

import hmac
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

ETC = os.environ.get("SBOX_ETC", "/etc/sbox")
BIN = os.environ.get("SBOX_BIN", "/usr/local/bin/sbox")
CONF = os.path.join(ETC, "sbox.conf")

KINDS = {
    "singbox": ("json", "singbox"),
    "singbox.json": ("json", "singbox"),
    "mihomo": ("yaml", "mihomo"),
    "mihomo.yaml": ("yaml", "mihomo"),
    "clash": ("yaml", "mihomo"),
    "v2ray": ("text", "v2ray"),
    "links": ("text", "links"),
}

CONTENT_TYPE = {
    "json": "application/json; charset=utf-8",
    "yaml": "text/yaml; charset=utf-8",
    "text": "text/plain; charset=utf-8",
}

_lock = threading.Lock()
_cache: dict[str, tuple[float, str]] = {}
CACHE_TTL = 2.0


def read_conf() -> dict[str, str]:
    conf: dict[str, str] = {}
    try:
        with open(CONF, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                conf[key.strip()] = value.strip()
    except OSError:
        pass
    return conf


CONF_DATA = read_conf()
TOKEN = CONF_DATA.get("SUB_TOKEN", "")
PORT = int(CONF_DATA.get("SUB_PORT") or 2087)
BIND = CONF_DATA.get("SUB_BIND") or "0.0.0.0"


def auth_settings() -> tuple[str, str, str]:
    """每次请求重新读取令牌与认证配置，便于 sbox sub token/auth 即时生效。"""
    conf = read_conf()
    return (conf.get("SUB_TOKEN", TOKEN), conf.get("SUB_USER", ""), conf.get("SUB_PASS", ""))


def render(kind: str) -> str:
    """调用 sbox 内部渲染接口，带短时缓存。"""
    now = time.monotonic()
    with _lock:
        cached = _cache.get(kind)
        if cached and now - cached[0] < CACHE_TTL:
            return cached[1]
    try:
        cmd = [BIN] if os.access(BIN, os.X_OK) else ["bash", BIN]
        proc = subprocess.run(
            cmd + ["internal", "render", kind],
            capture_output=True, text=True, timeout=15, check=True,
        )
        content = proc.stdout
    except (subprocess.SubprocessError, OSError) as exc:
        print(f"render failed: {exc}", file=sys.stderr)
        content = ""
    if content:
        with _lock:
            _cache[kind] = (now, content)
    return content


def pick_kind(user_agent: str) -> str:
    ua = (user_agent or "").lower()
    if any(k in ua for k in ("mihomo", "clash", "stash", "verge")):
        return "mihomo"
    if any(k in ua for k in ("sing-box", "sfa", "sfi", "sfm")):
        return "singbox"
    if any(k in ua for k in ("v2ray", "shadowrocket", "shadowrocket", "quantumult")):
        return "v2ray"
    return "singbox"


class Handler(BaseHTTPRequestHandler):
    server_version = "sbox-sub/1.0"
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: str = "", ctype: str = "text/plain; charset=utf-8",
              extra: dict[str, str] | None = None) -> None:
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _check_auth(self, user: str, password: str) -> bool:
        if not (user and password):
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        import base64

        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return False
        got_user, _, got_pass = decoded.partition(":")
        return (hmac.compare_digest(got_user, user)
                and hmac.compare_digest(got_pass, password))

    def _handle(self) -> None:
        parsed = urlparse(self.path)
        parts = [p for p in parsed.path.split("/") if p]
        if parsed.path == "/health":
            self._send(200, "ok\n")
            return

        token, auth_user, auth_pass = auth_settings()
        if not token or not parts or not hmac.compare_digest(parts[0], token):
            self._send(404, "not found\n")
            return
        if not self._check_auth(auth_user, auth_pass):
            self._send(401, "unauthorized\n", extra={"WWW-Authenticate": 'Basic realm="sbox"'})
            return

        kind = parts[1] if len(parts) > 1 else "auto"
        if kind == "auto":
            kind = pick_kind(self.headers.get("User-Agent", ""))
        elif kind == "proxies":
            kind = "mihomo"

        if kind not in KINDS:
            self._send(404, "unknown subscription type\n")
            return

        ctype, render_kind = KINDS[kind]
        body = render(render_kind)
        if not body:
            self._send(503, "subscription not ready (no node configured?)\n")
            return
        if kind in ("v2ray",):
            body = body.strip() + "\n"
        self._send(
            200,
            body,
            CONTENT_TYPE[ctype],
            extra={
                "Profile-Update-Interval": "12",
                "X-Profile-Format": kind,
            },
        )

    do_GET = _handle
    do_HEAD = _handle

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


def main() -> int:
    if not TOKEN:
        print("sbox-sub: SUB_TOKEN 未配置，退出", file=sys.stderr)
        return 1
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"sbox-sub: listening on {BIND}:{PORT}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Local-network subtitle transcription service for Apple Silicon Macs."""

import argparse
import hmac
import json
import os
import secrets
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


MODEL_REPO = "mlx-community/whisper-large-v3-turbo"
MODEL_ID = "mlx-whisper-large-v3-turbo"
MAX_AUDIO_BYTES = 32 * 1024 * 1024
MODEL_LOCK = threading.Lock()


def load_token(path: Path) -> str:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.exists():
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(secrets.token_urlsafe(32))
    if path.stat().st_mode & 0o077:
        raise RuntimeError(f"Token file must be readable only by this user: {path}")
    return path.read_text(encoding="utf-8").strip()


class SubtitleHandler(BaseHTTPRequestHandler):
    server_version = "LovortMacSubtitles/1"

    def send_json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def authorized(self) -> bool:
        supplied = self.headers.get("X-Lovort-Token", "")
        return hmac.compare_digest(supplied, self.server.access_token)

    def do_GET(self) -> None:
        if not self.authorized():
            self.send_json(401, {"error": "Unauthorized"})
            return
        if urlparse(self.path).path != "/health":
            self.send_json(404, {"error": "Not found"})
            return
        self.send_json(200, {"service": "lovort-mac-subtitles", "version": 1, "model": MODEL_ID})

    def do_POST(self) -> None:
        if not self.authorized():
            self.send_json(401, {"error": "Unauthorized"})
            return
        parsed = urlparse(self.path)
        if parsed.path != "/transcribe":
            self.send_json(404, {"error": "Not found"})
            return
        length_text = self.headers.get("Content-Length", "")
        if not length_text.isdecimal() or not 0 < int(length_text) <= MAX_AUDIO_BYTES:
            self.send_json(413, {"error": "Audio slice must be 1-32 MiB"})
            return
        language = parse_qs(parsed.query).get("language", [None])[0]
        if language not in (None, "ja", "en", "zh", "ko"):
            self.send_json(400, {"error": "Unsupported language"})
            return
        if not MODEL_LOCK.acquire(blocking=False):
            self.send_json(503, {"error": "Mac is already transcribing another slice"})
            return
        file_path = None
        try:
            with tempfile.NamedTemporaryFile(prefix="lovort-audio-", suffix=".m4a", delete=False) as audio:
                file_path = audio.name
                remaining = int(length_text)
                while remaining:
                    block = self.rfile.read(min(1024 * 1024, remaining))
                    if not block:
                        raise ValueError("Incomplete audio upload")
                    audio.write(block)
                    remaining -= len(block)

            import mlx_whisper

            kwargs = {"path_or_hf_repo": MODEL_REPO}
            if language:
                kwargs["language"] = language
            result = mlx_whisper.transcribe(file_path, **kwargs)
            segments = [
                {"start": float(item["start"]), "end": float(item["end"]), "text": str(item["text"])}
                for item in result.get("segments", [])
            ]
            self.send_json(200, {"segments": segments})
        except ValueError as error:
            self.send_json(400, {"error": str(error)})
        except Exception:
            self.log_exception()
            self.send_json(500, {"error": "Transcription failed; check the Mac service log"})
        finally:
            if file_path:
                Path(file_path).unlink(missing_ok=True)
            MODEL_LOCK.release()

    def log_exception(self) -> None:
        import traceback
        traceback.print_exc()

    def log_message(self, format_string: str, *args: object) -> None:
        print(f"{self.client_address[0]} - {format_string % args}")

    def log_request(self, code: int | str = "-", size: int | str = "-") -> None:
        # BaseHTTPRequestHandler otherwise logs the full request URL.
        self.log_message("HTTP %s %s", code, size)


def main() -> None:
    parser = argparse.ArgumentParser(description="Lovort LAN Mac subtitle service")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token-file", type=Path, default=Path.home() / ".config/lovort-mac-subtitles/token")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535")
    try:
        import mlx_whisper  # noqa: F401
    except ImportError as error:
        parser.error(f"mlx-whisper is not installed: {error}. Run pip install -r requirements.txt")
    token = load_token(args.token_file)
    server = ThreadingHTTPServer((args.host, args.port), SubtitleHandler)
    server.access_token = token
    server.daemon_threads = True
    print(f"Mac subtitle service listening on {args.host}:{args.port}")
    print(f"Access token: {token}")
    print("Use this service only on a trusted private LAN; HTTP audio and token are not encrypted.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

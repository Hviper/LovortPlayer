import http.client
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path

from server import MODEL_ID, SubtitleHandler, ThreadingHTTPServer, load_token


class SubtitleServerTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), SubtitleHandler)
        self.server.access_token = "test-secret"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        sys.modules.pop("mlx_whisper", None)

    def request(self, method, path, body=None, token=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        headers = {"X-Lovort-Token": token} if token else {}
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        status, data = response.status, response.read()
        connection.close()
        return status, data

    def test_health_requires_token_and_reports_model(self):
        self.assertEqual(self.request("GET", "/health")[0], 401)
        status, data = self.request("GET", "/health", token="test-secret")
        self.assertEqual(status, 200)
        self.assertIn(MODEL_ID.encode(), data)

    def test_audio_upload_returns_relative_segments(self):
        received = []

        def transcribe(path, **kwargs):
            received.append((Path(path).read_bytes(), kwargs["language"]))
            return {"segments": [{"start": 1.2, "end": 2.4, "text": "hello"}]}

        sys.modules["mlx_whisper"] = types.SimpleNamespace(transcribe=transcribe)
        status, data = self.request("POST", "/transcribe?language=en", body=b"audio-data", token="test-secret")
        self.assertEqual(status, 200)
        self.assertEqual(received[0], (b"audio-data", "en"))
        self.assertIn(b'"start": 1.2', data)
        self.assertIn(b'"text": "hello"', data)

    def test_token_file_is_reused_with_private_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            token = load_token(path)
            self.assertEqual(token, load_token(path))
            self.assertEqual(path.stat().st_mode & 0o077, 0)


if __name__ == "__main__":
    unittest.main()

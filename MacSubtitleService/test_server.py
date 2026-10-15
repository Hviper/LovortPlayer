import http.client
import json
import sys
import tempfile
import threading
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from jobs import JobStore
from server import MODEL_ID, SubtitleHandler, ThreadingHTTPServer, load_token


class SubtitleServerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), SubtitleHandler)
        self.server.access_token = "test-secret"
        self.server.job_store = JobStore(Path(self.directory.name))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        sys.modules.pop("mlx_whisper", None)
        self.directory.cleanup()

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

    def test_submitted_job_completes_without_client_connection(self):
        job_id = str(uuid.uuid4())
        clips = []

        def fake_ffmpeg(command, **kwargs):
            clips.append(float(command[command.index("-ss") + 1]))
            Path(command[-1]).write_bytes(b"wav")

        sys.modules["mlx_whisper"] = types.SimpleNamespace(transcribe=lambda path, **kwargs: {
            "segments": [{"start": 0.5, "end": 1.5, "text": "hello"}]
        })
        with patch("jobs.subprocess.check_output", return_value="250.0"), \
             patch("jobs.subprocess.run", side_effect=fake_ffmpeg):
            status, _ = self.request("POST", f"/jobs/{job_id}?language=en&preferred_start=240",
                                     body=b"audio-data", token="test-secret")
            self.assertEqual(status, 202)
            for _ in range(100):
                job = self.server.job_store.get(job_id)
                if job["status"] == "completed":
                    break
                threading.Event().wait(0.02)
            self.assertEqual(job["status"], "completed")
            self.assertEqual(job["completed_chunks"], [1, 0])
            self.assertEqual(clips, [240.0, 0.0])
            self.assertEqual(job["segments"][0]["start"], 240.5)
            self.assertFalse((Path(self.directory.name) / f"{job_id}.m4a").exists())
            status, _ = self.request("GET", f"/jobs/{job_id}", token="test-secret")
            self.assertEqual(status, 200)

    def test_restart_resumes_only_unfinished_chunks(self):
        job_id = str(uuid.uuid4())
        directory = Path(self.directory.name)
        (directory / f"{job_id}.m4a").write_bytes(b"audio-data")
        (directory / f"{job_id}.json").write_text(json.dumps({
            "id": job_id, "status": "processing", "language": "en",
            "completed_chunks": [0], "total_chunks": 2,
            "segments": [{"chunk": 0, "start": 0.5, "end": 1.5, "text": "first"}],
            "error": None, "updated_at": 0
        }), encoding="utf-8")
        clips = []

        def fake_ffmpeg(command, **kwargs):
            clips.append(float(command[command.index("-ss") + 1]))
            Path(command[-1]).write_bytes(b"wav")

        sys.modules["mlx_whisper"] = types.SimpleNamespace(transcribe=lambda path, **kwargs: {
            "segments": [{"start": 0.5, "end": 1.5, "text": "second"}]
        })
        with patch("jobs.subprocess.check_output", return_value="250.0"), \
             patch("jobs.subprocess.run", side_effect=fake_ffmpeg):
            resumed = JobStore(directory)
            for _ in range(100):
                job = resumed.get(job_id)
                if job["status"] == "completed":
                    break
                threading.Event().wait(0.02)
            self.assertEqual(job["status"], "completed")
            self.assertEqual(clips, [240.0])
            self.assertEqual(job["completed_chunks"], [0, 1])
            self.assertEqual(len(job["segments"]), 2)


if __name__ == "__main__":
    unittest.main()

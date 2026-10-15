"""Durable transcription jobs; the Mac keeps running after the phone disconnects."""

import json
import math
import os
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path


CHUNK_SECONDS = 240
RESULT_RETENTION_SECONDS = 7 * 24 * 60 * 60
MODEL_REPO = "mlx-community/whisper-large-v3-turbo"
MODEL_LOCK = threading.Lock()


class JobStore:
    def __init__(self, directory: Path):
        self.directory = directory
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.running: set[str] = set()
        self.resume()

    @staticmethod
    def valid_id(raw: str) -> str | None:
        try:
            return str(uuid.UUID(raw))
        except ValueError:
            return None

    def _paths(self, job_id: str) -> tuple[Path, Path]:
        return self.directory / f"{job_id}.json", self.directory / f"{job_id}.m4a"

    def get(self, job_id: str) -> dict | None:
        metadata, _ = self._paths(job_id)
        try:
            return json.loads(metadata.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            return None

    def _save(self, job: dict) -> None:
        metadata, _ = self._paths(job["id"])
        temporary = metadata.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(job, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, metadata)

    def submit(self, job_id: str, stream, size: int, language: str | None,
               preferred_start: float = 0) -> dict:
        with self.lock:
            existing = self.get(job_id)
            if existing and existing["status"] != "failed":
                return existing
            _, audio = self._paths(job_id)
            temporary = audio.with_suffix(".upload")
            try:
                with temporary.open("wb") as output:
                    remaining = size
                    while remaining:
                        block = stream.read(min(1024 * 1024, remaining))
                        if not block:
                            raise ValueError("Incomplete audio upload")
                        output.write(block)
                        remaining -= len(block)
                os.replace(temporary, audio)
            finally:
                temporary.unlink(missing_ok=True)
            job = {"id": job_id, "status": "queued", "language": language,
                   "preferred_start": preferred_start,
                   "completed_chunks": [], "total_chunks": 0, "segments": [],
                   "error": None, "updated_at": time.time()}
            self._save(job)
            self._start(job_id)
            return job

    def _start(self, job_id: str) -> None:
        if job_id in self.running:
            return
        self.running.add(job_id)
        threading.Thread(target=self._run, args=(job_id,), daemon=True).start()

    def resume(self) -> None:
        with self.lock:
            for metadata in self.directory.glob("*.json"):
                job = self.get(metadata.stem)
                if job and job.get("status") in ("completed", "failed") \
                        and time.time() - job.get("updated_at", 0) > RESULT_RETENTION_SECONDS:
                    metadata.unlink(missing_ok=True)
                    self._paths(metadata.stem)[1].unlink(missing_ok=True)
                    continue
                if job and job.get("status") in ("queued", "processing"):
                    self._start(metadata.stem)
            for upload in self.directory.glob("*.upload"):
                if time.time() - upload.stat().st_mtime > 60 * 60:
                    upload.unlink(missing_ok=True)

    def _run(self, job_id: str) -> None:
        _, audio = self._paths(job_id)
        try:
            with MODEL_LOCK:
                job = self.get(job_id)
                if job is None or not audio.is_file():
                    raise FileNotFoundError("Uploaded audio is missing")
                duration = float(subprocess.check_output([
                    "ffprobe", "-v", "error", "-show_entries", "format=duration",
                    "-of", "default=noprint_wrappers=1:nokey=1", str(audio)
                ], text=True).strip())
                if not math.isfinite(duration) or duration <= 0:
                    raise ValueError("Invalid audio duration")
                job["total_chunks"] = math.ceil(duration / CHUNK_SECONDS)
                job["status"] = "processing"
                self._save(job)
                import mlx_whisper

                preferred = min(job["total_chunks"] - 1,
                                int(job.get("preferred_start", 0) / CHUNK_SECONDS))
                order = sorted(range(job["total_chunks"]),
                               key=lambda index: (abs(index - preferred), index))
                for index in order:
                    if index in job["completed_chunks"]:
                        continue
                    start = index * CHUNK_SECONDS
                    length = min(CHUNK_SECONDS, duration - start)
                    with tempfile.TemporaryDirectory(prefix="lovort-job-") as directory:
                        clip = Path(directory) / "clip.wav"
                        subprocess.run([
                            "ffmpeg", "-loglevel", "error", "-ss", str(start),
                            "-i", str(audio), "-t", str(length), "-vn", "-ac", "1",
                            "-ar", "16000", "-y", str(clip)
                        ], check=True, timeout=180)
                        options = {"path_or_hf_repo": MODEL_REPO}
                        if job["language"]:
                            options["language"] = job["language"]
                        result = mlx_whisper.transcribe(str(clip), **options)
                    for segment in result.get("segments", []):
                        segment_start = float(segment["start"])
                        segment_end = float(segment["end"])
                        if 0 <= segment_start < segment_end <= length + 1:
                            job["segments"].append({
                                "chunk": index, "start": start + segment_start,
                                "end": min(duration, start + segment_end),
                                "text": str(segment["text"])
                            })
                    job["completed_chunks"].append(index)
                    job["updated_at"] = time.time()
                    self._save(job)
                job["status"] = "completed"
                job["updated_at"] = time.time()
                self._save(job)
        except Exception as error:
            import traceback
            traceback.print_exc()
            job = self.get(job_id)
            if job:
                job["status"] = "failed"
                job["error"] = str(error)[:300]
                job["updated_at"] = time.time()
                self._save(job)
        finally:
            audio.unlink(missing_ok=True)
            with self.lock:
                self.running.discard(job_id)

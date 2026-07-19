#!/usr/bin/env python3
"""Walking-skeleton stand-in for the GPU services (e2e evidence plane).

One image, two modes (MODE env):

  render (default) — stands in for the golden-service inference container
    (ghcr.io/nycterent/synorg/recommender/ranker has no real image yet). Serves:
      /render   simulated render (RENDER_SLEEP_MS), observed into the
                render_start_seconds histogram (recording-rules.yaml source)
      /healthz, /readyz   liveness/readiness (golden-service chart probes)
      /metrics  Prometheus text format

  trainer — stands in for the training image (ghcr.io/nycterent/synorg/ml/trainer).
    Implements the KTD12 checkpoint contract shape: writes a checkpoint of
    CHECKPOINT_SIZE_MB to CHECKPOINT_DIR every CHECKPOINT_INTERVAL_SECONDS,
    resumes from the newest checkpoint at start, flushes a final checkpoint on
    SIGTERM (and when the chart's preStop touches .final-checkpoint-requested).
    Serves /metrics with the game-day passGate series:
      training_checkpoint_lost_seconds        seconds since last durable flush
      checkpoint_store_write_throughput_mbps  measured MB/s of the last flush

No dependencies (stdlib only): the Prometheus exposition is hand-rolled so the
image is a bare python:slim. This is a stand-in, not a product: it exists so
the e2e physics and evidence chain can run before the real services land.
"""
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("MODE", "render")
PORT = int(os.environ.get("PORT", "8001"))

# --- render mode state --------------------------------------------------------
RENDER_SLEEP_MS = float(os.environ.get("RENDER_SLEEP_MS", "30"))
BUCKETS = [0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0]  # le buckets; +Inf implicit
_lock = threading.Lock()
_bucket_counts = [0] * (len(BUCKETS) + 1)
_hist_sum = 0.0
_hist_count = 0


def observe_render(seconds):
    global _hist_sum, _hist_count
    with _lock:
        _hist_sum += seconds
        _hist_count += 1
        # Per-bucket (non-cumulative) counts; render_metrics cumulates for `le`.
        for i, ub in enumerate(BUCKETS):
            if seconds <= ub:
                _bucket_counts[i] += 1
                break
        else:
            _bucket_counts[-1] += 1  # above all bounds: +Inf-only


# --- trainer mode state -------------------------------------------------------
CHECKPOINT_DIR = os.environ.get("CHECKPOINT_DIR", "/mnt/checkpoints")
CHECKPOINT_INTERVAL = int(os.environ.get("CHECKPOINT_INTERVAL_SECONDS", "300"))
CHECKPOINT_SIZE_MB = int(os.environ.get("CHECKPOINT_SIZE_MB", "64"))
_last_flush = time.monotonic()  # resume-or-start counts as flushed state
_last_mbps = 0.0
_stop = threading.Event()


def flush_checkpoint(reason):
    """Write one checkpoint; update flush time + measured throughput."""
    global _last_flush, _last_mbps
    os.makedirs(CHECKPOINT_DIR, exist_ok=True)
    path = os.path.join(CHECKPOINT_DIR, f"ckpt-{os.environ.get('JOB_COMPLETION_INDEX', '0')}.bin")
    tmp = path + ".tmp"
    chunk = b"\0" * (1024 * 1024)
    t0 = time.monotonic()
    with open(tmp, "wb") as f:
        for _ in range(CHECKPOINT_SIZE_MB):
            f.write(chunk)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)  # atomic: a killed mid-flush write never clobbers last-good
    dt = max(time.monotonic() - t0, 1e-6)
    with _lock:
        _last_flush = time.monotonic()
        _last_mbps = CHECKPOINT_SIZE_MB / dt
    print(f"checkpoint flushed reason={reason} mb={CHECKPOINT_SIZE_MB} mbps={CHECKPOINT_SIZE_MB / dt:.1f}", flush=True)


def trainer_loop():
    # Resume contract: newest checkpoint under CHECKPOINT_DIR is the start state.
    marker = os.path.join(CHECKPOINT_DIR, ".final-checkpoint-requested")
    next_flush = time.monotonic() + CHECKPOINT_INTERVAL
    while not _stop.is_set():
        if os.path.exists(marker):  # preStop hook asked for a final flush
            try:
                os.remove(marker)
            except OSError:
                pass
            flush_checkpoint("prestop-marker")
        if time.monotonic() >= next_flush:
            flush_checkpoint("interval")
            next_flush = time.monotonic() + CHECKPOINT_INTERVAL
        _stop.wait(1)


def render_metrics():
    lines = [
        "# TYPE render_start_seconds histogram",
    ]
    with _lock:
        acc = 0
        for i, ub in enumerate(BUCKETS):
            acc += _bucket_counts[i]
            lines.append(f'render_start_seconds_bucket{{le="{ub}"}} {acc}')
        lines.append(f'render_start_seconds_bucket{{le="+Inf"}} {_hist_count}')
        lines.append(f"render_start_seconds_sum {_hist_sum}")
        lines.append(f"render_start_seconds_count {_hist_count}")
    return "\n".join(lines) + "\n"


def trainer_metrics():
    with _lock:
        lost = time.monotonic() - _last_flush
        mbps = _last_mbps
    return (
        "# TYPE training_checkpoint_lost_seconds gauge\n"
        f"training_checkpoint_lost_seconds {lost:.1f}\n"
        "# TYPE checkpoint_store_write_throughput_mbps gauge\n"
        f"checkpoint_store_write_throughput_mbps {mbps:.1f}\n"
    )


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # request logs would swamp the evidence logs at load
        pass

    def _send(self, code, body, ctype="text/plain"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/healthz", "/readyz"):
            self._send(200, "ok\n")
        elif path == "/metrics":
            self._send(200, render_metrics() if MODE == "render" else trainer_metrics(),
                       "text/plain; version=0.0.4")
        elif path == "/render" and MODE == "render":
            t0 = time.monotonic()
            time.sleep(RENDER_SLEEP_MS / 1000.0)
            observe_render(time.monotonic() - t0)
            self._send(200, '{"render":"ok"}\n', "application/json")
        else:
            self._send(404, "not found\n")


def main():
    if MODE == "trainer":
        # Final checkpoint on SIGTERM: the 120 s grace window (KTD12) is far
        # more than one CHECKPOINT_SIZE_MB flush needs.
        def term(_sig, _frm):
            flush_checkpoint("sigterm")
            _stop.set()
            raise SystemExit(0)
        signal.signal(signal.SIGTERM, term)
        flush_checkpoint("startup-resume-point")
        threading.Thread(target=trainer_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("", PORT), Handler)
    print(f"inference-stub mode={MODE} port={PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

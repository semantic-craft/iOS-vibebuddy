#!/usr/bin/env python3
"""Replay ticket08 at the real daemon's HTTP/SSE boundary, never live Cursor.
Build first: swift build --package-path VibeBuddyMac --scratch-path .scratch/build-cursor-cloud --product vibebuddyd
Run: python3 tools/qa/cursor-cloud-stream.py <path-to-vibebuddyd> <evidence-dir>
"""
import http.server, json, os, pathlib, shutil, socket, subprocess, sys, tempfile, threading, time, urllib.request

started = time.monotonic()
state = {"requests": [], "emitted": {}, "streams": {}, "working": set()}
lock = threading.Lock()
AGENTS = ["bc-sse", "bc-expired", "bc-broken", "bc-poll", "bc-history"]

def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

class Upstream(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, value, code=200):
        body = json.dumps(value).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        path = self.path.split("?")[0]
        with lock: state["requests"].append({"path": path, "cursor": self.headers.get("Last-Event-ID")})
        if path == "/v1/agents":
            self.reply({"items": [{"id": a, "status": "IDLE" if a == "bc-history" else "ACTIVE", "latestRunId": "run-" + a} for a in AGENTS]}); return
        parts = path.split("/")
        agent = parts[3]
        run = "run-" + agent
        if path.endswith("/stream"):
            with lock:
                n = state["streams"].get(agent, 0); state["streams"][agent] = n+1
            if agent in ["bc-expired", "bc-poll", "bc-broken"]:
                if agent == "bc-expired":
                    with lock: state["emitted"][agent] = time.monotonic()
                self.reply({"code": "stream_expired" if agent == "bc-expired" else "offline"}, 410 if agent == "bc-expired" else 503); return
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            if n == 0:
                assert self.headers.get("Last-Event-ID") is None
                self.wfile.write(b'id: opaque-sse\nevent: assistant\ndata: {"text":"hello"}\n\n'); self.wfile.flush(); return
            assert self.headers.get("Last-Event-ID") == "opaque-sse"
            time.sleep(.2)
            with lock: state["emitted"][agent] = time.monotonic()
            terminal = f'event: status\ndata: {{"runId":"{run}","status":"FINISHED"}}\n\n'
            result = f'id: opaque-result\nevent: result\ndata: {{"runId":"{run}","status":"FINISHED","text":"done"}}\n\n'
            try: self.wfile.write((terminal+result+result+'id: opaque-result\nevent: done\ndata: {}\n\n').encode()); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if "/runs/" in path:
            if agent == "bc-broken": self.reply({}, 503); return
            if agent == "bc-poll" and time.monotonic()-started >= 3:
                with lock: state["emitted"].setdefault(agent, started+3)
            with lock: complete = agent in state["emitted"]
            self.reply({"id":run,"agentId":agent,"status":"FINISHED" if complete else "RUNNING","result":"boundary acceptance done"}); return
        self.reply({"id":agent,"status":"ACTIVE","repos":[{"url":"github.com/fixture/cloud"}]})

def main():
    binary, evidence = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    qa = pathlib.Path(tempfile.mkdtemp(prefix="vibebuddy-verify-cloud-", dir="/tmp"))
    home = qa / "home"; home.mkdir()
    daemon_port = port()
    assert daemon_port != 9876
    env = os.environ.copy()
    env.update(HOME=str(home), VIBEBUDDY_PORT=str(daemon_port), VIBEBUDDY_TOKEN="fixture-http-token",
               VIBEBUDDY_QA_CURSOR_CLOUD_URL=f"http://127.0.0.1:{upstream.server_port}",
               VIBEBUDDY_JOURNAL_PATH=str(qa/"journal.json"), VIBEBUDDY_DELIVERY_LOG_PATH=str(qa/"delivery.json"),
               VIBEBUDDY_DEVICE_REGISTRY_PATH=str(qa/"devices.json"), VIBEBUDDY_MISSED_PATH=str(qa/"missed.json"))
    log = (evidence/"daemon.log").open("w")
    proc = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
    def get(path, auth=True):
        request = urllib.request.Request(f"http://127.0.0.1:{daemon_port}"+path, headers={"Authorization":"Bearer fixture-http-token"} if auth else {})
        with urllib.request.urlopen(request, timeout=2) as response: return response.read()
    try:
        for _ in range(150):
            if proc.poll() is not None: raise RuntimeError("daemon exited; inspect daemon.log")
            try:
                assert get("/health",False) == b"ok"
                break
            except (OSError, AssertionError): time.sleep(.1)
        try: get("/snapshot",False); raise AssertionError("unauthenticated snapshot accepted")
        except urllib.error.HTTPError as e: assert e.code == 401
        observed = {}
        snapshots = []
        deadline = time.monotonic()+27
        while time.monotonic()<deadline:
            snap = json.loads(get("/snapshot")); now = time.monotonic()
            rows = {r["id"]: r for r in snap["sessions"]}
            for agent, row in rows.items():
                if row["status"] == "working": state["working"].add(agent)
                if row["status"] == "done" and agent in state["emitted"] and agent not in observed:
                    observed[agent] = round((now-state["emitted"][agent])*1000, 1)
            snapshots.append({"at":round(now-started,3),"rows":{a:{"status":r["status"],"completionID":r.get("completionID"),"historyOnly":r.get("historyOnly")} for a,r in rows.items() if a in AGENTS}})
            if {"bc-sse","bc-expired","bc-poll"} <= observed.keys(): break
            time.sleep(.05)
        assert {"bc-sse","bc-expired","bc-poll"} <= observed.keys(), observed
        assert rows["bc-broken"]["status"] == "working", rows["bc-broken"]
        assert rows["bc-history"].get("historyOnly") and not rows["bc-history"].get("completionID")
        assert observed["bc-sse"] < 2000 and observed["bc-poll"] > 5000, observed
        # A subsequent snapshot keeps one terminal completion identity, no replay.
        completion = rows["bc-sse"].get("completionID")
        assert completion
        time.sleep(.3)
        again = json.loads(get("/snapshot"))
        assert next(r for r in again["sessions"] if r["id"]=="bc-sse").get("completionID") == completion
        (evidence/"snapshot.json").write_text(json.dumps(again, indent=2))
        result = {"boundary":"fake upstream HTTP/SSE -> actual vibebuddyd -> authenticated snapshot; not live Cursor", "port":daemon_port, "daemon_pid":proc.pid,
                  "latency_ms":observed, "snapshots":snapshots, "requests":state["requests"], "checks":["opaque cursor resume","410 terminal read","broken read remains working","historical completion silent","deduplicated completion identity","poll fallback"]}
        (evidence/"results.json").write_text(json.dumps(result,indent=2))
        print(json.dumps({"latency_ms": observed, "evidence":str(evidence)}))
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        log.close(); upstream.shutdown(); upstream.server_close(); shutil.rmtree(qa)
        (evidence/"cleanup.json").write_text(json.dumps({"daemon_pid": proc.pid, "exit_code": proc.returncode,
                                                       "disposable_home_removed": not qa.exists()}, indent=2))

if __name__ == "__main__": main()

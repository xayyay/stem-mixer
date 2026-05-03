"""
Stem Mixer — Local DAW-style stem separator and mixer.
Runs fully offline. Uses Demucs for AI stem separation.
Persists processed songs in a local SQLite database.
"""

import os, sys, json, subprocess, threading, shutil, uuid, sqlite3, glob
from pathlib import Path
from datetime import datetime
from flask import Flask, render_template, request, jsonify, send_from_directory
import logging

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024  # 500 MB

BASE_DIR    = Path(__file__).parent
UPLOAD_DIR  = BASE_DIR / "uploads"
STEMS_DIR   = BASE_DIR / "stems_output"
STATIC_DIR  = BASE_DIR / "static"
DB_PATH     = BASE_DIR / "library.db"
# cookies.txt path: set COOKIES_TXT env var to override, otherwise look next to app.py
COOKIES_TXT = Path(os.environ.get("COOKIES_TXT", BASE_DIR / "cookies.txt"))

for d in (UPLOAD_DIR, STEMS_DIR, STATIC_DIR):
    d.mkdir(exist_ok=True)

# In-memory job tracker (active separations only)
jobs: dict[str, dict] = {}


# ── Database ──────────────────────────────────────────────────────────────────

def db_connect():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with db_connect() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS songs (
                id          TEXT PRIMARY KEY,
                title       TEXT NOT NULL,
                artist      TEXT DEFAULT '',
                source      TEXT DEFAULT 'file',
                source_url  TEXT DEFAULT '',
                duration    REAL DEFAULT 0,
                bpm         INTEGER DEFAULT 0,
                model       TEXT DEFAULT 'htdemucs',
                stem_dir    TEXT NOT NULL,
                stems_json  TEXT NOT NULL,
                added_at    TEXT NOT NULL,
                last_opened TEXT DEFAULT '',
                play_count  INTEGER DEFAULT 0,
                thumbnail   TEXT DEFAULT ''
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS mixer_presets (
                id         TEXT PRIMARY KEY,
                song_id    TEXT NOT NULL,
                name       TEXT NOT NULL,
                state_json TEXT NOT NULL,
                saved_at   TEXT NOT NULL,
                FOREIGN KEY(song_id) REFERENCES songs(id)
            )
        """)
        conn.commit()

def song_to_dict(row) -> dict:
    d = dict(row)
    d["stems"] = json.loads(d.pop("stems_json", "{}"))
    return d

def insert_song(job_id, title, source, source_url, duration,
                stem_dir, stems, model="htdemucs", thumbnail=""):
    with db_connect() as conn:
        conn.execute("""
            INSERT OR REPLACE INTO songs
              (id, title, source, source_url, duration, model,
               stem_dir, stems_json, added_at, thumbnail)
            VALUES (?,?,?,?,?,?,?,?,?,?)
        """, (job_id, title, source, source_url, duration, model,
              stem_dir, json.dumps(stems),
              datetime.now().isoformat(timespec='seconds'), thumbnail))
        conn.commit()

def touch_song(song_id):
    with db_connect() as conn:
        conn.execute(
            "UPDATE songs SET last_opened=?, play_count=play_count+1 WHERE id=?",
            (datetime.now().isoformat(timespec='seconds'), song_id))
        conn.commit()

def update_song_bpm(song_id, bpm):
    with db_connect() as conn:
        conn.execute("UPDATE songs SET bpm=? WHERE id=?", (bpm, song_id))
        conn.commit()

def delete_song_db(song_id):
    with db_connect() as conn:
        row = conn.execute("SELECT stem_dir FROM songs WHERE id=?", (song_id,)).fetchone()
        if not row:
            return None
        conn.execute("DELETE FROM mixer_presets WHERE song_id=?", (song_id,))
        conn.execute("DELETE FROM songs WHERE id=?", (song_id,))
        conn.commit()
        return row["stem_dir"]


# ── Helpers ───────────────────────────────────────────────────────────────────

def check_demucs():
    return shutil.which("demucs") is not None

def check_ytdlp():
    return shutil.which("yt-dlp") is not None

def brew_env():
    """Return env with extended PATH covering common macOS Node.js install locations."""
    env = os.environ.copy()
    extra = [
        "/opt/homebrew/bin",            # Apple Silicon Homebrew
        "/usr/local/bin",               # Intel Homebrew
        "/usr/local/opt/node/bin",      # Homebrew node formula
        os.path.expanduser("~/.volta/bin"),  # Volta
    ]
    # nvm — pick the most recently modified version
    nvm_bins = sorted(glob.glob(os.path.expanduser("~/.nvm/versions/node/*/bin")),
                      key=os.path.getmtime, reverse=True)
    extra += nvm_bins
    valid = [p for p in extra if os.path.isdir(p)]
    if valid:
        env["PATH"] = ":".join(valid) + ":" + env.get("PATH", "")
    return env

def get_duration(path):
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", str(path)],
            capture_output=True, text=True)
        return float(json.loads(r.stdout)["format"]["duration"])
    except Exception:
        return 0.0

def make_yt(url):
    from pytubefix import YouTube
    return YouTube(url, use_oauth=True, allow_oauth_cache=True)

def get_yt_info(url):
    try:
        yt = make_yt(url)
        return {
            "title":     yt.title        or "YouTube Track",
            "thumbnail": yt.thumbnail_url or "",
            "uploader":  yt.author        or "",
        }
    except Exception as e:
        log.warning("get_yt_info failed: %s", e)
    return {"title": "YouTube Track", "thumbnail": "", "uploader": ""}

def stems_to_url_map(job_id, stem_dir):
    return {wav.stem: f"/stems/{job_id}/{wav.name}"
            for wav in Path(stem_dir).glob("*.wav")}


# ── Separation workers ────────────────────────────────────────────────────────

def run_demucs(job_id, audio_path, out_dir, title,
               source="file", source_url="", thumbnail="", model="htdemucs"):
    jobs[job_id]["status"]  = "separating"
    jobs[job_id]["message"] = "Running AI stem separation… this may take a few minutes"

    cmd = [sys.executable, "-m", "demucs", "-n", model,
           "-o", str(out_dir), str(audio_path)]
    log.info("Demucs cmd: %s", " ".join(cmd))

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1)
    for line in proc.stdout:
        line = line.rstrip()
        log.info("[demucs] %s", line)
        if "%" in line:
            try:
                pct = float(line.split("%")[0].split()[-1])
                jobs[job_id]["progress"] = round(pct)
            except Exception:
                pass
    proc.wait()

    if proc.returncode != 0:
        jobs[job_id]["status"]  = "error"
        jobs[job_id]["message"] = "Demucs failed. Run: pip install demucs"
        return

    track_name = Path(audio_path).stem
    stem_dir   = Path(out_dir) / model / track_name
    if not stem_dir.exists():
        candidates = list(Path(out_dir).rglob("drums.wav"))
        if candidates:
            stem_dir = candidates[0].parent
        else:
            jobs[job_id]["status"]  = "error"
            jobs[job_id]["message"] = "Could not find output stems"
            return

    stems    = stems_to_url_map(job_id, stem_dir)
    duration = get_duration(audio_path)

    insert_song(job_id, title, source, source_url, duration,
                str(stem_dir), stems, model, thumbnail)

    jobs[job_id].update({
        "status":   "done",
        "progress": 100,
        "message":  "Separation complete — saved to library!",
        "stems":    stems,
        "stem_dir": str(stem_dir),
        "duration": duration,
        "title":    title,
        "song_id":  job_id,
    })


def run_ytdlp(job_id, url, _out_path, title, thumbnail, artist, model="htdemucs"):
    jobs[job_id]["status"]  = "downloading"
    jobs[job_id]["message"] = "Downloading audio from YouTube…"
    try:
        yt = make_yt(url)

        # Prefer highest-bitrate audio-only stream; fall back to lowest-res video
        stream = (yt.streams.filter(only_audio=True).order_by("abr").last()
                  or yt.streams.get_lowest_resolution())
        if not stream:
            raise RuntimeError("No downloadable streams found for this video")

        label = getattr(stream, "abr", None) or stream.mime_type
        jobs[job_id]["message"] = f"Downloading audio ({label})…"

        dl_file = Path(stream.download(output_path=str(UPLOAD_DIR),
                                       filename=f"{job_id}_yt"))
        run_demucs(job_id, dl_file, STEMS_DIR, title,
                   source="youtube", source_url=url, thumbnail=thumbnail, model=model)
    except Exception as e:
        log.exception("YouTube download failed")
        jobs[job_id]["status"]  = "error"
        jobs[job_id]["message"] = f"Download failed: {e}"


# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/status")
def status():
    return jsonify({"demucs": check_demucs(), "ytdlp": check_ytdlp()})

@app.route("/yt-title")
def yt_title_route():
    url = request.args.get("url", "").strip()
    if not url:
        return jsonify({"error": "No URL"}), 400
    info = get_yt_info(url)
    return jsonify(info)


# Library ─────────────────────────────────────────────────────────────────────

@app.route("/library")
def library():
    q     = request.args.get("q", "").strip()
    sort  = request.args.get("sort", "added_at")
    order = request.args.get("order", "desc").upper()
    if sort not in {"added_at", "last_opened", "play_count", "title", "duration"}:
        sort = "added_at"
    if order not in ("ASC", "DESC"):
        order = "DESC"
    with db_connect() as conn:
        if q:
            rows = conn.execute(
                f"SELECT * FROM songs WHERE title LIKE ? OR artist LIKE ? ORDER BY {sort} {order}",
                (f"%{q}%", f"%{q}%")).fetchall()
        else:
            rows = conn.execute(
                f"SELECT * FROM songs ORDER BY {sort} {order}").fetchall()
    return jsonify([song_to_dict(r) for r in rows])

@app.route("/library/<song_id>")
def library_song(song_id):
    with db_connect() as conn:
        row = conn.execute("SELECT * FROM songs WHERE id=?", (song_id,)).fetchone()
    if not row:
        return jsonify({"error": "Not found"}), 404
    touch_song(song_id)
    return jsonify(song_to_dict(row))

@app.route("/library/<song_id>", methods=["PATCH"])
def update_song(song_id):
    data = request.get_json(force=True) or {}
    sets = {k: v for k, v in data.items() if k in {"title", "artist"}}
    if not sets:
        return jsonify({"error": "Nothing to update"}), 400
    with db_connect() as conn:
        ph = ", ".join(f"{k}=?" for k in sets)
        conn.execute(f"UPDATE songs SET {ph} WHERE id=?", (*sets.values(), song_id))
        conn.commit()
    return jsonify({"ok": True})

@app.route("/library/<song_id>", methods=["DELETE"])
def delete_song(song_id):
    stem_dir = delete_song_db(song_id)
    if not stem_dir:
        return jsonify({"error": "Not found"}), 404
    shutil.rmtree(stem_dir, ignore_errors=True)
    return jsonify({"ok": True})

@app.route("/library/<song_id>/bpm", methods=["POST"])
def save_bpm(song_id):
    data = request.get_json(force=True) or {}
    bpm  = int(data.get("bpm", 0))
    if bpm > 0:
        update_song_bpm(song_id, bpm)
    return jsonify({"ok": True})


# Mixer presets ───────────────────────────────────────────────────────────────

@app.route("/library/<song_id>/presets")
def list_presets(song_id):
    with db_connect() as conn:
        rows = conn.execute(
            "SELECT * FROM mixer_presets WHERE song_id=? ORDER BY saved_at DESC",
            (song_id,)).fetchall()
    return jsonify([dict(r) for r in rows])

@app.route("/library/<song_id>/presets", methods=["POST"])
def save_preset(song_id):
    data  = request.get_json(force=True) or {}
    name  = (data.get("name") or "Preset").strip()
    state = data.get("state")
    if not state:
        return jsonify({"error": "No state"}), 400
    pid = uuid.uuid4().hex[:8]
    with db_connect() as conn:
        conn.execute(
            "INSERT INTO mixer_presets (id,song_id,name,state_json,saved_at) VALUES (?,?,?,?,?)",
            (pid, song_id, name, json.dumps(state),
             datetime.now().isoformat(timespec='seconds')))
        conn.commit()
    return jsonify({"id": pid, "name": name})

@app.route("/presets/<preset_id>", methods=["DELETE"])
def delete_preset(preset_id):
    with db_connect() as conn:
        conn.execute("DELETE FROM mixer_presets WHERE id=?", (preset_id,))
        conn.commit()
    return jsonify({"ok": True})


# Upload / YouTube ─────────────────────────────────────────────────────────────

@app.route("/upload", methods=["POST"])
def upload():
    if "file" not in request.files:
        return jsonify({"error": "No file"}), 400
    f   = request.files["file"]
    ext = Path(f.filename).suffix.lower()
    if ext not in {".mp3", ".wav", ".flac", ".m4a", ".ogg", ".mp4", ".mkv", ".webm"}:
        return jsonify({"error": f"Unsupported format: {ext}"}), 400
    title  = Path(f.filename).stem
    model  = request.form.get("model", "htdemucs_6s")
    if model not in {"htdemucs", "htdemucs_6s", "htdemucs_ft"}:
        model = "htdemucs_6s"
    job_id = uuid.uuid4().hex[:8]
    dst    = UPLOAD_DIR / f"{job_id}{ext}"
    f.save(dst)
    jobs[job_id] = {"status": "queued", "progress": 0, "message": "Queued", "stems": {}}
    threading.Thread(target=run_demucs, args=(job_id, dst, STEMS_DIR, title, "file", "", "", model),
                     daemon=True).start()
    return jsonify({"job_id": job_id})

@app.route("/youtube", methods=["POST"])
def youtube():
    data  = request.get_json(force=True) or {}
    url   = data.get("url", "").strip()
    model = data.get("model", "htdemucs_6s")
    if model not in {"htdemucs", "htdemucs_6s", "htdemucs_ft"}:
        model = "htdemucs_6s"
    if not url:
        return jsonify({"error": "No URL"}), 400
    info   = get_yt_info(url)
    job_id = uuid.uuid4().hex[:8]
    dst    = UPLOAD_DIR / f"{job_id}.mp4"
    jobs[job_id] = {"status": "queued", "progress": 0, "message": "Queued",
                    "stems": {}, "title": info["title"]}
    threading.Thread(
        target=run_ytdlp,
        args=(job_id, url, dst, info["title"], info["thumbnail"], info["uploader"], model),
        daemon=True).start()
    return jsonify({"job_id": job_id, "title": info["title"]})

@app.route("/job/<job_id>")
def job_status(job_id):
    job = jobs.get(job_id)
    if not job:
        return jsonify({"error": "Unknown job"}), 404
    return jsonify(job)


# Stem file serving ────────────────────────────────────────────────────────────

@app.route("/stems/<song_id>/<filename>")
def serve_stem(song_id, filename):
    stem_dir = (jobs.get(song_id) or {}).get("stem_dir")
    if not stem_dir:
        with db_connect() as conn:
            row = conn.execute("SELECT stem_dir FROM songs WHERE id=?", (song_id,)).fetchone()
        if row:
            stem_dir = row["stem_dir"]
    if not stem_dir or not Path(stem_dir).exists():
        return "Stem not found", 404
    return send_from_directory(stem_dir, filename)


if __name__ == "__main__":
    init_db()
    print("\n🎛  Stem Mixer  —  http://localhost:5056\n")
    app.run(host="0.0.0.0", port=5056, debug=False, threaded=True)

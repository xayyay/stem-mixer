# Stem Mixer — Local DAW-style AI Stem Separator

A fully **offline** app that splits any audio/video file into individual
instrument stems (Drums, Bass, Vocals, Guitar/Other) and lets you mix them
live with per-channel faders, mute, solo, and pan controls.

---

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| Python 3.9+ | Runtime | https://python.org |
| ffmpeg | Audio decoding | see below |
| demucs | AI stem separation | `pip install demucs` |
| flask | Local web server | `pip install flask` |
| yt-dlp *(optional)* | YouTube download | `pip install yt-dlp` |

### Install ffmpeg

**macOS:**
```bash
brew install ffmpeg
```

**Ubuntu / Debian:**
```bash
sudo apt install ffmpeg
```

**Windows:**
Download from https://ffmpeg.org/download.html and add to PATH.

---

## Quick start

```bash
# 1. Clone / download this folder
cd stem-mixer

# 2. Install Python dependencies
pip install -r requirements.txt

# 3. Run the app
python app.py

# 4. Open in browser
open http://localhost:5056
```

On first use, Demucs will download its AI model (~80 MB). After that,
everything runs 100% offline.

---

## Usage

### Local file
- Drag and drop any audio/video file onto the drop zone
- Supported: MP3, WAV, FLAC, M4A, OGG, MP4, MKV, WEBM (up to 500 MB)
- Separation takes ~1–3 minutes depending on track length and your CPU/GPU

### YouTube URL
- Paste any YouTube URL (requires yt-dlp installed)
- Audio is downloaded locally to your machine first, then separated
- No data is sent to any external service during separation

---

## Mixer controls

| Control | Description |
|---------|-------------|
| **Fader** | Volume for each stem (0–100%) |
| **Pan** | Stereo position (left–centre–right) |
| **Mute** | Silence a stem without losing its fader level |
| **Solo** | Hear only the soloed stem(s) |
| **Master** | Overall output volume |
| **Loop** | Loop the whole track |

---

## Stems produced by Demucs

| Stem | Instruments |
|------|------------|
| **drums** | Drums, percussion |
| **bass** | Bass guitar, low-end |
| **vocals** | Lead and backing vocals |
| **other** | Guitar, keys, synths, and everything else |

For 6-stem separation (including piano and guitar separately), change
the model in `app.py`:

```python
model = "htdemucs_6s"   # 6 stems: drums, bass, guitar, piano, vocals, other
```

---

## GPU acceleration

Demucs is CPU-capable but significantly faster on a GPU. If you have an
NVIDIA GPU with CUDA:

```bash
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118
```

Apple Silicon (M1/M2/M3) is automatically accelerated via Metal.

---

## Project structure

```
stem-mixer/
├── app.py              ← Flask backend + separation logic
├── templates/
│   └── index.html      ← Full mixer UI (Web Audio API)
├── uploads/            ← Temporary uploaded files
├── stems_output/       ← Separated stems (per job)
├── requirements.txt
└── README.md
```

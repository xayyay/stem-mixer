"""
Stem Mixer — Desktop launcher.
Starts Flask on a local port and opens the UI in a native OS window
(WKWebView on macOS, Edge WebView2 on Windows) via pywebview.
No browser is opened.
"""

import socket
import sys
import threading
import time

import webview

PORT = 5056


def _wait_for_flask(port: int, timeout: float = 15.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def _run_flask() -> None:
    from app import app, init_db
    init_db()
    # Silence Flask's default startup banner
    import logging
    logging.getLogger("werkzeug").setLevel(logging.WARNING)
    app.run(host="127.0.0.1", port=PORT, debug=False,
            threaded=True, use_reloader=False)


def main() -> None:
    flask_thread = threading.Thread(target=_run_flask, daemon=True)
    flask_thread.start()

    if not _wait_for_flask(PORT):
        print("ERROR: Flask server did not start in time.", file=sys.stderr)
        sys.exit(1)

    window = webview.create_window(
        title="Stem Mixer",
        url=f"http://127.0.0.1:{PORT}",
        width=1440,
        height=900,
        min_size=(1100, 700),
        text_select=True,
    )
    webview.start(debug=False)


if __name__ == "__main__":
    main()

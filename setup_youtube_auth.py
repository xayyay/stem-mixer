"""
Run this once to authenticate with YouTube via Google OAuth.
The token is cached locally — you won't need to repeat this unless it expires.

Usage:
    python setup_youtube_auth.py
"""
from pytubefix import YouTube

print("Authenticating with YouTube...\n")
yt = YouTube(
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    use_oauth=True,
    allow_oauth_cache=True,
)
print(f"\nSuccess! Fetched: {yt.title}")
print("\nOAuth token cached. You can now start the app normally with: python app.py")

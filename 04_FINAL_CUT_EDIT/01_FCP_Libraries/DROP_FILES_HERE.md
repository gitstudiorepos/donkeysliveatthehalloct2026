# 🎬 01_FCP_Libraries — Final Cut Pro Project Libraries

Store your **Final Cut Pro** library (`.fcpbundle`) or project file here.

### Golden Rules for Final Cut Pro in GitStudio
1. **Storage Locations -> "In Library" vs "External":** In Final Cut Pro Library Properties, set **Media** to reference the external folders (`../../03_VIDEO_CAMERAS/` and `../../02_AUDIO_MIX_BOUNCES/`) and check **"Leave files in place"** on import.
2. **Render Caches are Ignored Automatically:** `.gitignore` automatically excludes `Render Files/`, `High Quality Media/`, `Analysis Files/`, and `.fcplock` so your library stays lightweight when pushing and pulling.
3. **Close Final Cut Pro Before Pushing:** Quit Final Cut Pro before running `git add . && git commit && git push` so all database changes are flushed cleanly.

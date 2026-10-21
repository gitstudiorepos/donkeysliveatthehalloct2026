# 🤝 Collaborator Workflow Guide (Logic Pro + Final Cut Pro)

Welcome to **donkeysLiveAtTheHallOct2026**! This repository uses **Git LFS** backed by a private **GitStudio Media Vault** so our team can share multi-gigabyte audio stems and multi-camera video without broken file links.

---

## 1. First-Time Setup on Your Mac
1. Open **Terminal** and install Git LFS if you haven't already:
   ```bash
   git lfs install
   ```
2. Clone the repository and configure your personal GitStudio key (sent to your email or copied from GitStudio):
   ```bash
   git clone https://github.com/gitstudiorepos/donkeysliveatthehalloct2026.git
   cd donkeysliveatthehalloct2026
   git config lfs.url "https://gitstudio.web.app/api/lfs/batch?key=<YOUR_GITSTUDIO_KEY>"
   ```
3. Pull only the folders you need right now, or pull everything:
   - **Pull everything:** `git lfs pull`
   - **Audio Engineer only (pull only Logic Audio):**
     ```bash
     git lfs pull --include="01_AUDIO_PRODUCTION/**,02_AUDIO_MIX_BOUNCES/**"
     ```
   - **Video Editor working on Proxies + Guide Mix only:**
     ```bash
     git lfs pull --include="02_AUDIO_MIX_BOUNCES/**,03_VIDEO_CAMERAS/Proxies_720p_1080p/**,04_FINAL_CUT_EDIT/**"
     ```

---

## 2. Audio Engineer Workflow (Logic Pro)
1. Place raw stage multitracks in `01_AUDIO_PRODUCTION/01_Raw_Multitracks/` and your Logic Pro session in `01_AUDIO_PRODUCTION/02_Logic_Pro_Sessions/`.
2. Export stereo sync guide mixes (48kHz / 24-bit WAV) into `02_AUDIO_MIX_BOUNCES/01_Sync_Guide_Mix/` so video editors can sync camera angles.
3. Save & quit Logic Pro, then push:
   ```bash
   git add .
   git commit -m "Update Logic Pro session and stereo guide mix"
   git push origin main
   ```

---

## 3. Video Editor Workflow (Final Cut Pro)
1. Place camera card offloads into their matching folder under `03_VIDEO_CAMERAS/`.
2. Create or open the Final Cut Pro library in `04_FINAL_CUT_EDIT/01_FCP_Libraries/`.
3. When importing media from `03_VIDEO_CAMERAS/` and `02_AUDIO_MIX_BOUNCES/`, **always choose "Leave files in place"**. Because every collaborator has the exact same folder structure, media stays linked automatically on every machine!
4. Export a snapshot `.fcpxml` to `04_FINAL_CUT_EDIT/02_FCPXML_Interchange/` and close Final Cut Pro before pushing.

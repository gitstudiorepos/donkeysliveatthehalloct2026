# 🎸🎬 donkeysLiveAtTheHallOct2026

Managed with **[GitStud.io](https://gitstudio.web.app)** — Collaborative Concert Film & Multitrack Audio Vault.

- **Audio Workflow:** Logic Pro
- **Video Workflow:** Final Cut Pro (5 Camera Angles)
- **GitHub Repository:** `https://github.com/gitstudiorepos/donkeysliveatthehalloct2026`

---

## 📂 Production Folder Map (Where to Drop Files)

```text
donkeysliveatthehalloct2026/
├── 01_AUDIO_PRODUCTION/
│   ├── 01_Raw_Multitracks/          # Raw stage-box / console multitrack WAV/AIFF stems
│   ├── 02_Logic_Pro_Sessions/         # Logic Pro session files (.logicx / project folders)
│   └── 03_Audio_Samples_IRs/        # Impulse responses, room tone, or patch assets
├── 02_AUDIO_MIX_BOUNCES/
│   ├── 01_Sync_Guide_Mix/           # Stereo guide mix WAV for syncing multi-cam video in Final Cut Pro
│   ├── 02_Song_Mix_Stems/           # Mixed stems (Drums, Bass, Guitars, Keys, Vocals, Crowd)
│   └── 03_Final_Masters/            # Final 24-bit/48kHz stereo & surround concert masters
├── 03_VIDEO_CAMERAS/
│   ├── Cam_A_Main_Wide/
│   ├── Cam_B_Stage_Left/
│   ├── Cam_C_Stage_Right/
│   ├── Cam_D_Closeups_Roaming/
│   ├── x6360/
│   └── Proxies_720p_1080p/          # Lightweight proxy media for fast remote multi-cam editing
├── 04_FINAL_CUT_EDIT/
│   ├── 01_FCP_Libraries/             # Final Cut Pro libraries (Use "Leave files in place"!)
│   ├── 02_FCPXML_Interchange/       # Lightweight .fcpxml / .fcpxmld timeline exports
│   └── 03_Graphics_Titles_LUTs/     # Concert lower-thirds, credits, and camera LUTs
├── 05_EXPORTS_AND_CUTS/
│   ├── 01_Rough_Cuts_Review/        # Work-in-progress MP4/MOV cuts for band review in GitStudio
│   └── 02_Final_Masters/            # Final mastered concert film exports
└── 06_DOCS_SETLIST_NOTES/
    ├── SETLIST_AND_TIMECODE.md      # Concert setlist, timecode markers & mix/edit notes
    └── COLLABORATOR_WORKFLOW.md     # Golden rules for Logic Pro & Final Cut Pro collaborators
```

---

## 🚀 Quick Local Setup (Clone + Configure Key + Open in Finder)

Run this in macOS **Terminal** (replace `<YOUR_GITSTUDIO_KEY>` with your personal `gs_...` or `gs_collab_...` key):

```bash
git lfs install
git clone https://github.com/gitstudiorepos/donkeysliveatthehalloct2026.git
cd donkeysliveatthehalloct2026
git config lfs.url "https://gitstudio.web.app/api/lfs/batch?key=<YOUR_GITSTUDIO_KEY>"
open .
```

### Pushing Your Audio or Video Files
After dropping your files into the folders above:
```bash
git add .
git commit -m "Add concert audio stems / camera footage"
git push origin main
```

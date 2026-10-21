# 🎛️ 02_Logic_Pro_Sessions — Drop Logic Pro Sessions Here

Drop your **Logic Pro** project files or packages (e.g. `donkeysLiveAtTheHallOct2026.logicx`) into this folder.

### Best Practices for Logic Pro + Git LFS
1. **Save Before Committing:** Always save and close Logic Pro before running `git add . && git commit`.
2. **Automatic Cache Exclusion:** Temporary `Freeze Files/` and `Undo Data.nosync/` inside `.logicx` bundles are automatically ignored via `.gitignore` so you only upload actual audio & session data.
3. **Bounce a Sync Guide Mix:** Whenever the timing/arrangement is locked, export a stereo WAV guide mix into `../../02_AUDIO_MIX_BOUNCES/01_Sync_Guide_Mix/` so video editors can sync multi-cam angles in Final Cut Pro.

# 🎬 Large Media Sync Guide (Users & AI Agents)

This repository stores multi-gigabyte concert audio stems and multi-camera video in **Git LFS** backed by the **GitStudio Media Vault** (`https://gitstudio.web.app/api/lfs/batch`).

> **⚠️ IMPORTANT RULE — DO NOT RUN `git add .` ON LARGE CAMERA OFFLOADS**
>
> When you run `git add` on a Git LFS file, Git LFS copies the **entire file** into `.git/lfs/objects/` before committing or uploading. If you have 480 GB of new `.MOV` / `.insv` footage on an SSD with 440 GB of free space, `git add .` will duplicate all 480 GB into `.git/lfs/objects/` at once and **run the drive completely out of disk space**.

Instead, always sync new media using the root scripts below, which batch small files first and then stage, commit, push, and **force-prune** large files **one at a time, smallest first**.

---

## 🚀 Quick Start (Two-Window Workflow)

### Window 1 — Run the Resumable Sync Script
From the repository root (`donkeysliveatthehalloct2026/`):

```bash
# 1. Preview what will be synced (read-only dry run)
./sync-large-files.sh --dry-run

# 2. Start syncing (interactive confirmation)
./sync-large-files.sh

# Or run non-interactively (for AI agents / unattended overnight runs):
./sync-large-files.sh --yes

# Optional: upload 2 large files in parallel (~2x overseas throughput when SSD free space permits; default is 1):
./sync-large-files.sh --parallel 2 --yes
```

**What you see in Window 1:**
- Overall summary of drive free space, parallel stream count (default `1`), the Phase 1 small-files batch, and the numbered smallest-to-largest Phase 2 queue.
- Per-file / per-batch `[1/4] Staging` → `[2/4] Committing` → `[3/4] Uploading` (displays **Git LFS's live `Uploading LFS objects: XX% ... | XX MB/s` progress line**, automatically using HTTP/1.1 via `GODEBUG=http2client=0` for ~50% higher per-stream speed) → `[4/4] Verifying remote & pruning local LFS cache`.
- If `--parallel 2` is used and free SSD space ever gets too tight for a pair, the script automatically throttles back to `1` file so `.git/lfs/objects/` never fills the drive.
- Automatic `caffeinate -i` on macOS so your Mac will not sleep during multi-hour uploads.

---

### Window 2 — Check Detailed Progress & Individual / Cumulative ETAs
Open a **second Terminal window** in the repository root and run:

```bash
./check-sync-progress.sh
```

**What `check-sync-progress.sh` does:**
1. Prompts you to enter your **current upload speed in `MB/s`** (you can read this right off the `| XX MB/s` Git LFS line in Window 1, or pass `--speed 12 --once` for non-interactive use).
2. Reads live byte-level progress from `.git/lfs/sync_progress.log` and `.git/lfs/sync_state.env` to show:
   - **Currently uploading file:** visual progress bar, exact GB & `%` completed, GB remaining, and **time left to finish the current file** (with local clock finish time).
   - *(If a file is still in the pre-upload LFS hashing/staging step, it shows live hashing `%` too.)*
3. Scans all **remaining queued files** (sorted smallest → largest) and prints a table with:
   - **Individual ETA:** how long each file will take on its own at your entered `MB/s`.
   - **Cumulative ETA:** total time from right now until that file finishes (including the remainder of the currently uploading file + all smaller files ahead of it) and estimated finish clock time.
4. Press **`Enter`** anytime to refresh with live progress, type a **new `MB/s` number** if your upload speed changes, or press **`q`** / **`Ctrl+C`** to exit.

---

## 🔁 Safe Cancellation & Automatic Recovery

**Both scripts are 100% safe to cancel (`Ctrl+C`) at any moment and recover simply by starting them again:**

- **Restarting `./sync-large-files.sh`:**
  1. **Interrupted mid-upload (`git push`):** Detects the unpushed commit on `main`, skips re-hashing, immediately resumes pushing the file to GitStudio LFS, verifies the remote copy, and prunes `.git/lfs/objects/` before continuing with the remaining queue.
  2. **Interrupted mid-stage (`git add`):** Cleans any stale lock/temp partials, resets half-staged uncommitted index entries back to the working tree, prunes any orphaned LFS cache objects, and restarts cleanly at the smallest remaining file.
  3. **Already-pushed files are never re-uploaded:** Because every completed file has its own commit already pushed to `origin/main`, restarting picks up strictly at the files still left to sync.
- **Restarting `./check-sync-progress.sh`:**
  - Completely read-only. Start, stop (`Ctrl+C`), and restart it whenever you want — even before `sync-large-files.sh` starts (to estimate total upload time) or while paused.

---

## 🤖 Rules & Manual Protocol for AI Agents

If you are an AI agent operating on this repository:

1. **Prefer `./sync-large-files.sh` over manual `git add` / `git push`:**
   - First inspect with `./sync-large-files.sh --dry-run`.
   - Execute with `./sync-large-files.sh --yes` (custom cutoff optional via `--threshold-mb <MB>`, default `100`).
   - Check live status/ETAs anytime via `./check-sync-progress.sh --speed <MB_PER_SEC> --once`.
2. **Never run `git add .` or `git add -A` when untracked files `>= 100 MB` exist.**
3. **If executing manual commands on a large file (`>= 100 MB`), strictly follow this sequence per file (smallest byte size first):**
   ```bash
   # 1. Confirm drive free space exceeds (file size + 5 GB buffer)
   df -h .

   # 2. Verify the file matches a Git LFS filter in .gitattributes
   git check-attr filter -- "path/to/file.MOV"
   # Must output: path/to/file.MOV: filter: lfs
   # If not, run: git lfs track "*.EXT" && git add .gitattributes

   # 3. Stage, commit, and push ONLY that single large file
   git add -- "path/to/file.MOV"
   git commit -m "Add file.MOV"
   git push origin main

   # 4. MANDATORY: Verify remote vault copy & delete local .git/lfs/objects duplicate
   git lfs prune --force --verify-remote
   ```
   > **Why `--force --verify-remote` is mandatory:** Plain `git lfs prune` keeps objects referenced by `HEAD` and recent commits, which still fills up `.git/lfs/objects/` across consecutive files. `--verify-remote` confirms GitStudio Vault holds the object, and `--force` deletes *only* the redundant cache copy inside `.git/lfs/objects/` while leaving the working-tree media file intact.

#!/usr/bin/env bash
# =============================================================================
# sync-large-files.sh — Safe, Resumable Git LFS Sync for Large Media Files
# Repository: donkeysLiveAtTheHallOct2026
#
# Why this exists:
#   `git add` copies every LFS-tracked media file into `.git/lfs/objects/`
#   before upload. Adding hundreds of GB at once can exceed free SSD space.
#   This script:
#     1. Recovers automatically from any interrupted previous run (pushes any
#        unpushed commit, resets half-staged index, and prunes stale LFS cache).
#     2. Batches small files (< threshold, default 100 MB) in one commit/push.
#     3. Processes large files (>= threshold) in ascending size order (smallest
#        -> largest), staging/committing/pushing 1 at a time by default (or N
#        in parallel via `--parallel N` when free SSD space permits), verifying
#        each copy on the GitStudio LFS remote before freeing local cache.
#
# Safe to cancel (Ctrl+C) anytime: simply run `./sync-large-files.sh` again
# to resume right where it left off.
#
# Companion monitor (run in a second Terminal window):
#   ./check-sync-progress.sh
# =============================================================================
set -euo pipefail

# Disable Go HTTP/2 client in git-lfs so single-stream uploads use HTTP/1.1
# with full OS TCP window scaling instead of 16 KiB HTTP/2 flow-control frames
export GODEBUG="${GODEBUG:-http2client=0}"

# Always run from the repository root containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Defaults
DRY_RUN=0
ASSUME_YES=0
THRESHOLD_MB=100
PARALLEL=1
SAFETY_BUFFER_BYTES=5000000000 # 5 GB safety margin on drive free space

usage() {
  cat <<'EOF'
Usage: ./sync-large-files.sh [options]

Options:
  -p, --parallel <N>       Max large files to stage & upload in parallel per
                           batch (default: 1; use 2 to double overseas upload
                           throughput when drive free space permits).
  -n, --dry-run            Preview recovery state, small-file batch, and sorted
                           large-file queue without modifying anything.
  -y, --yes                Non-interactive mode (no confirmation prompt; ideal
                           for AI agents or unattended overnight runs).
  -t, --threshold-mb <MB>  Size cutoff in MB (1 MB = 1,000,000 bytes). Files
                           below this batch together; files >= this sync in
                           smallest-first order. (Default: 100)
  -h, --help               Show this help message.
EOF
}

ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--parallel)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -le 0 ]]; then
        echo "❌ Error: --parallel requires a positive integer (e.g. 1 or 2)." >&2
        exit 1
      fi
      PARALLEL="$2"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    -t|--threshold-mb)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -le 0 ]]; then
        echo "❌ Error: --threshold-mb requires a positive integer." >&2
        exit 1
      fi
      THRESHOLD_MB="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "❌ Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Keep macOS awake during multi-hour uploads (skip for --dry-run)
if [[ "$DRY_RUN" -eq 0 && -z "${__SYNC_CAFFEINATED:-}" ]] && command -v caffeinate >/dev/null 2>&1; then
  if [[ ${#ORIG_ARGS[@]} -gt 0 ]]; then
    exec env __SYNC_CAFFEINATED=1 caffeinate -i "$0" "${ORIG_ARGS[@]}"
  else
    exec env __SYNC_CAFFEINATED=1 caffeinate -i "$0"
  fi
fi

THRESHOLD_BYTES=$(( THRESHOLD_MB * 1000000 ))

# Ensure we are inside a Git work tree
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null || true)"
if [[ -z "$GIT_DIR" ]]; then
  echo "❌ Error: Not inside a Git repository." >&2
  exit 1
fi
# Convert GIT_DIR to an absolute path (required by GIT_LFS_PROGRESS)
GIT_DIR="$(cd "$GIT_DIR" && pwd)"
LFS_DIR="$GIT_DIR/lfs"
mkdir -p "$LFS_DIR"

STATE_FILE="$LFS_DIR/sync_state.env"
PROGRESS_FILE="$LFS_DIR/sync_progress.log"
PID_FILE="$LFS_DIR/sync.pid"

# Temp workspace cleaned on exit
TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/gitstudio-sync.XXXXXX")"

# Helpers
get_file_size() {
  local f="$1"
  stat -f%z "$f" 2>/dev/null || stat -c%s "$f"
}

get_free_bytes() {
  df -Pk . | awk 'NR==2 {printf "%.0f\n", $4 * 1024}'
}

human_size() {
  awk -v b="$1" 'BEGIN {
    if (b >= 1000000000)      printf "%.2f GB", b / 1000000000;
    else if (b >= 1000000)    printf "%.2f MB", b / 1000000;
    else if (b >= 1000)       printf "%.1f KB", b / 1000;
    else                      printf "%.0f B", b;
  }'
}

format_duration() {
  local s="$1"
  local h=$(( s / 3600 ))
  local m=$(( (s % 3600) / 60 ))
  local sec=$(( s % 60 ))
  if (( h > 0 )); then
    printf "%dh %02dm %02ds" "$h" "$m" "$sec"
  elif (( m > 0 )); then
    printf "%dm %02ds" "$m" "$sec"
  else
    printf "%ds" "$sec"
  fi
}

write_state() {
  local phase="$1"
  local cur_file="${2:-}"
  local cur_size="${3:-0}"
  local cur_idx="${4:-0}"
  local tot_large="${5:-0}"
  local started="${6:-$(date +%s)}"
  local batch_files="${7:-$cur_file}"
  local stage_base="${8:-0}"
  local tmp_state="$STATE_FILE.tmp.$$"
  {
    printf "STATE=%s\n" "$phase"
    printf "SYNC_PID=%s\n" "$$"
    printf "PARALLEL=%s\n" "$PARALLEL"
    printf "CURRENT_FILE=%s\n" "$cur_file"
    printf "BATCH_FILES=%s\n" "$batch_files"
    printf "CURRENT_SIZE_BYTES=%s\n" "$cur_size"
    printf "STAGE_BASE_BYTES=%s\n" "$stage_base"
    printf "CURRENT_INDEX=%s\n" "$cur_idx"
    printf "TOTAL_LARGE=%s\n" "$tot_large"
    printf "PHASE_START_EPOCH=%s\n" "$started"
    printf "THRESHOLD_BYTES=%s\n" "$THRESHOLD_BYTES"
    printf "UPDATED_EPOCH=%s\n" "$(date +%s)"
  } > "$tmp_state"
  mv -f "$tmp_state" "$STATE_FILE"
}

COMPLETED_NORMALLY=0
CLEANED_UP=0

on_interrupt() {
  echo ""
  echo "⚠️  Sync interrupted by user/signal."
  echo "   Everything already pushed is safely on GitHub & GitStudio LFS."
  echo "   Run ./sync-large-files.sh again anytime to resume cleanly."
  exit 130
}

on_exit() {
  if [[ "$CLEANED_UP" -eq 1 ]]; then
    return
  fi
  CLEANED_UP=1
  rm -rf "$TMP_WORK"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ -f "$PID_FILE" ]] && [[ "$(cat "$PID_FILE" 2>/dev/null || true)" == "$$" ]]; then
      rm -f "$PID_FILE"
    fi
    if [[ "$COMPLETED_NORMALLY" -eq 0 ]]; then
      write_state "interrupted" "" 0 0 0
    fi
  fi
}

trap on_interrupt INT TERM
trap on_exit EXIT

echo "========================================================================"
echo "🎬 GitStudio Large Media Sync — donkeysLiveAtTheHallOct2026"
echo "========================================================================"

# Guard against concurrent runs
if [[ -f "$PID_FILE" ]]; then
  EXISTING_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$EXISTING_PID" && "$EXISTING_PID" != "$$" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    echo "❌ Another sync-large-files.sh process is currently running (PID $EXISTING_PID)." >&2
    echo "   Wait for it to finish or stop it before starting a new run." >&2
    COMPLETED_NORMALLY=1
    exit 1
  fi
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "$$" > "$PID_FILE"
fi

# Verify Git LFS is available
if ! git lfs version >/dev/null 2>&1; then
  echo "❌ Error: git-lfs is not installed. Install with: brew install git-lfs" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  git lfs install --local >/dev/null 2>&1 || true
fi

# Verify branch is main
CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "❌ Error: Expected to be on branch 'main', currently on '${CURRENT_BRANCH:-detached HEAD}'." >&2
  exit 1
fi

# Verify GitStudio LFS key is configured
CURRENT_LFS_URL="$(git config --local lfs.url || true)"
if [[ -z "$CURRENT_LFS_URL" || "$CURRENT_LFS_URL" != *"key="* ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "⚠️  Note: Local GitStudio LFS key (lfs.url) is not configured yet."
  elif [[ "$ASSUME_YES" -eq 1 ]]; then
    echo "❌ Error: Local Git LFS key is not configured in .git/config." >&2
    echo "   Run: git config lfs.url \"https://gitstudio.web.app/api/lfs/batch?key=<YOUR_KEY>\"" >&2
    exit 1
  else
    echo ""
    echo "🔑 Your local Git LFS key is not configured yet."
    read -r -p "Paste your GitStudio Key (gs_... or gs_collab_...): " USER_KEY
    if [[ -z "$USER_KEY" ]]; then
      echo "❌ Cannot sync LFS media without a GitStudio key." >&2
      exit 1
    fi
    git config lfs.url "https://gitstudio.web.app/api/lfs/batch?key=$USER_KEY"
    echo "✅ Saved key locally in .git/config."
  fi
fi

# Recover stale .git/index.lock if no git process is active
if [[ -f "$GIT_DIR/index.lock" ]]; then
  if pgrep -f "git" >/dev/null 2>&1; then
    echo "⚠️  Warning: $GIT_DIR/index.lock exists and another git process may be running."
    if [[ "$DRY_RUN" -eq 0 ]]; then
      echo "   Wait a moment and re-run once any other git command finishes." >&2
      exit 1
    fi
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    echo "🔧 [Dry Run] Stale .git/index.lock detected — would remove automatically."
  else
    echo "🔧 Removing stale .git/index.lock from an interrupted prior git command..."
    rm -f "$GIT_DIR/index.lock"
  fi
fi

# Fetch remote state to check if we are behind or ahead of origin/main
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "🔄 Checking remote status on origin/main..."
  git fetch origin main
fi

BEHIND_COUNT="$(git --no-optional-locks rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
AHEAD_COUNT="$(git --no-optional-locks rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"

if (( BEHIND_COUNT > 0 )); then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "⬇️  [Dry Run] Local branch is $BEHIND_COUNT commit(s) behind origin/main — would pull first."
  elif (( AHEAD_COUNT == 0 )); then
    echo "⬇️  Pulling $BEHIND_COUNT new commit(s) from origin/main (pointer fast-forward)..."
    GIT_LFS_SKIP_SMUDGE=1 git merge --ff-only origin/main
    echo "   (Pulling any new remote LFS files...)"
    git lfs pull
  else
    echo "❌ Local 'main' ($AHEAD_COUNT ahead) and 'origin/main' ($BEHIND_COUNT behind) have diverged." >&2
    echo "   Please reconcile with 'git pull --rebase origin main' before syncing large files." >&2
    exit 1
  fi
fi

# =============================================================================
# RECOVERY STEP: Resume any unpushed commits, half-staged files, or unpruned LFS
# =============================================================================
AHEAD_COUNT="$(git --no-optional-locks rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
if (( AHEAD_COUNT > 0 )); then
  UNPUSHED_DESC="$(git --no-optional-locks log -1 --format='%s' HEAD)"
  UNPUSHED_LIST="$TMP_WORK/unpushed_files.txt"
  git --no-optional-locks -c core.quotePath=false diff-tree --no-commit-id --name-only -r origin/main HEAD > "$UNPUSHED_LIST" || true

  UNPUSHED_BYTES=0
  UNPUSHED_FILE_COUNT=0
  UNPUSHED_LABEL=""
  UNPUSHED_PIPE=""
  while IFS= read -r uf; do
    [[ -z "$uf" ]] && continue
    UNPUSHED_FILE_COUNT=$(( UNPUSHED_FILE_COUNT + 1 ))
    if [[ -z "$UNPUSHED_LABEL" ]]; then
      UNPUSHED_LABEL="$uf"
      UNPUSHED_PIPE="$uf"
    else
      UNPUSHED_LABEL="${UNPUSHED_LABEL} + $(basename "$uf")"
      UNPUSHED_PIPE="${UNPUSHED_PIPE}|${uf}"
    fi
    if [[ -f "$uf" ]]; then
      UNPUSHED_BYTES=$(( UNPUSHED_BYTES + $(get_file_size "$uf") ))
    fi
  done < "$UNPUSHED_LIST"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "🔁 [Dry Run] Recovery needed: $AHEAD_COUNT unpushed local commit(s) (${UNPUSHED_FILE_COUNT} file(s), $(human_size "$UNPUSHED_BYTES")):"
    git --no-optional-locks log --oneline origin/main..HEAD | sed 's/^/     /'
    echo "   Would finish pushing to origin/main (concurrenttransfers=$PARALLEL) and force-prune LFS cache first."
  else
    echo ""
    echo "🔁 Resuming interrupted push ($AHEAD_COUNT unpushed commit(s): \"$UNPUSHED_DESC\")..."
    if (( PARALLEL > 1 && UNPUSHED_FILE_COUNT < PARALLEL )); then
      echo "   ℹ️  Finishing ${UNPUSHED_FILE_COUNT} already-committed file first; remaining files will upload ${PARALLEL} at a time."
    fi
    echo "   💡 Tip: Run ./check-sync-progress.sh in another window for live % & ETAs."
    : > "$PROGRESS_FILE"
    write_state "uploading" "${UNPUSHED_LABEL:-$UNPUSHED_DESC}" "$UNPUSHED_BYTES" 0 0 "$(date +%s)" "$UNPUSHED_PIPE" 0
    GIT_LFS_PROGRESS="$PROGRESS_FILE" git -c lfs.concurrenttransfers="$PARALLEL" push origin main
    write_state "pruning" "${UNPUSHED_LABEL:-$UNPUSHED_DESC}" "$UNPUSHED_BYTES" 0 0 "$(date +%s)" "$UNPUSHED_PIPE" 0
    echo "🧹 Verifying remote copy & reclaiming local LFS cache..."
    git lfs prune --force --verify-remote
    : > "$PROGRESS_FILE"
    echo "✅ Resumed push completed and local LFS cache cleared!"
  fi
fi

# Reset any half-staged uncommitted index entries so files queue cleanly
if ! git --no-optional-locks diff --cached --quiet; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "🔧 [Dry Run] Staged uncommitted changes detected — would unstage so files queue cleanly."
  else
    echo "🔧 Unstaging partially staged files from an earlier interrupted run..."
    git reset --quiet HEAD
  fi
fi

# Ensure local .git/lfs/objects starts clean if no unpushed commits remain
AHEAD_NOW="$(git --no-optional-locks rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
if [[ "$DRY_RUN" -eq 0 && "$AHEAD_NOW" -eq 0 && -d "$LFS_DIR/objects" ]]; then
  if [[ -n "$(find "$LFS_DIR/objects" -type f -maxdepth 4 2>/dev/null | head -n 1)" ]]; then
    echo "🧹 Cleaning leftover local LFS cache objects before starting queue..."
    git lfs prune --force --verify-remote
  fi
fi

# Clean any leftover temp partials in .git/lfs/tmp
if [[ "$DRY_RUN" -eq 0 && -d "$LFS_DIR/tmp" ]]; then
  rm -rf "$LFS_DIR/tmp/"* 2>/dev/null || true
fi

# =============================================================================
# SCAN & PARTITION WORKING TREE
# =============================================================================
SMALL_LIST="$TMP_WORK/small_files.zlist"
LARGE_RAW="$TMP_WORK/large_raw.tsv"
LARGE_SORTED="$TMP_WORK/large_sorted.tsv"
ALL_CANDIDATES="$TMP_WORK/candidates.zlist"

: > "$SMALL_LIST"
: > "$LARGE_RAW"
: > "$LARGE_SORTED"

{
  git --no-optional-locks ls-files -z --others --exclude-standard
  git --no-optional-locks diff -z --name-only HEAD
} | sort -zu > "$ALL_CANDIDATES"

SMALL_COUNT=0
SMALL_TOTAL_BYTES=0
LARGE_COUNT=0
LARGE_TOTAL_BYTES=0

while IFS= read -r -d '' filepath; do
  [[ -z "$filepath" ]] && continue
  if [[ ! -e "$filepath" ]]; then
    # Deleted tracked file -> include in small batch
    printf "%s\0" "$filepath" >> "$SMALL_LIST"
    SMALL_COUNT=$(( SMALL_COUNT + 1 ))
    continue
  fi
  if [[ -f "$filepath" || -L "$filepath" ]]; then
    fsize="$(get_file_size "$filepath")"
    if (( fsize < THRESHOLD_BYTES )); then
      printf "%s\0" "$filepath" >> "$SMALL_LIST"
      SMALL_COUNT=$(( SMALL_COUNT + 1 ))
      SMALL_TOTAL_BYTES=$(( SMALL_TOTAL_BYTES + fsize ))
    else
      printf "%s\t%s\n" "$fsize" "$filepath" >> "$LARGE_RAW"
      LARGE_COUNT=$(( LARGE_COUNT + 1 ))
      LARGE_TOTAL_BYTES=$(( LARGE_TOTAL_BYTES + fsize ))
    fi
  fi
done < "$ALL_CANDIDATES"

if (( LARGE_COUNT > 0 )); then
  LC_ALL=C sort -t $'\t' -k1,1n "$LARGE_RAW" > "$LARGE_SORTED"
fi

FREE_BYTES_NOW="$(get_free_bytes)"

echo ""
echo "💾 Drive Free Space:    $(human_size "$FREE_BYTES_NOW")"
echo "⚡ Parallel Streams:    ${PARALLEL} file(s) per batch (HTTP/1.1 enabled)"
echo "📏 Large-File Cutoff:   ${THRESHOLD_MB} MB ($(human_size "$THRESHOLD_BYTES"))"
echo "📦 Phase 1 (Batch):     ${SMALL_COUNT} small/deleted file(s) ($(human_size "$SMALL_TOTAL_BYTES"))"
echo "🎞️  Phase 2 (Queue):     ${LARGE_COUNT} large file(s) ($(human_size "$LARGE_TOTAL_BYTES") total)"

if (( SMALL_COUNT == 0 && LARGE_COUNT == 0 )); then
  echo ""
  echo "✅ Everything is already synced with origin/main! Nothing to upload."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    write_state "completed" "" 0 0 0 "$(date +%s)" "" 0
  fi
  COMPLETED_NORMALLY=1
  exit 0
fi

if (( SMALL_COUNT > 0 )); then
  echo ""
  echo "--- Phase 1: Small Files Batch (all committed & pushed together) ---"
  SHOW_LIMIT=12
  SHOWN=0
  while IFS= read -r -d '' sfile; do
    SHOWN=$(( SHOWN + 1 ))
    if (( SHOWN <= SHOW_LIMIT )); then
      if [[ -e "$sfile" ]]; then
        printf "   • %s (%s)\n" "$sfile" "$(human_size "$(get_file_size "$sfile")")"
      else
        printf "   • %s (deleted)\n" "$sfile"
      fi
    fi
  done < "$SMALL_LIST"
  if (( SMALL_COUNT > SHOW_LIMIT )); then
    echo "   ... and $(( SMALL_COUNT - SHOW_LIMIT )) more small file(s)"
  fi
fi

# Load sorted large files into indexed bash 3.2 arrays
LARGE_SIZES=()
LARGE_FILES=()
MAX_SINGLE_LARGE=0
if (( LARGE_COUNT > 0 )); then
  echo ""
  if (( PARALLEL > 1 )); then
    echo "--- Phase 2: Large Files Queue (smallest -> largest, up to ${PARALLEL} in parallel + LFS prune) ---"
  else
    echo "--- Phase 2: Large Files Queue (smallest -> largest, 1-by-1 + LFS prune) ---"
  fi
  IDX=0
  while IFS=$'\t' read -r lsize lfile; do
    LARGE_SIZES+=("$lsize")
    LARGE_FILES+=("$lfile")
    IDX=$(( IDX + 1 ))
    if (( lsize > MAX_SINGLE_LARGE )); then
      MAX_SINGLE_LARGE="$lsize"
    fi
    printf "   [%d/%d] %10s  %s\n" "$IDX" "$LARGE_COUNT" "$(human_size "$lsize")" "$lfile"
  done < "$LARGE_SORTED"

  REQUIRED_PEAK=$(( MAX_SINGLE_LARGE + SAFETY_BUFFER_BYTES ))
  echo ""
  if (( FREE_BYTES_NOW >= REQUIRED_PEAK )); then
    echo "✅ Cache Space Check:   Largest single file is $(human_size "$MAX_SINGLE_LARGE") (+ 5 GB buffer) — fits within $(human_size "$FREE_BYTES_NOW") free."
    if (( PARALLEL > 1 )); then
      echo "   (Batches of ${PARALLEL} automatically fall back to smaller batches if free space is tight.)"
    fi
  else
    echo "⚠️  Cache Space Warning: Largest file needs $(human_size "$MAX_SINGLE_LARGE") (+ 5 GB buffer), free space is $(human_size "$FREE_BYTES_NOW")."
  fi
fi

echo ""
echo "📊 Companion Progress Monitor (run anytime in a second Terminal window):"
echo "   ./check-sync-progress.sh"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo ""
  echo "✅ Dry run complete. No files were staged, committed, or pushed."
  COMPLETED_NORMALLY=1
  exit 0
fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
  echo ""
  read -r -p "Start syncing now? [Y/n]: " CONFIRM
  case "${CONFIRM:-Y}" in
    [Yy]*|"") ;;
    *)
      echo "Cancelled before starting."
      COMPLETED_NORMALLY=1
      exit 0
      ;;
  esac
fi

ensure_lfs_tracked() {
  local target="$1"
  local attr_out
  attr_out="$(git check-attr filter -- "$target" 2>/dev/null || true)"
  if [[ "$attr_out" == *": filter: lfs" ]]; then
    return 0
  fi

  local base ext
  base="$(basename "$target")"
  if [[ "$base" == *.* ]]; then
    ext="${base##*.}"
    echo "   📌 Extension '.$ext' was not in .gitattributes — registering '*.$ext' with Git LFS..."
    git lfs track "*.$ext" >/dev/null
  else
    echo "   📌 File '$target' has no extension — registering exact path with Git LFS..."
    git lfs track "$target" >/dev/null
  fi
  git add .gitattributes

  attr_out="$(git check-attr filter -- "$target" 2>/dev/null || true)"
  if [[ "$attr_out" != *": filter: lfs" ]]; then
    echo "❌ Error: '$target' is still not matched by Git LFS filter ($attr_out)." >&2
    echo "   Refusing to commit large file into standard Git objects." >&2
    exit 1
  fi
}

# =============================================================================
# EXECUTE PHASE 1: SMALL FILES BATCH
# =============================================================================
if (( SMALL_COUNT > 0 )); then
  echo ""
  echo "========================================================================"
  echo "📦 Phase 1: Staging, committing & pushing ${SMALL_COUNT} small file(s) ($(human_size "$SMALL_TOTAL_BYTES"))"
  echo "========================================================================"
  PHASE1_START="$(date +%s)"
  : > "$PROGRESS_FILE"
  write_state "staging" "Small files batch (${SMALL_COUNT} files)" "$SMALL_TOTAL_BYTES" 0 "$LARGE_COUNT" "$PHASE1_START" "" 0

  GIT_LFS_PROGRESS="$PROGRESS_FILE" xargs -0 git add -- < "$SMALL_LIST"

  if ! git diff --cached --quiet; then
    git commit -m "Sync ${SMALL_COUNT} small project/edit file(s) ($(human_size "$SMALL_TOTAL_BYTES"))"
    : > "$PROGRESS_FILE"
    write_state "uploading" "Small files batch (${SMALL_COUNT} files)" "$SMALL_TOTAL_BYTES" 0 "$LARGE_COUNT" "$(date +%s)" "" 0
    GIT_LFS_PROGRESS="$PROGRESS_FILE" git -c lfs.concurrenttransfers="$PARALLEL" push origin main
    write_state "pruning" "Small files batch (${SMALL_COUNT} files)" "$SMALL_TOTAL_BYTES" 0 "$LARGE_COUNT" "$(date +%s)" "" 0
    git lfs prune --force --verify-remote
    : > "$PROGRESS_FILE"
    PHASE1_ELAPSED=$(( $(date +%s) - PHASE1_START ))
    echo "✅ Phase 1 complete in $(format_duration "$PHASE1_ELAPSED")."
  else
    echo "ℹ️  No effective changes to commit in Phase 1."
  fi
fi

# =============================================================================
# EXECUTE PHASE 2: LARGE FILES (1-BY-1 OR UP TO N IN PARALLEL, SMALLEST FIRST)
# =============================================================================
if (( LARGE_COUNT > 0 )); then
  POS=0
  while (( POS < LARGE_COUNT )); do
    BATCH_START_EPOCH="$(date +%s)"
    FREE_NOW="$(get_free_bytes)"

    FIRST_FILE="${LARGE_FILES[$POS]}"
    FIRST_SIZE="${LARGE_SIZES[$POS]}"
    NEEDED_FIRST=$(( FIRST_SIZE + SAFETY_BUFFER_BYTES ))

    if (( FREE_NOW < NEEDED_FIRST )); then
      echo ""
      echo "❌ Insufficient free disk space on drive to safely cache '$FIRST_FILE' in .git/lfs/objects." >&2
      echo "   Required (file + 5 GB buffer): $(human_size "$NEEDED_FIRST")" >&2
      echo "   Available right now:           $(human_size "$FREE_NOW")" >&2
      exit 1
    fi

    # Build batch up to $PARALLEL files that fit together in FREE_NOW
    BATCH_IDX_START=$(( POS + 1 ))
    BATCH_PATHS=("$FIRST_FILE")
    BATCH_SIZES=("$FIRST_SIZE")
    BATCH_BYTES="$FIRST_SIZE"
    BATCH_LABEL="$FIRST_FILE"
    BATCH_PIPE="$FIRST_FILE"
    BATCH_COMMIT_NAMES="$(basename "$FIRST_FILE")"
    POS=$(( POS + 1 ))

    while (( ${#BATCH_PATHS[@]} < PARALLEL && POS < LARGE_COUNT )); do
      NEXT_FILE="${LARGE_FILES[$POS]}"
      NEXT_SIZE="${LARGE_SIZES[$POS]}"
      if (( BATCH_BYTES + NEXT_SIZE + SAFETY_BUFFER_BYTES <= FREE_NOW )); then
        BATCH_PATHS+=("$NEXT_FILE")
        BATCH_SIZES+=("$NEXT_SIZE")
        BATCH_BYTES=$(( BATCH_BYTES + NEXT_SIZE ))
        BATCH_LABEL="${BATCH_LABEL} + $(basename "$NEXT_FILE")"
        BATCH_PIPE="${BATCH_PIPE}|${NEXT_FILE}"
        BATCH_COMMIT_NAMES="${BATCH_COMMIT_NAMES}, $(basename "$NEXT_FILE")"
        POS=$(( POS + 1 ))
      else
        echo ""
        echo "ℹ️  Drive free space ($(human_size "$FREE_NOW")) fits ${#BATCH_PATHS[@]} file(s) safely this round — throttling batch size."
        break
      fi
    done

    BATCH_IDX_END="$POS"
    BATCH_LEN="${#BATCH_PATHS[@]}"

    echo ""
    echo "========================================================================"
    if (( BATCH_LEN == 1 )); then
      echo "🎬 [File ${BATCH_IDX_START}/${LARGE_COUNT}] $FIRST_FILE"
    else
      echo "🎬 [Files ${BATCH_IDX_START}-${BATCH_IDX_END}/${LARGE_COUNT} (${BATCH_LEN} parallel)] $BATCH_LABEL"
    fi
    echo "   Batch Size: $(human_size "$BATCH_BYTES")  |  Drive Free: $(human_size "$FREE_NOW")  |  Started: $(date '+%H:%M:%S')"
    echo "========================================================================"

    # 1. Ensure Git LFS tracks every file in this batch before staging
    for bf in "${BATCH_PATHS[@]}"; do
      ensure_lfs_tracked "$bf"
    done

    # 2. Stage each file in the batch into .git/lfs/objects
    echo "   [1/4] Staging ${BATCH_LEN} file(s) into Git LFS cache (hashing $(human_size "$BATCH_BYTES"))..."
    STAGE_BASE=0
    for (( bi = 0; bi < BATCH_LEN; bi++ )); do
      bf="${BATCH_PATHS[$bi]}"
      bs="${BATCH_SIZES[$bi]}"
      if (( BATCH_LEN > 1 )); then
        echo "         • Hashing ($(( bi + 1 ))/${BATCH_LEN}): $(basename "$bf") ($(human_size "$bs"))..."
      fi
      : > "$PROGRESS_FILE"
      write_state "staging" "$BATCH_LABEL" "$BATCH_BYTES" "$BATCH_IDX_END" "$LARGE_COUNT" "$(date +%s)" "$BATCH_PIPE" "$STAGE_BASE"
      GIT_LFS_PROGRESS="$PROGRESS_FILE" git add -- "$bf"
      STAGE_BASE=$(( STAGE_BASE + bs ))
    done

    # 3. Commit
    echo "   [2/4] Committing LFS pointer(s)..."
    write_state "committing" "$BATCH_LABEL" "$BATCH_BYTES" "$BATCH_IDX_END" "$LARGE_COUNT" "$(date +%s)" "$BATCH_PIPE" "$BATCH_BYTES"
    if ! git diff --cached --quiet; then
      git commit -m "Add ${BATCH_COMMIT_NAMES} ($(human_size "$BATCH_BYTES"))"
    fi

    # 4. Push (concurrenttransfers=$BATCH_LEN opens parallel HTTP/1.1 streams)
    echo "   [3/4] Uploading to GitStudio LFS Vault (streams=${BATCH_LEN}, live progress below)..."
    : > "$PROGRESS_FILE"
    write_state "uploading" "$BATCH_LABEL" "$BATCH_BYTES" "$BATCH_IDX_END" "$LARGE_COUNT" "$(date +%s)" "$BATCH_PIPE" 0
    GIT_LFS_PROGRESS="$PROGRESS_FILE" git -c lfs.concurrenttransfers="$BATCH_LEN" push origin main

    # 5. Verify remote copy & force-prune local .git/lfs/objects duplicates
    echo "   [4/4] Verifying remote vault copy & pruning local LFS cache..."
    write_state "pruning" "$BATCH_LABEL" "$BATCH_BYTES" "$BATCH_IDX_END" "$LARGE_COUNT" "$(date +%s)" "$BATCH_PIPE" 0
    git lfs prune --force --verify-remote
    : > "$PROGRESS_FILE"

    BATCH_ELAPSED=$(( $(date +%s) - BATCH_START_EPOCH ))
    FREE_AFTER="$(get_free_bytes)"
    echo "   ✅ Finished [${BATCH_IDX_START}-${BATCH_IDX_END}/${LARGE_COUNT}] ${BATCH_COMMIT_NAMES} in $(format_duration "$BATCH_ELAPSED") (Drive free: $(human_size "$FREE_AFTER"))"
  done
fi

write_state "completed" "" 0 "$LARGE_COUNT" "$LARGE_COUNT" "$(date +%s)" "" 0
COMPLETED_NORMALLY=1

echo ""
echo "========================================================================"
echo "🎉 All files are synced to GitHub & GitStudio LFS Vault, and local LFS"
echo "   cache has been verified and pruned! Free space: $(human_size "$(get_free_bytes)")"
echo "========================================================================"

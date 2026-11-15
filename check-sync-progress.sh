#!/usr/bin/env bash
# =============================================================================
# check-sync-progress.sh — Live Upload Progress & ETA Calculator (Window 2)
# Repository: donkeysLiveAtTheHallOct2026
#
# Run this in a second Terminal window while `./sync-large-files.sh` is running
# (or even before/after cancelling to plan upload times).
#
# What it does:
#   1. Asks for your current upload speed in MB/s (e.g. read off the Git LFS
#      upload line in Window 1 or Activity Monitor).
#   2. Reads live byte-level progress of the currently uploading file from
#      `.git/lfs/sync_progress.log` & `.git/lfs/sync_state.env`, showing exact
#      completion (% and GB) and time remaining for the current file.
#   3. Scans all remaining queued large files (sorted smallest -> largest) and
#      shows BOTH individual upload duration AND cumulative completion time
#      (including the remainder of the current file).
#
# 100% read-only & stateless: safe to Ctrl+C and restart anytime.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SPEED_MBPS=""
RUN_ONCE=0
DEFAULT_THRESHOLD_MB=100
CLI_THRESHOLD_MB=""

usage() {
  cat <<'EOF'
Usage: ./check-sync-progress.sh [options]

Options:
  -s, --speed <MB/s>       Upload speed in MB/s (e.g. 12 or 8.5). If omitted,
                           prompts interactively.
  -o, --once               Print report once and exit (no interactive refresh).
  -t, --threshold-mb <MB>  Override large-file cutoff in MB (defaults to active
                           sync-large-files.sh setting, or 100 MB).
  -h, --help               Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--speed)
      if [[ $# -lt 2 ]]; then
        echo "❌ Error: --speed requires a numeric MB/s value." >&2
        exit 1
      fi
      SPEED_MBPS="$2"
      shift 2
      ;;
    -o|--once)
      RUN_ONCE=1
      shift
      ;;
    -t|--threshold-mb)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -le 0 ]]; then
        echo "❌ Error: --threshold-mb requires a positive integer." >&2
        exit 1
      fi
      CLI_THRESHOLD_MB="$2"
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

GIT_DIR="$(git --no-optional-locks rev-parse --git-dir 2>/dev/null || true)"
if [[ -z "$GIT_DIR" ]]; then
  echo "❌ Error: Not inside a Git repository." >&2
  exit 1
fi
GIT_DIR="$(cd "$GIT_DIR" && pwd)"
LFS_DIR="$GIT_DIR/lfs"
STATE_FILE="$LFS_DIR/sync_state.env"
PROGRESS_FILE="$LFS_DIR/sync_progress.log"
PID_FILE="$LFS_DIR/sync.pid"

TMP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/gitstudio-progress.XXXXXX")"
cleanup() {
  rm -rf "$TMP_WORK"
}
trap cleanup EXIT
trap 'echo ""; exit 0' INT TERM

is_valid_speed() {
  awk -v s="$1" 'BEGIN { exit !(s ~ /^[0-9]+(\.[0-9]+)?$/ && (s + 0) > 0) }'
}

get_file_size() {
  local f="$1"
  stat -f%z "$f" 2>/dev/null || stat -c%s "$f"
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
  awk -v total="$1" 'BEGIN {
    s = int(total + 0.5);
    if (s < 0) s = 0;
    d = int(s / 86400);
    h = int((s % 86400) / 3600);
    m = int((s % 3600) / 60);
    sec = s % 60;
    if (d > 0)      printf "%dd %02dh %02dm", d, h, m;
    else if (h > 0) printf "%dh %02dm %02ds", h, m, sec;
    else if (m > 0) printf "%dm %02ds", m, sec;
    else            printf "%ds", sec;
  }'
}

format_eta_clock() {
  local add_sec
  add_sec="$(awk -v s="$1" 'BEGIN { printf "%.0f", (s < 0 ? 0 : s) }')"
  local target_epoch=$(( $(date +%s) + add_sec ))
  date -r "$target_epoch" "+%a %H:%M" 2>/dev/null || date -d "@$target_epoch" "+%a %H:%M" 2>/dev/null || echo "--:--"
}

progress_bar() {
  local done_b="$1"
  local tot_b="$2"
  awk -v d="$done_b" -v t="$tot_b" 'BEGIN {
    width = 24;
    pct = (t > 0) ? (d * 100.0 / t) : 0;
    if (pct < 0) pct = 0;
    if (pct > 100) pct = 100;
    filled = int((pct / 100.0) * width + 0.5);
    printf "[";
    for (i = 1; i <= width; i++) {
      printf (i <= filled ? "#" : "-");
    }
    printf "] %5.1f%%", pct;
  }'
}

read_state_key() {
  local key="$1"
  if [[ -f "$STATE_FILE" ]]; then
    awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$STATE_FILE"
  fi
}

observed_speed_hint() {
  if [[ -f "$PID_FILE" && -f "$STATE_FILE" && -f "$PROGRESS_FILE" ]]; then
    local pid state start_ep
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      state="$(read_state_key "STATE")"
      start_ep="$(read_state_key "PHASE_START_EPOCH")"
      if [[ "$state" == "uploading" && -n "$start_ep" ]]; then
        local last_upload elapsed done_b
        last_upload="$(tail -n 50 "$PROGRESS_FILE" 2>/dev/null | awk '/^upload / {line=$0} END {if (line != "") print line}')"
        elapsed=$(( $(date +%s) - start_ep ))
        if [[ -n "$last_upload" && "$elapsed" -gt 2 ]]; then
          done_b="$(printf "%s\n" "$last_upload" | awk '{split($3, a, "/"); print a[1]}')"
          if [[ -n "$done_b" && "$done_b" -gt 0 ]]; then
            awk -v b="$done_b" -v s="$elapsed" 'BEGIN { printf "%.2f", (b / 1000000.0) / s }'
            return 0
          fi
        fi
      fi
    fi
  fi
  return 1
}

# Prompt for upload speed if not supplied (or invalid)
while [[ -z "$SPEED_MBPS" ]] || ! is_valid_speed "$SPEED_MBPS"; do
  if [[ -n "$SPEED_MBPS" ]]; then
    echo "❌ Invalid speed '$SPEED_MBPS'. Please enter a positive number (e.g. 12 or 8.5)."
    if [[ "$RUN_ONCE" -eq 1 ]]; then
      exit 1
    fi
  fi
  HINT_SPEED="$(observed_speed_hint || true)"
  if [[ -n "$HINT_SPEED" ]]; then
    read -r -p "Enter current upload speed in MB/s [observed avg ~${HINT_SPEED} MB/s]: " INPUT_SPEED
    SPEED_MBPS="${INPUT_SPEED:-$HINT_SPEED}"
  else
    read -r -p "Enter current upload speed in MB/s (e.g. 12 or 8.5): " SPEED_MBPS
  fi
done

render_report() {
  local speed_bps
  speed_bps="$(awk -v s="$SPEED_MBPS" 'BEGIN { printf "%.2f", s * 1000000.0 }')"

  # Determine threshold bytes (CLI flag -> active state file -> 100 MB default)
  local threshold_bytes=$(( DEFAULT_THRESHOLD_MB * 1000000 ))
  if [[ -n "$CLI_THRESHOLD_MB" ]]; then
    threshold_bytes=$(( CLI_THRESHOLD_MB * 1000000 ))
  else
    local st_thresh
    st_thresh="$(read_state_key "THRESHOLD_BYTES")"
    if [[ -n "$st_thresh" && "$st_thresh" =~ ^[0-9]+$ && "$st_thresh" -gt 0 ]]; then
      threshold_bytes="$st_thresh"
    fi
  fi

  # Inspect active sync process state
  local sync_alive=0
  local sync_pid=""
  if [[ -f "$PID_FILE" ]]; then
    sync_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$sync_pid" ]] && kill -0 "$sync_pid" 2>/dev/null; then
      sync_alive=1
    fi
  fi

  local state="" cur_file="" cur_size=0 cur_idx=0 tot_large=0
  if [[ "$sync_alive" -eq 1 && -f "$STATE_FILE" ]]; then
    state="$(read_state_key "STATE")"
    cur_file="$(read_state_key "CURRENT_FILE")"
    cur_size="$(read_state_key "CURRENT_SIZE_BYTES")"
    cur_idx="$(read_state_key "CURRENT_INDEX")"
    tot_large="$(read_state_key "TOTAL_LARGE")"
    [[ -z "$cur_size" ]] && cur_size=0
    [[ -z "$cur_idx" ]] && cur_idx=0
    [[ -z "$tot_large" ]] && tot_large=0
  fi

  local cur_done_bytes=0
  local cur_total_bytes="$cur_size"
  local cur_rem_bytes=0
  local cur_rem_sec=0
  local exclude_working_file=""

  echo ""
  echo "================================================================================"
  echo "📊 GitStudio Upload Progress & ETA Report  ($(date '+%a %d %b %Y %H:%M:%S'))"
  echo "   Assumed Upload Speed: ${SPEED_MBPS} MB/s  (1 MB/s = 1,000,000 B/s, matches Git LFS)"
  echo "================================================================================"

  # ---------------------------------------------------------------------------
  # SECTION 1: CURRENTLY ACTIVE OR RESUMABLE FILE
  # ---------------------------------------------------------------------------
  if [[ "$sync_alive" -eq 1 && -n "$state" && "$state" != "completed" && "$state" != "interrupted" ]]; then
    exclude_working_file="$cur_file"
    local idx_label=""
    if (( cur_idx > 0 && tot_large > 0 )); then
      idx_label=" [File ${cur_idx} of ${tot_large}]"
    fi

    if [[ "$state" == "uploading" ]]; then
      local last_up=""
      if [[ -f "$PROGRESS_FILE" ]]; then
        last_up="$(tail -n 50 "$PROGRESS_FILE" 2>/dev/null | awk '/^upload / {line=$0} END {if (line != "") print line}')"
      fi
      if [[ -n "$last_up" ]]; then
        cur_done_bytes="$(printf "%s\n" "$last_up" | awk '{split($3, a, "/"); printf "%.0f", a[1]}')"
        local parsed_tot
        parsed_tot="$(printf "%s\n" "$last_up" | awk '{split($3, a, "/"); printf "%.0f", a[2]}')"
        if (( parsed_tot > 0 )); then
          cur_total_bytes="$parsed_tot"
        fi
      fi
      cur_rem_bytes=$(( cur_total_bytes > cur_done_bytes ? cur_total_bytes - cur_done_bytes : 0 ))
      cur_rem_sec="$(awk -v r="$cur_rem_bytes" -v sp="$speed_bps" 'BEGIN { printf "%.2f", r / sp }')"

      echo ""
      echo "🟢 CURRENTLY UPLOADING${idx_label}: $cur_file"
      echo "   Progress:   $(progress_bar "$cur_done_bytes" "$cur_total_bytes")"
      echo "   Completed:  $(human_size "$cur_done_bytes") / $(human_size "$cur_total_bytes")  ($(human_size "$cur_rem_bytes") left)"
      echo "   Time Left:  $(format_duration "$cur_rem_sec")  (Est. finish: $(format_eta_clock "$cur_rem_sec"))"

    elif [[ "$state" == "staging" || "$state" == "committing" ]]; then
      local hashed_b=0 hash_tot="$cur_total_bytes" last_clean=""
      if [[ -f "$PROGRESS_FILE" ]]; then
        last_clean="$(tail -n 50 "$PROGRESS_FILE" 2>/dev/null | awk '/^clean / {line=$0} END {if (line != "") print line}')"
      fi
      if [[ -n "$last_clean" ]]; then
        hashed_b="$(printf "%s\n" "$last_clean" | awk '{split($3, a, "/"); printf "%.0f", a[1]}')"
        local parsed_htot
        parsed_htot="$(printf "%s\n" "$last_clean" | awk '{split($3, a, "/"); printf "%.0f", a[2]}')"
        if (( parsed_htot > 0 )); then
          hash_tot="$parsed_htot"
        fi
      fi
      cur_done_bytes=0
      cur_rem_bytes="$cur_total_bytes"
      cur_rem_sec="$(awk -v r="$cur_rem_bytes" -v sp="$speed_bps" 'BEGIN { printf "%.2f", r / sp }')"

      echo ""
      echo "🟡 PREPARING FOR UPLOAD${idx_label}: $cur_file"
      echo "   LFS Cache Staging: $(progress_bar "$hashed_b" "$hash_tot") ($(human_size "$hashed_b") / $(human_size "$hash_tot") hashed)"
      echo "   Upload Complete:   0.00 GB / $(human_size "$cur_total_bytes") (0.0% — upload begins right after staging)"
      echo "   Upload Duration:   $(format_duration "$cur_rem_sec") once upload starts  (Est. finish: $(format_eta_clock "$cur_rem_sec"))"

    elif [[ "$state" == "pruning" ]]; then
      cur_done_bytes="$cur_total_bytes"
      cur_rem_bytes=0
      cur_rem_sec=0
      echo ""
      echo "🧹 VERIFYING & PRUNING CACHE${idx_label}: $cur_file"
      echo "   Progress:   $(progress_bar "$cur_total_bytes" "$cur_total_bytes")"
      echo "   Completed:  $(human_size "$cur_total_bytes") / $(human_size "$cur_total_bytes") — freeing local LFS cache before next file"
    fi

  else
    # Not actively running sync-large-files.sh — check if an unpushed commit is waiting to resume
    local ahead_cnt
    ahead_cnt="$(git --no-optional-locks rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
    if (( ahead_cnt > 0 )); then
      local unpushed_files="$TMP_WORK/unpushed.txt"
      git --no-optional-locks -c core.quotePath=false diff-tree --no-commit-id --name-only -r origin/main HEAD > "$unpushed_files" || true
      local up_bytes=0 up_label=""
      while IFS= read -r uf; do
        [[ -z "$uf" ]] && continue
        up_label="$uf"
        if [[ -f "$uf" ]]; then
          up_bytes=$(( up_bytes + $(get_file_size "$uf") ))
        fi
      done < "$unpushed_files"
      cur_total_bytes="$up_bytes"
      cur_done_bytes=0
      cur_rem_bytes="$up_bytes"
      cur_rem_sec="$(awk -v r="$cur_rem_bytes" -v sp="$speed_bps" 'BEGIN { printf "%.2f", r / sp }')"

      echo ""
      echo "⏸️  PAUSED / UNPUSHED COMMIT READY TO RESUME: ${up_label:-($ahead_cnt commit(s))}"
      echo "   Upload Complete:  0.00 GB / $(human_size "$cur_total_bytes") (0.0% — run ./sync-large-files.sh to resume)"
      echo "   Upload Duration:  $(format_duration "$cur_rem_sec") at ${SPEED_MBPS} MB/s  (Est. finish: $(format_eta_clock "$cur_rem_sec"))"
    else
      echo ""
      echo "⚪ CURRENT UPLOAD: None actively running right now."
      echo "   (Start ./sync-large-files.sh in another window to begin or resume uploading.)"
    fi
  fi

  # ---------------------------------------------------------------------------
  # SECTION 2: REMAINING FILES QUEUE (INDIVIDUAL & CUMULATIVE ETAS)
  # ---------------------------------------------------------------------------
  local cand_file="$TMP_WORK/candidates.zlist"
  local rem_raw="$TMP_WORK/rem_raw.tsv"
  local rem_sorted="$TMP_WORK/rem_sorted.tsv"
  : > "$rem_raw"
  : > "$rem_sorted"

  {
    git --no-optional-locks ls-files -z --others --exclude-standard
    git --no-optional-locks diff -z --name-only HEAD
  } | sort -zu > "$cand_file"

  local small_rem_count=0
  local small_rem_bytes=0
  local large_rem_count=0
  local large_rem_bytes=0

  while IFS= read -r -d '' filepath; do
    [[ -z "$filepath" ]] && continue
    # Do not double-count the file already displayed in Section 1
    if [[ -n "$exclude_working_file" && "$filepath" == "$exclude_working_file" ]]; then
      continue
    fi
    if [[ ! -e "$filepath" ]]; then
      small_rem_count=$(( small_rem_count + 1 ))
      continue
    fi
    if [[ -f "$filepath" || -L "$filepath" ]]; then
      local fsize
      fsize="$(get_file_size "$filepath")"
      if (( fsize < threshold_bytes )); then
        small_rem_count=$(( small_rem_count + 1 ))
        small_rem_bytes=$(( small_rem_bytes + fsize ))
      else
        printf "%s\t%s\n" "$fsize" "$filepath" >> "$rem_raw"
        large_rem_count=$(( large_rem_count + 1 ))
        large_rem_bytes=$(( large_rem_bytes + fsize ))
      fi
    fi
  done < "$cand_file"

  if (( large_rem_count > 0 )); then
    LC_ALL=C sort -t $'\t' -k1,1n "$rem_raw" > "$rem_sorted"
  fi

  local cum_sec="$cur_rem_sec"
  if (( small_rem_bytes > 0 )); then
    cum_sec="$(awk -v c="$cum_sec" -v b="$small_rem_bytes" -v sp="$speed_bps" 'BEGIN { printf "%.2f", c + (b / sp) }')"
  fi

  if (( small_rem_count > 0 )); then
    local small_sec
    small_sec="$(awk -v b="$small_rem_bytes" -v sp="$speed_bps" 'BEGIN { printf "%.2f", b / sp }')"
    echo ""
    echo "📦 Pending Small-Files Batch: ${small_rem_count} file(s) ($(human_size "$small_rem_bytes")) — ~$(format_duration "$small_sec")"
  fi

  echo ""
  if (( large_rem_count == 0 )); then
    echo "🎞️  Remaining Large Files Queue: None (0 files waiting after current step)."
  else
    echo "🎞️  REMAINING LARGE FILES (${large_rem_count} file(s), smallest -> largest):"
    echo "--------------------------------------------------------------------------------"
    printf "  %-4s  %10s  %15s  %15s  %-10s  %s\n" "#" "Size" "Individual ETA" "Cumulative ETA" "Est. Done" "File"
    echo "--------------------------------------------------------------------------------"

    local qidx=0
    while IFS=$'\t' read -r rsize rfile; do
      qidx=$(( qidx + 1 ))
      local indiv_sec
      indiv_sec="$(awk -v b="$rsize" -v sp="$speed_bps" 'BEGIN { printf "%.2f", b / sp }')"
      cum_sec="$(awk -v c="$cum_sec" -v i="$indiv_sec" 'BEGIN { printf "%.2f", c + i }')"
      printf "  %-4s  %10s  %15s  %15s  %-10s  %s\n" \
        "$qidx" \
        "$(human_size "$rsize")" \
        "$(format_duration "$indiv_sec")" \
        "$(format_duration "$cum_sec")" \
        "$(format_eta_clock "$cum_sec")" \
        "$rfile"
    done < "$rem_sorted"
    echo "--------------------------------------------------------------------------------"
  fi

  local grand_rem_bytes=$(( cur_rem_bytes + small_rem_bytes + large_rem_bytes ))
  echo ""
  echo "🏁 TOTAL REMAINING DATA: $(human_size "$grand_rem_bytes")"
  echo "⏱️  TOTAL TIME REMAINING: $(format_duration "$cum_sec") at ${SPEED_MBPS} MB/s  (All done: $(format_eta_clock "$cum_sec"))"
  echo "   💾 Current Drive Free Space: $(human_size "$(df -Pk . | awk 'NR==2 {printf "%.0f\n", $4 * 1024}')")"
  echo "================================================================================"
}

while true; do
  render_report

  if [[ "$RUN_ONCE" -eq 1 ]]; then
    break
  fi

  echo ""
  read -r -p "[Enter] Refresh at ${SPEED_MBPS} MB/s  |  Type new MB/s speed  |  [q] Quit: " NEXT_ACTION
  case "$NEXT_ACTION" in
    "")
      continue
      ;;
    [Qq]|[Qq][Uu][Ii][Tt]|[Ee][Xx][Ii][Tt])
      break
      ;;
    *)
      if is_valid_speed "$NEXT_ACTION"; then
        SPEED_MBPS="$NEXT_ACTION"
      else
        echo "⚠️  Unrecognized input '$NEXT_ACTION' — keeping speed at ${SPEED_MBPS} MB/s."
      fi
      ;;
  esac
done

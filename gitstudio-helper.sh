#!/usr/bin/env bash
# =============================================================================
# GitStudio Local Workspace Helper — donkeysLiveAtTheHallOct2026
# Repository: https://github.com/gitstudiorepos/donkeysliveatthehalloct2026
# =============================================================================
set -e

echo "========================================================"
echo "🎬 GitStudio Workspace Helper: donkeysLiveAtTheHallOct2026"
echo "========================================================"

# Ensure Git LFS is initialized
git lfs install >/dev/null 2>&1 || {
  echo "❌ Error: git-lfs is not installed. Install via: brew install git-lfs"
  exit 1
}

CURRENT_LFS_URL=$(git config --local lfs.url || true)
if [[ -z "$CURRENT_LFS_URL" || "$CURRENT_LFS_URL" != *"key="* ]]; then
  echo ""
  echo "🔑 Your local Git LFS key is not configured yet."
  read -r -p "Paste your GitStudio Key (gs_... or gs_collab_...): " USER_KEY
  if [[ -n "$USER_KEY" ]]; then
    git config lfs.url "https://gitstudio.web.app/api/lfs/batch?key=$USER_KEY"
    echo "✅ Saved key locally in .git/config (never committed to GitHub)."
  fi
fi

echo ""
echo "Choose an action:"
echo "  1) 📊 Check Status (see modified or new audio/video files)"
echo "  2) ⬇️  Pull Latest Changes & Media (git pull + git lfs pull)"
echo "  3) ⬆️  Add, Commit & Push New Media to GitStudio Vault"
echo "  4) 📂 Open Project Folder in Finder"
echo "  5) Exit"
echo ""
read -r -p "Select [1-5]: " CHOICE

case "$CHOICE" in
  1)
    git status
    echo ""
    git lfs status
    ;;
  2)
    git pull origin main
    git lfs pull
    echo "✅ Workspace is up to date!"
    ;;
  3)
    git status --short
    echo ""
    read -r -p "Enter a short note describing this update (e.g. 'Add Logic Pro raw audio stems'): " MSG
    MSG=${MSG:-"Update production media"}
    git add .
    git commit -m "$MSG"
    git push origin main
    echo "✅ Pushed to GitHub & GitStudio LFS Vault!"
    ;;
  4)
    open .
    ;;
  *)
    exit 0
    ;;
esac


#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================
# QUANTAI - GITHUB DEPLOYMENT
# ==========================================

GITHUB_USER="baileyizbad"
REPO_NAME="QuantAI-FastAPI-Android"
BRANCH="LocalHost"
REMOTE_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"

PROJECT_DIR="$(pwd)"

echo "=========================================="
echo "       QUANTAI GITHUB UPLOADER"
echo "=========================================="

# Check dependencies
for cmd in git gh; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing dependency: $cmd"
        echo "Install with: apt install git gh"
        exit 1
    fi
done

# Verify GitHub authentication
if ! gh auth status >/dev/null 2>&1; then
    echo "GitHub authentication required."
    gh auth login
fi

# Verify project
if [[ ! -f "$PROJECT_DIR/README.md" ]]; then
    echo "ERROR: README.md not found."
    echo "Run this script from your QuantAI project directory."
    exit 1
fi

# Protect secrets and generated files
cat >> .gitignore <<'EOF'

# Python
__pycache__/
*.py[cod]
.venv/
venv/
.pytest_cache/
.coverage

# Secrets
.env
.env.*
!.env.example
*.pem
*.key

# Android / Flutter
.dart_tool/
.flutter-plugins
.flutter-plugins-dependencies
build/
.gradle/
local.properties

# IDE
.idea/
.vscode/

# OS
.DS_Store
Thumbs.db
EOF

# Initialize Git if necessary
if [[ ! -d ".git" ]]; then
    git init
fi

git config user.name "QuantAI Developer"

# Set GitHub remote
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_URL"
else
    git remote add origin "$REMOTE_URL"
fi

echo "[1/5] Checking repository..."

git fetch origin

# Switch to existing branch or create new branch
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        git switch "$BRANCH"
    else
        git switch -c "$BRANCH" --track "origin/$BRANCH"
    fi
else
    git switch -C "$BRANCH"
fi

echo "[2/5] Adding project files..."

git add -A

# Check for staged changes
if ! git diff --cached --quiet; then
    echo "[3/5] Creating commit..."
    git commit -m "QuantAI: Update FastAPI LocalHost Android release"
else
    echo "[3/5] No new changes to commit."
fi

echo "[4/5] Uploading to GitHub..."

git push -u origin "$BRANCH"

echo "[5/5] Verifying upload..."

git fetch origin

LOCAL_COMMIT="$(git rev-parse HEAD)"
REMOTE_COMMIT="$(git rev-parse "origin/$BRANCH")"

if [[ "$LOCAL_COMMIT" != "$REMOTE_COMMIT" ]]; then
    echo "ERROR: Remote verification failed."
    exit 1
fi

echo
echo "=========================================="
echo "       UPLOAD SUCCESSFUL"
echo "=========================================="
echo "Repository:"
echo "https://github.com/$GITHUB_USER/$REPO_NAME"
echo
echo "Branch:"
echo "$BRANCH"
echo
echo "Commit:"
git log -1 --oneline
echo
echo "Branch URL:"
echo "https://github.com/$GITHUB_USER/$REPO_NAME/tree/$BRANCH"
echo "=========================================="


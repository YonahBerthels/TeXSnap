#!/bin/bash
# Installs TeXSnap's offline model into ~/Library/Application Support/TeXSnap/LocalModel.
#
#   scripts/install-model.sh                   download the model from the GitHub release
#   scripts/install-model.sh path/to/texsnap-model-v1.zip
#
# Needs an Apple Silicon Mac and uv (https://docs.astral.sh/uv/). Then choose
# Settings > Engine > "On this Mac (offline)" in TeXSnap.
set -euo pipefail

REPO="${TEXSNAP_REPO:-YonahBerthels/TeXSnap}"
TAG="model-v1"
ASSET="texsnap-model-v1.zip"
SHA256="44fdc084d2c98425f1efd1c979ae4ea5a2d86ba4e07e47242ba7e0db9e6c0fb2"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Library/Application Support/TeXSnap/LocalModel"
STAGING="$DEST.staging"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ "$(uname -m)" != "arm64" ]; then
  echo "The offline model needs an Apple Silicon Mac (it runs on MLX)." >&2
  exit 1
fi
if ! command -v uv >/dev/null; then
  echo "uv is needed to set up the model's Python. Install it with:" >&2
  echo "  curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

# 1. Get the model.
if [ $# -ge 1 ]; then
  ZIP="$1"
else
  ZIP="$WORK/$ASSET"
  echo "Downloading the model (about 1 GB)…"
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh release download "$TAG" --repo "$REPO" --pattern "$ASSET" --dir "$WORK"
  else
    curl -fL --progress-bar -o "$ZIP" "https://github.com/$REPO/releases/download/$TAG/$ASSET"
  fi
fi
echo "Checking the download…"
if [ "$(shasum -a 256 "$ZIP" | awk '{print $1}')" != "$SHA256" ]; then
  echo "The model file does not match the expected checksum; download it again." >&2
  exit 1
fi

# 2. Unpack it with the server and a Python environment of its own.
rm -rf "$STAGING"
mkdir -p "$STAGING"
unzip -q "$ZIP" -d "$WORK"
mv "$WORK/texsnap-model-v1" "$STAGING/model"
cp "$ROOT/ml/serve.py" "$STAGING/serve.py"
echo "Setting up Python (about 600 MB)…"
uv venv --quiet --relocatable --python 3.12 "$STAGING/venv"
uv pip install --quiet --python "$STAGING/venv/bin/python" -r "$ROOT/ml/requirements-serve.txt"

# 3. Check that it works before replacing an existing install.
echo "Testing…"
REPLY_LINE="$(printf '{"id":1,"image":"%s","prompt":"Transcribe this image into LaTeX.","max_tokens":200}\n' \
  "$ROOT/Tests/fixtures/quadratic.png" |
  HF_HUB_OFFLINE=1 "$STAGING/venv/bin/python" "$STAGING/serve.py" "$STAGING/model" 2>/dev/null | grep '"done"' || true)"
if [ -z "$REPLY_LINE" ]; then
  echo "The model did not run. Rerun with the server's output:" >&2
  echo "  \"$STAGING/venv/bin/python\" \"$STAGING/serve.py\" \"$STAGING/model\"" >&2
  exit 1
fi

cat > "$STAGING/runtime.json" <<EOF
{
  "python": "$DEST/venv/bin/python",
  "server": "$DEST/serve.py",
  "model": "$DEST/model",
  "name": "TeXSnap local model v1"
}
EOF
rm -rf "$DEST"
mv "$STAGING" "$DEST"  # the venv is relocatable, so it keeps working after the move

echo "Installed the offline model to $DEST."
echo "In TeXSnap, open Settings and choose Engine > On this Mac (offline)."

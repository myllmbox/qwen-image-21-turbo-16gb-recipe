#!/usr/bin/env bash
# Qwen-Image-2.1-Turbo (hibrid NVFP4/BF16) on ONE RTX 50-series GPU with 16 GB: download if needed, check free GPU memory,
# serve, wait healthy, render one test image. Everything is configured in recipe.yaml. OpenAI Images API on :$PORT.
# ./stop.sh stops, ./view.sh shows the live log.
set -euo pipefail
cd "$(dirname "$0")"
command -v docker >/dev/null || { echo "docker is required"; exit 1; }
command -v nvidia-smi >/dev/null || { echo "nvidia-smi not found — install the NVIDIA driver (590 or newer) first"; exit 1; }

# --- tiny recipe.yaml reader (two-level: section -> key: value; strips quotes/comments) ---------
rkey() {  # rkey <section> <key>
  awk -v s="$1" -v k="$2" '
    /^[A-Za-z_]/ { sec=$1; sub(":$","",sec) }
    sec==s && $1==k":" {
      sub(/^[ ]*[^:]*:[ ]*/,""); sub(/[ ]+#.*$/,"")
      gsub(/^["\x27]|["\x27]$/,""); print; exit
    }' recipe.yaml
}
rsection() {  # all key/value lines of a section, "key<TAB>value" (quotes/comments stripped)
  awk -v s="$1" '
    /^[A-Za-z_]/ { sec=$1; sub(":$","",sec); next }
    sec==s && /^[ ]+[A-Za-z0-9_-]+:[ ]/ {
      line=$0; sub(/^[ ]+/,"",line)
      key=line; sub(/:.*/,"",key)
      val=line; sub(/^[^:]*:[ ]*/,"",val); sub(/[ ]+#.*$/,"",val)
      gsub(/^["\x27]|["\x27]$/,"",val)
      if (key != "") print key "\t" val
    }' recipe.yaml
}

IMAGE="$(rkey server image)";       PORT="$(rkey server port)"
HF_REPO="$(rkey server model)"
MODELS_DIR="$(rkey server models_dir)"; CACHE_DIR="$(rkey server cache_dir)"
NEED_MIB="$(rkey server min_free_vram_mib)"
NAME="qwen-image-21-turbo"
mkdir -p "$MODELS_DIR" "$CACHE_DIR"
MODELS_ABS="$(cd "$MODELS_DIR" && pwd)"; CACHE_ABS="$(cd "$CACHE_DIR" && pwd)"
LOCAL_NAME="$(basename "$HF_REPO")"
MODEL_DIR="$MODELS_ABS/$LOCAL_NAME"

# --- GPU: NVFP4 runs only on Blackwell (RTX 50-series, compute capability 12.x) ----------------------------------------
CAP="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')"
GPU="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
case "$CAP" in
  12.*|10.*) ;;
  "") echo "✗ no NVIDIA GPU visible (nvidia-smi found none)"; exit 1 ;;
  *) echo "✗ $GPU (compute capability $CAP): these weights are NVFP4 and need a Blackwell GPU (RTX 50-series)"; exit 1 ;;
esac

# --- Hugging Face access ----------------------------------------------------------------------------------------------
# Anonymous downloads are rate-limited. Token order: $HF_TOKEN → ~/.cache/huggingface/token (from `hf auth login`) → ask,
# when interactive. Nothing is stored by this script; `hf auth login` is how a token is kept.
hf_access() {  # hf_access <hf-repo>   — exports HF_TOKEN when one is found or entered; returns 1 when the download cannot work
  local repo="$1" meta who
  if [ -z "${HF_TOKEN:-}" ] && [ -s "$HOME/.cache/huggingface/token" ]; then
    HF_TOKEN="$(tr -d '\n' < "$HOME/.cache/huggingface/token")"; export HF_TOKEN
  fi
  meta="$(curl -s --max-time 15 "https://huggingface.co/api/models/$repo" || true)"
  case "$meta" in
    "") echo "  (huggingface.co not reachable — skipping the access check)"; return 0 ;;
    *'"id"'*) ;;
    *) echo "✗ $repo: not found on Hugging Face"; return 1 ;;
  esac
  if [ -z "${HF_TOKEN:-}" ]; then
    echo "· no Hugging Face token (HF_TOKEN unset, no hf auth login) — anonymous downloads are rate-limited; a free READ token"
    echo "  from https://huggingface.co/settings/tokens is faster:  export HF_TOKEN=hf_...   or   hf auth login"
    if [ -t 0 ]; then
      read -rsp "  paste a token to use it now, or Enter to continue anonymously: " HF_TOKEN; echo
      if [ -n "$HF_TOKEN" ]; then export HF_TOKEN; else unset HF_TOKEN; fi
    fi
    [ -n "${HF_TOKEN:-}" ] || return 0
  fi
  who="$(curl -s --max-time 15 -H "Authorization: Bearer $HF_TOKEN" https://huggingface.co/api/whoami-v2 | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$who" ] || { echo "✗ the Hugging Face token is not valid (whoami failed) — check HF_TOKEN / hf auth login"; return 1; }
  echo "· Hugging Face: $who"
}

# --- weights: ~14.5G, resumable (rerun on interruption) ---------------------------------------------------------------
if [ ! -f "$MODEL_DIR/transformer/diffusion_pytorch_model.safetensors.index.json" ] || \
   [ -n "$(find "$MODEL_DIR/.cache" -name '*.incomplete' -print -quit 2>/dev/null)" ]; then
  hf_access "$HF_REPO" || exit 1
  echo "· downloading $HF_REPO -> $MODEL_DIR"
  if command -v hf >/dev/null; then
    hf download "$HF_REPO" --local-dir "$MODEL_DIR"
  else
    TTY=""; [ -t 1 ] && TTY="-t"
    # the container runs as root — hand the files back to the host user afterwards
    docker run --rm $TTY -e HF_TOKEN -e HF_HUB_OFFLINE=0 -v "$MODELS_ABS:/dl" --entrypoint python3 "$IMAGE" \
      -c "from huggingface_hub import snapshot_download; import subprocess; snapshot_download('$HF_REPO', local_dir='/dl/$LOCAL_NAME'); subprocess.run(['chown', '-R', '$(id -u):$(id -g)', '/dl/$LOCAL_NAME'], check=False)"
  fi
fi

# --- docker env straight from the recipe ------------------------------------------------------------------------------
ENVS=()
while IFS=$'\t' read -r k v; do [ -n "$k" ] && ENVS+=(-e "$k=$v"); done < <(rsection env)

docker rm -f "$NAME" >/dev/null 2>&1 || true

# --- free GPU memory gate: the serve peaks at ~14.4 GB of a 16 GB card. A just-stopped serve frees its memory within
# seconds — wait for it.
t=0; while :; do
  free_mib="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')"
  [ "${free_mib:-0}" -ge "${NEED_MIB:-15000}" ] && { echo "  ✓ GPU: $GPU, ${free_mib} MiB free"; break; }
  if [ "$t" -ge 30 ]; then
    echo "  ✗ $GPU has ${free_mib} MiB free, the serve needs ${NEED_MIB} MiB. Something else uses the GPU (nvidia-smi shows what) —"
    echo "    a desktop on this card, a browser, another model. Free it first."
    exit 1
  fi
  [ "$t" = 0 ] && echo "  · waiting for GPU memory (${free_mib} MiB free, need ${NEED_MIB})…"
  sleep 5; t=$((t+5))
done

echo "· starting $NAME  ($IMAGE)  on :$PORT — healthy in ~30 s"
docker run -d --name "$NAME" --gpus all --ipc=host \
  -p "$PORT:8000" \
  -v "$(readlink -f "$MODEL_DIR"):/models/$LOCAL_NAME:ro" -v "$CACHE_ABS:/cache" \
  -e MODEL_PATH="/models/$LOCAL_NAME" -e HF_HUB_OFFLINE=1 -e TRANSFORMERS_OFFLINE=1 \
  -e TRITON_CACHE_DIR=/cache/triton -e TORCHINDUCTOR_CACHE_DIR=/cache/inductor \
  "${ENVS[@]}" \
  "$IMAGE" >/dev/null

echo "· streaming the server log until healthy (Ctrl-C detaches; the container keeps booting)"
docker logs -f "$NAME" 2>&1 &
LOGS=$!
trap 'kill "$LOGS" 2>/dev/null || true' EXIT INT TERM
for i in $(seq 1 120); do
  if curl -sf -m 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    kill "$LOGS" 2>/dev/null || true; wait "$LOGS" 2>/dev/null || true
    # the container runs as root — hand ./cache back to the host user
    docker exec "$NAME" chown -R "$(id -u):$(id -g)" /cache >/dev/null 2>&1 || true
    # warm-up + self-check: one 1024² image → ./smoke.png
    python3 - "$PORT" <<'PY' || echo "· warm-up skipped"
import base64, json, sys, time, urllib.request
port = sys.argv[1]
body = {"prompt": "A red apple on a rustic wooden table, soft window light, photorealistic.", "size": "1024x1024", "seed": 1}
t0 = time.time()
req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/images/generations", data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json"})
d = json.loads(urllib.request.urlopen(req, timeout=600).read())
if "data" in d:
    open("smoke.png", "wb").write(base64.b64decode(d["data"][0]["b64_json"]))
    print(f"✓ warm-up: 1024×1024 image in {time.time() - t0:.1f} s → ./smoke.png (the first one also reads the weights from disk)")
else:
    print(f"⚠ warm-up failed: {d.get('error')}")
PY
    echo
    echo "──────────────────────────────────────────────────────────"
    echo "✓ server booted — OpenAI Images API is live"
    echo "    generate : POST http://127.0.0.1:$PORT/v1/images/generations"
    echo "    edit     : POST http://127.0.0.1:$PORT/v1/images/edits"
    echo "    monitor  : ./view.sh"
    echo "    stop     : ./stop.sh"
    echo "──────────────────────────────────────────────────────────"
    exit 0
  fi
  if ! docker ps -q --filter "name=$NAME" | grep -q .; then
    kill "$LOGS" 2>/dev/null || true; wait "$LOGS" 2>/dev/null || true
    echo "✗ container exited — see above"; exit 1
  fi
  sleep 5
done
echo "✗ not healthy after 10 min — still booting? watch: docker logs -f $NAME"; exit 1

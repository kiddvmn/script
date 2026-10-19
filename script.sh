#!/usr/bin/env bash
# Krea2 Complete - Vast.ai ComfyUI provisioning script
# Source: exported ai-launcher-config-krea2-complete.json
# Installs 13 model files and 7 custom node repositories; does NOT install ComfyUI.
# Credentials: define HF_TOKEN and CIVITAI_TOKEN in the Vast.ai template environment.
set -Eeuo pipefail
set +x  # Never print access tokens when a caller enables shell tracing.

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
MODEL_DIR="$COMFYUI_DIR/models"
NODES_DIR="$COMFYUI_DIR/custom_nodes"
HF_TOKEN="${HF_TOKEN:-${HUGGINGFACE_TOKEN:-}}"
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
PYTHON_BIN="${PYTHON_BIN:-/venv/main/bin/python}"

log()  { printf '[Krea2] %s\n' "$*"; }
warn() { printf '[Krea2] WARNING: %s\n' "$*" >&2; }

if [[ ! -x "$PYTHON_BIN" ]]; then
    PYTHON_BIN="$(command -v python3 || true)"
fi
for cmd in curl git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        warn "Missing dependency: $cmd"
        exit 1
    fi
done
if [[ -z "$PYTHON_BIN" || ! -x "$PYTHON_BIN" ]]; then
    warn "Python interpreter not found; set PYTHON_BIN."
    exit 1
fi
if [[ ! -f "$COMFYUI_DIR/main.py" ]]; then
    warn "ComfyUI not found at $COMFYUI_DIR (missing main.py)."
    warn "Use the official Vast.ai ComfyUI image or set COMFYUI_DIR."
    exit 1
fi
mkdir -p "$MODEL_DIR" "$NODES_DIR"

# Reject empty, HTML error pages and invalid safetensors files.
# Inspect only file metadata/header, never load the model into memory.
valid_model() {
    "$PYTHON_BIN" - "$1" <<'PYVALID'
import os, struct, sys
p = sys.argv[1]
try:
    if os.path.getsize(p) < 65536:
        sys.exit(1)
    with open(p, 'rb') as f:
        first = f.read(8)
        if p.endswith('.safetensors') or p.endswith('.safetensors.part'):
            n = struct.unpack('<Q', first)[0]
            if not 2 <= n <= 100_000_000 or f.read(1) != b'{':
                sys.exit(1)
        elif first.lstrip().lower().startswith((b'<html', b'<!doct', b'<?xml')):
            sys.exit(1)
except (OSError, ValueError, struct.error):
    sys.exit(1)
PYVALID
}

# Returns success for an already-existing valid file or a new successful download.
# Downloads to .part and atomically renames, so interrupted downloads are recoverable.
download_model() {
    local provider="$1" category="$2" filename="$3" url="$4"
    local directory="$MODEL_DIR/$category" target="$MODEL_DIR/$category/$filename"
    local tmp="${target}.part" code=0
    local -a auth=()
    mkdir -p "$directory"

    if [[ -e "$target" ]]; then
        if valid_model "$target"; then
            log "SKIP (exists): $category/$filename"
            ((model_skipped+=1))
            return 0
        fi
        warn "Existing file is incomplete or invalid, re-downloading: $target"
        rm -f -- "$target"
    fi

    case "$provider" in
        huggingface)
            [[ -z "$HF_TOKEN" ]] || auth=(-H "Authorization: Bearer $HF_TOKEN")
            ;;
        civitai)
            [[ -z "$CIVITAI_TOKEN" ]] || auth=(-H "Authorization: Bearer $CIVITAI_TOKEN")
            ;;
        *) warn "Unknown provider: $provider"; return 1 ;;
    esac

    log "DOWNLOAD: $category/$filename"
    # Curl follows HF/Civitai CDN redirects and resumes partial files where supported.
    curl --fail --location --retry 4 --retry-delay 4 \
         --connect-timeout 30 --speed-time 120 --speed-limit 1024 \
         --continue-at - --output "$tmp" "${auth[@]}" "$url" || code=$?

    if ((code == 33)); then
        # HTTP server did not accept a Range request: retry the full file.
        warn "Range resume not available; starting from zero: $filename"
        rm -f -- "$tmp"
        code=0
        curl --fail --location --retry 4 --retry-delay 4 \
             --connect-timeout 30 --speed-time 120 --speed-limit 1024 \
             --output "$tmp" "${auth[@]}" "$url" || code=$?
    fi
    if ((code != 0)); then
        warn "Download failed (curl code $code): $category/$filename"
        warn "Partial download (if present) kept at $tmp"
        return 1
    fi
    if ! valid_model "$tmp"; then
        warn "Downloaded file failed validation: $category/$filename"
        warn "Check authentication/access and storage space."
        rm -f -- "$tmp"
        return 1
    fi
    mv -f -- "$tmp" "$target"
    log "OK: $category/$filename"
    ((model_downloaded+=1))
}

# Runs dependency installation in the ComfyUI Python environment.
install_requirements() {
    local requirements="$1"
    if command -v uv >/dev/null 2>&1; then
        uv pip install --python "$PYTHON_BIN" --no-cache -r "$requirements"
    else
        "$PYTHON_BIN" -m pip install --no-cache-dir -r "$requirements"
    fi
}

install_node() {
    local name="$1" url="$2" dir="$NODES_DIR/$1"
    log "NODE: $name"
    if [[ -d "$dir" ]]; then
        if [[ ! -d "$dir/.git" && ! -f "$dir/__init__.py" ]]; then
            warn "Node directory exists but looks incomplete: $dir"
            return 1
        fi
        log "SKIP clone (already exists): $name"
    else
        if ! git clone --depth 1 "$url" "$dir"; then
            warn "Clone failed: $url"
            return 1
        fi
    fi
    if [[ -f "$dir/requirements.txt" ]]; then
        log "Installing Python requirements for $name"
        if ! install_requirements "$dir/requirements.txt"; then
            warn "Requirements failed for $name"
            return 1
        fi
    fi
    if [[ "$name" == 'ComfyUI-Impact-Pack' && -f "$dir/install.py" ]]; then
        # Impact Pack would otherwise download an extra SAM model not in this config.
        touch "$NODES_DIR/skip_download_model"
        log "Running Impact Pack installer (without extra SAM download)"
        if ! (cd "$dir" && COMFYUI_PATH="$COMFYUI_DIR" COMFYUI_MODEL_PATH="$MODEL_DIR" "$PYTHON_BIN" install.py); then
            warn "Impact Pack installer failed"
            return 1
        fi
    fi
    ((nodes_ok+=1))
}

model_skipped=0
model_downloaded=0
model_failed=0
nodes_ok=0
nodes_failed=0

log "Starting provisioning in $COMFYUI_DIR"
log "HF token: $( [[ -n "$HF_TOKEN" ]] && printf 'provided' || printf 'not set' ); Civitai token: $( [[ -n "$CIVITAI_TOKEN" ]] && printf 'provided' || printf 'not set' )"

# All 7 custom nodes from the JSON export (including those marked selected:false).
while IFS='|' read -r name url; do
    [[ -n "$name" ]] || continue
    if ! install_node "$name" "$url"; then
        ((nodes_failed+=1))
    fi
done <<'NODES_LIST'
ComfyUI-krea2-negpip|https://github.com/blue-pen5805/ComfyUI-krea2-negpip
ComfyUI-PromptRandomChoice|https://github.com/ruminar/ComfyUI-PromptRandomChoice
ComfyUI-Image-Saver|https://github.com/alexopus/ComfyUI-Image-Saver
Vantage-Nodes|https://github.com/vantagewithai/Vantage-Nodes
ComfyUI-Impact-Pack|https://github.com/ltdrdata/ComfyUI-Impact-Pack
ComfyUI-Detail-Daemon|https://github.com/Jonseed/ComfyUI-Detail-Daemon
ComfyUI-Krea2-Ostris-Edit|https://github.com/ostris/ComfyUI-Krea2-Ostris-Edit
ComfyUI-Krea2Edit|https://github.com/lbouaraba/comfyui-krea2edit
ComfyUI-Krea2-Control|https://github.com/facok/comfyui-krea2-controlnet
KJNodes-for-ComfyUI|https://github.com/kijai/ComfyUI-KJNodes
NODES_LIST

# Exactly 13 model URLs/filenames from the JSON export.
while IFS='|' read -r provider category filename url; do
    [[ -n "$filename" ]] || continue
    if ! download_model "$provider" "$category" "$filename" "$url"; then
        ((model_failed+=1))
    fi
done <<'MODELS_LIST'
civitai|diffusion_models|snofs__sex__nudes__and_other_fun_stuff__merged_krea_2_turbo_v1_4.safetensors|https://civitai.com/api/download/models/3333138
huggingface|text_encoders|qwen3vl_4b_fp8_scaled.safetensors|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors
huggingface|vae|qwen_image_vae.safetensors|https://huggingface.co/Comfy-Org/Krea-2/resolve/main/vae/qwen_image_vae.safetensors
civitai|loras|krea2-realism-v1___v2_krea2-realism-v2.safetensors|https://civitai.com/api/download/models/3090634
civitai|loras|bfs_-_best_face_swap_krea_2_body_swap_exp__v1.safetensors|https://civitai.com/api/download/models/3188610
civitai|loras|bfs_-_best_face_swap_krea_2_-_v1_experimental.safetensors|https://civitai.com/api/download/models/3181157
huggingface|loras|kirsten_vh_krea2.safetensors|https://huggingface.co/kiddvmn/kirsten_vh_krea2/resolve/main/kirsten_vh_krea2.safetensors
huggingface|loras|claw97style.safetensors|https://huggingface.co/kiddvmn/claw97style/resolve/main/claw97style.safetensors
huggingface|loras|claw97style_000002000.safetensors|https://huggingface.co/kiddvmn/claw97style/resolve/main/claw97style_000002000.safetensors
huggingface|upscale_models|x1_ITF_SkinDiffDetail_Lite_v1.pth|https://huggingface.co/gemasai/x1_ITF_SkinDiffDetail_Lite_v1/resolve/main/x1_ITF_SkinDiffDetail_Lite_v1.pth
huggingface|upscale_models|4x_NMKD-Superscale-SP_178000_G.pth|https://huggingface.co/gemasai/4x_NMKD-Superscale-SP_178000_G/resolve/main/4x_NMKD-Superscale-SP_178000_G.pth
civitai|loras|Krea2_Selfie_POV_v1.safetensors|https://civitai.com/api/download/models/3390306
civitai|loras|realistic_snapshot__z-image-turbo___krea_2__krea2__v1_0_.safetensors|https://civitai.com/api/download/models/3371723
huggingface|loras|krea2_general_edit_v2.safetensors|https://huggingface.co/conradlocke/krea2-identity-edit/resolve/main/krea2_general_edit_v2.safetensors
huggingface|loras|krea2_identity_edit_v2.safetensors|https://huggingface.co/conradlocke/krea2-identity-edit/resolve/main/krea2_identity_edit_v2.safetensors
MODELS_LIST

log "RESULT: model downloads=$model_downloaded, already present=$model_skipped, failed=$model_failed; nodes installed/checked=$nodes_ok, failed=$nodes_failed"
if ((model_failed > 0 || nodes_failed > 0)); then
    warn "Provisioning incomplete. Run this script again to resume failed items."
    exit 1
fi
# Vast.ai launches Supervisor before provisioning. Restart ComfyUI so new nodes load.
if command -v supervisorctl >/dev/null 2>&1 && supervisorctl status comfyui >/dev/null 2>&1; then
    log "Restarting ComfyUI to load installed custom nodes"
    if ! supervisorctl restart comfyui; then
        warn "Could not restart ComfyUI automatically. Run: supervisorctl restart comfyui"
    fi
fi
log "Provisioning complete."

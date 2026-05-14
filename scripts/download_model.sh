#!/usr/bin/env bash
set -euo pipefail

MODEL_DIR="${HOME}/.local/share/ocash"
MODEL_FILE="${MODEL_DIR}/model.gguf"
# Mirror via GitHub Release (no LFS, sin quota, accesible desde sandboxes
# que bloquean huggingface.co). Original: HuggingFace mradermacher/Qwen2.5-OCamler.
MODEL_URL="${MODEL_URL:-https://github.com/AbstractBike/ocash/releases/download/v0.1-model/model.gguf}"
MODEL_URL_HF="https://huggingface.co/mradermacher/Qwen2.5-OCamler-1.5B-Instruct-i1-GGUF/resolve/main/Qwen2.5-OCamler-1.5B-Instruct.i1-Q4_K_M.gguf"

mkdir -p "${MODEL_DIR}"

if [ -f "${MODEL_FILE}" ]; then
  echo "Modelo ya descargado en ${MODEL_FILE}"
  exit 0
fi

echo "Descargando Qwen2.5-OCamler Q4_K_M (~940 MB) desde GitHub..."
if ! wget --show-progress -O "${MODEL_FILE}" "${MODEL_URL}"; then
  echo "Descarga falló desde GitHub, intentando HuggingFace..."
  if ! wget --show-progress -O "${MODEL_FILE}" "${MODEL_URL_HF}"; then
    rm -f "${MODEL_FILE}"
    echo ""
    echo "Ambas fuentes fallaron (¿firewall bloqueando github.com y huggingface.co?)."
    echo "Alternativas:"
    echo "  1) Descarga manual desde otra máquina y copia a ${MODEL_FILE}"
    echo "  2) Usa otro modelo GGUF compatible con llama-server:"
    echo "     Qwen2.5-1.5B-Instruct, Phi-3-mini, Gemma-2-2b-it..."
    echo "  3) Apunta OCASH_AI_URL a otro endpoint OpenAI-compatible"
    exit 1
  fi
fi
echo "Modelo guardado en ${MODEL_FILE}"

# Instalar llama.cpp si no existe
if ! command -v llama-server &>/dev/null; then
  echo ""
  echo "Instalando llama.cpp..."
  git clone https://github.com/ggerganov/llama.cpp /tmp/llama.cpp
  cd /tmp/llama.cpp
  cmake -B build -DGGML_NATIVE=ON
  cmake --build build -j$(nproc) --target llama-server
  sudo cp build/bin/llama-server /usr/local/bin/
  echo "llama-server instalado"
fi

echo ""
echo "Para iniciar el servidor AI:"
echo "  llama-server -m ${MODEL_FILE} --port 8080 --ctx-size 4096 -ngl 99"
echo ""
echo "Luego lanza ocash:"
echo "  export OCASH_AI_URL=http://localhost:8080"
echo "  ./_build/default/bin/main.exe"

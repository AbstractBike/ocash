#!/usr/bin/env bash
# Compila e instala llama-server (parte de llama.cpp) en /usr/local/bin.
#
# Detecta automáticamente CUDA (NVIDIA) y compila con soporte si está;
# si no, build CPU normal. Usa cmake.

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
BUILD_DIR="${BUILD_DIR:-/tmp/llama.cpp-build}"
JOBS="$(nproc 2>/dev/null || echo 4)"
USE_SUDO="${USE_SUDO:-auto}"

# Detecta GPU NVIDIA → build con CUDA
CUDA_FLAG=""
CUDA_ARCH_FLAG=""
if command -v nvidia-smi &>/dev/null || [ -e /dev/nvidia0 ]; then
  if command -v nvcc &>/dev/null; then
    CUDA_FLAG="-DGGML_CUDA=ON"
    echo "→ NVIDIA + nvcc detectados, compilando con CUDA"

    # Detecta compute capabilities reales para evitar warnings de sm_35/37/50
    # deprecados ("nvcc warning: ... deprecated gpu targets"). Sin esto, llama.cpp
    # compila para una lista por defecto que incluye arquitecturas antiguas.
    arch_list=""
    if command -v nvidia-smi &>/dev/null; then
      arch_list=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
        | awk -F. 'NF==2 {printf "%s%d%d", (NR>1?";":""), $1, $2}')
    fi
    if [ -z "$arch_list" ]; then
      # Fallback: arquitecturas modernas soportadas por CUDA 11/12.
      # Volta(70) Turing(75) Ampere(80/86) Ada(89) Hopper(90).
      arch_list="70;75;80;86;89;90"
      echo "  (no se pudo detectar compute_cap; usando default $arch_list)"
    else
      echo "  compute capabilities detectadas: $arch_list"
    fi
    CUDA_ARCH_FLAG="-DCMAKE_CUDA_ARCHITECTURES=$arch_list -DCMAKE_CUDA_FLAGS=-Wno-deprecated-gpu-targets"
  else
    echo "⚠ NVIDIA detectado pero sin nvcc. Instala CUDA toolkit para GPU support."
    echo "  Continúo con build CPU."
  fi
fi

# AMD ROCm
if [ -e /dev/kfd ] && command -v hipcc &>/dev/null; then
  echo "→ AMD ROCm detectado, compilando con HIP"
  CUDA_FLAG="-DGGML_HIPBLAS=ON"
fi

# Apple Silicon → Metal (auto-detectado por llama.cpp en macOS arm64)
if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ]; then
  echo "→ Apple Silicon detectado, build automático con Metal"
fi

# Determina si necesitamos sudo
need_sudo=false
if [ "$USE_SUDO" = "auto" ]; then
  if [ ! -w "$INSTALL_DIR" ]; then need_sudo=true; fi
elif [ "$USE_SUDO" = "1" ] || [ "$USE_SUDO" = "true" ]; then
  need_sudo=true
fi
SUDO=""
$need_sudo && SUDO="sudo"

# Dependencias
echo "→ Verificando build deps..."
for cmd in cmake make g++ git; do
  command -v $cmd &>/dev/null || {
    echo "ERROR: falta $cmd. Instala con:"
    echo "  apt:  $SUDO apt-get install -y cmake build-essential git"
    echo "  brew: brew install cmake gcc git"
    exit 1
  }
done

# Clone o pull
if [ -d "$BUILD_DIR/.git" ]; then
  echo "→ Updating existing $BUILD_DIR"
  cd "$BUILD_DIR" && git pull --rebase
else
  echo "→ Cloning llama.cpp en $BUILD_DIR"
  git clone --depth 1 https://github.com/ggerganov/llama.cpp "$BUILD_DIR"
  cd "$BUILD_DIR"
fi

# Configure
echo "→ cmake configure..."
cmake -B build \
  -DGGML_NATIVE=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=ON \
  $CUDA_FLAG $CUDA_ARCH_FLAG

# Build solo llama-server (más rápido)
echo "→ Building llama-server (-j$JOBS)..."
cmake --build build -j"$JOBS" --target llama-server

# Install
echo "→ Installing a $INSTALL_DIR"
$SUDO cp build/bin/llama-server "$INSTALL_DIR/"
# Copia shared libs ggml si existen (algunas distros llama.cpp las compilan así)
for so in build/bin/*.so*; do
  [ -f "$so" ] && $SUDO cp "$so" "$INSTALL_DIR/../lib/" 2>/dev/null || true
done
$SUDO ldconfig 2>/dev/null || true

echo ""
echo "✓ llama-server instalado en $INSTALL_DIR/llama-server"
"$INSTALL_DIR/llama-server" --version 2>&1 | head -3 || true

echo ""
echo "Uso típico:"
echo "  llama-server -m ~/.local/share/ocash/model.gguf --port 8080 --ctx-size 4096 -ngl 99"
echo ""
echo "Después lanza ocash:"
echo "  OCASH_AI_URL=http://localhost:8080 ocash"

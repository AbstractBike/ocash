#!/usr/bin/env bash
# Construye un bundle autocontenido de ocash:
#   - dist/ocash            (binario OCaml: bytecode + ocamlrun embebido)
#   - dist/llama-server     (opcional, si está disponible)
#   - dist/model.gguf       (opcional, si está descargado)
#   - dist/launch.sh        (lanzador que arranca llama-server + ocash)
#
# El binario OCaml ya es "fat" (incluye ocamlrun + stdlib + compiler-libs
# para el toploop embebido). Solo depende de libc/libssl/libev/libcrypto
# del sistema.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${ROOT}/dist"
MODEL="${HOME}/.local/share/ocash/model.gguf"

cd "${ROOT}"
mkdir -p "${DIST}"

echo "=== ocash fatbin ==="

# 1. Build
echo "[1/4] Compilando ocash..."
dune build --release bin/main.exe
cp "_build/default/bin/main.exe" "${DIST}/ocash"
strip "${DIST}/ocash" 2>/dev/null || true
echo "  ✓ $(du -h "${DIST}/ocash" | cut -f1)"

# 2. llama-server
echo "[2/4] Buscando llama-server..."
if command -v llama-server &>/dev/null; then
  cp "$(command -v llama-server)" "${DIST}/llama-server"
  echo "  ✓ llama-server copiado"
else
  echo "  ⚠ llama-server no encontrado (omitido)"
fi

# 3. Modelo
echo "[3/4] Buscando modelo GGUF..."
if [ -f "${MODEL}" ]; then
  cp "${MODEL}" "${DIST}/model.gguf"
  echo "  ✓ modelo copiado ($(du -h "${MODEL}" | cut -f1))"
else
  echo "  ⚠ modelo no descargado (omitido)"
fi

# 4. Launcher
echo "[4/4] Generando launcher..."
cat > "${DIST}/launch.sh" <<'LAUNCH'
#!/usr/bin/env bash
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ -x "${HERE}/llama-server" ] && [ -f "${HERE}/model.gguf" ]; then
  if ! curl -fsS http://localhost:8080/health >/dev/null 2>&1; then
    echo "Iniciando llama-server (puerto 8080)..."
    "${HERE}/llama-server" \
      -m "${HERE}/model.gguf" \
      --port 8080 --ctx-size 4096 \
      > "${HERE}/llama-server.log" 2>&1 &
    LLAMA_PID=$!
    trap 'kill $LLAMA_PID 2>/dev/null || true' EXIT
    for i in $(seq 1 30); do
      if curl -fsS http://localhost:8080/health >/dev/null 2>&1; then break; fi
      sleep 0.5
    done
  fi
fi

export OCASH_AI_URL="${OCASH_AI_URL:-http://localhost:8080}"
exec "${HERE}/ocash" "$@"
LAUNCH
chmod +x "${DIST}/launch.sh"

echo ""
echo "=== ✓ bundle en ${DIST} ==="
ls -lh "${DIST}"
echo ""
echo "Ejecuta: ${DIST}/launch.sh"
echo "Empaqueta para distribuir: tar czf ocash-fatbin.tar.gz -C dist ."

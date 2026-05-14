#!/usr/bin/env bash
# Construye un "fatbin" autocontenido de ocash:
#   - dist/ocash            (binario OCaml estáticamente linkeado)
#   - dist/llama-server     (opcional, si está disponible)
#   - dist/model.gguf       (opcional, si está descargado)
#   - dist/launch.sh        (lanzador que arranca llama-server + ocash)
#
# Requisitos para link estático completo:
#   - musl-gcc o un switch opam con flambda+musl
#   - libev estático (apt: libev-dev)
#
# Si link estático falla, hace fallback a build dinámico.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${ROOT}/dist"
MODEL="${HOME}/.local/share/ocash/model.gguf"

cd "${ROOT}"
mkdir -p "${DIST}"

echo "=== ocash fatbin ==="

# 1. Build estático
echo "[1/4] Compilando con profile static..."
if dune build --profile static bin/main.exe 2>/dev/null; then
  cp "_build/default/bin/main.exe" "${DIST}/ocash"
  echo "  ✓ binario estático generado"
else
  echo "  ⚠ link estático falló (libs sin .a). Fallback a build normal."
  dune build bin/main.exe
  cp "_build/default/bin/main.exe" "${DIST}/ocash"
fi

# Strip para reducir tamaño
strip "${DIST}/ocash" 2>/dev/null || true

# 2. Empaquetar llama-server si existe
echo "[2/4] Buscando llama-server..."
if command -v llama-server &>/dev/null; then
  cp "$(command -v llama-server)" "${DIST}/llama-server"
  echo "  ✓ llama-server copiado"
else
  echo "  ⚠ llama-server no encontrado (omitido)"
fi

# 3. Empaquetar modelo si existe
echo "[3/4] Buscando modelo GGUF..."
if [ -f "${MODEL}" ]; then
  cp "${MODEL}" "${DIST}/model.gguf"
  echo "  ✓ modelo copiado ($(du -h "${MODEL}" | cut -f1))"
else
  echo "  ⚠ modelo no descargado (omitido)"
fi

# 4. Generar launcher autocontenido
echo "[4/4] Generando launcher..."
cat > "${DIST}/launch.sh" <<'LAUNCH'
#!/usr/bin/env bash
# Launcher autocontenido de ocash.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

# Arranca llama-server en background si está empaquetado
if [ -x "${HERE}/llama-server" ] && [ -f "${HERE}/model.gguf" ]; then
  if ! curl -fsS http://localhost:8080/health >/dev/null 2>&1; then
    echo "Iniciando llama-server (puerto 8080)..."
    "${HERE}/llama-server" \
      -m "${HERE}/model.gguf" \
      --port 8080 --ctx-size 4096 \
      > "${HERE}/llama-server.log" 2>&1 &
    LLAMA_PID=$!
    trap 'kill $LLAMA_PID 2>/dev/null || true' EXIT
    # Espera health endpoint
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
echo "=== ✓ fatbin en ${DIST} ==="
ls -lh "${DIST}"
echo ""
echo "Ejecuta: ${DIST}/launch.sh"
echo "O empaqueta para distribuir: tar czf ocash-fatbin.tar.gz -C dist ."

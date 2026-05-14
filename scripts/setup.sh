#!/usr/bin/env bash
set -euo pipefail

echo "=== ocash Setup ==="

# 1. Instalar opam si no existe
if ! command -v opam &>/dev/null; then
  echo "Instalando opam..."
  bash -c "$(curl -fsSL https://opam.ocaml.org/install.sh)"
fi

# 2. Inicializar opam
opam init --disable-sandboxing -y || true
eval $(opam env)

# 3. Instalar dependencias OCaml
echo "Instalando dependencias OCaml..."
opam install -y \
  dune \
  lwt \
  lwt_ppx \
  lambda-term \
  angstrom \
  cohttp-lwt-unix \
  yojson \
  str \
  conf-libev

# 4. Instalar Ansible (opcional, para el builtin)
if ! command -v ansible &>/dev/null; then
  echo "Instalando Ansible (opcional)..."
  pip install --user ansible || echo "(skip) instala Ansible manualmente con: pip install ansible"
fi

# 5. Compilar ocash
echo "Compilando ocash..."
dune build

echo ""
echo "=== Compilacion exitosa ==="
echo "Ejecuta: ./scripts/download_model.sh para descargar el modelo AI"
echo "Luego:   ./_build/default/bin/main.exe"

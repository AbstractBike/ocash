# ocash multi-stage Dockerfile
# Stage 1: builder con OCaml + libs + compila ocash y el unikernel
FROM ocaml/opam:ubuntu-24.04-ocaml-4.14 AS builder

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    libev-dev libssl-dev pkg-config m4 cmake build-essential git \
 && rm -rf /var/lib/apt/lists/*

USER opam
WORKDIR /home/opam/ocash
COPY --chown=opam:opam ocash.opam ./
RUN opam install -y --deps-only --with-test .

COPY --chown=opam:opam . .
RUN eval $(opam env) && dune build && \
    cp _build/default/bin/main.exe /tmp/ocash && \
    cp _build/default/unikernel/uni.exe /tmp/ocash-uni

# Stage 2: runtime mínimo
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libev4 libssl3 ca-certificates bash ansible curl wget \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /tmp/ocash /usr/local/bin/ocash
COPY --from=builder /tmp/ocash-uni /usr/local/bin/ocash-ai-unikernel

# Modelo opcional vía build-arg o volume
# ARG MODEL_URL=https://github.com/AbstractBike/ocash/releases/download/v0.1-model/model.gguf
# RUN mkdir -p /root/.local/share/ocash && \
#     curl -L -o /root/.local/share/ocash/model.gguf $MODEL_URL

ENV OCASH_AI_BACKEND=local
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/ocash"]

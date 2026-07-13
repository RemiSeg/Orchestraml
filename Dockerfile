FROM ocaml/opam:debian-12-ocaml-5.2@sha256:fb0e032e3b8d6e0119e8d35f5c9663f7fa90ac356ac79ed632c0f561624bcb62 AS build
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev libgmp-dev pkg-config && rm -rf /var/lib/apt/lists/*
USER opam
WORKDIR /workspace
COPY --chown=opam:opam orchestraml.opam dune-project ./
RUN opam install . --deps-only --yes
COPY --chown=opam:opam . .
RUN opam exec -- dune build --profile release bin/coordinator/main.exe bin/worker/main.exe bin/cli/main.exe

FROM debian:12-slim AS coordinator
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libpq5 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home orchestraml
COPY --from=build /workspace/_build/default/bin/coordinator/main.exe /usr/local/bin/orchestraml-coordinator
COPY migrations /app/migrations
USER 10001:10001
WORKDIR /app
ENTRYPOINT ["/usr/local/bin/orchestraml-coordinator"]

FROM debian:12-slim AS worker
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates docker.io && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home orchestraml \
 && mkdir -p /var/lib/orchestraml && chown 10001:10001 /var/lib/orchestraml
COPY --from=build /workspace/_build/default/bin/worker/main.exe /usr/local/bin/orchestraml-worker
USER 10001:10001
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/orchestraml-worker"]

FROM debian:12-slim AS cli
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --create-home orchestraml
COPY --from=build /workspace/_build/default/bin/cli/main.exe /usr/local/bin/orchestraml
USER 10001:10001
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/orchestraml"]

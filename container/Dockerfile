# Lightweight alternative to the VM: omp in a container, same binary installer.
# Build:  docker build -t omp-sandbox container/
# Run:    ./run-container.sh /path/to/project
FROM ubuntu:24.04

# OMP_REF: empty = latest release; or a tag like v18.8.0
ARG OMP_REF=
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip python3 python3-venv openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash omp
USER omp
WORKDIR /home/omp
ENV PATH="/home/omp/.local/bin:${PATH}"

RUN if [ -n "$OMP_REF" ]; then \
      curl -fsSL https://omp.sh/install | sh -s -- --binary --ref "$OMP_REF"; \
    else \
      curl -fsSL https://omp.sh/install | sh -s -- --binary; \
    fi \
    && omp --version

# Disposable sandbox: no per-tool approval prompts.
RUN mkdir -p /home/omp/.omp/agent && printf 'startup:\n  quiet: true\ntools:\n  approvalMode: yolo\n' > /home/omp/.omp/agent/config.yml

WORKDIR /work
ENTRYPOINT ["omp"]

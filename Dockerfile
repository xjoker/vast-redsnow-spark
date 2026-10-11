# GPUtw DGX Spark（GB10，linux/arm64，sm_121）。权重不进镜像。
ARG BASE_IMAGE=nvcr.io/nvidia/pytorch:26.07-py3@sha256:2140e699b3beaf7f96a0081fd9c9406bc3832b435cdb60dfa2d261f7d2f34a1c
ARG KERNELS_IMAGE=ghcr.io/xjoker/redsnow-kernels:7c1636fead6b6d802dc3ebf0e7ef02c4e76e9c2f
FROM ${KERNELS_IMAGE} AS kernels
FROM --platform=linux/arm64 ${BASE_IMAGE}

ARG SERVER_REF=b96fac226d9689c9e574f9b1b491c01d5340030d
ARG EASYTIER_VERSION=2.6.4
ARG EASYTIER_SHA256=f533ec25a7ea714e09f645615012200278058525795cc3bb690ff011aec1a70f
ENV TORCH_CUDA_ARCH_LIST=12.1 \
    DEBIAN_FRONTEND=noninteractive \
    TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
    PIP_INDEX_URL=https://pypi.org/simple \
    HF_ENDPOINT=https://huggingface.co \
    PYTHONUNBUFFERED=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssh-server sudo \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd \
 && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
 && useradd --create-home --shell /bin/bash --user-group tunnel \
 && printf 'tunnel ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/tunnel \
 && chmod 440 /etc/sudoers.d/tunnel

COPY install_easytier.py /tmp/install_easytier.py
COPY licenses/easytier-v2.6.4-LICENSE /usr/share/licenses/easytier/LICENSE
COPY licenses/GPL-3.0.txt /usr/share/licenses/easytier/GPL-3.0.txt
RUN curl -fsSL -o /tmp/easytier.zip \
      "https://github.com/EasyTier/EasyTier/releases/download/v${EASYTIER_VERSION}/easytier-linux-aarch64-v${EASYTIER_VERSION}.zip" \
 && echo "${EASYTIER_SHA256}  /tmp/easytier.zip" | sha256sum -c - \
 && python3 /tmp/install_easytier.py /tmp/easytier.zip /usr/local/bin \
 && rm -f /tmp/easytier.zip /tmp/install_easytier.py \
 && printf '%s\n' \
      "easytier-core easytier-cli ${EASYTIER_VERSION}" \
      "unmodified binaries from https://github.com/EasyTier/EasyTier/releases/tag/v${EASYTIER_VERSION}" \
      "corresponding source: https://github.com/EasyTier/EasyTier/tree/v${EASYTIER_VERSION}" \
      "zip sha256 ${EASYTIER_SHA256}" \
      > /usr/share/licenses/easytier/SOURCE \
 && easytier-core --version \
 && easytier-cli --version

COPY --from=kernels /wheels/ /tmp/wheels/
RUN torch_before="$(python3 -c 'import torch; print(torch.__version__)')" \
 && pip install --no-cache-dir --index-url https://pypi.org/simple --no-deps /tmp/wheels/exllamav3-*.whl \
 && pip install --no-cache-dir --index-url https://pypi.org/simple "huggingface_hub[hf_xet]>=0.32" jsonschema "transformers>=5.0" jinja2 \
 && torch_after="$(python3 -c 'import torch; print(torch.__version__)')" \
 && echo "torch ${torch_before} -> ${torch_after}" \
 && test "${torch_before}" = "${torch_after}" \
 && mkdir -p /usr/share/licenses/exllamav3 \
 && cp /tmp/wheels/exllamav3-LICENSE /usr/share/licenses/exllamav3/LICENSE \
 && rm -rf /tmp/wheels \
 && python3 -c "import exllamav3, exllamav3_ext, transformers; print(transformers.__version__)"

RUN git clone https://github.com/Weschera/RED-SNOW-5.3-Flash-2.49bpw-1x-DGX-Spark.git /tmp/redsnow \
 && git -C /tmp/redsnow checkout --detach "${SERVER_REF}" \
 && mkdir -p /opt/redsnow/server /usr/share/licenses/redsnow-server \
 && cp /tmp/redsnow/server/serve_glm.py /tmp/redsnow/server/protocol.py /tmp/redsnow/server/glm_protocol.py /tmp/redsnow/server/worker.py /opt/redsnow/server/ \
 && cp /tmp/redsnow/LICENSE /usr/share/licenses/redsnow-server/LICENSE \
 && rm -rf /tmp/redsnow

COPY auth_proxy.py download_model.py /opt/redsnow/
COPY entrypoint.sh /opt/redsnow/entrypoint.sh
COPY normalize_apt_sources.py /usr/local/bin/normalize_apt_sources.py
RUN chmod 755 /opt/redsnow/entrypoint.sh /opt/redsnow/auth_proxy.py /opt/redsnow/download_model.py /usr/local/bin/normalize_apt_sources.py \
 && python3 /usr/local/bin/normalize_apt_sources.py

ARG IMAGE_VERSION=20261011.1
ENV IMAGE_VERSION=${IMAGE_VERSION}
LABEL org.opencontainers.image.title="redsnow-exl3" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.source="https://github.com/xjoker/vast-redsnow-spark"
WORKDIR /opt/redsnow
EXPOSE 22 8898
ENTRYPOINT ["/opt/redsnow/entrypoint.sh"]

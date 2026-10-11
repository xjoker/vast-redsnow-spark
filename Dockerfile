# GPUtw DGX Spark（GB10，linux/arm64，sm_121）。权重不进镜像。
FROM --platform=linux/arm64 nvcr.io/nvidia/pytorch:26.07-py3

ARG EXL3_REF=7c1636fead6b6d802dc3ebf0e7ef02c4e76e9c2f
ARG SERVER_REF=b96fac226d9689c9e574f9b1b491c01d5340030d
ARG MAX_JOBS=16
ARG IMAGE_VERSION=20261011.1
# 直取 Release 资产。EasyTier 标签里的 install.sh 仍会装 latest。
ARG EASYTIER_VERSION=2.6.4
ARG EASYTIER_SHA256=f533ec25a7ea714e09f645615012200278058525795cc3bb690ff011aec1a70f

# 官方源。落到哪台边缘由发布方按部署地点解析，这里不写国家，也不用大陆镜像站。
ENV TORCH_CUDA_ARCH_LIST=12.1 \
    MAX_JOBS=${MAX_JOBS} \
    DEBIAN_FRONTEND=noninteractive \
    TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
    PIP_INDEX_URL=https://pypi.org/simple \
    HF_ENDPOINT=https://huggingface.co

LABEL org.opencontainers.image.title="redsnow-spark" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.description="RED-SNOW EXL3 on one DGX Spark for GPUtw"

COPY normalize_apt_sources.py /tmp/normalize_apt_sources.py
RUN python3 /tmp/normalize_apt_sources.py /etc/apt/sources.list /etc/apt/sources.list.d \
 && rm -f /tmp/normalize_apt_sources.py \
 && rm -f /etc/pip.conf /etc/xdg/pip/pip.conf /root/.pip/pip.conf /root/.config/pip/pip.conf \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-server iproute2 sudo \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/run/sshd \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

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

RUN git clone https://github.com/vcruz305/exllamav3.git /opt/exllamav3 \
 && git -C /opt/exllamav3 checkout --detach "${EXL3_REF}" \
 && pip install --no-cache-dir --index-url https://pypi.org/simple -r /opt/exllamav3/requirements.txt \
 && pip install --no-cache-dir --index-url https://pypi.org/simple --no-build-isolation -e /opt/exllamav3 \
 && pip install --no-cache-dir --index-url https://pypi.org/simple huggingface_hub jsonschema "transformers>=5.0" jinja2 \
 && python -c "import exllamav3, exllamav3_ext, transformers; print(transformers.__version__)"

RUN git clone https://github.com/Weschera/RED-SNOW-5.3-Flash-2.49bpw-1x-DGX-Spark.git /tmp/redsnow-src \
 && git -C /tmp/redsnow-src checkout --detach "${SERVER_REF}" \
 && mkdir -p /opt/redsnow/server /usr/share/licenses/redsnow-server \
 && cp /tmp/redsnow-src/server/serve_glm.py /tmp/redsnow-src/server/protocol.py \
       /tmp/redsnow-src/server/glm_protocol.py /tmp/redsnow-src/server/worker.py \
       /opt/redsnow/server/ \
 && cp /tmp/redsnow-src/LICENSE /usr/share/licenses/redsnow-server/LICENSE \
 && rm -rf /tmp/redsnow-src

COPY auth_proxy.py entrypoint.sh /opt/redsnow/
RUN chmod 755 /opt/redsnow/entrypoint.sh

WORKDIR /opt/redsnow
EXPOSE 22
ENTRYPOINT ["/opt/redsnow/entrypoint.sh"]

# GPUtw DGX Spark（GB10，linux/arm64，sm_121）。权重不进镜像。
ARG BASE_IMAGE=nvcr.io/nvidia/pytorch:26.07-py3@sha256:2140e699b3beaf7f96a0081fd9c9406bc3832b435cdb60dfa2d261f7d2f34a1c
ARG KERNELS_IMAGE=ghcr.io/xjoker/redsnow-kernels:7c1636fead6b6d802dc3ebf0e7ef02c4e76e9c2f
FROM ${KERNELS_IMAGE} AS kernels
FROM --platform=linux/arm64 ${BASE_IMAGE}

ARG SERVER_REF=b96fac226d9689c9e574f9b1b491c01d5340030d
ARG EASYTIER_VERSION=2.6.4
ARG EASYTIER_SHA256=f533ec25a7ea714e09f645615012200278058525795cc3bb690ff011aec1a70f
ARG NV_MONITOR_VERSION=1.14.0
ARG NV_MONITOR_SHA256=d778d2b2db377b7aa52a8ce5119d97592f9e0731ccdde03da63ea37241205f1c
ARG DGXTOP_VERSION=0.2.5
ARG DGXTOP_SHA256=c935802f666a56550c8a19c2a48a262fed38a66f645954421871c31706de0a6d
ARG CLOUDFLARED_VERSION=2026.9.3
ARG CLOUDFLARED_SHA256=aaeb2d7d0da3614634c7e03ab13487a1522c2e79165ed2929cfe23d5e95b326d
ENV TORCH_CUDA_ARCH_LIST=12.1 \
    DEBIAN_FRONTEND=noninteractive \
    TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas \
    PIP_INDEX_URL=https://pypi.org/simple \
    HF_ENDPOINT=https://huggingface.co \
    PYTHONUNBUFFERED=1 \
    EXL3_UMA=1

COPY normalize_apt_sources.py /tmp/normalize_apt_sources.py
RUN python3 /tmp/normalize_apt_sources.py /etc/apt/sources.list /etc/apt/sources.list.d \
 && rm -f /tmp/normalize_apt_sources.py \
 && rm -f /etc/pip.conf /etc/xdg/pip/pip.conf /root/.pip/pip.conf /root/.config/pip/pip.conf \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssh-server iproute2 sudo \
      btop htop tmux ncdu \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd \
 && printf 'ClientAliveInterval 30\nClientAliveCountMax 10\n' > /etc/ssh/sshd_config.d/10-keepalive.conf \
 && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config \
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

# GB10 统一内存下 nvidia-smi 的显存是 N/A。nv-monitor 按 MemAvailable 和页缓存分开算，另有 GPU 功耗、温度、时钟；-n -l 可无界面写 CSV。
COPY licenses/nv-monitor-v1.14.0-LICENSE /usr/share/licenses/nv-monitor/LICENSE
RUN curl -fsSL -o /usr/local/bin/nv-monitor \
      "https://github.com/wentbackward/nv-monitor/releases/download/v${NV_MONITOR_VERSION}/nv-monitor-linux-arm64" \
 && echo "${NV_MONITOR_SHA256}  /usr/local/bin/nv-monitor" | sha256sum -c - \
 && chmod 755 /usr/local/bin/nv-monitor \
 && nv-monitor -v

# 用 musl 静态包，不依赖基础镜像的 glibc 版本。发行包是 tar.gz，sha256 校验的是压缩包本身。
COPY licenses/dgxtop-v0.2.5-LICENSE /usr/share/licenses/dgxtop/LICENSE
RUN curl -fsSL -o /tmp/dgxtop.tar.gz \
      "https://github.com/DennySORA/dgxtop/releases/download/v${DGXTOP_VERSION}/dgxtop-aarch64-unknown-linux-musl.tar.gz" \
 && echo "${DGXTOP_SHA256}  /tmp/dgxtop.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/dgxtop.tar.gz -C /usr/local/bin dgxtop \
 && rm /tmp/dgxtop.tar.gz \
 && chmod 755 /usr/local/bin/dgxtop \
 && dgxtop --version

# cloudflared 把认证代理暴露到公网，入口只指向 PROXY_PORT。Apache-2.0。
COPY licenses/cloudflared-2026.9.3-LICENSE /usr/share/licenses/cloudflared/LICENSE
RUN curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-arm64" \
 && echo "${CLOUDFLARED_SHA256}  /usr/local/bin/cloudflared" | sha256sum -c - \
 && chmod 755 /usr/local/bin/cloudflared \
 && cloudflared --version

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

# server.patch：图片输入、developer 角色、JSON response_format、强制 tool_choice、reasoning_effort 开思考、
# generation_config 采样默认值、OpenAI 标准响应字段、单个任务失败（含 OOM）不拖垮生成线程。只对钉死的 SERVER_REF 生效，换提交要重做补丁。
COPY server.patch /tmp/server.patch
RUN git clone https://github.com/Weschera/RED-SNOW-5.3-Flash-2.49bpw-1x-DGX-Spark.git /tmp/redsnow \
 && git -C /tmp/redsnow checkout --detach "${SERVER_REF}" \
 && git -C /tmp/redsnow apply /tmp/server.patch \
 && rm -f /tmp/server.patch \
 && mkdir -p /opt/redsnow/server /usr/share/licenses/redsnow-server \
 && cp /tmp/redsnow/server/serve_glm.py /tmp/redsnow/server/protocol.py /tmp/redsnow/server/glm_protocol.py /tmp/redsnow/server/worker.py /opt/redsnow/server/ \
 && cp /tmp/redsnow/LICENSE /usr/share/licenses/redsnow-server/LICENSE \
 && rm -rf /tmp/redsnow

COPY auth_proxy.py download_model.py /opt/redsnow/
COPY entrypoint.sh /opt/redsnow/entrypoint.sh
RUN chmod 755 /opt/redsnow/entrypoint.sh /opt/redsnow/auth_proxy.py /opt/redsnow/download_model.py

ARG IMAGE_VERSION=20261011.10
ENV IMAGE_VERSION=${IMAGE_VERSION}
ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}
LABEL org.opencontainers.image.title="redsnow-exl3" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.source="https://github.com/xjoker/vast-redsnow-spark"
WORKDIR /opt/redsnow
EXPOSE 22 8898
ENTRYPOINT ["/opt/redsnow/entrypoint.sh"]

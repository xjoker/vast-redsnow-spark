# GPUtw DGX Spark（GB10，linux/arm64，sm_121）。权重不进镜像。
FROM --platform=linux/arm64 nvcr.io/nvidia/pytorch:26.07-py3

ARG EXL3_REF=7c1636fead6b6d802dc3ebf0e7ef02c4e76e9c2f
ARG SERVER_REF=b96fac226d9689c9e574f9b1b491c01d5340030d
ARG MAX_JOBS=16
ARG IMAGE_VERSION=20261010.1

ENV TORCH_CUDA_ARCH_LIST=12.1 \
    MAX_JOBS=${MAX_JOBS} \
    DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="redsnow-spark" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.description="RED-SNOW EXL3 on one DGX Spark for GPUtw"

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git openssh-server \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/run/sshd \
 && ssh-keygen -A \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
 && curl -fsSL https://tailscale.com/install.sh | sh

RUN git clone https://github.com/vcruz305/exllamav3.git /opt/exllamav3 \
 && git -C /opt/exllamav3 checkout --detach "${EXL3_REF}" \
 && pip install --no-cache-dir -r /opt/exllamav3/requirements.txt \
 && pip install --no-cache-dir --no-build-isolation -e /opt/exllamav3 \
 && pip install --no-cache-dir huggingface_hub jsonschema "transformers>=5.0" jinja2 \
 && python -c "import exllamav3, exllamav3_ext, transformers; print(transformers.__version__)"

RUN git clone https://github.com/Weschera/RED-SNOW-5.3-Flash-2.49bpw-1x-DGX-Spark.git /tmp/redsnow-src \
 && git -C /tmp/redsnow-src checkout --detach "${SERVER_REF}" \
 && mkdir -p /opt/redsnow/server \
 && cp /tmp/redsnow-src/server/serve_glm.py /tmp/redsnow-src/server/protocol.py \
       /tmp/redsnow-src/server/glm_protocol.py /tmp/redsnow-src/server/worker.py \
       /opt/redsnow/server/ \
 && rm -rf /tmp/redsnow-src

COPY auth_proxy.py entrypoint.sh /opt/redsnow/
RUN chmod 755 /opt/redsnow/entrypoint.sh

WORKDIR /opt/redsnow
EXPOSE 22
ENTRYPOINT ["/opt/redsnow/entrypoint.sh"]

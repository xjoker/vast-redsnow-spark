# redsnow-spark

Vast.ai 和 GPUtw 上单台 DGX Spark（GB10，linux/arm64）的 RED-SNOW 推理镜像。版本在仓库根目录 `VERSION`。

镜像里只有运行时和入口。权重不进镜像，启动时按目录找：

```text
/vault/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw
/workspace/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw
```

GPUtw 的持久盘是 `/vault`。Vast 的实例盘是 `/workspace`。`DATA_DIRECTORY` 有值时也会找它下面的 `models/`。要改路径就填 `MODEL_DIR`。

运行时钉死两处提交：

- exllamav3 `7c1636fead6b6d802dc3ebf0e7ef02c4e76e9c2f`
- 用法仓库的服务层 `b96fac226d9689c9e574f9b1b491c01d5340030d`

EasyTier 钉在 `v2.6.4` 的 aarch64 发布包，`easytier-core` 和 `easytier-cli` 来自同一个 zip，二进制不改。许可在镜像的 `/usr/share/licenses/easytier/`：上游 LGPL-3.0、它所包含的 GPL-3.0，以及对应源码标签。exllamav3 的 MIT 文本留在 `/opt/exllamav3/LICENSE`。服务层四个文件的 MIT 文本在 `/usr/share/licenses/redsnow-server/LICENSE`。NVIDIA 基础镜像自带的许可文件保持原样。

SSH 主机密钥在容器第一次启动时生成，不写进镜像。

## 构建

在 arm64 机器上，于本目录执行：

```bash
./build.sh
```

产物是本地镜像 `redsnow-exl3:` 加 `VERSION` 里的版本号。脚本固定 `--platform linux/arm64`，默认不推送。

版本号是当天 UTC 的 `YYYYMMDD.N`。当天第一发是 `.1`，同一天再发才递增。推送镜像只用这个 tag，不用 `latest`。GPUtw 拒绝 `latest`。

推到 `main` 会跑测试，并在 `ubuntu-24.04-arm` 上构建镜像，不推送。发布要在 Actions 里手动运行「发布镜像」。它核对 `VERSION` 的日期是今天，再用 `--no-cache` 推到 `ghcr.io/<owner>/redsnow-exl3:<VERSION>`，并打上 `v<VERSION>`。仓库密钥要有 `NGC_API_KEY`，值是 NVIDIA NGC 的 API key。

NGC 基础镜像 `nvcr.io/nvidia/pytorch:26.07-py3` 在本地构建时可能要先 `docker login nvcr.io`。

## 部署

两个平台都用这份镜像自己的入口。启动参数留空。不要把 8898 或 8899 映成公网端口。镜像只 `EXPOSE 22`。

Vast 用 Entrypoint 启动模式。SSH 和 Jupyter 模式会换掉镜像入口，推理不会起来；若用了这两种，onstart 里要执行 `/opt/redsnow/entrypoint.sh`。Vast 注入的 `SSH_PUBLIC_KEY` 会写入 `/root/.ssh/authorized_keys`。

GPUtw 用自订映像，`sshEnabled` 打开，不要开 Web UI。平台要求容器自己听 22，入口会起 sshd。`customImage.env` 最多 32 个。不要自己填 `PUBLIC_KEY`、`GATEWAY_KEY`、`NVIDIA_VISIBLE_DEVICES`、`NVIDIA_DRIVER_CAPABILITIES`，平台会拒绝。

可以写进表单的变量是 `.env.example` 里的 17 个。必填只有 `API_TOKEN`。EasyTier 和隧道用户都是填了才启动，留空就跳过。其余有默认值，表单留空。密钥只放在部署表单里，不进镜像。

构建时的 apt、pip、GitHub、Hugging Face 都用官方主机。国家代码和大陆镜像站会改回 `archive.ubuntu.com`、`ports.ubuntu.com`、`pypi.org`、`github.com`、`huggingface.co`。落到哪台边缘由这些服务自己解析，镜像里不写地区。

入口先听 22，再加载权重。EasyTier 在后台连，不占权重加载的那大约一分钟。日志出现 `Native API listening` 之后，API 才能调用。

推理进程只听 `127.0.0.1:8899`。对外是带 Bearer 的代理，默认 `8898`：

- `SSH_PASSWORD` 或 `SSH_USER_PUBLIC_KEY` 填了才创建隧道用户，默认用户名 `tunnel`，两个可以同时给。登录后执行 `sudo -i` 就是 root，不用再输密码。平台注入给 root 的公钥仍然可用，root 这个名字不能用密码登录。`SSH_TUNNELS` 留空时只允许转发到 `127.0.0.1:8898`。本机执行 `ssh -N -L 8898:127.0.0.1:8898 tunnel@<主机>`
- `ET_NETWORK_NAME` 和 `ET_NETWORK_SECRET` 都填：EasyTier peer。有 `/dev/net/tun` 时分配虚拟 IP，代理再绑到这个地址。默认监听 tcp/udp `11010`；`ET_PEERS` 用逗号分隔，留空就等别人来连。别人要从公网连进来时，只映 `11010`，不要映 API 端口

请求头 `Authorization: Bearer <API_TOKEN>`。模型名 `RED-SNOW-5.3-FLASH-EXL3-2.49`。SSH 登录后这些运行参数在 `/etc/environment`，权限 600。

日志出现 `Native API listening` 后才能调用。加载约 105GB 权重需要大约一分钟，前提是页缓存已经让出来、切分没有超过当时的空闲显存。

`GPU_SPLIT_GB` 留空时，入口按启动时空闲显存取 `min(112, floor(GiB)-2)`。这次实测：空闲约 112 GiB 时切分 110 能载入 256K；空闲约 114 GiB 时切分 112 能载入 384K 的缓存。显式写 112 而当时空闲只有大约 101 GiB 时，加载会失败。

默认上下文 `262144`。提示词加上一页余量（256）之后没有输出空间时，服务返回 400，入口不会裁提示词。客户端要在 `prompt_tokens` 达到 `CACHE_SIZE - 256` 之前自己压缩。

## 实测对速度的含义

解码大约 30 token/s。MTP 接受率高时能到 36，低时会掉到 18 附近。默认 `NUM_DRAFT_TOKENS=2`，没有新的测量就不要加大。

预填到 64K 大约 6300 token/s，64K 的首 token 大约 10 秒。128K 及以上首 token 大约 100 秒，一直到 256K 都停在这个量级，不是按长度线性变长。要响应快，就把单次提示留在 64K 以内。256K 的 KV 大约 2.3 GiB，限制首 token 的是这段预填，不是显存装不下。

上次用 SSH 隧道量到的额外往返大约 0.2 秒，不改变解码速度。服务同一时间只处理一个请求。这次对外只走 EasyTier。

容器里通常写不了 `/proc/sys/vm/drop_caches`。加载失败时先看空闲显存和 `GPU_SPLIT_GB`，不是先把上下文改成 131072。`TRITON_PTXAS_PATH` 必须指向认识 `sm_121a` 的 ptxas，镜像里默认是 `/usr/local/cuda/bin/ptxas`。NGC 26.07 这支 ptxas 是否认识 `sm_121a` 还没在这台镜像里跑过；不认识的话，加载会死在 `causal_conv1d_update`。

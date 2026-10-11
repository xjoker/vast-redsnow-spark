# redsnow-spark

单台 DGX Spark（GB10，linux/arm64，128 GB 统一内存）上的 OpenAI 兼容推理镜像：GLM-5.3-Flash 多模态 RED-SNOW 2.49bpw EXL3，最大 262,144 token 上下文，支持工具调用、JSON 输出、图片输入。

镜像 `ghcr.io/xjoker/redsnow-exl3:<VERSION>`（`VERSION` 文件，格式 `YYYYMMDD.N`）。权重（约 97 GiB）不进镜像，启动时从 Hugging Face 下载。对外只有带 Bearer 的认证代理，推理进程只听 `127.0.0.1`。

## 快速开始（Vast.ai）

用 CLI 建实例，ENTRYPOINT 模式：

```bash
vastai create instance <OFFER_ID> --image ghcr.io/xjoker/redsnow-exl3:<VERSION> --disk 150 \
  --env "-e API_TOKEN=<API_TOKEN> -e MODEL_DIR=/workspace/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw -p 22:22 -p 8898:8898" \
  --entrypoint /opt/redsnow/entrypoint.sh --args serve
```

- `--entrypoint` 和非空的 `--args` 都要带；不带 `--args` 会被建成 SSH 模式。`--args` 的内容入口忽略。
- `--env` 是 docker 风格的空格分隔字符串，值里不能有空格。
- 没挂卷时必须设 `MODEL_DIR`：默认目录 `/models/...` 要求 `/models` 是挂载点，否则入口不下载、不起推理（SSH 和代理照常）。
- `API_TOKEN` 是唯一必填项。其余都有默认值，见下文环境变量表。
- 网页表单建 ENTRYPOINT 模式出现过 `unknown flag --runtime`，CLI 没有。

启动流程：先起 sshd，再起认证代理和 Cloudflare 隧道，然后下载（缺权重时）并加载模型。新机实测：容器约 20 秒进入 running，下载 97 GiB 约 6 分钟，加载约 3 分钟。

看容器日志（`vastai logs <INSTANCE_ID>`），出现下面的横幅就可以调用：

```text
==== 模型就绪：接入信息（整段复制给 AI，只需补 API_TOKEN） ====
  加载用时 ... 秒
  协议      OpenAI Chat Completions 兼容
  Base URL  https://<随机>.trycloudflare.com/v1
  模型      RED-SNOW-5.3-FLASH-EXL3-2.49
  鉴权      请求头 Authorization: Bearer <API_TOKEN>
  上下文    262144 tok，输入加 max_tokens 超过会返回 400
  ...
```

横幅里有 Base URL、模型名、上下文上限、串流要求、能力和 curl 示例，整段可直接贴给任意 AI，只需把 `<API_TOKEN>` 换成真值（真实 token 不进日志）。匿名隧道地址同时写在容器内 `/run/redsnow/tunnel_url`。

验证：

```bash
curl -N <BASE_URL>/chat/completions \
  -H 'Authorization: Bearer <API_TOKEN>' -H 'Content-Type: application/json' \
  -d '{"model":"RED-SNOW-5.3-FLASH-EXL3-2.49","stream":true,"messages":[{"role":"user","content":"你好"}]}'
```

`GET /health` 也要带 Bearer，返回里有 `image_version` 和 `git_commit`，用来确认远端跑的是哪一版。加载期间请求返回 503 `model is still loading`。

## 接入

### API

| 项 | 值 |
|---|---|
| 协议 | OpenAI Chat Completions |
| 路径 | `GET /v1/models`、`GET /v1/models/{id}`、`POST /v1/chat/completions`、`GET /health`（无 `/v1` 前缀的同名路径也可用） |
| 模型名 | `RED-SNOW-5.3-FLASH-EXL3-2.49` |
| 鉴权 | `Authorization: Bearer <API_TOKEN>`，所有路径都要，错误返回 401 |
| 并发 | 同时只处理 1 个请求，其余排队 |

支持：

- 角色 system / developer（按 system）/ user / assistant / tool；流式（可加 `stream_options.include_usage`）和非流式。
- 工具调用，含流式参数拼接；`tool_choice` 支持 auto、required、指定函数（后两者服务预填函数名，模型必定调用）。
- `response_format` 的 `json_object` 和 `json_schema`：靠系统指令引导，没有受限解码，不保证输出合法 JSON。
- 图片：user 和 tool 消息里的 `image_url`，data URI 或 http(s)，单张上限 20 MiB；需要 `VISION=1`（默认），`VISION=0` 时带图请求返回 400。
- 思考：请求带 `chat_template_kwargs.enable_thinking=true`，或带 `reasoning_effort`（`none`、`minimal` 除外）且没显式给 `enable_thinking`，思考内容在 `reasoning_content`。默认不思考。
- 采样参数没给时用模型 `generation_config.json`：temperature 0.7、top_p 0.95、min_p 0。

不支持，返回 400：`n>1`、`logprobs`。没有 `/v1/completions`、`/v1/responses`、`/v1/embeddings`。这些能力来自 `server.patch`（打在钉死的上游服务层提交上），官方 openai Python SDK 17 项兼容检查全过（`handoff/scripts/compat.py`）。

### opencode

`~/.config/opencode/opencode.json`，`baseURL` 换成横幅里的 Base URL，`apiKey` 从环境变量 `API_TOKEN` 读：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "redsnow": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "RED-SNOW",
      "options": { "baseURL": "<BASE_URL>", "apiKey": "{env:API_TOKEN}" },
      "models": {
        "RED-SNOW-5.3-FLASH-EXL3-2.49": {
          "name": "RED-SNOW 5.3 Flash",
          "tool_call": true, "reasoning": true, "attachment": true,
          "modalities": { "input": ["text", "image"], "output": ["text"] },
          "limit": { "context": 230000, "output": 32000 }
        }
      }
    }
  },
  "model": "redsnow/RED-SNOW-5.3-FLASH-EXL3-2.49"
}
```

`limit.context` 230000 / `limit.output` 32000 是推荐值，让自动压缩提前到约 197K、给单步工具输出留余量，这组值未单独验证。已实测的配置是 `max_tokens` 32000：opencode 在约 229K 自动压缩，17 轮到 231,572 token 无 4xx。opencode 把工具读到的图片放进新的 user 消息而不是 tool 消息；标题生成请求带 `reasoning_effort: low`，会开思考。

### 上下文与串流限制

- 上下文由 `CACHE_SIZE` 决定（默认 262144），输入 token 加 `max_tokens` 超过就返回 400，服务不会裁剪提示词。客户端要在接近上限前自己压缩，`max_tokens` 建议不超过 32000。
- 经 Cloudflare 访问必须 `stream: true`：非串流请求超过 100 秒会被 Cloudflare 返回 524。首 token 随提示长度线性增长（25 万 token 约 6 分钟），长提示更要串流。

## 环境变量

必填只有 `API_TOKEN`。完整模板见 `.env.example`。部署表单里留空 = 使用默认值。

| 变量 | 默认 | 作用 |
|---|---|---|
| `API_TOKEN` | 必填 | 认证代理的 Bearer 值；启动时只记"已设置"，不打印 |
| `MODEL_DIR` | `/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw` | 唯一模型目录，不会去别的路径找。目录完整 = 有 `tokenizer_config.json`、`model.safetensors.index.json` 和索引列出的每个分片。默认路径必须是挂载点；其他路径不检查 |
| `MODEL_DOWNLOAD` | `1` | 目录不完整时是否下载。`0` 则不下载、不起推理，sshd 和代理继续（先测 SSH 和端口用）。只接受 0/1 |
| `MODEL_REPO` | `vcruz305/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw` | 下载的 Hugging Face 仓库 |
| `MODEL_REVISION` | `071adefe6c1c8de379d76977985811b7d4385454` | 下载的修订 |
| `MODEL_DOWNLOAD_WORKERS` | `8` | 同时下载的文件数；单文件内部另有 Xet 并发。已完成分片下次跳过，未完成的块留在模型目录 `.hf-cache`，中断后接着传；网络错误退避重试，磁盘满则停 |
| `GPU_SPLIT_GB` | 空，实际用 `112` | 显存切分（`-gs`），对齐上游 `serve.sh`；填了才覆盖 |
| `CACHE_SIZE` | `262144` | KV 缓存和 `--max-model-len`（token）。KV 启动时一次分配，上下文变长不涨内存 |
| `NUM_DRAFT_TOKENS` | `2` | MTP 草稿 token 数 |
| `MAX_ACTIVE_REQUESTS` | `1` | 并发槽位数：同时生成的请求数，其余排队；正整数。`-ambs` 同值，加载时按它预留内存。默认 1；调大会多占内存，性能对比见实测（待补） |
| `VISION` | `1` | `1` 加载视觉塔，接受 `image_url`；`0` 省内存，带图请求返回 400 |
| `MAX_IMAGE_TOKENS` | 空，处理器默认 8000 | 单图 token 上限，正整数；越大越吃统一内存 |
| `PROXY_PORT` | `8898` | 认证代理端口，监听 `0.0.0.0` |
| `SERVE_PORT` | `8899` | 推理端口，只听 `127.0.0.1`，无鉴权，不要映射、不要放进隧道目标 |
| `PROXY_TIMEOUT` | `7200` | 代理到推理的超时（秒），正整数 |
| `METRICS_INTERVAL` | `60` | 容器日志里一行 GPU / 内存 / 进行中请求 / 公网地址指标的间隔（秒），`0` 关闭 |
| `CF_TUNNEL` | `1` | `1` 用 cloudflared 把认证代理暴露到公网，`0` 关闭。只指向 `PROXY_PORT` |
| `CF_TUNNEL_TOKEN` | 空 | 空 = 匿名 trycloudflare 隧道；填 Cloudflare 具名隧道 token 则走具名隧道。token 只进子进程环境变量，不上命令行、不进日志 |
| `SSH_PUBLIC_KEY` | 平台注入 | 写入 root 的 `authorized_keys`；Vast 传入账号 SSH Keys 里的公钥，一般不用自己填 |
| `SSH_USER` | `tunnel` | 隧道用户名：小写字母开头，不能是 `root` |
| `SSH_PASSWORD` | 空 | 隧道用户的密码（至少 12 字符，不能含换行）。空则该用户不能用密码登录 |
| `SSH_USER_PUBLIC_KEY` | 空 | 隧道用户的公钥，可与密码并用。`SSH_PASSWORD` 和它都空时不创建隧道用户 |
| `SSH_TUNNELS` | 空，等于 `127.0.0.1:$PROXY_PORT` | 隧道用户允许转发的目标，逗号分隔，最多 16 个 |
| `EASYTIER_NETWORK_NAME` | 空 | EasyTier 网络名；与 `EASYTIER_NETWORK_SECRET` 都填才启动，都空则不启动，只填一个则启动时 warn 并不启动 |
| `EASYTIER_NETWORK_SECRET` | 空 | EasyTier 网络密钥，不进日志，不写入 `/etc/environment` |
| `EASYTIER_PEERS` | 空 | 逗号分隔，`tcp://host:port` 或 `udp://host:port`，格式不对启动即退出。空则只监听 tcp/udp 11010 等别人来连。peer 要填公网可达地址，填 `127.0.0.1` 无效 |
| `EASYTIER_IPV4` | 空 | 固定虚拟网地址（如 `10.144.144.2/24`）；空则 DHCP |
| `EASYTIER_HOSTNAME` | `redsnow` | EasyTier 节点名 |
| `EASYTIER_PRIVATE_MODE` | `1` | `1` 私有模式，密钥不同的节点连入会被拒绝；`0` 关闭。只接受 0/1 |

入口把以上 `EASYTIER_*` 映射成 `easytier-core` 自己读取的 `ET_*`，用户侧不再使用 `ET_*`。容器没有 `/dev/net/tun` 和 `CAP_NET_ADMIN`，所以只能 no-tun：节点拿到虚拟 IP 后，其它节点才能经虚拟 IP 访问 `PROXY_PORT`；没有虚拟 IP 的节点只转发、不可达。入口常驻每 5 秒读取一次虚拟 IP，写入 `/run/redsnow/easytier_ip`，并在就绪横幅和指标行里显示。DHCP 需要先连上至少一个活的同网节点才分配虚拟 IP；入网后日志打印 `EasyTier 已入网` 横幅，晚入网也会补打。peer 连接失败日志默认不输出。

镜像内固定、可用环境变量覆盖的两项：`EXL3_UMA=1`（exllamav3 按 `MemAvailable` 判断内存余量，页缓存可回收，新下载完权重后可直接加载；设 `0` 回到 CUDA 空闲显存检查，空闲比切分少 2 GiB 以上会加载失败）和 `TRITON_PTXAS_PATH=/usr/local/cuda/bin/ptxas`。启动后运行参数写入容器内 `/etc/environment`（权限 600）。入口不接受启动参数。

## 访问方式

| 方式 | 地址 | 说明 |
|---|---|---|
| Cloudflare 匿名隧道（默认） | `https://<随机>.trycloudflare.com` | 每次重启地址都变，无可用性保证，同时最多 200 个请求。HTTPS |
| Cloudflare 具名隧道 | 你自己的主机名 | 设 `CF_TUNNEL_TOKEN`；在 Cloudflare 控制台把服务地址填成 `http://localhost:8898` |
| Vast 直连 | `http://<PUBLIC_IPADDR>:<VAST_TCP_PORT_8898>` | 外部端口随机，启动日志的 `Vast API` 行给出；HTTP 明文，token 会明文传输 |
| SSH 隧道 | `http://127.0.0.1:8898`（本机转发） | 见下 |
| EasyTier | 虚拟 IP + `PROXY_PORT`（同网节点） | 设 `EASYTIER_NETWORK_NAME` 和 `EASYTIER_NETWORK_SECRET`；虚拟 IP 见横幅的 `EasyTier` 行；鉴权与其他方式相同 |

所有方式都要 Bearer。就绪横幅优先给隧道地址，Vast 直连作为备用 URL。

### SSH

- root 只认公钥（`PermitRootLogin prohibit-password`，全局禁用密码登录）。ENTRYPOINT 模式下 Vast 只注入账号级 SSH Keys，不注入单实例附加的公钥，所以公钥要加到账号的 SSH Keys。
- 密码登录只对隧道用户（`SSH_USER`，默认 `tunnel`），免密码 sudo：登录后 `sudo -i` 即 root。该用户的 sshd 配置只允许本地转发，只能转到 `SSH_TUNNELS` 列出的目标。
- 连接用直连，不走 `sshN.vast.ai` 代理。sshd 每 30 秒探测，连续 10 次无回应才断开。

```bash
ssh -p <VAST_TCP_PORT_22> root@<PUBLIC_IPADDR> -o ServerAliveInterval=30
ssh -N -L 8898:127.0.0.1:8898 tunnel@<主机>      # 然后本机访问 http://127.0.0.1:8898/v1
```

镜像内的监控工具：`nv-monitor`（GB10 专用，统一内存下仍能区分应用占用和页缓存，另有功耗、温度、时钟；无界面采样 `nv-monitor -n -l /tmp/gpu.csv -i 1000`）、`dgxtop`、`btop`、`htop`、`ncdu`、`tmux`。GB10 上 `nvidia-smi` 的显存一栏是 N/A。

### 备用部署：SSH 模式 + On-start

Vast 注入 sshd，On-start 启动入口：

```bash
setsid nohup /opt/redsnow/entrypoint.sh > /var/log/redsnow.log 2>&1 < /dev/null &
```

Ports 加 `8898`，环境变量照常填，日志在 `/var/log/redsnow.log`。入口发现 sshd 已在运行时只让它重读配置，不再自己起。个别 GB10 主机在此模式下停在 `docker_build() error writing dockerfile`，换 Ubuntu 也一样，换主机。

### GPUtw

用自订映像，`sshEnabled` 打开，不开 Web UI；平台要求容器自己听 22。`customImage.env` 最多 32 项，不要填 `PUBLIC_KEY`、`GATEWAY_KEY`、`NVIDIA_VISIBLE_DEVICES`、`NVIDIA_DRIVER_CAPABILITIES`（平台拒绝）。镜像 tag 必须是具体版本，GPUtw 拒绝 `latest`。

## 实测性能与限制

测试机：DGX Spark（GB10），`NUM_DRAFT_TOKENS=2`，thinking 关。

| 提示 token | 首 token | 预填 tok/s | 大海捞针 |
|---|---|---|---|
| 12,144 | 21.9 s | 554 | OK |
| 48,523 | 74.8 s | 648 | OK |
| 99,047 | 148.5 s | 667 | OK |
| 200,687 | 299.5 s | 670 | OK |
| 249,761 | 378.4 s | 660 | OK |

- 预填约 660 tok/s（GPU 跑满 96%），不随长度明显变化，首 token 随提示线性增长。
- 前缀缓存有效：同一份约 9.4 万 token 文档，第二次起换问题或追问，首 token 约 0.8 s。
- 解码：写代码 33–34 tok/s（MTP 接受率 0.86–0.89）；接近 25 万 token 时 19–26 tok/s。
- 只有 1 个并发槽：4 个请求排队执行，总吞吐约 25 tok/s。
- `NUM_DRAFT_TOKENS=3` 写代码快约 5%，但接受率降到 0.73–0.80，默认维持 2。预填 `chunk_size` 提到 8192 会让长提示失败（`Generator drained`），维持 4096。

内存边界（`MAX_IMAGE_TOKENS` 默认 8000，cgroup `memory.events` 全程 oom=0）：

| 测试 | prompt token | 耗时 | MemAvailable 最低 |
|---|---|---|---|
| 单张 2400×1600 密集文字图 | 5,188 | 13.7 s | 6.82 GB |
| 同一请求 3 张大图 | 15,179 | 31.1 s | 6.32 GB |
| 1 张大图 + 约 25 万 token 大海捞针 | 254,763 | 390.5 s | 4.68 GB |

视觉：模型卡称视觉组件未做质量测试；640×400 文字截图识别正确，约 5 s。

真实任务（opencode 驱动，同一任务对比 Claude Sonnet）：

| 任务 | RED-SNOW | Sonnet |
|---|---|---|
| 单模型查询接口 | 276 s，测试过，有重复代码 | 42 s |
| dgxtop 进镜像 | 147 s，测试过，Dockerfile 缺 curl 下载 URL，实际构建会失败 | 52 s，可构建 |

定位：本地模型能完成大部分工作，但慢 3–6 倍且会漏细节，适合它写、人审。

## 构建与发版

镜像由三部分组成：`Dockerfile.kernels`（在 arm64 上编译 exllamav3 的 sm_121 wheel，产物镜像 `ghcr.io/<owner>/redsnow-kernels:<exllamav3 提交>`）、`Dockerfile`（应用镜像，拷贝 wheel，不再编译）、`server.patch`（上游服务层补丁）。基础镜像 `nvcr.io/nvidia/pytorch:26.07-py3` 按摘要钉死，不需要 NGC 密钥。运行时钉死两处提交：exllamav3 `7c1636fe…`，上游服务层 `b96fac22…`（换提交要重做补丁）。EasyTier、nv-monitor、dgxtop、cloudflared 都钉版本和 sha256，许可文本在镜像 `/usr/share/licenses/`。

本地构建（仅 arm64；模拟构建需 `ALLOW_EMULATED_BUILD=1`），产物 `redsnow-exl3:<VERSION>`，不推送：

```bash
./build.sh
```

测试（CI 在推送到 `main` 和 PR 时跑同样的内容）：

```bash
bash -n entrypoint.sh && bash tests/entrypoint_test.sh
for t in tests/test_*.py; do python3 "$t"; done
```

发版：

1. `date -u +%Y%m%d` 取当天日期，改 `VERSION` 为 `YYYYMMDD.N`（当天首发 `.1`，同日递增，跨天重置）；发布时 `IMAGE_VERSION` 由 workflow 从 `VERSION` 传入。
2. 提交并推到 `main`。
3. 在 Actions 手动运行「发布镜像」（`release.yml`，`workflow_dispatch`）：先在 `ubuntu-24.04-arm` 上检查内核镜像标签里的 exllamav3 提交和基础镜像摘要，有变化才重建内核镜像；再核对 `VERSION` 是今天 UTC 的日期；然后 `--no-cache` 构建并推送 `ghcr.io/<owner>/redsnow-exl3:<VERSION>`（所有层重压 zstd，拉取端需 Docker 23+），最后打 `v<VERSION>` 标签。
4. 验证远端：`GET /health` 的 `image_version` / `git_commit` 要与新版一致，否则说明没生效。

`VERSION` 是版本单一真相源，经 `IMAGE_VERSION` / `GIT_COMMIT` 注入 `/health`。推送只用具体 tag，不用 `latest`。

## 排障

| 现象 | 原因与处理 |
|---|---|
| root 公钥登录被拒 | 平台重建容器时可能把 `/root/.ssh` 写成宿主 uid（如 128:988），sshd 的 StrictModes 拒绝。20261011.4 起入口启动时自动改回 root。ENTRYPOINT 模式下公钥必须在账号级 SSH Keys，`vastai attach ssh` 加到单实例的不会进容器 |
| 密码登录失败 | 只有隧道用户（`SSH_USER`）能用密码，root 不能。要设了 `SSH_PASSWORD` 或 `SSH_USER_PUBLIC_KEY` 才会创建该用户 |
| 524 | 经 Cloudflare 的非串流请求超过 100 秒。改用 `stream: true` |
| 400（上下文） | 输入 token 加 `max_tokens` 超过 `CACHE_SIZE`。客户端提前压缩，调小 `max_tokens` |
| 400（图片） | `VISION=0` 时带图请求会被拒 |
| 503 `model is still loading` | 推理还在加载或已退出。看日志是否出现 `Native API listening` 和就绪横幅 |
| 401 | 缺 Bearer，或 token 不对 |
| 容器 running 但不下载、不起推理 | 默认 `MODEL_DIR` 的 `/models` 不是挂载点。设 `MODEL_DIR=/workspace/models/...` 或挂盘到 `/models` |
| 加载很慢 | 冷加载约 4 到 6 分钟，权重已在页缓存时约 1 分钟。新机还要先下载 97 GiB（约 6 分钟，可 `MODEL_DOWNLOAD_WORKERS` 调线程） |
| 加载失败 | 先看空闲内存和 `GPU_SPLIT_GB`，不要先把 `CACHE_SIZE` 降到 131072。容器里（Vast 为 gVisor）通常写不了 `/proc/sys/vm/drop_caches`，靠 `EXL3_UMA=1` 绕过 |
| `vastai recycle` 后仍是旧配置 | `vastai update instance` 后立刻 recycle 可能用旧配置重建。先 `vastai show instance` 确认 `image_uuid` 和 `extra_env` 已更新 |
| recycle 后权重重新下载 | 重建会清空容器。想保留权重就把 `MODEL_DIR` 放在持久卷 |
| 匿名隧道地址变了 | 重启必变。`cat /run/redsnow/tunnel_url` 或看日志；要稳定地址用具名隧道 |

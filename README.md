# redsnow-spark

Vast.ai 和 GPUtw 上单台 DGX Spark（GB10，linux/arm64）的 RED-SNOW 推理镜像。版本在仓库根目录 `VERSION`。

镜像里只有运行时和入口。权重不进镜像。模型只认一个目录，默认是：

```text
/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw
```

把以后买的存储挂到 `/models`，文件就在这一层。平台盘不在这里时，用 `MODEL_DIR` 指向那块盘上的同一层目录，例如 GPUtw 的 `/vault/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw`，或 Vast 的 `/workspace/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw`。启动不会再去别的路径找。

这个目录算完整，要同时有 `tokenizer_config.json`、`model.safetensors.index.json`，以及索引 `weight_map` 里的每个分片。齐全就直接加载。不齐全时，`MODEL_DOWNLOAD=1`（默认）把 `vcruz305/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw` 的修订 `071adefe6c1c8de379d76977985811b7d4385454` 下载到这个目录，线程数是 `MODEL_DOWNLOAD_WORKERS`（默认 8）。每个文件内部由 Xet 并发拉取。已完成的分片下次跳过；没下完的块写在同目录的 `.hf-cache`，中断后接着传。网络中断会退避重试，磁盘满了则停。默认路径 `/models` 必须是挂载点，否则不把约 97GiB 写进容器层。`MODEL_DOWNLOAD=0` 时就算目录是空的也不下载，不起推理，22 和认证代理继续，用来先测 SSH 和端口。

运行时钉死两处提交：

- exllamav3 `7c1636fead6b6d802dc3ebf0e7ef02c4e76e9c2f`
- 用法仓库的服务层 `b96fac226d9689c9e574f9b1b491c01d5340030d`

EasyTier 钉在 `v2.6.4` 的 aarch64 发布包，`easytier-core` 和 `easytier-cli` 来自同一个 zip，二进制不改。许可在镜像的 `/usr/share/licenses/easytier/`：上游 LGPL-3.0、它所包含的 GPL-3.0，以及对应源码标签。exllamav3 的 MIT 文本在 `/usr/share/licenses/exllamav3/LICENSE`。服务层四个文件的 MIT 文本在 `/usr/share/licenses/redsnow-server/LICENSE`。NVIDIA 基础镜像自带的许可文件保持原样。

SSH 主机密钥在容器第一次启动时生成，不写进镜像。

## 构建

在 arm64 机器上，于本目录执行：

```bash
./build.sh
```

产物是本地镜像 `redsnow-exl3:` 加 `VERSION` 里的版本号。脚本固定 `--platform linux/arm64`，默认不推送。改入口、代理或 `VERSION` 只重建最后几层。

版本号是当天 UTC 的 `YYYYMMDD.N`。当天第一发是 `.1`，同一天再发才递增。推送镜像只用这个 tag，不用 `latest`。GPUtw 拒绝 `latest`。

推到 `main` 只跑测试。发布要在 Actions 里手动运行「发布镜像」。它先看内核镜像上的 exllamav3 提交和基础镜像摘要，有变化才在 `ubuntu-24.04-arm` 上重建 `ghcr.io/<owner>/redsnow-kernels:<exllamav3 提交>`。应用镜像从这份内核镜像拷贝 wheel，不再在应用构建里编译。然后核对 `VERSION` 的日期是今天，用 `--no-cache` 推到 `ghcr.io/<owner>/redsnow-exl3:<VERSION>`，并打上 `v<VERSION>`。应用镜像的所有层（包括基础镜像的层）都重压成 zstd，主机首次拉取时解压更快；拉取端需要 Docker 23 或更新。基础镜像 `nvcr.io/nvidia/pytorch:26.07-py3` 按摘要钉死，构建不需要 NGC 密钥。

## 部署

镜像入口是 `/opt/redsnow/entrypoint.sh`，不需要启动参数，传了也只打一行日志后忽略。镜像 `EXPOSE 22` 和 `8898`，另外从 NVIDIA 基础镜像继承了 `6006`、`8888`（没有服务在听）。不要映射 `8899`。

Vast 推荐 ENTRYPOINT 模式，用 CLI 建。之前用网页表单建 ENTRYPOINT 模式时报过 `unknown flag --runtime`，CLI 方式没出现。示例（占位符自行替换）：

```bash
vastai create instance <OFFER_ID> --image ghcr.io/xjoker/redsnow-exl3:<VERSION> --disk 150 \
  --env "-e API_TOKEN=<API_TOKEN> -e MODEL_DIR=/workspace/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw -p 22:22 -p 8898:8898" \
  --entrypoint /opt/redsnow/entrypoint.sh --args serve
```

- `--entrypoint` 和非空的 `--args` 都要带。不带 `--args` 时 CLI 默认建成 SSH 模式。`--args` 的内容入口会忽略。
- `--env` 是整串 docker 风格参数，按空格切分，所以变量值里不能有空格。
- 没挂存储时必须设 `MODEL_DIR`，否则 `/models` 不是挂载点，入口不下载、不起推理。
- ENTRYPOINT 模式下 Vast 不注入 sshd，但会传 `SSH_PUBLIC_KEY`（账号 SSH Keys 里的公钥）。入口把它写给 root 并自己起 sshd。`vastai attach ssh` 加到单个实例的公钥不会进容器，要加到账号的 SSH Keys。root 只用公钥；隧道用户用 `SSH_PASSWORD` 登录。
- 外部端口是随机的，启动日志里的 `Vast SSH` 和 `Vast API` 用的是 `PUBLIC_IPADDR` 和 `VAST_TCP_PORT_*`。
- 镜像已在主机缓存时，容器约 20 秒进入 running。新机全流程实测：下载 97 GiB 约 6 分钟，加载约 3 分钟。
- 重建（recycle）会清空容器，权重要重新下载。`vastai update instance` 后马上 recycle 可能仍用旧配置重建；先 `vastai show instance` 确认 image_uuid 和 extra_env 已更新，再 recycle。

备选是 SSH 模式 + On-start。Vast 注入 sshd，入口由 On-start 启动：

```bash
setsid nohup /opt/redsnow/entrypoint.sh > /var/log/redsnow.log 2>&1 < /dev/null &
```

Ports 加 `8898`。环境变量照常填，On-start 能读到。启动日志在 `/var/log/redsnow.log`。入口发现 Vast 的 sshd 已在运行，只让它重读配置，不再自己起。SSH 模式下 recycle 后，Vast 有时把 `/root/.ssh/authorized_keys` 写成宿主 uid（128:988），入口启动时会改回 root。个别 GB10 主机在 SSH 模式下停在 `docker_build() error writing dockerfile`，换 ubuntu 也一样，换一台主机。

SSH 保活：sshd 每 30 秒发一次探测，连续 10 次没有回应才断开。Vast 的 SSH 模式登录后会自动进 tmux，断线重连回到同一个会话。客户端用直连 `ssh -p <VAST_TCP_PORT_22> root@<PUBLIC_IPADDR> -o ServerAliveInterval=30`，不要经过 `sshN.vast.ai` 代理。

GPUtw 照旧用镜像自己的入口。

看机器状态用镜像里的 `nv-monitor`（GB10 专用，统一内存下仍能显示应用实际占用和页缓存，另有 GPU 使用率、功耗、温度、时钟和 GPU 进程），以及 `btop`、`htop`、`ncdu`。GB10 上 `nvidia-smi` 的显存一栏是 N/A。要无界面采样可以用 `nv-monitor -n -l /tmp/gpu.csv -i 1000`。`dgxtop` 是 DGX Spark 用的终端监控，一屏看 GPU、CPU、内存、磁盘和网络，以及占用 GPU 的进程。

GPUtw 用自订映像，`sshEnabled` 打开，不要开 Web UI。平台要求容器自己听 22，入口会起 sshd。`customImage.env` 最多 32 个。不要自己填 `PUBLIC_KEY`、`GATEWAY_KEY`、`NVIDIA_VISIBLE_DEVICES`、`NVIDIA_DRIVER_CAPABILITIES`，平台会拒绝。

可以写进表单的变量是 `.env.example` 里的 25 个。必填只有 `API_TOKEN`。EasyTier 和隧道用户都是填了才启动，留空就跳过。只测 SSH 和端口时设 `MODEL_DOWNLOAD=0`。其余有默认值，表单留空。密钥只放在部署表单里，不进镜像。

构建时的 apt、pip、GitHub、Hugging Face 都用官方主机。国家代码和大陆镜像站会改回 `archive.ubuntu.com`、`ports.ubuntu.com`、`pypi.org`、`github.com`、`huggingface.co`。落到哪台边缘由这些服务自己解析，镜像里不写地区。

入口先听 22，再开认证代理，然后才下载或加载权重。EasyTier 在后台连，不占这条路径。日志出现 `Native API listening` 之后，API 才能调用。容器日志带 UTC 时间和 `[redsnow]`，下载、显存切分、推理退出码都在里面。

推理进程只听 `127.0.0.1:8899`。对外是带 Bearer 的代理，默认 `0.0.0.0:8898`：

- 没配 EasyTier 时，用服务器 IP 和 `8898`。请求头 `Authorization: Bearer <API_TOKEN>`。
- `ET_NETWORK_NAME` 和 `ET_NETWORK_SECRET` 都填：EasyTier peer 起来之后，虚拟网地址的同一个端口也能访问，鉴权相同。默认监听 tcp/udp `11010`；`ET_PEERS` 用逗号分隔，留空就等别人来连。
- 用户 `tunnel` 在镜像里，sudo 免密码。`SSH_PASSWORD` 在启动时写入；不填密码时这个用户不能用密码登录。`SSH_USER_PUBLIC_KEY` 可以同时给。root 只用平台公钥。`SSH_TUNNELS` 留空时只允许转发到 `127.0.0.1:8898`。本机执行 `ssh -N -L 8898:127.0.0.1:8898 tunnel@<主机>`

请求头 `Authorization: Bearer <API_TOKEN>`。模型名 `RED-SNOW-5.3-FLASH-EXL3-2.49`。SSH 登录后这些运行参数在 `/etc/environment`，权限 600。

日志出现 `Native API listening` 后才能调用。加载约 105GB 权重需要大约一分钟，前提是页缓存已经让出来、切分没有超过当时的空闲显存。

`GPU_SPLIT_GB` 留空时用上游 `serve.sh` 的 `112`。加载前丢一次页缓存，加载过程中每 2 秒再丢，直到日志出现 `Native API listening`。容器里通常写不了 `/proc/sys/vm/drop_caches`。刚下载完的权重会占约 88 GiB 页缓存，CUDA 读到的空闲只剩约 40 GiB。镜像默认 `EXL3_UMA=1`，exllamav3 改用 `MemAvailable` 和 cgroup 余量判断，页缓存会被回收，所以新下载后可以直接加载；系统保留默认 8 GiB（`EXL3_UMA_RESERVE_MB`）。设 `EXL3_UMA=0` 会退回 CUDA 空闲显存检查，这种情况下空闲显存比切分少 2 GiB 以上就会加载失败。

默认上下文 `262144`。提示词加上一页余量（256）之后没有输出空间时，服务返回 400，入口不会裁提示词。客户端要在 `prompt_tokens` 达到 `CACHE_SIZE - 256` 之前自己压缩。

加载失败时先看空闲显存和 `GPU_SPLIT_GB`，不是先把上下文改成 131072。`TRITON_PTXAS_PATH` 必须指向认识 `sm_121a` 的 ptxas，镜像里默认是 `/usr/local/cuda/bin/ptxas`。NGC 26.07 这支 ptxas 是否认识 `sm_121a` 还没在这台镜像里跑过；不认识的话，加载会死在 `causal_conv1d_update`。

## Cloudflare 隧道

入口默认用 cloudflared 把认证代理（`PROXY_PORT`，默认 8898）暴露到公网。`CF_TUNNEL=0` 关闭。隧道只指向认证代理，不指向 8899。

- `CF_TUNNEL_TOKEN` 留空：匿名快速隧道。地址是 `https://<随机>.trycloudflare.com`，每次重启都变，没有可用性保证，同时最多 200 个请求。地址打在启动日志里，也写进 `/run/redsnow/tunnel_url`，`cat /run/redsnow/tunnel_url` 即可。
- `CF_TUNNEL_TOKEN` 填自己的具名隧道 token：在 Cloudflare 控制台把公网主机名的服务地址指向 `http://localhost:8898`。token 只走环境变量，不进命令行，不进日志。
- 限制：非串流请求超过 100 秒，Cloudflare 返回 524。客户端用 `stream: true`。

## OpenAI 兼容与多模态

接口是 `/v1/models` 和 `/v1/chat/completions`。流式和非流式都支持，流式时可以加 `stream_options.include_usage`。两个接口都要 `Authorization: Bearer <API_TOKEN>`。

支持的内容：

- 消息角色：system、developer（按 system 处理）、user、assistant、tool。
- 工具调用，包括流式下的参数拼接。`tool_choice` 支持 auto、required 和指定函数。为 required 或指定函数时，服务预填函数名，模型一定会调用。
- `stop`、`max_tokens`、`max_completion_tokens`。
- `response_format` 支持 `json_object` 和 `json_schema`。这靠系统指令引导，**不保证**输出合法 JSON，没有受限解码。
- 思考：请求带 `chat_template_kwargs.enable_thinking=true`，或带 `reasoning_effort`（`none`、`minimal` 除外）且没有显式给 `enable_thinking` 时开启。思考内容在 `reasoning_content`。默认不思考。
- 采样参数没给时，用模型的 `generation_config.json`：temperature 0.7、top_p 0.95，min_p 为 0。

图片：user 和 tool 消息里的 `image_url` 支持 data URI 和 http(s) 地址，单张上限 20 MiB。

- 环境变量 `VISION`（默认 `1`）控制是否加载视觉部分。设为 `0` 时，带图请求返回 400。
- `MAX_IMAGE_TOKENS` 留空时用处理器默认值 8000。
- `METRICS_INTERVAL` 留空时每 60 秒往容器日志写一行指标（GPU、内存、进行中请求、公网地址）。设为 `0` 关闭。
- 模型卡说明视觉组件未做质量测试。实测一张 640×400 的文字截图，识别正确，约 5 秒。

不支持的请求返回 400，不伪造结果：`n` 大于 1、`logprobs`。没有 `/v1/completions`、`/v1/responses`，也没有 `/v1/embeddings`（这不是嵌入模型）。

用官方 openai Python SDK 跑过 17 项兼容检查，全部通过。

## 接 opencode

在 `~/.config/opencode/opencode.json` 里加 provider。`baseURL` 换成实际地址，`apiKey` 从环境变量 `API_TOKEN` 读取：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "redsnow": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "RED-SNOW",
      "options": { "baseURL": "http://<主机>:<8898 映射端口>/v1", "apiKey": "{env:API_TOKEN}" },
      "models": {
        "RED-SNOW-5.3-FLASH-EXL3-2.49": {
          "name": "RED-SNOW 5.3 Flash",
          "tool_call": true, "reasoning": true, "attachment": true,
          "modalities": { "input": ["text", "image"], "output": ["text"] },
          "limit": { "context": 262144, "output": 32768 }
        }
      }
    }
  },
  "model": "redsnow/RED-SNOW-5.3-FLASH-EXL3-2.49"
}
```

opencode 会把工具读到的图片放进一条新的 user 消息，不放在 tool 消息里。标题生成请求带 `reasoning_effort: low`，补丁之后会开思考。

实测两轮写代码任务用时 52 s 和 19 s，测试全过；读图任务 29 s，结果正确。

## 实测对速度的含义

数据来自 DGX Spark（GB10），`NUM_DRAFT_TOKENS=2`，thinking 关。

| 提示 token | 首 token | 预填 tok/s | 大海捞针 |
|---|---|---|---|
| 12,144 | 21.9 s | 554 | OK |
| 48,523 | 74.8 s | 648 | OK |
| 99,047 | 148.5 s | 667 | OK |
| 200,687 | 299.5 s | 670 | OK |
| 249,761 | 378.4 s | 660 | OK |

- 预填在 GPU 跑满（96%）时约 660 tok/s。4.8 万 token 以上在 648–670 之间，1.2 万 token 时为 554。
- 预填速度基本不随长度变化，所以首 token 随提示长度线性增长。25 万 token 约 6 分钟。提示越短，响应越快。
- 前缀缓存有效。同一份约 9.4 万 token 的文档，第二次起换问题或多轮追问，首 token 约 0.8 s。
- 解码：写代码 33–34 tok/s（MTP 接受率 0.86–0.89）。接近 25 万 token 时为 19–26 tok/s。
- 服务同时只处理一个请求，并发会排队。4 个请求排队执行时，总吞吐约 25 tok/s。

### 调参结论

- `NUM_DRAFT_TOKENS=3`：写代码快约 5%，但 MTP 接受率从 0.86–0.89 降到 0.73–0.80。默认维持 2。
- 预填 `chunk_size` 提到 8192 会让长提示请求失败（报 `Generator drained`）。维持 4096。

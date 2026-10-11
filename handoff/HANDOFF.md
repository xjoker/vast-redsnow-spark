# 交接

给接手的 AI 或工程师。部署、变量、接入方式见 `README.md`，这里只记当前状态、已验证结论、坑和未完成事项。

## 当前状态

- 镜像 `ghcr.io/xjoker/redsnow-exl3:20261011.10`（`VERSION`）。Vast ENTRYPOINT 模式（CLI 建实例）开机自动下载、加载，就绪后打印给 AI 用的接入横幅；匿名 Cloudflare 隧道、EasyTier、定时指标都在镜像里。
- 20261011.8–.10 在两台 GB10 上实测：MemTotal 121.6 GiB 的 151363 和 119.6 GiB 的 146927 都是冷启动一次加载成功，官方 openai SDK 17 项兼容检查全过（146927 走 Vast 直连，151363 走隧道）。
- EasyTier 两节点实测：三条 peer 中公网回环那条不通也能入网；两节点同时 DHCP 撞 IP 后自动换开；经虚拟 IP 访问对方 8898，无 token 401、带 token 正常；peer 全死时 EasyTier 不打日志，只有入口在 60 秒提示一次。
- 上游生成线程遇 OOM 只让相关请求返回 503 `out_of_memory`，服务保持健康（146927 上用 8 GiB 预留复现过）。
- 发版用 `release.yml` 手动触发；`main` 上 CI 跑 `tests/`。

## 约束（沿用）

- 不提交密钥、实例地址、token；不 force push；`git push`、`docker push`、删实例、删文件前先问用户。
- 版本号 `YYYYMMDD.N`，bump 前先跑 `date -u`。
- 不换 vLLM / llama.cpp；权重不进镜像；exllamav3 钉 `aa86ccd7…`（vcruz305 fork）。
- 上游服务层（Weschera 仓库，`SERVER_REF=b96fac22…`）不直接改文件，改动全放 `server.patch`，Dockerfile 在 clone 后 `git apply`，只动 `protocol.py`、`serve_glm.py` 和 `worker.py`。换 `SERVER_REF` 要重做补丁。
- 仓库文档和注释用简体中文。

## 已验证结论

以下都是真实测量，机器是 Vast 上的 DGX Spark（GB10），`NUM_DRAFT_TOKENS=2`，thinking 关。

**预填与解码**

| 提示 token | 首 token | 预填 tok/s | 大海捞针 |
|---|---|---|---|
| 12,144 | 21.9 s | 554 | OK |
| 48,523 | 74.8 s | 648 | OK |
| 99,047 | 148.5 s | 667 | OK |
| 200,687 | 299.5 s | 670 | OK |
| 249,761 | 378.4 s | 660 | OK |

- 预填约 660 tok/s 是 GPU 跑满（96%）时的速度；前缀缓存有效，同一份 9.4 万 token 文档第二次起首 token 0.8 s。
- 解码：写代码 33–34 tok/s（MTP 接受率 0.86–0.89），接近 25 万 token 时 19–26 tok/s。
- 并发槽默认 1（`MAX_ACTIVE_REQUESTS` 可调）。总吞吐 24–31 tok/s 不随槽数变；4 槽时单请求降到 9–10 tok/s。262K 缓存配 2 槽时 2×60K 起 CUDA OOM，配 4 槽时 4×32K 就 OOM；4 槽配 `CACHE_SIZE=131072`：4×60K 因页池错开预填而通过，4×32K 两次一过一挂（边缘）；短请求配 `NUM_DRAFT_TOKENS=1` 单请求 13–15 tok/s、总吞吐约 30 tok/s。OOM 只让当次请求 503，worker 不再整体失效（`server.patch` 改了 worker.py）。完整表格见 README。
- `NUM_DRAFT_TOKENS=3` 快约 5% 但接受率降到 0.73–0.80，维持 2；预填 `chunk_size` 8192 会 `Generator drained`，维持 4096。
- DFlash2 草稿器（`incoai/GLM-5.3-Flash-DFlash2`，`-dm` 替换 `--mtp`）评估过，不集成。同机同提示（代码、中文、JSON、推理各跑贪心和默认采样，600 token）加权解码：MTP 草稿 2 为 31.8 tok/s（接受率 0.78）；DFlash2 草稿 3/5/7/7 动态分别为 30.9/33.7/30.0/30.4 tok/s（接受率 0.69/0.58/0.46/0.56）。最好只快 6%，与 MTP 草稿 3 相当；加载后多占约 1.5–2 GiB，多下 2.2 GB，许可证 cc-by-nc-nd-4.0。草稿器按原版 GLM-5.3-Flash 训练，在 RED-SNOW 上草稿越长接受率掉得越快，只有短 JSON 输出能到 45–58 tok/s。

**内存（视觉，`MAX_IMAGE_TOKENS` 8000）**

| 测试 | prompt token | 耗时 | 结果 | MemAvailable 最低 |
|---|---|---|---|---|
| 单张 2400×1600 密集文字图 | 5,188 | 13.7 s | 正确 | 6.82 GB |
| 同一请求 3 张大图 | 15,179 | 31.1 s | 全对 | 6.32 GB |
| 1 张大图 + 约 25 万 token 大海捞针 | 254,763 | 390.5 s | 两问都对 | 4.68 GB |

cgroup `memory.events` 全程 oom=0；KV 缓存启动时按 `CACHE_SIZE` 一次分配。载入视觉后空闲时 `MemAvailable` 约 10 GB，GPU 68–79°C，无热降频。

**opencode 与上下文**

- opencode 在约 229K（262144−32768）自动压缩；`max_tokens` 32000 下 17 轮到 231,572 token 无 4xx。
- 两轮写代码任务 52 s + 19 s，测试全过；读图任务 29 s 正确；640×400 测试图约 5 s。
- 推荐 `limit.context` 230000、`limit.output` 32000 **未单独验证**。

**真实任务对比（RED-SNOW vs Claude Sonnet）**

| 任务 | RED-SNOW | Sonnet |
|---|---|---|
| t1：单模型查询接口 | 276 s，测试过，有重复代码 | 42 s |
| t2：dgxtop 进镜像 | 147 s，测试过，Dockerfile 缺 curl 下载 URL，实际构建会失败 | 52 s，可构建 |

结论：慢 3–6 倍且会漏细节，适合它写、人审。

**部署时间**：镜像已在主机缓存时容器约 20 秒 running；下载 97 GiB 约 6 分钟；加载约 3 分钟。

## 已知坑

- 网页表单建 ENTRYPOINT 模式报 `unknown flag --runtime`，必须用 CLI；`--args` 不能为空，否则变成 SSH 模式。
- ENTRYPOINT 模式 Vast 只注入账号级 SSH Keys 对应的 `SSH_PUBLIC_KEY`，`vastai attach ssh` 加到单实例的公钥不进容器。
- `vastai update instance` 后马上 `vastai recycle instance` 可能仍用旧配置；先 `vastai show instance` 确认 `image_uuid`、`extra_env`。
- `vastai update instance --env` 不会删掉创建时就有的变量：`extra_env` 里看不到了，容器里仍是旧值（实测 `MAX_ACTIVE_REQUESTS=4` 删不掉）。要去掉变量就显式设成默认值，或重建实例。
- recycle 会清空容器，权重要重下；SSH 模式 recycle 后 `/root/.ssh/authorized_keys` 有时被写成宿主 uid（128:988），入口已自动改回 root（20261011.4 起）。
- 个别主机在 SSH 模式停在 `docker_build() error writing dockerfile`（换 Ubuntu 也一样），换主机。已知坏：machine 150922；好：151363（日本）。列表上看不出，开机 3 分钟内不 running 就销毁（Loading 不计费）。
- Vast 注入 `CONTAINER_RUNTIME=gvisor`，容器里写不了 `/proc/sys/vm/drop_caches`；新下载的权重占约 88 GiB 页缓存，靠镜像默认 `EXL3_UMA=1`（按 `MemAvailable` 判断）避免加载失败。
- 同为 GB10，内核 6.17.0-1026 的主机（如 146927）MemTotal 119.63 GiB，比 1022 内核的 151363 少 2 GiB。fork 默认 `EXL3_UMA_RESERVE_MB=8192` 下首次加载报 `Insufficient VRAM`，重启后加载成功但第一个请求在 MTP 词表镜像（1.18 GiB）上 OOM。入口按 MemTotal 自动改用 6144：20 万 token 和 6 万 token 加 3 图都过，MemAvailable 最低 2.5 GiB；5120 时只剩 0.55 GiB，预填也变慢。
- SSH 走直连，不走 `sshN.vast.ai`；推理重启、内存大量释放的瞬间网络路径断过一次（sshd 没死）。
- EasyTier 只能 no-tun：容器无 `/dev/net/tun`、无 `CAP_NET_ADMIN`。节点拿到虚拟 IP（DHCP 或 `EASYTIER_IPV4`）后，其它节点才能经虚拟 IP 访问 `PROXY_PORT`；没有虚拟 IP 的节点只转发。`EASYTIER_PEERS` 要填公网可达地址，填 `127.0.0.1` 无效。
- 经 Cloudflare 非串流超 100 秒返回 524；匿名隧道最多 200 个并发请求，地址每次重启都变。
- 认证代理必须用 `read1` 逐块转发，`read` 会攒满 64 KiB 才返回，SSE 被攒住（已修，`c616b86`）。
- 模型卡把该模型定位为攻击性安全模型，工作会话里曾多次被安全分类器中断（写大图测试脚本、读服务层响应代码、复现失败项时），原因不明；大图测试后来用 `handoff/scripts/mem_test.py` 完成。

## 未完成

- OpenAI 缺口（视需求）：`n>1`、`logprobs`（返回 400，不要伪造）、`/v1/completions`、`/v1/responses`。`/v1/embeddings` 不适用。
- `response_format` 没有受限解码（无库），只靠系统指令，不保证合法 JSON。
- opencode 推荐的 `limit.context 230000` 未实测。
- 无其他在途任务。

## handoff/scripts

测试与排查脚本，不进镜像。都假定在实例容器内运行，路径写死 `/root/...`、`127.0.0.1:8899`，Python 脚本只用标准库，`compat.py`、`mem_test.py`、`vtest.py` 另需 Pillow，`compat.py` 还需 `openai`。

| 脚本 | 用途 |
|---|---|
| `bench.py` | 压测：`--tests smoke,tool,ctx,conc`，冒烟、工具调用、上下文扫描（预填/解码速度 + 大海捞针，`--ctx` 名义值约产生 1.5 倍 token）、并发（`--conc`）；`--url` 默认 `http://127.0.0.1:8899`，经代理时加 `--token` |
| `prefix.py` | 同一长文档连问三次，看第二、三次首 token 是否复用前缀缓存；参数为文档 token 数 |
| `compat.py` | 官方 openai SDK 的 17 项兼容检查：`compat.py <base_url> <api_key>` |
| `vtest.py` | 视觉冒烟：本地画图，走 `image_url` data URI，流式和非流式各一次：`vtest.py [url] [token]` |
| `mem_test.py` | 内存边界测试，参数 `A`（单张大图）、`A2`（三张大图）、`B`（视觉 + 长上下文），每项输出一行 JSON；`MEM_URL` 可改地址 |
| `mem_driver.sh` | 依次跑 A / A2 / B，每项前后记录 cgroup `memory.events`，每项后探活，服务不通即停；结果写 `/root/mem_results.jsonl`、`/root/mem_events.log` |
| `capture.py` | 临时抓包代理：听 `127.0.0.1:8897`，记录请求结构（长字符串截短）到 `/root/capture.jsonl` 后原样转发到 8899，用来看客户端（如 opencode）实际发了什么 |
| `vstart.sh` | 用 `/root/vserver` 里的服务层（需自备）和 `/root/redsnow.env` 重启推理，调试 `server.patch` 时不用重建镜像；会先杀掉入口进程 |

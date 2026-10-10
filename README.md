# redsnow-spark

GPUtw 上单台 DGX Spark（GB10，linux/arm64）的 RED-SNOW 推理镜像。版本在仓库根目录 `VERSION`，当前 `20261010.1`。

镜像里只有运行时和入口。权重留在 Vault：

```text
/vault/models/RED-SNOW-5.3-FLASH-EXL3-SAGE-2.49bpw
```

运行时钉死两处提交：

- exllamav3 `7c1636fead6b6d802dc3ebf0e7ef02c4e76e9c2f`
- 用法仓库的服务层 `b96fac226d9689c9e574f9b1b491c01d5340030d`

## 构建

在 arm64 机器上，于本目录执行：

```bash
./build.sh
```

产物是本地镜像 `redsnow-exl3:20261010.1`。脚本固定 `--platform linux/arm64`，默认不推送。推送到 GHCR 时自己指定仓库名：

```bash
IMAGE=ghcr.io/<owner>/redsnow-exl3:20261010.1 ./build.sh --push
```

NGC 基础镜像 `nvcr.io/nvidia/pytorch:26.07-py3` 可能要先 `docker login nvcr.io`。tag 不能用 `latest`，GPUtw 会拒绝。

## 部署

在 GPUtw 选 DGX Spark GB10 128GB，使用自订 Docker 映像：

| 表单项 | 填写 |
|---|---|
| Docker 映像 | `ghcr.io/<owner>/redsnow-exl3:20261010.1` |
| 启用 SSH | 勾选 |
| 映像提供 Web UI | 不勾 |
| 启动引数 | 留空 |

环境变量见 `.env.example`。`API_TOKEN` 和 `TS_AUTHKEY` 只放在部署表单里，不进镜像。部署后不要再开 HTTP 或 raw 端口。

先在 Tailscale 后台打开 HTTPS Certificates。服务地址是 `https://redsnow.<tailnet>.ts.net/v1`，请求头 `Authorization: Bearer <API_TOKEN>`。模型名 `RED-SNOW-5.3-FLASH-EXL3-2.49`。

日志出现 `Native API listening` 后才能调用。加载约 105GB 权重需要数分钟。

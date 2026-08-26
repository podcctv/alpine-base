# Alpine Base 3.24

一套可重复构建的 Alpine 3.24 基础镜像源码，同时产出 **Incus System Container** 和 **Podman OCI** 镜像。

[![Build](https://github.com/podcctv/alpine-base/actions/workflows/build.yml/badge.svg)](https://github.com/podcctv/alpine-base/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/podcctv/alpine-base?label=release)](https://github.com/podcctv/alpine-base/releases)
[![License](https://img.shields.io/github/license/podcctv/alpine-base)](LICENSE)
[![Alpine](https://img.shields.io/badge/Alpine-3.24-blue)](https://www.alpinelinux.org/)
[![GHCR](https://img.shields.io/badge/GHCR-alpine--base-blue)](https://github.com/podcctv/alpine-base/pkgs/container/alpine-base)

## 核心目标

彻底解决 Alpine 镜像经常无法使用 SSH root 密码登录的问题，并把真实密码 SSH 登录纳入发布门禁。

## 特性

- Alpine v3.24，官方支持至 2028-06-01
- 统一 sshd_config：`PermitRootLogin yes` + `PasswordAuthentication yes`
- 镜像不含固定密码、SSH 私钥、Host Key — 每实例独立生成
- Incus 用 distrobuilder 构建 System Container
- Podman 用 Containerfile 构建 OCI Image
- GitHub Actions CI 自动验证 + GHCR 推送
- 打 tag 自动创建 GitHub Release 并分发 Incus 镜像

## 仓库结构

```
alpine-base/
├── VERSION                    # Alpine 主版本 (3.24)
├── .gitignore
├── .gitattributes             # 强制脚本 LF 行尾
├── common/
│   ├── packages.txt           # 基础软件包清单
│   ├── sshd_config            # 统一 OpenSSH 策略
│   └── setup-base.sh          # 基础初始化与镜像清理
├── incus/
│   └── image.yaml             # distrobuilder 定义
├── podman/
│   ├── Containerfile          # OCI 构建定义
│   └── entrypoint.sh          # OCI 启动逻辑
├── scripts/
│   ├── build-incus.sh         # 构建 Incus 镜像
│   ├── build-podman.sh        # 构建 OCI 镜像
│   ├── build-all.sh           # 一键构建两种镜像
│   ├── generate-streams.py    # Incus 镜像 → simple-streams 树
│   ├── serve-incus.sh         # 一键生成 + Docker 启动镜像源
│   ├── test-ssh.sh            # SSH 密码登录发布门禁
│   └── release.sh             # 发布 stable
├── incus-server/              # 自建 Incus 镜像仓库 (Docker)
│   ├── Dockerfile
│   ├── nginx.conf
│   ├── docker-compose.yml
│   └── www/                   # 生成的 simple-streams 树 (gitignore)
├── docs/
│   └── versioning.md          # 版本和回滚规范
├── .github/workflows/
│   └── build.yml              # CI 自动构建与验证
└── output/                    # 构建产物 (gitignore)
```

## 安全原则

基础镜像**不保存**以下任何内容：

- 固定 root 密码
- SSH 私钥
- Host Key
- WireGuard 私钥
- API Token
- 机器唯一标识 (`machine-id`)

每个新实例在首次启动时通过 `ssh-keygen -A` 生成独立 Host Key；root 密码由实例创建者单独设置。

## 快速开始

### Incus (System Container)

```bash
# 构建
./scripts/build-incus.sh

# 导入 Image Store
incus image import output/incus/incus.tar.xz output/incus/rootfs.squashfs \
  --alias alpine/3.24-test

# 启动实例
incus launch alpine/3.24-test alpine-ssh-test

# 设置 root 密码
PASS='YourStrongPassword'
printf 'root:%s\n' "$PASS" | incus exec alpine-ssh-test -- chpasswd

# 生成 Host Key
incus exec alpine-ssh-test -- ssh-keygen -A
incus exec alpine-ssh-test -- rc-service sshd restart

# 验收
./scripts/test-ssh.sh incus alpine-ssh-test "$PASS"

# 验收通过后发布 stable
./scripts/release.sh v1.0.0
```

### Podman (OCI)

```bash
# 构建
./scripts/build-podman.sh

# 启动测试容器
printf '%s' 'YourStrongPassword' > /tmp/root_password
podman secret create alpine_root_password /tmp/root_password
podman run -d --name alpine-test -p 2222:22 \
  --secret alpine_root_password,target=root_password \
  localhost/alpine-base:3.24-test

# SSH 测试
ssh -p 2222 -o PreferredAuthentications=password -o PubkeyAuthentication=no root@127.0.0.1
```

## 版本规则

| 类型 | 格式 | 说明 |
|------|------|------|
| Alpine stable | `3.24` | 滚动稳定 tag |
| `latest` | `latest` | 每次 `main` 构建的最新镜像，方便测试 |
| 不可变版本 | `3.24-v1.0.0` | 不可变制品，生产推荐 |
| Git Tag | `v1.0.0` | 与不可变镜像对应，触发 Release |

详见 [docs/versioning.md](docs/versioning.md)。

## 发布门禁

只有 [SSH 验收](scripts/test-ssh.sh) 中全部 P0 项通过，才能提升为 stable：

1. `sshd -t` 语法通过
2. `PermitRootLogin yes`
3. `PasswordAuthentication yes`
4. root 未锁定且有密码
5. sshd 在 OpenRC 中
6. TCP/22 监听
7. 真实密码 SSH 登录成功
8. 重启后仍可 SSH
9. Host Key 每实例唯一
10. `PermitEmptyPasswords no`

## 技术栈

- [Alpine Linux 3.24](https://www.alpinelinux.org/)
- [distrobuilder](https://github.com/lxc/distrobuilder)
- [Incus](https://linuxcontainers.org/incus/)
- [Podman](https://podman.io/)
- [GitHub Actions](https://docs.github.com/en/actions)
- [GHCR](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

## 使用生成的镜像

### Podman / OCI（从 GHCR 拉取）

每次 `main` 分支 push 或打 `v*` tag 推送后，CI 会自动把镜像推到 GHCR：

```bash
# latest（最方便，始终指向最新构建）
podman pull ghcr.io/podcctv/alpine-base:latest

# 滚动稳定版（固定 Alpine 大版本）
podman pull ghcr.io/podcctv/alpine-base:3.24

# 不可变版本（可追溯到具体构建，推荐生产使用）
podman pull ghcr.io/podcctv/alpine-base:3.24-v1.0.0
```

> 仓库已设为 Public，但 GHCR 包的可见性**独立于仓库**。要让别人免登录拉取，仍需在
> GitHub → Packages → alpine-base → Settings 里把可见性改为 Public；
> 否则拉取方要用有 `read:packages` 权限的 token 登录 `ghcr.io`。

不想/不能走 GHCR 时，也可以直接从 Release 下载 Podman 镜像 tar 包：

```bash
# 下载最新 main 分支的 continuous 构建（无需任何登录）
curl -fSL -O https://github.com/podcctv/alpine-base/releases/download/continuous/alpine-base-3.24-podman.tar

# 加载到本地 Podman
podman load -i alpine-base-3.24-podman.tar

# 启动（密码通过 secret 注入，不烧进镜像）
printf '%s' '你的强密码' > /tmp/root_password
podman secret create alpine_root_password /tmp/root_password
podman run -d --name alpine -p 2222:22 \
  --secret alpine_root_password,target=root_password \
  localhost/alpine-base:3.24-test
```

或从 GHCR 拉取（需要 GHCR 包 Public 或登录）：

```bash
printf '%s' '你的强密码' > /tmp/root_password
podman secret create alpine_root_password /tmp/root_password
podman run -d --name alpine -p 2222:22 \
  --secret alpine_root_password,target=root_password \
  ghcr.io/podcctv/alpine-base:3.24
```

> **Release 资产速查**
>
> | 产物 | Release tag | 用途 |
> |---|---|---|
> | `alpine-base-3.24-podman.tar` | `continuous` / `v*` | `podman load -i` 直接加载 |
> | `incus.tar.xz` + `rootfs.squashfs` | `continuous` / `v*` | `incus image import` |
> | `incus-streams.tar.gz` | `continuous` / `v*` | 自建 simple-streams 镜像源 |

### Incus（从 Release 产物或 CI 产物导入）

Incus 是 System Container，**不进 GHCR**（GHCR 只存 OCI 镜像）。两种方式获取：

- **Release 资产**：到 [Releases](https://github.com/podcctv/alpine-base/releases) 下载 `incus.tar.xz` + `rootfs.squashfs`
- **CI 产物**：到 Actions → 最新 `Build Incus Image` → 下载 `alpine-3.24-incus`

导入到本机 Incus：

```bash
incus image import incus.tar.xz rootfs.squashfs --alias alpine/3.24-test
incus launch alpine/3.24-test my-vm
printf 'root:%s\n' '你的强密码' | incus exec my-vm -- chpasswd
```

需要对外分发 Incus 镜像时，用下面介绍的**自建镜像仓库**，不要混用 GHCR。

## Incus 镜像仓库（自建镜像源，Docker 部署）

Incus 使用 **simple-streams** 协议拉取镜像，本仓库内置了一个静态镜像源，
用 Docker 一键跑起来后，任何 Incus 主机都能像用官方源一样 `incus launch`。

镜像源本质是一个静态文件树（`streams/v1/index.json` + 镜像文件），由
`scripts/generate-streams.py` 从构建产物生成，再用 nginx 通过 HTTP 提供。

### 1. 生成 simple-streams 树

```bash
# 需要已构建的 output/incus/incus.tar.xz + rootfs.squashfs
./scripts/generate-streams.py \
  --input-dir output/incus \
  --output-dir incus-server/www
```

CI 在每次 `Build Incus Image` 时也会自动生成，并作为
`alpine-3.24-incus-streams` 产物 / Release 的 `incus-streams.tar.gz` 提供。
下载解压到 `incus-server/www` 即可：

```bash
tar -xzf incus-streams.tar.gz -C incus-server/www
```

### 2. Docker 一键启动

```bash
cd incus-server
docker compose up -d --build
```

服务监听 `:8080`，根路径提供 `/streams/v1/index.json`。
（`scripts/serve-incus.sh` 把「生成 + 启动」合成一步。）

> 没装 Docker 也行：直接 `python3 -m http.server 8080 --directory incus-server/www`
> 或任意静态服务器，只要 `http://<host>:8080/streams/v1/index.json` 可达。

### 3. 客户端添加镜像源并启动

在**任意 Incus 主机**上：

```bash
# 添加为 simplestreams 镜像源
incus remote add alpine-base http://<镜像源主机>:8080 --protocol=simplestreams

# 直接启动（alias: alpine/3.24）
incus launch alpine-base:alpine/3.24 my-instance

# 设置 root 密码 + 生成独立 Host Key
printf 'root:%s\n' '你的强密码' | incus exec my-instance -- chpasswd
incus exec my-instance -- ssh-keygen -A
incus exec my-instance -- rc-service sshd restart

# SSH 登录
ssh root@<实例IP>     # IP 用 incus list 查
```

### 4. 更新镜像

重新构建 → 重新生成树 → 重启服务即可，客户端下次 `incus launch` 自动拿到新版本：

```bash
./scripts/build-incus.sh
./scripts/serve-incus.sh        # 生成 + docker compose up -d
```

> 安全提示：镜像源默认 **HTTP 且未签名**。内网/自用没问题；要公网暴露建议
> 套一层 HTTPS 反向代理，并给 `images.json` / `index.json` 做 GPG 签名
> （simple-streams 原生支持，参数见 `generate-streams.py --help`）。

## 维护节奏

| 频率 | 动作 |
|------|------|
| 每月 | `git pull` → `./scripts/build-all.sh` → `test-ssh.sh` → `release.sh` |
| 出现 CVE | 立即重构建 + 完整 SSH 验收 + 发 patch 版本 |
| 升级大版本 | 3.24 → 3.25 时**新建独立 alias/tag**，不要覆盖 3.24 |

## License

[MIT](LICENSE)

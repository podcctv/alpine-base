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
- Incus 镜像内置 OpenRC + cloud-init，启动时可注入密码、静态 IPv4/IPv6 和 SSH 配置
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

## 一键 Docker 部署与更新

对外提供 `alpine-base` 的 Incus 镜像源（simple-streams）只需一两条命令，且**支持幂等更新**：
`scripts/serve-incus.sh` 会自动准备镜像树（优先用已生成的 `incus-server/www`，
其次本地 `output/incus` 构建产物，最后回退到 GitHub Release 的 `incus-streams.tar.gz`），
再用 Docker 启动 nginx 静态源。`incus-server/www` 以只读卷挂载进容器，
因此「更新镜像」= 更新镜像树 + 重建容器，无需重建 nginx 镜像。

### 首次部署（一键）

```bash
git clone https://github.com/podcctv/alpine-base.git
cd alpine-base
./scripts/serve-incus.sh          # 取镜像树 + docker compose up -d --build --force-recreate
```

部署完成后本地 `http://localhost:8080/streams/v1/index.json` 即为镜像源入口。

### 更新（一键）

```bash
git pull
./scripts/serve-incus.sh --download   # 强制拉取 main 的 continuous 镜像树并重建容器
```

需要固定到稳定版本时可显式指定 tag：

```bash
./scripts/serve-incus.sh --download --release-tag v1.0.0
```

也可用环境变量 `ALPINE_BASE_RELEASE_TAG=v1.0.0`。默认使用 `continuous`；GitHub 的
`releases/latest` 会忽略 prerelease，因此不适合用于获取随 `main` 滚动更新的镜像。

- 已有本地构建产物（`output/incus` 或已生成的 `incus-server/www`）时，直接
  `./scripts/serve-incus.sh` 即可；脚本会复用已有镜像树、仅重建容器（幂等）。
- 重新构建了 Incus 镜像后想对外生效：`build-incus.sh` → `serve-incus.sh` 一条龙即可。
- 仅更新镜像树（不重拉容器也可）：`docker compose -f incus-server/docker-compose.yml up -d --force-recreate`。

### 停服

```bash
./scripts/serve-incus.sh --stop
```

### 不依赖仓库的一键起（仅用 Release 资产）

若只是想快速起一个镜像源、不想 clone 整个仓库，可只用 Release 提供的静态树 + 内置 compose：

```bash
curl -fSL -O https://github.com/podcctv/alpine-base/releases/download/continuous/incus-streams.tar.gz
mkdir -p incus-server/www && tar -xzf incus-streams.tar.gz -C incus-server/www
cd incus-server && docker compose up -d --build
```

### 客户端接入

部署完成后，在**任意 Incus 主机**上：

```bash
incus remote add alpine-base http://<镜像源主机>:8080 --protocol=simplestreams
incus launch alpine-base:alpine/3.24 my-instance
```

完整原理、多镜像托管与签名见下方「Incus 镜像仓库」一节。

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

### 5. 拉取自定义精选镜像（在一个源里托管你的精选集）

simple-streams 支持在同一个镜像源里挂多份镜像，每份对应一个 `alias`。
你可以把多张基于 Alpine 的定制镜像（例如：干净最小版、带 Docker 的、带编译工具链的）
都导入到母鸡 Incus 的本地镜像库，各自起不同 alias，再统一由自建源对外分发：

```bash
# 在装有 Incus 的构建机上，导入多张镜像并起不同 alias
incus image import output/incus/incus.tar.xz output/incus/rootfs.squashfs \
  --alias alpine/3.24/base
incus image import ./other/incus-dev.tar.xz ./other/rootfs.squashfs \
  --alias alpine/3.24/dev

# 重新生成 simple-streams 树（扫描本地镜像库里匹配规则的全部镜像）
./scripts/generate-streams.py \
  --input-dir output/incus \
  --output-dir incus-server/www

# 重启镜像源服务，客户端即可看到全部 alias
cd incus-server && docker compose up -d --build
```

客户端按需拉取自己想要的精选：

```bash
incus remote add alpine-base http://<镜像源>:8080 --protocol=simplestreams
incus launch alpine-base:alpine/3.24/base my-base
incus launch alpine-base:alpine/3.24/dev  my-dev
```

> 当前 `generate-streams.py` 默认只收录 `alpine/3.24` 这一份；要托管多份，给每份镜像起好
> alias 后扩展脚本的扫描规则即可（见 `scripts/generate-streams.py --help`）。

> 安全提示：镜像源默认 **HTTP 且未签名**。内网/自用没问题；要公网暴露建议
> 套一层 HTTPS 反向代理，并给 `images.json` / `index.json` 做 GPG 签名
> （simple-streams 原生支持，参数见 `generate-streams.py --help`）。

## 主要使用场景

| 场景 | 说明 |
|------|------|
| **内网 / 离线 Incus 分发** | 不依赖公网 `images.linuxcontainers.org`，自建源在内网一键起，所有 Incus 母鸡统一从这里拉镜像 |
| **统一基础镜像版本** | 团队 / 平台共用同一份 `alpine-base`（含一致 sshd 策略、发布门禁），避免各节点镜像漂移 |
| **多节点 Incus 集群统一源** | 一个镜像源服务整个集群，更新一次、全集群生效 |
| **作为平台 / PaaS 的自定义实例镜像** | 例如在 [runman-agent](https://github.com/podcctv/runman-agent)（NarwhalCloud NAT VPS 母鸡 Agent）里，把 `alpine-base` 作为租户实例的基础镜像 |

## 在 runman-agent 中作为自定义镜像

[runman-agent](https://github.com/podcctv/runman-agent) 支持 **Podman / cloud-hypervisor / Incus** 三种虚拟化后端，
实例镜像以 OCI 引用（Podman）或 Incus 镜像别名（Incus）指定。两种后端接入 `alpine-base` 的方式如下。

### Podman 后端（推荐，零改动）

runman-agent 的 Podman 后端用 `req.OsImage` 作为**任意 OCI 引用**直接 `podman pull`，
默认是 `docker.io/narwhalcloud/alpine:podman`。把它替换成 `alpine-base` 的 OCI 镜像即可：

```bash
# 方式一：直接拉 GHCR（需 GHCR 包设为 Public，或母鸡已登录 ghcr.io）
podman pull ghcr.io/podcctv/alpine-base:3.24

# 方式二：从 Release 下载 tar 包再 load（完全免登录）
curl -fSL -O https://github.com/podcctv/alpine-base/releases/download/continuous/alpine-base-3.24-podman.tar
podman load -i alpine-base-3.24-podman.tar
```

之后在创建 runman 实例时把镜像引用填为 `ghcr.io/podcctv/alpine-base:3.24`
（或 `localhost/alpine-base:3.24-test`）。`alpine-base` 已内置 `openssh` 与一致 sshd 策略，
runman 注入 root 密码后即可 SSH 登录。

### Incus 后端（用自建 simple-streams 源）

runman-agent 的 Incus 后端默认从 `https://images.linuxcontainers.org` 拉 `alpine/3.23/cloud`
并自动构建 `ready` 镜像、发布到**母鸡本地** Incus 镜像库。要让它改用 `alpine-base`：

> `alpine-base` 的 Incus 产物包含 OpenRC 和 cloud-init 四阶段服务，可直接处理 Incus `cloud-init.user-data`。新版 runman-agent 也会通过 Incus agent 做一次运行时兜底，以兼容旧镜像和精简镜像。

1. 在 runman 母鸡上把 `alpine-base` 导入本地 Incus 镜像库，并以 runman 期望的 alias 发布
   （注意含架构后缀，runman 实际启动用的是 `.../ready` 别名）：

   ```bash
   # 取 Incus 产物（Release 下载，或自建源提供）
   curl -fSL -O https://github.com/podcctv/alpine-base/releases/download/continuous/incus.tar.xz
   curl -fSL -O https://github.com/podcctv/alpine-base/releases/download/continuous/rootfs.squashfs

   ARCH=amd64   # 或 arm64
   incus image import incus.tar.xz rootfs.squashfs \
     --alias alpine/3.24/cloud/${ARCH}/ready
   ```

2. 创建实例时把 `OsImage` 指定为 `alpine/3.24/cloud`：runman 会优先使用本地已存在的
   `.../ready` 别名，跳过从公网源重新构建，直接以 `alpine-base` 启动实例。

> 若想让 runman 的 Incus 后端**直接从你的自建 simple-streams 源**拉取（而不是本地导入），
> 需要把 `manager/incus/incus.go` 里的镜像服务器地址改为你的源地址（目前硬编码为
> `images.linuxcontainers.org`）。

## 维护节奏

| 频率 | 动作 |
|------|------|
| 每月 | `git pull` → `./scripts/build-all.sh` → `test-ssh.sh` → `release.sh` |
| 出现 CVE | 立即重构建 + 完整 SSH 验收 + 发 patch 版本 |
| 升级大版本 | 3.24 → 3.25 时**新建独立 alias/tag**，不要覆盖 3.24 |

## License

[MIT](LICENSE)

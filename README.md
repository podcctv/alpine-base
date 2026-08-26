# Flanker Alpine Base 3.24

一套可重复构建的 Alpine 3.24 基础镜像源码，同时产出 **Incus System Container** 和 **Podman OCI** 镜像。

## 核心目标

彻底解决 Alpine 镜像经常无法使用 SSH root 密码登录的问题，并把真实密码 SSH 登录纳入发布门禁。

## 特性

- Alpine v3.24，官方支持至 2028-06-01
- 统一 sshd_config：`PermitRootLogin yes` + `PasswordAuthentication yes`
- 镜像不含固定密码、SSH 私钥、Host Key — 每实例独立生成
- Incus 用 distrobuilder 构建 System Container
- Podman 用 Containerfile 构建 OCI Image
- GitHub Actions CI 自动验证 + GHCR 推送

## 仓库结构

```
flanker-alpine-base/
├── VERSION                    # Alpine 主分支版本 (3.24)
├── .gitignore
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
│   ├── test-ssh.sh            # SSH 密码登录发布门禁
│   └── release.sh             # 发布 stable
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

### Incus

```bash
# 构建
./scripts/build-incus.sh

# 导入 Image Store
incus image import output/incus/incus.tar.xz output/incus/rootfs.squashfs \
  --alias flanker-alpine/3.24-test

# 启动实例
incus launch flanker-alpine/3.24-test alpine-ssh-test

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

### Podman

```bash
# 构建
./scripts/build-podman.sh

# 启动测试容器
printf '%s' 'YourStrongPassword' > /tmp/root_password
podman secret create alpine_root_password /tmp/root_password
podman run -d --name alpine-test -p 2222:22 \
  --secret alpine_root_password,target=root_password \
  localhost/flanker-alpine-base:3.24-test

# SSH 测试
ssh -p 2222 -o PreferredAuthentications=password -o PubkeyAuthentication=no root@127.0.0.1
```

## 版本规则

| 类型 | 格式 | 说明 |
|------|------|------|
| Alpine stable | `3.24` | 滚动稳定 |
| 不可变版本 | `3.24-v1.0.0` | 不可变制品 |
| Git Tag | `v1.0.0` | 与不可变镜像对应 |

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
podman pull ghcr.io/podcctv/flanker-alpine-base:latest

# 滚动稳定版（固定 Alpine 大版本）
podman pull ghcr.io/podcctv/flanker-alpine-base:3.24

# 不可变版本（可追溯到具体构建，推荐生产使用）
podman pull ghcr.io/podcctv/flanker-alpine-base:3.24-v1.0.0
```

> 当前仓库为 Private，GHCR 包默认也是私有。要让别人免登录拉取，需在
> GitHub → Packages → flanker-alpine-base → Settings 里把可见性改为 Public，
> 或在拉取方用有 `read:packages` 权限的 token 登录 `ghcr.io`。

启动（密码通过 secret 注入，不烧进镜像）：

```bash
printf '%s' '你的强密码' > /tmp/root_password
podman secret create alpine_root_password /tmp/root_password
podman run -d --name alpine -p 2222:22 \
  --secret alpine_root_password,target=root_password \
  ghcr.io/podcctv/flanker-alpine-base:3.24
```

### Incus（从 CI 产物导入）

Incus 是 System Container，**不进 GHCR**（GHCR 只存 OCI 镜像）。CI 会把
`incus.tar.xz` + `rootfs.squashfs` 作为 artifact 上传：

1. 到 Actions → 最新 `Build Incus Image` → 下载 `flanker-alpine-3.24-incus` 产物
2. 导入到本机 Incus：

```bash
incus image import incus.tar.xz rootfs.squashfs --alias flanker-alpine/3.24-test
incus launch flanker-alpine/3.24-test my-vm
printf 'root:%s\n' '你的强密码' | incus exec my-vm -- chpasswd
```

需要对外分发 Incus 镜像时，用 Incus 官方镜像服务（`incus-publish` / 自建
`incus image server`），不要混用 GHCR。

## License

MIT

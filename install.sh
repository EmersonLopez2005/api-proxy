#!/usr/bin/env bash
# ============================================================================
#  api-proxy 一键部署引导脚本
#
#  它在做三件事：装 Docker → 把项目文件拉到本机 → 把控制权交给交互向导。
#
#  推荐用法（先下载再执行，这样向导能正常接收键盘输入）：
#     curl -fsSL https://raw.githubusercontent.com/EmersonLopez2005/api-proxy/main/install.sh -o /tmp/api-proxy.sh
#     sudo bash /tmp/api-proxy.sh
#
#  管道用法也行（脚本会自动改从 /dev/tty 读输入）：
#     curl -fsSL https://raw.githubusercontent.com/EmersonLopez2005/api-proxy/main/install.sh | sudo bash
#
#  可覆盖的变量：
#     DIR=/opt/api-proxy      安装目录
#     BRANCH=main             分支
#     NO_DOCKER_INSTALL=1     不自动安装 Docker，装不上时直接报错
# ============================================================================
set -euo pipefail

REPO="${REPO:-EmersonLopez2005/api-proxy}"
BRANCH="${BRANCH:-main}"
DIR="${DIR:-/opt/api-proxy}"
TARBALL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_END=$'\033[0m'
log()  { printf '%s[+]%s %s\n' "$C_OK"   "$C_END" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_END" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_ERR"  "$C_END" "$*" >&2; exit 1; }
tty_ok() { { [ -r /dev/tty ] && [ -w /dev/tty ]; } 2>/dev/null; }

# ---------------------------------------------------------------------------
# 0. 环境检查
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "请用 root 运行：  sudo bash install.sh"
command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装：apt install -y curl"

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    die "需要 bash 4.0 或更高版本（当前: ${BASH_VERSION:-unknown}）"
fi

# ---------------------------------------------------------------------------
# 1. 确保 Docker / Compose 可用
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    if [ "${NO_DOCKER_INSTALL:-0}" = "1" ]; then
        die "未检测到 Docker，且已设置 NO_DOCKER_INSTALL=1。请自行安装后重试。"
    fi
    log "未检测到 Docker，正在在线安装（get.docker.com）..."
    curl -fsSL https://get.docker.com | sh
    command -v systemctl >/dev/null 2>&1 && systemctl enable --now docker
fi

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    die "Docker 已安装但缺少 compose。请安装 docker-compose-plugin 后重试。"
fi
log "Docker 就绪：$DC"

# ---------------------------------------------------------------------------
# 2. 拉取项目文件
#    只覆盖仓库里跟踪的文件；sites.conf / settings.conf / .env / nginx.conf
#    这些本地状态文件不在压缩包里，因此更新时不会被冲掉。
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log "下载项目文件 ..."
FETCHED=0

if command -v tar >/dev/null 2>&1 && curl -fsSL "$TARBALL" -o "$TMP/src.tar.gz"; then
    mkdir -p "$TMP/src"
    if tar -xzf "$TMP/src.tar.gz" -C "$TMP/src" --strip-components=1 2>/dev/null; then
        FETCHED=1
    fi
    rm -f "$TMP/src.tar.gz"
fi

if [ "$FETCHED" = "0" ] && command -v git >/dev/null 2>&1; then
    log "压缩包方式失败，改用 git clone ..."
    if git clone --depth 1 --branch "$BRANCH" "https://github.com/${REPO}.git" "$TMP/src" 2>/dev/null; then
        rm -rf "$TMP/src/.git"
        FETCHED=1
    fi
fi

if [ "$FETCHED" = "0" ]; then
    log "改用逐文件下载 ..."
    RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
    mkdir -p "$TMP/src/templates" "$TMP/src/.github/workflows"
    for f in docker-compose.yml setup.sh install.sh Makefile \
             .gitignore .gitattributes .env.example sites.conf.example LICENSE README.md \
             templates/nginx.conf.tpl .github/workflows/validate.yml; do
        curl -fsSL "$RAW/$f" -o "$TMP/src/$f" || warn "下载失败（跳过）: $f"
    done
    FETCHED=1
fi

[ -f "$TMP/src/setup.sh" ] || die "下载内容不完整，缺少 setup.sh。请检查网络或仓库地址。"
[ -f "$TMP/src/templates/nginx.conf.tpl" ] || die "下载内容不完整，缺少配置模板。"
[ -f "$TMP/src/sites.conf" ] && warn "压缩包里出现了 sites.conf（不应被提交），已忽略。"

# 压缩包/克隆里不该出现的本地状态文件先清掉，避免把别人的域名带进来
for f in sites.conf settings.conf .env nginx/nginx.conf; do
    [ -e "$TMP/src/$f" ] && rm -f "$TMP/src/$f"
done

mkdir -p "$DIR"
cp -a "$TMP/src/." "$DIR/"

chmod +x "$DIR/setup.sh" 2>/dev/null || true
log "项目已就位：$DIR"

# ---------------------------------------------------------------------------
# 3. 端口占用提醒
# ---------------------------------------------------------------------------
PORT_CHECK=$(grep -E '^[[:space:]]*HTTP_PORT=' "$DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2- || true)
PORT_CHECK="${PORT_CHECK:-80}"
if command -v ss >/dev/null 2>&1 && ss -lntp 2>/dev/null | grep -q ":${PORT_CHECK} "; then
    warn "宿主机 ${PORT_CHECK} 端口已被占用，常见原因是系统 nginx / apache / caddy 还在跑。"
    warn "先停掉它们（systemctl stop nginx apache2 caddy），或在向导里换个端口。"
fi

# ---------------------------------------------------------------------------
# 4. 交给交互向导
# ---------------------------------------------------------------------------
printf '\n' >&2
if [ "$#" -gt 0 ]; then
    log "进入配置流程（带参数，跳过向导提问）..."
    bash "$DIR/setup.sh" "$@"
elif tty_ok; then
    log "进入配置向导 ..."
    # 关键：从 /dev/tty 读输入，这样 `curl | bash` 时向导也能正常交互
    bash "$DIR/setup.sh" < /dev/tty
else
    warn "当前没有可交互的终端，无法进入向导。"
    warn "请手动执行：  sudo bash $DIR/setup.sh"
    warn "或用参数模式： sudo bash $DIR/setup.sh --add 你的域名 https://上游地址 --yes"
    exit 0
fi

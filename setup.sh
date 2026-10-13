#!/usr/bin/env bash
# ============================================================================
#  api-proxy · 配置向导 / 配置生成器
#
#  最常用（交互式，一路回车即可）：
#      sudo ./setup.sh
#
#  非交互（适合脚本、CI、批量）：
#      sudo ./setup.sh --add api.example.com https://up.api.com --yes
#      ./setup.sh --render-only --out /tmp/x.conf --add a.com https://b.com
#
#  参数一览：
#      --add <域名> <上游URL> [转发Host]   追加/覆盖一个站点（可重复）
#      --remove <域名>                     删除一个站点
#      --list                              只列出现有站点
#      --render-only                       只生成 nginx.conf，不校验、不碰 Docker
#      --out <路径>                        指定生成位置（默认 nginx/nginx.conf）
#      --yes                               不提问，全部使用默认值并直接部署
#      -h | --help                         帮助
#
#  环境变量：
#      DIR=<路径>      项目目录（默认取脚本所在目录）
#      SITES_FILE=<路径>     站点清单（默认 $DIR/sites.conf）
#      SETTINGS_FILE=<路径>  全局设置（默认 $DIR/settings.conf）
# ============================================================================
set -euo pipefail

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "本脚本需要 bash 4.0 或更高版本（当前: ${BASH_VERSION:-unknown}）" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 路径与常量
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIR="${DIR:-$SCRIPT_DIR}"
SITES_FILE="${SITES_FILE:-$DIR/sites.conf}"
SETTINGS_FILE="${SETTINGS_FILE:-$DIR/settings.conf}"
TPL="$DIR/templates/nginx.conf.tpl"
OUT="$DIR/nginx/nginx.conf"
ENV_FILE="$DIR/.env"

NGINX_IMAGE="nginx:1.27-alpine"
DEFAULT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_END=$'\033[0m'
log()  { printf '%s[+]%s %s\n' "$C_OK"   "$C_END" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_END" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_ERR"  "$C_END" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_END" >&2; }

# ---------------------------------------------------------------------------
# 终端交互（关键：兼容 `curl | bash`，此时 stdin 是管道，必须读 /dev/tty）
# ---------------------------------------------------------------------------
tty_ok() {
    # APX_NO_TTY=1 时强制走 stdin，便于自动化测试或在无 tty 的 SSH 里跑
    if [ "${APX_NO_TTY:-0}" = "1" ]; then return 1; fi
    { [ -r /dev/tty ] && [ -w /dev/tty ]; } 2>/dev/null
}

read_input() {
    local __r=""
    if tty_ok; then
        IFS= read -r __r < /dev/tty || __r=""
    else
        IFS= read -r __r || __r=""
    fi
    printf -v "$1" '%s' "$__r"
}

# ask_opt VAR "提示" "默认值"   允许为空
ask_opt() {
    local __v=$1 __p=$2 __d=${3-} __a=""
    if [ -n "$__d" ]; then printf '  %s [%s]: ' "$__p" "$__d" >&2
    else                      printf '  %s: ' "$__p" >&2; fi
    read_input __a
    [ -n "$__a" ] || __a="$__d"
    printf -v "$__v" '%s' "$__a"
}

# ask_req VAR "提示" "默认值"   不允许为空（有默认值时空回车取默认值）
ask_req() {
    local __v=$1 __p=$2 __d=${3-} __a=""
    while :; do
        if [ -n "$__d" ]; then printf '  %s [%s]: ' "$__p" "$__d" >&2
        else                      printf '  %s: ' "$__p" >&2; fi
        read_input __a
        [ -n "$__a" ] || __a="$__d"
        if [ -n "$__a" ]; then break; fi
        printf '  %s必填，请重新输入%s\n' "$C_WARN" "$C_END" >&2
    done
    printf -v "$__v" '%s' "$__a"
}

# ask_yn VAR "问题" "默认(Y/N)"
ask_yn() {
    local __v=$1 __p=$2 __d=${3:-N} __a=""
    while :; do
        if [ "$__d" = "Y" ]; then printf '  %s [Y/n]: ' "$__p" >&2
        else                      printf '  %s [y/N]: ' "$__p" >&2; fi
        read_input __a
        [ -n "$__a" ] || __a="$__d"
        case "${__a,,}" in
            y|yes) printf -v "$__v" 'Y'; return 0 ;;
            n|no)  printf -v "$__v" 'N'; return 0 ;;
            *) printf '  %s请输入 y 或 n%s\n' "$C_WARN" "$C_END" >&2 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# settings.conf 读写
# ---------------------------------------------------------------------------
cfg_get() {   # cfg_get KEY 默认值
    local k=$1 d=${2-} v=""
    if [ -f "$SETTINGS_FILE" ]; then
        v=$(grep -E "^[[:space:]]*${k}=" "$SETTINGS_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)
    fi
    printf '%s' "${v:-$d}"
}

cfg_set() {   # cfg_set KEY VALUE
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    if [ -f "$SETTINGS_FILE" ] && grep -qE "^[[:space:]]*${1}=" "$SETTINGS_FILE"; then
        awk -v k="$1" -v v="$2" '
            index($0, k"=") == 1 { print k"="v; next }
            { print }
        ' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    else
        printf '%s=%s\n' "$1" "$2" >> "$SETTINGS_FILE"
    fi
}

write_settings_header() {
    [ -f "$SETTINGS_FILE" ] && return 0
    {
        printf '# api-proxy 全局设置（本文件已被 .gitignore 排除，请勿提交）\n'
        printf '#\n'
        printf '# UA_ENABLED  1=转发时统一改写 User-Agent，0=原样透传\n'
        printf '# UA_VALUE    统一使用的 User-Agent 值\n'
        printf '\n'
    } > "$SETTINGS_FILE"
}

# ---------------------------------------------------------------------------
# sites.conf 读写
# ---------------------------------------------------------------------------
SITE_DOMAIN=(); SITE_UPSTREAM=(); SITE_HOST=()

load_sites() {
    SITE_DOMAIN=(); SITE_UPSTREAM=(); SITE_HOST=()
    [ -f "$SITES_FILE" ] || return 0
    local line d u h rest
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        read -r d u h rest <<< "$line" || true
        [ -n "${d:-}" ] || continue
        [ -n "${u:-}" ] || continue
        SITE_DOMAIN+=("$d")
        SITE_UPSTREAM+=("$(norm_upstream "$u")")
        SITE_HOST+=("${h:-}")
    done < "$SITES_FILE"
}

write_sites() {
    {
        printf '# api-proxy 站点清单（本文件已被 .gitignore 排除，请勿提交到公开仓库）\n'
        printf '#\n'
        printf '# 语法: <对外域名> <上游URL> [转发Host]    用空格或 Tab 分隔\n'
        printf '#       Host 留空时自动取上游 URL 的主机名\n'
        printf '#\n'
        printf '# 例:   api.example.com   https://api.upstream.com\n'
        printf '#       api2.example.com  https://api.other.com   api.other.com\n'
        printf '#\n'
        printf '# 也可以直接跑交互向导来生成:  sudo ./setup.sh\n'
        printf '#\n'
    } > "$SITES_FILE"

    [ "${#SITE_DOMAIN[@]}" -gt 0 ] || return 0

    local i out=""
    for i in "${!SITE_DOMAIN[@]}"; do
        if [ -n "${SITE_HOST[$i]}" ]; then
            printf '%-30s %-45s %s\n' "${SITE_DOMAIN[$i]}" "${SITE_UPSTREAM[$i]}" "${SITE_HOST[$i]}" >> "$SITES_FILE"
        else
            printf '%-30s %s\n' "${SITE_DOMAIN[$i]}" "${SITE_UPSTREAM[$i]}" >> "$SITES_FILE"
        fi
    done
}

site_index_of() {   # site_index_of 域名 -> 打印下标，找不到打印 -1
    local i
    for i in "${!SITE_DOMAIN[@]}"; do
        [ "${SITE_DOMAIN[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
    done
    printf '%s' "-1"
}

list_sites() {
    if [ "${#SITE_DOMAIN[@]}" -eq 0 ]; then
        dim "  （还没有配置任何站点）"
        return 0
    fi
    local i n=0
    for i in "${!SITE_DOMAIN[@]}"; do
        n=$((n+1))
        printf '  %d) %-30s -> %s%s\n' "$n" "${SITE_DOMAIN[$i]}" "${SITE_UPSTREAM[$i]}" \
            "$([ -n "${SITE_HOST[$i]}" ] && printf '   [Host: %s]' "${SITE_HOST[$i]}")" >&2
    done
}

# ---------------------------------------------------------------------------
# 输入校验 / 归一化
# ---------------------------------------------------------------------------
norm_upstream() {   # 补协议、去尾部斜杠；只回显不报错
    local u=$1
    case "$u" in
        http://*|https://*) ;;
        *://*) printf '%s' "$u"; return 0 ;;
        *) u="https://$u" ;;
    esac
    printf '%s' "${u%/}"
}

upstream_host() {   # 从 URL 取主机名
    local u=$1
    u="${u#*://}"
    u="${u%%/*}"
    printf '%s' "$u"
}

validate_domain() {   # 0=合法
    local d=$1
    [ -n "$d" ] || return 1
    case "$d" in
        *[!A-Za-z0-9.*_-]*) return 1 ;;   # 含空格、斜杠等一律拒绝
    esac
    case "$d" in .*|*.) return 1 ;; esac
    return 0
}

add_site() {   # add_site 域名 上游 [Host] —— 已存在则覆盖
    local d=$1 u=$2 h=${3:-}
    validate_domain "$d" || die "域名不合法: $d"
    case "$u" in
        *://*) ;;
        *) u="https://$u" ;;
    esac
    case "$u" in
        http://*|https://*) ;;
        *) die "上游只支持 http/https: $u" ;;
    esac
    u="${u%/}"
    [ -n "$h" ] || h=$(upstream_host "$u")
    [ -n "$h" ] || die "无法从上游 URL 解析出 Host，请显式指定: $u"

    local i
    i=$(site_index_of "$d")
    if [ "$i" != "-1" ]; then
        SITE_UPSTREAM[$i]="$u"; SITE_HOST[$i]="$h"
        warn "站点 $d 已存在，已更新为 -> $u"
    else
        SITE_DOMAIN+=("$d"); SITE_UPSTREAM+=("$u"); SITE_HOST+=("$h")
        log "已添加站点: $d -> $u"
    fi
}

remove_site() {
    local d=$1
    [ "$(site_index_of "$d")" != "-1" ] || { warn "没有找到站点: $d"; return 1; }
    local td=() tu=() th=() k
    for k in "${!SITE_DOMAIN[@]}"; do
        [ "${SITE_DOMAIN[$k]}" = "$d" ] && continue
        td+=("${SITE_DOMAIN[$k]}"); tu+=("${SITE_UPSTREAM[$k]}"); th+=("${SITE_HOST[$k]}")
    done
    SITE_DOMAIN=(); SITE_UPSTREAM=(); SITE_HOST=()
    if [ "${#td[@]}" -gt 0 ]; then
        SITE_DOMAIN=("${td[@]}"); SITE_UPSTREAM=("${tu[@]}"); SITE_HOST=("${th[@]}")
    fi
    log "已删除站点: $d"
}

# ---------------------------------------------------------------------------
# 渲染 nginx.conf
# ---------------------------------------------------------------------------
build_sites_block() {
    if [ "${#SITE_DOMAIN[@]}" -eq 0 ]; then
        printf '    # ---------------------------------------------------------------\n'
        printf '    # 尚未配置任何站点。运行下面的命令开始配置：\n'
        printf '    #     sudo ./setup.sh\n'
        printf '    # ---------------------------------------------------------------\n'
        return 0
    fi

    local ua_enabled ua_value i n=0
    ua_enabled=$(cfg_get UA_ENABLED 1)
    ua_value=$(cfg_get UA_VALUE "$DEFAULT_UA")

    for i in "${!SITE_DOMAIN[@]}"; do
        n=$((n+1))
        local d="${SITE_DOMAIN[$i]}" u="${SITE_UPSTREAM[$i]}" h="${SITE_HOST[$i]}"
        [ -n "$h" ] || h=$(upstream_host "$u")

        printf '\n'
        printf '    # ------------------------------------------------------------------\n'
        printf '    # 站点 %s :  %s   ->   %s\n' "$n" "$d" "$u"
        printf '    # ------------------------------------------------------------------\n'
        printf '    server {\n'
        printf '        listen       80;\n'
        printf '        server_name  %s;\n' "$d"
        printf '\n'
        printf '        location / {\n'
        printf '            proxy_pass  %s/;\n' "$u"
        printf '\n'
        printf '            # 以 SNI + 显式 Host 访问上游，确保命中正确的证书与回源规则\n'
        printf '            proxy_ssl_server_name on;\n'
        printf '            proxy_set_header      Host  %s;\n' "$h"
        printf '\n'
        printf '            # 抹掉一切可能暴露真实访客的请求头\n'
        printf '            proxy_set_header  X-Real-IP            "";\n'
        printf '            proxy_set_header  X-Forwarded-For      "";\n'
        printf '            proxy_set_header  X-Forwarded-Proto    "";\n'
        printf '            proxy_set_header  X-Forwarded-Host     "";\n'
        printf '            proxy_set_header  HTTP_X_FORWARDED_FOR "";\n'
        printf '            proxy_set_header  CF-Connecting-IP     "";\n'
        printf '            proxy_set_header  True-Client-IP       "";\n'
        printf '            proxy_set_header  CF-Ray               "";\n'
        printf '            proxy_set_header  CF-Visitor           "";\n'
        printf '            proxy_set_header  CF-IPCountry         "";\n'
        printf '            proxy_set_header  Referer              "";\n'
        if [ "$ua_enabled" = "1" ]; then
            printf '\n'
            printf '            # 统一出口 User-Agent（可在 settings.conf 关闭）\n'
            printf '            proxy_set_header  User-Agent  "%s";\n' "$ua_value"
        fi
        printf '\n'
        printf '            # 流式响应：不做缓冲 + 长超时\n'
        printf '            proxy_http_version    1.1;\n'
        printf '            proxy_set_header      Connection "";\n'
        printf '            proxy_connect_timeout 300s;\n'
        printf '            proxy_send_timeout    300s;\n'
        printf '            proxy_read_timeout    300s;\n'
        printf '        }\n'
        printf '    }\n'
    done
}

render() {
    [ -f "$TPL" ] || die "找不到模板文件: $TPL"

    local now
    now=$(date '+%Y-%m-%d %H:%M:%S %z')

    mkdir -p "$(dirname "$OUT")"

    # 说明：整个循环的 stdout 重定向到 $OUT，因此 build_sites_block 的输出
    # 会直接落到 {{SITES}} 所在的位置。这样不需要临时文件，也不怕中途失败
    # 留下垃圾文件。
    local line t
    while IFS= read -r line || [ -n "$line" ]; do
        # 只有「单独一行、且内容恰好是占位符」才注入站点块。
        # 否则注释里提到占位符也会被误判成注入点。
        t="${line#"${line%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        if [ "$t" = "{{SITES}}" ]; then
            build_sites_block
            continue
        fi
        line="${line//\{\{GENERATED_AT\}\}/$now}"
        line="${line//\{\{SITE_COUNT\}\}/${#SITE_DOMAIN[@]}}"
        printf '%s\n' "$line"
    done < "$TPL" > "$OUT"

    log "已生成: $OUT  （${#SITE_DOMAIN[@]} 个站点）"
}

# ---------------------------------------------------------------------------
# .env（docker compose 用，控制宿主机对外端口）
# ---------------------------------------------------------------------------
write_env() {   # write_env 端口
    local port=$1
    if [ -f "$ENV_FILE" ] && grep -qE '^[[:space:]]*HTTP_PORT=' "$ENV_FILE"; then
        awk -v p="$port" '
            index($0, "HTTP_PORT=") == 1 { print "HTTP_PORT="p; next }
            { print }
        ' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
    else
        {
            printf '# 宿主机对外监听端口（容器内部固定监听 80）\n'
            printf 'HTTP_PORT=%s\n' "$port"
        } >> "$ENV_FILE"
    fi
}

read_env_port() {
    local p=""
    if [ -f "$ENV_FILE" ]; then
        p=$(grep -E '^[[:space:]]*HTTP_PORT=' "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)
    fi
    printf '%s' "${p:-80}"
}

# ---------------------------------------------------------------------------
# Docker 操作
# ---------------------------------------------------------------------------
compose_cmd() {
    if docker compose version >/dev/null 2>&1; then printf '%s' "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then printf '%s' "docker-compose"
    else die "未找到 docker compose，请先运行 install.sh 或手动安装 docker-compose-plugin"; fi
}

validate_conf() {
    command -v docker >/dev/null 2>&1 || die "未找到 docker，无法校验（可用 --render-only 跳过）"
    [ -f "$OUT" ] || die "配置尚未生成: $OUT"
    # docker -v 需要绝对路径，否则会被当成卷名
    local abs
    abs="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
    log "校验 nginx 配置语法 ..."
    docker run --rm -v "$abs:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE" nginx -t
}

deploy() {
    local dc was_running=""
    dc=$(compose_cmd)

    # 先判断容器是否已经在跑。这一步很关键：
    # 容器已在运行时，`docker compose up -d` 会因为 compose 层面的定义
    # （镜像/端口/挂载声明）没变而完全不动它，nginx 也不会去重读挂载进去的
    # nginx.conf —— 结果就是「配置生成成功、新站点却不生效」。
    # 所以已在运行的情况下，必须显式热重载。
    if ( cd "$DIR" && $dc ps -q api-proxy 2>/dev/null ) | grep -q .; then
        was_running=1
    fi

    ( cd "$DIR" && $dc up -d )

    if [ -n "$was_running" ]; then
        # -T 关掉伪终端分配，保证在没有 tty 的环境（如 curl|bash、CI）里也能跑
        if ( cd "$DIR" && $dc exec -T api-proxy nginx -s reload ); then
            log "已热重载 nginx，新配置立即生效"
        else
            warn "热重载失败，请手动执行: make reload"
        fi
    fi

    printf '\n' >&2
    ( cd "$DIR" && $dc ps ) >&2
}

# ---------------------------------------------------------------------------
# 交互式向导
# ---------------------------------------------------------------------------
wizard() {
    if [ "${APX_NO_TTY:-0}" != "1" ] && ! tty_ok && [ ! -t 0 ]; then
        die "当前环境没有可交互的终端。请改用参数模式，例如:
    sudo ./setup.sh --add api.example.com https://up.api.com --yes"
    fi

    write_settings_header
    load_sites

    printf '\n' >&2
    printf '%s\n' "==========================================================" >&2
    printf '%s\n' "            api-proxy  配置向导" >&2
    printf '%s\n' "==========================================================" >&2
    printf '\n' >&2

    if [ "${#SITE_DOMAIN[@]}" -gt 0 ]; then
        printf '当前已配置 %d 个站点：\n' "${#SITE_DOMAIN[@]}" >&2
        list_sites
        printf '\n' >&2
        dim "  提示：删除站点用  sudo ./setup.sh --remove <域名>"
        printf '\n' >&2
        local RESET=""
        ask_yn RESET "是否清空现有站点、从头重新配置？" "N"
        if [ "$RESET" = "Y" ]; then
            SITE_DOMAIN=(); SITE_UPSTREAM=(); SITE_HOST=()
            log "已清空，下面从头添加。"
        fi
    fi

    # ---- 逐个添加站点 ----
    printf '\n' >&2
    printf -- '--- 添加站点 -------------------------------------------------\n' >&2
    dim "  示例：对外域名 api.example.com，上游 https://api.upstream.com"
    printf '\n' >&2

    local d u h
    while :; do
        ask_opt d "对外域名（直接回车结束添加）" ""
        [ -n "$d" ] || break

        if ! validate_domain "$d"; then
            warn "域名不合法（不能含空格或斜杠）: $d"
            continue
        fi
        if [ "$(site_index_of "$d")" != "-1" ]; then
            warn "域名 $d 已在列表中，继续输入将覆盖它。"
        fi

        ask_req u "  上游地址（例 https://api.upstream.com）"
        local uh; uh=$(upstream_host "$(norm_upstream "$u")")
        ask_opt h "  转发时携带的 Host（回车用 $uh）" ""

        add_site "$d" "$u" "$h"
        printf '\n' >&2
    done

    if [ "${#SITE_DOMAIN[@]}" -eq 0 ]; then
        die "一个站点都没配置，已终止。"
    fi

    # ---- 出口 User-Agent ----
    printf -- '--- 出口 User-Agent ------------------------------------------\n' >&2
    dim "  统一改写 UA 可避免上游按客户端类型做差异化处理。"
    printf '\n' >&2

    local cur_ua_en cur_ua_val UA_YN UA_VAL
    cur_ua_en=$(cfg_get UA_ENABLED 1)
    cur_ua_val=$(cfg_get UA_VALUE "$DEFAULT_UA")
    ask_yn UA_YN "转发时统一出口 User-Agent？" "$([ "$cur_ua_en" = "1" ] && printf 'Y' || printf 'N')"
    if [ "$UA_YN" = "Y" ]; then
        ask_opt UA_VAL "  UA 值（回车用默认 Chrome UA）" "$cur_ua_val"
        cfg_set UA_ENABLED 1
        cfg_set UA_VALUE "$UA_VAL"
    else
        cfg_set UA_ENABLED 0
        cfg_set UA_VALUE "$cur_ua_val"
    fi

    # ---- 对外端口 ----
    printf '\n' >&2
    printf -- '--- 网络 -----------------------------------------------------\n' >&2
    local cur_port PORT
    cur_port=$(read_env_port)
    ask_opt PORT "  宿主机对外监听端口（容器内部固定 80）" "$cur_port"
    case "$PORT" in
        ''|*[!0-9]*) warn "端口不合法，回退为 $cur_port"; PORT="$cur_port" ;;
    esac
    write_env "$PORT"

    # ---- 落盘 + 生成 ----
    printf '\n' >&2
    write_sites
    render

    printf '\n' >&2
    log "站点清单已保存: $SITES_FILE   (已被 .gitignore 排除)"
    warn "以上两个 .conf 文件包含你的私人域名，请勿提交到公开仓库。"

    # ---- 部署 ----
    printf '\n' >&2
    local GO=""
    ask_yn GO "是否立即校验并启动 / 重启容器？" "Y"
    if [ "$GO" = "Y" ]; then
        validate_conf
        deploy
        printf '\n' >&2
        log "完成。本机自检："
        for i in "${!SITE_DOMAIN[@]}"; do
            printf '    curl -I http://127.0.0.1:%s/ -H "Host: %s"\n' "$(read_env_port)" "${SITE_DOMAIN[$i]}" >&2
        done
    else
        dim "已跳过部署。稍后手动执行： make test && make up"
    fi
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
PENDING_ADD=(); PENDING_REMOVE=()
LIST_ONLY=0; RENDER_ONLY=0; ASSUME_YES=0; INTERACTIVE=1

usage() {
    cat >&2 <<'USAGE'
api-proxy 配置向导 / 配置生成器

最常用（交互式，一路回车即可）：
    sudo ./setup.sh

非交互（适合脚本、CI、批量）：
    sudo ./setup.sh --add api.example.com https://up.api.com --yes
    ./setup.sh --render-only --out /tmp/x.conf --add a.com https://b.com

参数一览：
    --add <域名> <上游URL> [转发Host]   追加/覆盖一个站点（可重复）
    --remove <域名>                     删除一个站点
    --list                              只列出现有站点
    --render-only                       只生成 nginx.conf，不校验、不碰 Docker
    --out <路径>                        指定生成位置（默认 nginx/nginx.conf）
    --yes                               不提问，全部使用默认值并直接部署
    -h | --help                         显示本帮助

环境变量：
    DIR=<路径>              项目目录（默认取脚本所在目录）
    SITES_FILE=<路径>       站点清单（默认 $DIR/sites.conf）
    SETTINGS_FILE=<路径>    全局设置（默认 $DIR/settings.conf）
    APX_NO_TTY=1            强制从 stdin 读输入，不读 /dev/tty
                            （用于自动化测试，或在没有终端的 SSH 会话里跑向导）
USAGE
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --add)
            shift
            [ $# -ge 2 ] || die "--add 需要 <域名> <上游URL> [转发Host]"
            _d=$1; _u=$2; shift 2
            _h=""
            if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then _h=$1; shift; fi
            PENDING_ADD+=("$_d|$_u|$_h")
            INTERACTIVE=0
            ;;
        --remove)
            shift
            [ $# -ge 1 ] || die "--remove 需要 <域名>"
            PENDING_REMOVE+=("$1"); shift
            INTERACTIVE=0
            ;;
        --list)        LIST_ONLY=1;    INTERACTIVE=0; shift ;;
        --render-only) RENDER_ONLY=1;  INTERACTIVE=0; shift ;;
        --yes|-y)      ASSUME_YES=1;   INTERACTIVE=0; shift ;;
        --out)         shift; [ $# -ge 1 ] || die "--out 需要一个路径"; OUT="$1"; shift ;;
        -h|--help)     usage ;;
        *) die "未知参数: $1    （用 --help 查看用法）" ;;
    esac
done

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" = "1" ]; then
    load_sites
    list_sites
    exit 0
fi

if [ "$INTERACTIVE" = "1" ] && [ "$RENDER_ONLY" = "0" ]; then
    wizard
    exit 0
fi

# ---- 非交互模式 ----
write_settings_header
load_sites

if [ "${#PENDING_REMOVE[@]}" -gt 0 ]; then
    for _r in "${PENDING_REMOVE[@]}"; do remove_site "$_r" || true; done
fi
if [ "${#PENDING_ADD[@]}" -gt 0 ]; then
    for _e in "${PENDING_ADD[@]}"; do
        IFS='|' read -r _d _u _h <<< "$_e"
        add_site "$_d" "$_u" "$_h"
    done
fi

if [ "${#SITE_DOMAIN[@]}" -eq 0 ]; then
    die "没有任何站点可生成。请用 --add，或直接跑向导: sudo ./setup.sh"
fi

[ -f "$SITES_FILE" ] || write_sites
if [ "${#PENDING_ADD[@]}" -gt 0 ] || [ "${#PENDING_REMOVE[@]}" -gt 0 ]; then
    write_sites
fi

render

if [ "$RENDER_ONLY" = "1" ]; then
    dim "（--render-only：已跳过配置校验与容器操作）"
    exit 0
fi

[ -f "$ENV_FILE" ] || write_env "80"
validate_conf
deploy

printf '\n' >&2
log "完成。"

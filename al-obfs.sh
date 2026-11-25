#!/usr/bin/env bash
# =============================================================================
#  singbox-nat  ·  Alpine Linux NAT VPS 一键安装 sing-box
#  协议：VLESS Reality(TCP) / TUIC v5(UDP) / Hysteria2(UDP)
#  特性：SNI 自动优选 · 端口自定义 · 进程守护与抗杀 · 一键出客户端链接
#
#  用法：bash install.sh [选项]     或   sbx（安装后进入管理菜单）
#  帮助：bash install.sh --help
# =============================================================================
set -Eeuo pipefail

SBN_BUILD="1.0.0"
SBN_FALLBACK_VERSION="1.14.4"   # 无法访问 GitHub API 时的兜底版本

# ---------- 路径（可用环境变量覆盖，便于测试）----------
SBN_ETC="${SBN_ETC:-/etc/sing-box}"
SBN_BIN="${SBN_BIN:-/usr/local/bin/sing-box}"
SBN_INIT="${SBN_INIT:-/etc/init.d/sing-box}"
SBN_LIB="${SBN_LIB:-/usr/local/lib/singbox-nat}"
SBN_LOG="${SBN_LOG:-/var/log/sing-box.log}"
SBN_STATE="$SBN_ETC/nat.state"
SBN_CONF="$SBN_ETC/config.json"
SBN_LINKS="$SBN_ETC/links.txt"
SBN_CLIENT="$SBN_ETC/client-singbox.json"
SBN_CERT="$SBN_ETC/cert.pem"
SBN_KEY="$SBN_ETC/key.pem"
SYS_CA="${SYS_CA:-/etc/ssl/certs/ca-certificates.crt}"

# ---------- 颜色 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RST=$'\033[0m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
    C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;36m'; C_DIM=$'\033[2m'
else
    C_RST=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""
fi

info() { printf '%s %s\n' "${C_BLU}[信息]${C_RST}" "$*"; }
ok()   { printf '%s %s\n' "${C_GRN}[完成]${C_RST}" "$*"; }
warn() { printf '%s %s\n' "${C_YEL}[提示]${C_RST}" "$*"; }
die()  { printf '%s %s\n' "${C_RED}[错误]${C_RST}" "$*" >&2; exit 1; }
hr()   { printf '%s\n' "------------------------------------------------------------------------"; }

trap 'rc=$?; [ "$rc" -ne 0 ] && printf "\n%s 第 %s 行执行失败：%s（退出码 %s）\n" "${C_RED}[错误]${C_RST}" "$LINENO" "$BASH_COMMAND" "$rc" >&2' ERR

# ---------- 小工具 ----------
env_or()  { local v="${1:-}"; local nv="${!v:-}"; printf '%s' "${nv:-$2}"; }
env_set() { local v="${1:-}"; if [ -n "${!v:-}" ]; then printf '1'; else printf '0'; fi; }

now_ms() {
    local t
    t="$(date +%s%3N 2>/dev/null || true)"
    case "$t" in
        ''|*[!0-9]*) t=$(( $(date +%s) * 1000 )) ;;
    esac
    printf '%s' "$t"
}

tty_available() { [ -c /dev/tty ] && { : </dev/tty; } 2>/dev/null; }

ask() {  # ask "提示" "默认值" -> stdout
    local prompt="$1" def="${2:-}" ans=""
    if [ "${ASSUME_YES:-0}" = "1" ] || ! tty_available; then
        printf '%s' "$def"; return 0
    fi
    printf '%s%s%s [%s]: ' "$C_BLU" "$prompt" "$C_RST" "$def" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    [ -n "$ans" ] || ans="$def"
    printf '%s' "$ans"
}

ask_yes() {  # ask_yes "提示" -> 0/1
    local prompt="$1" ans=""
    if [ "${ASSUME_YES:-0}" = "1" ] || ! tty_available; then return 1; fi
    printf '%s%s%s [y/N]: ' "$C_YEL" "$prompt" "$C_RST" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

need_root() { [ "$(id -u)" = "0" ] || die "请用 root 运行（sudo / su -）。"; }
is_alpine() { [ -r /etc/alpine-release ] || command -v apk >/dev/null 2>&1; }

# =============================================================================
#  参数与默认值
# =============================================================================
VLESS_PORT="$(env_or VLESS_PORT 443)";  VLESS_PORT_SET="$(env_set VLESS_PORT)"
TUIC_PORT="$(env_or TUIC_PORT 443)";    TUIC_PORT_SET="$(env_set TUIC_PORT)"
HY2_PORT="$(env_or HY2_PORT 8443)";     HY2_PORT_SET="$(env_set HY2_PORT)"
SNI="$(env_or SNI '')";                 SNI_SET="$(env_set SNI)"
PROTOS="$(env_or PROTOS 'vless,tuic,hy2')"; PROTOS_SET="$(env_set PROTOS)"
NODE_NAME="$(env_or NODE_NAME "$(hostname 2>/dev/null || echo vps)")"; NAME_SET="$(env_set NODE_NAME)"
PUBLIC_IP="$(env_or PUBLIC_IP '')";     IP_SET="$(env_set PUBLIC_IP)"
HY2_OBFS="$(env_or HY2_OBFS 0)";        OBFS_SET="$(env_set HY2_OBFS)"
MASQUERADE="$(env_or MASQUERADE 'https://www.bing.com/')"; MASQ_SET="$(env_set MASQUERADE)"
LOG_LEVEL="$(env_or LOG_LEVEL warn)"
SINGBOX_VERSION="$(env_or SINGBOX_VERSION '')"
GH_PROXY="$(env_or GH_PROXY '')"
REPO_SLUG="$(env_or SBN_REPO '')"

ASSUME_YES=0
DO_RESET=0
DO_TUNE=1
DAILY_RESTART=0
CUSTOM_CERT=""
CUSTOM_KEY=""
CERT_CUSTOM="0"
CERT_PATH=""
KEY_PATH=""
MEM_LIMIT_MIB=""

# 凭证
UUID=""; REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; SHORT_ID=""
TUIC_UUID=""; TUIC_PASSWORD=""; HY2_PASSWORD=""; HY2_OBFS_PASSWORD=""
TLS_SERVER_NAME=""
LISTEN_ADDR=""

SBN_SELF=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SBN_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
fi

# =============================================================================
#  帮助
# =============================================================================
usage() {
    cat <<'EOF'
singbox-nat —— Alpine Linux NAT VPS 一键安装 sing-box（VLESS Reality / TUIC / Hysteria2）

用法:
  bash install.sh [选项]        安装（已安装则沿用凭证，仅更新改动项）
  bash install.sh --menu        打开管理菜单
  sbx                           同上（安装后可用）

常用选项:
  -y, --yes                 全自动，不交互（用默认值/参数值）
      --sni <域名>          Reality 的 SNI/伪装站；不填则自动优选
      --port <端口>         VLESS Reality 端口（TCP，默认 443）
      --vless-port <端口>   同上
      --tuic-port <端口>    TUIC 端口（UDP，默认 443）
      --hy2-port <端口>     Hysteria2 端口（UDP，默认 8443）
      --proto <列表>        启用协议，逗号分隔：vless,tuic,hy2（默认全部）
      --name <节点名>       客户端显示的节点名（默认主机名）
      --obfs                 为 Hysteria2 开启 salamander 混淆（默认关闭）
      --public-ip <IP>      手动指定公网 IP（NAT 机器自动探测失败时用）
      --cert <证书> --key <私钥>   使用自有证书（如 acme.sh 签发），不再自签
      --version <版本>      指定 sing-box 版本，如 1.14.4（默认取最新）
      --proxy <镜像前缀>    GitHub 加速前缀，如 https://gh-proxy.com/
      --repo <owner/repo>   你的 GitHub 仓库（用于下载管理脚本）
      --reset               重新生成全部凭证（所有客户端需重新导入）
      --no-tune             跳过 sysctl 网络调优
      --daily-restart       每天 04:10 自动重启一次
  -h, --help                显示帮助
  -v, --version             显示脚本版本

环境变量：VLESS_PORT / TUIC_PORT / HY2_PORT / SNI / PROTOS / NODE_NAME /
          PUBLIC_IP / HY2_OBFS / SINGBOX_VERSION / GH_PROXY / SBN_REPO
示例:
  bash install.sh -y --port 20001 --tuic-port 20002 --hy2-port 20003
  bash install.sh -y --sni www.microsoft.com --proto vless,hy2
EOF
}

# =============================================================================
#  环境与依赖
# =============================================================================
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   printf 'amd64' ;;
        aarch64|arm64)  printf 'arm64' ;;
        armv7l|armv7)   printf 'armv7' ;;
        armv6l)         printf 'armv6' ;;
        i386|i686)      printf '386' ;;
        *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
}

ensure_deps() {
    is_alpine || return 0
    local missing=()
    command -v curl    >/dev/null 2>&1 || missing+=(curl)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v tar     >/dev/null 2>&1 || missing+=(tar)
    command -v awk     >/dev/null 2>&1 || missing+=(busybox)
    [ -r "$SYS_CA" ] || missing+=(ca-certificates)
    if [ "${#missing[@]}" -gt 0 ]; then
        info "安装依赖：${missing[*]}"
        apk update >/dev/null 2>&1 || true
        if ! apk add --no-cache "${missing[@]}" >/dev/null 2>&1; then
            die "依赖安装失败。请先执行：apk add --no-cache ${missing[*]}"
        fi
    fi
}

# =============================================================================
#  sing-box 二进制安装
# =============================================================================
resolve_version() {
    if [ -n "$SINGBOX_VERSION" ]; then
        printf '%s' "${SINGBOX_VERSION#v}"; return 0
    fi
    local v=""
    v="$(curl -fsSL --max-time 12 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | awk -F'"' '/"tag_name"/{print $4; exit}' || true)"
    if [ -z "$v" ]; then
        v="$(curl -fsSI --max-time 12 https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null \
            | tr -d '\r' | awk -F'/' 'tolower($1) ~ /^location:/{print $NF}' | tail -n 1 || true)"
    fi
    v="${v#v}"
    case "$v" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) v="$SBN_FALLBACK_VERSION" ;;
    esac
    printf '%s' "$v"
}

fetch_asset() {  # fetch_asset <url> <dest> ；自动尝试镜像
    local url="$1" dest="$2" m full
    local mirrors=()
    if [ -n "$GH_PROXY" ]; then mirrors+=("$GH_PROXY"); fi
    mirrors+=("" "https://gh-proxy.com/" "https://ghfast.top/" "https://ghproxy.net/")
    for m in "${mirrors[@]}"; do
        if [ -z "$m" ]; then full="$url"; else full="${m%/}/$url"; fi
        info "下载：$full"
        if curl -fL --connect-timeout 10 --max-time 900 \
                --speed-limit 30000 --speed-time 25 \
                -o "$dest" "$full" 2>/dev/null && [ -s "$dest" ]; then
            return 0
        fi
        rm -f "$dest"
        warn "该源不可用，换下一个"
    done
    return 1
}

install_binary() {
    local ver arch asset url suffix tdir tmp bin found=0
    ver="$(resolve_version)"
    arch="$(detect_arch)"
    info "sing-box 目标版本：v${ver}（linux-${arch}）"

    if [ -x "$SBN_BIN" ] && "$SBN_BIN" version 2>/dev/null | grep -q "version ${ver}"; then
        ok "已安装 v${ver}，跳过下载"
        return 0
    fi

    tdir="$(mktemp -d)"; tmp="$tdir/pkg.tar.gz"
    for suffix in musl ""; do
        asset="sing-box-${ver}-linux-${arch}${suffix:+-$suffix}.tar.gz"
        url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${asset}"
        if fetch_asset "$url" "$tmp"; then found=1; break; fi
    done
    [ "$found" = "1" ] || die "下载 sing-box 失败。可加 --proxy https://gh-proxy.com/ 或 --version 指定其他版本。"

    tar xzf "$tmp" -C "$tdir" || die "解压失败"
    bin="$(find "$tdir" -type f -name sing-box 2>/dev/null | head -n 1)"
    [ -n "$bin" ] || die "安装包内未找到 sing-box 可执行文件"

    mkdir -p "$(dirname "$SBN_BIN")"
    rm -f "$SBN_BIN"
    cp -f "$bin" "$SBN_BIN"
    chmod 755 "$SBN_BIN"
    rm -rf "$tdir"

    "$SBN_BIN" version >/dev/null 2>&1 || die "sing-box 无法运行（架构或 musl 不匹配）"
    ok "已安装 sing-box：$("$SBN_BIN" version | head -n 1)"
}

# =============================================================================
#  SNI 自动优选
# =============================================================================
SNI_CANDIDATES=(
    www.microsoft.com www.apple.com www.bing.com dl.google.com
    www.cloudflare.com www.samsung.com www.nvidia.com www.tesla.com
    addons.mozilla.org www.wikipedia.org www.adobe.com www.intel.com
    www.amd.com one.one.one.one gateway.icloud.com www.oracle.com
    steamcommunity.com www.swift.org gitlab.com www.python.org
)

probe_sni_one() {  # 输出 "<毫秒>\t<域名>\t<是否确认h2:0/1>"；不合格则无输出
    local h="$1" out rc=0 st en ms ca=() alpn score=1
    if [ -r "$SYS_CA" ]; then ca=(-CAfile "$SYS_CA" -verify_return_error); fi
    st="$(now_ms)"
    # -brief 输出稳定、不会挂住，用来判定 TLS1.3 + 证书链
    out="$(timeout 6 openssl s_client -connect "${h}:443" -servername "$h" \
            -alpn h2 -tls1_3 -brief "${ca[@]}" </dev/null 2>&1)" || rc=$?
    en="$(now_ms)"
    [ "$rc" = "0" ] || return 0
    printf '%s' "$out" | grep -qi 'tlsv1\.3' || return 0
    # ALPN 需从完整输出读取（-brief 不含该行）；探测失败不淘汰，只降低优先级
    alpn="$(timeout 4 openssl s_client -connect "${h}:443" -servername "$h" \
            -alpn h2 -tls1_3 </dev/null 2>&1 | grep -i 'alpn protocol' || true)"
    case "$alpn" in *h2*|*H2*) score=0 ;; esac
    ms=$(( en - st ))
    printf '%s\t%s\t%s\n' "$ms" "$h" "$score"
}

pick_sni() {  # 返回最优域名；全部失败返回空（进度信息一律走 stderr，避免污染返回值）
    local resdir total batch=6 i=0 host ms score best
    total="${#SNI_CANDIDATES[@]}"
    resdir="$(mktemp -d)"
    info "正在探测 ${total} 个候选 SNI（TLS1.3 + 证书链，优先 HTTP/2）…" >&2
    while [ "$i" -lt "$total" ]; do
        local pids=() j=0
        while [ "$j" -lt "$batch" ] && [ "$i" -lt "$total" ]; do
            probe_sni_one "${SNI_CANDIDATES[$i]}" > "$resdir/$i.out" 2>/dev/null &
            pids+=("$!")
            i=$((i + 1)); j=$((j + 1))
        done
        wait "${pids[@]}" 2>/dev/null || true
    done
    cat "$resdir"/*.out 2>/dev/null | sort -k3,3n -k1,1n > "$resdir/all" || true
    if [ -s "$resdir/all" ]; then
        head -n 5 "$resdir/all" | while IFS=$'\t' read -r ms host score; do
            if [ "$score" = "0" ]; then mark="h2"; else mark="tls1.3"; fi
            printf '  %5sms  %-10s %s\n' "$ms" "$mark" "$host" >&2
        done
        best="$(head -n 1 "$resdir/all" | cut -f2)"
        score="$(head -n 1 "$resdir/all" | cut -f3)"
        if [ "$score" != "0" ]; then
            warn "最优候选未确认 HTTP/2（TLS1.3 与证书链已验证），已选用 $best" >&2
        fi
    fi
    rm -rf "$resdir"
    printf '%s' "${best:-}"
}

# =============================================================================
#  凭证生成
# =============================================================================
gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        "$SBN_BIN" generate uuid
    fi
}

gen_pass() {  # 24 位纯字母数字（避免 URL/JSON 转义问题）
    local p=""
    while [ "${#p}" -lt 24 ]; do
        p="${p}$(openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' || true)"
    done
    printf '%s' "${p:0:24}"
}

gen_reality_keys() {
    local out=""
    out="$("$SBN_BIN" generate reality-keypair 2>/dev/null)" || die "生成 Reality 密钥失败"
    REALITY_PRIVATE_KEY="$(printf '%s\n' "$out" | awk -F': ' '/PrivateKey/{print $2; exit}')"
    REALITY_PUBLIC_KEY="$(printf '%s\n' "$out" | awk -F': ' '/PublicKey/{print $2; exit}')"
    if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
        die "解析 Reality 密钥失败（sing-box 版本过旧？）"
    fi
}

gen_all_secrets() {
    info "生成凭证…"
    UUID="$(gen_uuid)"
    gen_reality_keys
    SHORT_ID="$(openssl rand -hex 4)"
    TUIC_UUID="$(gen_uuid)"
    TUIC_PASSWORD="$(gen_pass)"
    HY2_PASSWORD="$(gen_pass)"
    HY2_OBFS_PASSWORD="$(gen_pass)"
    ok "凭证已生成"
}

# =============================================================================
#  状态文件（保存凭证，重装/改端口不失效）
# =============================================================================
save_state() {
    local tmp="$SBN_STATE.tmp"
    {
        printf '# singbox-nat 安装状态（自动生成，勿手工编辑）\n'
        printf 'SBN_BUILD="%s"\n'        "$SBN_BUILD"
        printf 'UUID="%s"\n'             "$UUID"
        printf 'REALITY_PRIVATE_KEY="%s"\n' "$REALITY_PRIVATE_KEY"
        printf 'REALITY_PUBLIC_KEY="%s"\n'  "$REALITY_PUBLIC_KEY"
        printf 'SHORT_ID="%s"\n'         "$SHORT_ID"
        printf 'TUIC_UUID="%s"\n'        "$TUIC_UUID"
        printf 'TUIC_PASSWORD="%s"\n'    "$TUIC_PASSWORD"
        printf 'HY2_PASSWORD="%s"\n'     "$HY2_PASSWORD"
        printf 'HY2_OBFS_PASSWORD="%s"\n' "$HY2_OBFS_PASSWORD"
        printf 'HY2_OBFS="%s"\n'         "$HY2_OBFS"
        printf 'SNI="%s"\n'              "$SNI"
        printf 'TLS_SERVER_NAME="%s"\n'  "$TLS_SERVER_NAME"
        printf 'VLESS_PORT="%s"\n'       "$VLESS_PORT"
        printf 'TUIC_PORT="%s"\n'        "$TUIC_PORT"
        printf 'HY2_PORT="%s"\n'         "$HY2_PORT"
        printf 'PROTOS="%s"\n'           "$PROTOS"
        printf 'NODE_NAME="%s"\n'        "$NODE_NAME"
        printf 'PUBLIC_IP="%s"\n'        "$PUBLIC_IP"
        printf 'MASQUERADE="%s"\n'       "$MASQUERADE"
        printf 'LOG_LEVEL="%s"\n'        "$LOG_LEVEL"
        printf 'CERT_CUSTOM="%s"\n'      "$CERT_CUSTOM"
        printf 'CERT_PATH="%s"\n'        "$SBN_CERT"
        printf 'KEY_PATH="%s"\n'         "$SBN_KEY"
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$SBN_STATE"
}

load_state() {
    [ -f "$SBN_STATE" ] || return 1
    local bad
    bad="$(grep -cvE '^(#.*)?$|^[A-Z][A-Z0-9_]*="[A-Za-z0-9 .,_:@/+=~-]*"$' "$SBN_STATE" 2>/dev/null || true)"
    if [ "${bad:-0}" != "0" ]; then
        printf '%s 状态文件格式异常，已忽略\n' "${C_YEL}[提示]${C_RST}" >&2
        return 1
    fi
    # 记录环境变量/参数显式给出的值，source 后还原
    local ov_vless="$VLESS_PORT" ov_tuic="$TUIC_PORT" ov_hy2="$HY2_PORT"
    local ov_sni="$SNI" ov_protos="$PROTOS" ov_name="$NODE_NAME" ov_ip="$PUBLIC_IP"
    local ov_obfs="$HY2_OBFS" ov_masq="$MASQUERADE" ov_cert="$CUSTOM_CERT" ov_key="$CUSTOM_KEY"
    set -a
    # shellcheck disable=SC1090
    . "$SBN_STATE"
    set +a
    if [ "$VLESS_PORT_SET" = "1" ]; then VLESS_PORT="$ov_vless"; fi
    if [ "$TUIC_PORT_SET"  = "1" ]; then TUIC_PORT="$ov_tuic"; fi
    if [ "$HY2_PORT_SET"   = "1" ]; then HY2_PORT="$ov_hy2"; fi
    if [ "$SNI_SET"        = "1" ]; then SNI="$ov_sni"; fi
    if [ "$PROTOS_SET"     = "1" ]; then PROTOS="$ov_protos"; fi
    if [ "$NAME_SET"       = "1" ]; then NODE_NAME="$ov_name"; fi
    if [ "$IP_SET"         = "1" ]; then PUBLIC_IP="$ov_ip"; fi
    if [ "$OBFS_SET"       = "1" ]; then HY2_OBFS="$ov_obfs"; fi
    if [ "$MASQ_SET" = "1" ]; then MASQUERADE="$ov_masq"; fi
    if [ -n "$ov_cert" ]; then CUSTOM_CERT="$ov_cert"; fi
    if [ -n "$ov_key" ];  then CUSTOM_KEY="$ov_key"; fi
    if [ -z "$TLS_SERVER_NAME" ]; then TLS_SERVER_NAME="$SNI"; fi
    return 0
}

# =============================================================================
#  端口 / 网络检测
# =============================================================================
has_proto() { case ",$PROTOS," in *",$1,"*) return 0 ;; esac; return 1; }

validate_proto_list() {
    local p IFS=','
    for p in $PROTOS; do
        case "$p" in
            vless|tuic|hy2) ;;
            *) die "未知协议：$p（可选 vless,tuic,hy2）" ;;
        esac
    done
    [ -n "$PROTOS" ] || die "至少需要启用一个协议"
}

validate_port() {
    local v="$1" name="$2"
    case "$v" in
        ''|*[!0-9]*) die "$name 端口必须是数字：$v" ;;
    esac
    if [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then
        die "$name 端口超出范围（1-65535）：$v"
    fi
    if [ "$v" = "22" ]; then
        warn "$name 端口为 22，可能影响 SSH，请确认。"
    fi
}

check_ports() {
    if has_proto tuic && has_proto hy2 && [ "$TUIC_PORT" = "$HY2_PORT" ]; then
        die "TUIC 与 Hysteria2 都用 UDP，不能同为 ${TUIC_PORT}。请用 --hy2-port 指定别的端口。
       例如：--tuic-port 8443 --hy2-port 8444"
    fi
    if has_proto vless; then validate_port "$VLESS_PORT" "VLESS"; fi
    if has_proto tuic;  then validate_port "$TUIC_PORT" "TUIC"; fi
    if has_proto hy2;   then validate_port "$HY2_PORT" "Hysteria2"; fi
}

port_in_use() {  # port_in_use <port> <tcp|udp> -> 0 表示被占用
    local port="$1" proto="$2" out=""
    if command -v ss >/dev/null 2>&1; then
        if [ "$proto" = "udp" ]; then out="$(ss -lnu 2>/dev/null || true)"; else out="$(ss -lnt 2>/dev/null || true)"; fi
    elif command -v netstat >/dev/null 2>&1; then
        if [ "$proto" = "udp" ]; then out="$(netstat -lnu 2>/dev/null || true)"; else out="$(netstat -lnt 2>/dev/null || true)"; fi
    else
        return 1
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out" | awk -v port=":$port" '$4 ~ (port "$") {found=1} END{exit(found?0:1)}'
}

warn_port_busy() {
    local port="$1" proto="$2" label="$3"
    if port_in_use "$port" "$proto"; then
        warn "$label 端口 ${port}/${proto} 已被其他程序占用（若只是旧 sing-box 在跑可忽略）。"
    fi
}

detect_public_ip() {
    local u ip=""
    for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
        ip="$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '\r\n ' || true)"
        case "$ip" in
            *[!0-9.]*|'') ip="" ;;
        esac
        if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi
    done
    return 1
}

local_ipv4() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
    fi
    [ -n "$ip" ] || ip="$(hostname -i 2>/dev/null | awk '{print $1}' || true)"
    printf '%s' "$ip"
}

detect_listen_addr() {
    if [ -s /proc/net/if_inet6 ]; then printf '::'; else printf '0.0.0.0'; fi
}

# =============================================================================
#  证书
# =============================================================================
gen_cert() {
    if [ "$CERT_CUSTOM" = "1" ]; then
        SBN_CERT="$CERT_PATH"
        SBN_KEY="$KEY_PATH"
        [ -f "$SBN_CERT" ] || die "证书文件不存在：$SBN_CERT"
        [ -f "$SBN_KEY" ]  || die "私钥文件不存在：$SBN_KEY"
        info "使用自有证书：$SBN_CERT"
        return 0
    fi
    local name="$TLS_SERVER_NAME"
    info "生成自签证书（ECDSA P-256，SAN=${name}）…"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -nodes -keyout "$SBN_KEY" -out "$SBN_CERT" \
        -subj "/CN=${name}" -addext "subjectAltName=DNS:${name}" >/dev/null 2>&1 \
        || die "证书生成失败"
    chmod 600 "$SBN_KEY" "$SBN_CERT"
}

# =============================================================================
#  配置生成
# =============================================================================
tpl_vless() {
    cat <<EOF
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${VLESS_PORT},
      "tcp_fast_open": true,
      "users": [
        { "name": "u1", "uuid": "${UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": [ "${SHORT_ID}" ]
        }
      }
    }
EOF
}

tpl_tuic() {
    cat <<EOF
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${TUIC_PORT},
      "users": [
        { "name": "u1", "uuid": "${TUIC_UUID}", "password": "${TUIC_PASSWORD}" }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "${TLS_SERVER_NAME}",
        "alpn": [ "h3" ],
        "certificate_path": "${SBN_CERT}",
        "key_path": "${SBN_KEY}"
      }
    }
EOF
}

tpl_hy2() {
    if [ "$HY2_OBFS" = "1" ]; then
        cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${HY2_PORT},
      "users": [
        { "name": "u1", "password": "${HY2_PASSWORD}" }
      ],
      "ignore_client_bandwidth": true,
      "obfs": {
        "type": "salamander",
        "password": "${HY2_OBFS_PASSWORD}"
      },
      "masquerade": "${MASQUERADE}",
      "tls": {
        "enabled": true,
        "server_name": "${TLS_SERVER_NAME}",
        "alpn": [ "h3" ],
        "certificate_path": "${SBN_CERT}",
        "key_path": "${SBN_KEY}"
      }
    }
EOF
        return 0
    fi
    cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "${LISTEN_ADDR}",
      "listen_port": ${HY2_PORT},
      "users": [
        { "name": "u1", "password": "${HY2_PASSWORD}" }
      ],
      "ignore_client_bandwidth": true,
      "masquerade": "${MASQUERADE}",
      "tls": {
        "enabled": true,
        "server_name": "${TLS_SERVER_NAME}",
        "alpn": [ "h3" ],
        "certificate_path": "${SBN_CERT}",
        "key_path": "${SBN_KEY}"
      }
    }
EOF
}

gen_server_config() {
    local parts=() joined="" p
    if has_proto vless; then parts+=("$(tpl_vless)"); fi
    if has_proto tuic;  then parts+=("$(tpl_tuic)");  fi
    if has_proto hy2;   then parts+=("$(tpl_hy2)");   fi
    for p in "${parts[@]}"; do
        if [ -n "$joined" ]; then joined="${joined},"$'\n'; fi
        joined="${joined}${p}"
    done
    mkdir -p "$SBN_ETC"; chmod 700 "$SBN_ETC"
    cat > "$SBN_CONF" <<EOF
{
  "log": {
    "level": "${LOG_LEVEL}",
    "timestamp": true
  },
  "inbounds": [
${joined}
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "final": "direct"
  }
}
EOF
    chmod 600 "$SBN_CONF"
}

validate_server_config() {
    "$SBN_BIN" check -c "$SBN_CONF" >/tmp/sbn-check.log 2>&1 || {
        cat /tmp/sbn-check.log >&2
        die "服务端配置校验失败（见上面错误）"
    }
    ok "服务端配置校验通过"
}

# ---------- 客户端配置 ----------
client_insecure() {
    if [ "$CERT_CUSTOM" = "1" ]; then printf 'false'; else printf 'true'; fi
}

gen_client_config() {
    local parts=() joined="" p server insecure
    server="$PUBLIC_IP"
    [ -n "$server" ] || server="$(local_ipv4)"
    [ -n "$server" ] || server="127.0.0.1"
    insecure="$(client_insecure)"

    if has_proto vless; then
        parts+=("$(cat <<EOF
    {
      "type": "vless",
      "tag": "reality",
      "server": "${server}",
      "server_port": ${VLESS_PORT},
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled": true,
          "public_key": "${REALITY_PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    }
EOF
)")
    fi
    if has_proto tuic; then
        parts+=("$(cat <<EOF
    {
      "type": "tuic",
      "tag": "tuic",
      "server": "${server}",
      "server_port": ${TUIC_PORT},
      "uuid": "${TUIC_UUID}",
      "password": "${TUIC_PASSWORD}",
      "congestion_control": "bbr",
      "udp_relay_mode": "native",
      "tls": {
        "enabled": true,
        "server_name": "${TLS_SERVER_NAME}",
        "alpn": [ "h3" ],
        "insecure": ${insecure}
      }
    }
EOF
)")
    fi
    if has_proto hy2; then
        local obfs=""
        if [ "$HY2_OBFS" = "1" ]; then
            obfs="$(cat <<EOF
,
      "obfs": { "type": "salamander", "password": "${HY2_OBFS_PASSWORD}" }
EOF
)"
        fi
        parts+=("$(cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "server": "${server}",
      "server_port": ${HY2_PORT},
      "password": "${HY2_PASSWORD}"${obfs},
      "tls": {
        "enabled": true,
        "server_name": "${TLS_SERVER_NAME}",
        "alpn": [ "h3" ],
        "insecure": ${insecure}
      }
    }
EOF
)")
    fi

    for p in "${parts[@]}"; do
        if [ -n "$joined" ]; then joined="${joined},"$'\n'; fi
        joined="${joined}${p}"
    done

    local tags="" first="" t
    if has_proto vless; then tags="${tags}\"reality\", "; fi
    if has_proto tuic;  then tags="${tags}\"tuic\", "; fi
    if has_proto hy2;   then tags="${tags}\"hysteria2\", "; fi
    tags="${tags%, }"
    case "$tags" in
        \"reality\"*) first="reality" ;;
        *) first="$(printf '%s' "$tags" | cut -d'"' -f2)" ;;
    esac

    cat > "$SBN_CLIENT" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080 }
  ],
  "outbounds": [
${joined},
    { "type": "selector", "tag": "proxy", "outbounds": [ ${tags} ], "default": "${first}" },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "final": "proxy"
  }
}
EOF
    chmod 600 "$SBN_CLIENT"

    if "$SBN_BIN" check -c "$SBN_CLIENT" >/tmp/sbn-client-check.log 2>&1; then
        ok "客户端配置校验通过：$SBN_CLIENT"
    else
        cat /tmp/sbn-client-check.log >&2
        warn "客户端配置校验未通过（不影响服务端），请保留上面错误信息反馈。"
    fi
}

# =============================================================================
#  分享链接
# =============================================================================
host_for_url() {
    local h="$1"
    case "$h" in
        *:*) printf '[%s]' "$h" ;;
        *)   printf '%s' "$h" ;;
    esac
}

url_tag() {
    local n="$1"
    printf '%s' "$n" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-32
}

gen_links() {
    local server base tag insecure="1" q n
    server="$PUBLIC_IP"
    [ -n "$server" ] || server="$(local_ipv4)"
    [ -n "$server" ] || server="127.0.0.1"
    base="$(host_for_url "$server")"
    n="$(url_tag "$NODE_NAME")"
    if [ "$CERT_CUSTOM" = "1" ]; then insecure="0"; fi

    { echo "# singbox-nat 客户端链接 —— 生成时间 $(date '+%Y-%m-%d %H:%M:%S')"
      echo "# 服务器：${server}"
      echo
    } > "$SBN_LINKS"
    chmod 600 "$SBN_LINKS"

    if has_proto vless; then
        tag="${n}-reality"
        q="vless://${UUID}@${base}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${tag}"
        printf '# VLESS Reality（TCP）\n%s\n\n' "$q" >> "$SBN_LINKS"
    fi
    if has_proto tuic; then
        tag="${n}-tuic"
        q="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${base}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&sni=${TLS_SERVER_NAME}&udp_relay_mode=native&allow_insecure=${insecure}&disable_sni=0#${tag}"
        printf '# TUIC v5（UDP / QUIC）\n%s\n\n' "$q" >> "$SBN_LINKS"
    fi
    if has_proto hy2; then
        tag="${n}-hy2"
        if [ "$HY2_OBFS" = "1" ]; then
            q="hysteria2://${HY2_PASSWORD}@${base}:${HY2_PORT}/?sni=${TLS_SERVER_NAME}&insecure=${insecure}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}#${tag}"
        else
            q="hysteria2://${HY2_PASSWORD}@${base}:${HY2_PORT}/?sni=${TLS_SERVER_NAME}&insecure=${insecure}#${tag}"
        fi
        printf '# Hysteria2（UDP / QUIC）\n%s\n\n' "$q" >> "$SBN_LINKS"
    fi
    ok "客户端链接已写入：$SBN_LINKS"
}

# =============================================================================
#  openrc 服务
# =============================================================================
mem_total_mib() {
    local m
    m="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)"
    case "$m" in ''|*[!0-9]*) m=512 ;; esac
    printf '%s' "$m"
}

write_service() {
    local total limit
    total="$(mem_total_mib)"
    limit=$(( total / 4 ))
    [ "$limit" -lt 64 ]  && limit=64
    [ "$limit" -gt 320 ] && limit=320
    MEM_LIMIT_MIB="$limit"

    cat > "$SBN_INIT" <<EOF
#!/sbin/openrc-run
# 由 singbox-nat 生成，请勿手工修改（改参数请用 sbx 菜单）
name="sing-box"
description="sing-box — VLESS Reality / TUIC / Hysteria2"

command="${SBN_BIN}"
command_args="run -c ${SBN_CONF}"
command_user="root:root"
command_background="true"
pidfile="/run/\${RC_SVCNAME}.pid"

# 进程守护：崩溃 / 被杀 / 被 OOM 后自动拉起
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
respawn_period=60

output_log="${SBN_LOG}"
error_log="${SBN_LOG}"

# 文件句柄上限，避免高并发下 too many open files
rc_ulimit="-n 65535"

# 抗杀关键：给 Go 运行时设堆上限，内存紧张时主动 GC 而不是被内核 OOM 干掉
export GOMEMLIMIT="${limit}MiB"
export GOGC="100"
# 降低被内核 OOM killer 选中的概率（-1000~1000，越低越不容易被杀）
export SSD_OOM_SCORE_ADJ="-300"

depend() {
    need net
    after firewall
    provide sing-box
}

start_pre() {
    checkpath -f -m 0640 -o root:root "${SBN_LOG}"
}
EOF
    chmod 755 "$SBN_INIT"
    ok "openrc 服务已写入：$SBN_INIT（GOMEMLIMIT=${limit}MiB，总内存 ${total}MiB）"
}

install_logrotate() {
    mkdir -p /etc/periodic/daily
    cat > /etc/periodic/daily/singbox-logrotate <<EOF
#!/bin/sh
# 由 singbox-nat 生成：日志超过 8MB 时保留尾部并重启服务，避免磁盘被写满
f="${SBN_LOG}"
[ -f "\$f" ] || exit 0
size=\$(stat -c %s "\$f" 2>/dev/null || echo 0)
if [ "\$size" -gt 8388608 ]; then
    tail -c 262144 "\$f" > "\$f.tmp" 2>/dev/null && mv -f "\$f.tmp" "\$f"
    rc-service sing-box restart >/dev/null 2>&1 || true
fi
exit 0
EOF
    chmod 755 /etc/periodic/daily/singbox-logrotate
}

install_daily_restart() {
    mkdir -p /etc/periodic/daily
    cat > /etc/periodic/daily/singbox-restart <<'EOF'
#!/bin/sh
# 由 singbox-nat 生成：随 Alpine 每日 cron（默认 02:00）重启一次，清理长连接与内存碎片
rc-service sing-box restart >/dev/null 2>&1 || true
exit 0
EOF
    chmod 755 /etc/periodic/daily/singbox-restart
}

apply_tuning() {
    [ "$DO_TUNE" = "1" ] || { info "已跳过网络调优（--no-tune）"; return 0; }
    local conf=/etc/sysctl.d/99-singbox-nat.conf
    modprobe tcp_bbr >/dev/null 2>&1 || true
    local cc=""
    cc="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
    local bbr_ok=0
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then bbr_ok=1; fi

    mkdir -p /etc/sysctl.d
    {
        echo "# 由 singbox-nat 生成"
        if [ "$bbr_ok" = "1" ]; then
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        fi
        echo "net.ipv4.tcp_fastopen = 3"
        echo "net.core.somaxconn = 8192"
        # QUIC(UDP) 收发缓冲，提升 TUIC / Hysteria2 吞吐
        echo "net.core.rmem_max = 26214400"
        echo "net.core.wmem_max = 26214400"
    } > "$conf"

    if command -v sysctl >/dev/null 2>&1; then
        sysctl -p "$conf" >/dev/null 2>&1 || warn "部分 sysctl 项未能应用（容器/VPS 可能只读），不影响运行"
    fi
    if [ "$bbr_ok" = "1" ]; then
        ok "TCP BBR 已启用（当前：$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unknown)）"
    else
        warn "当前内核不支持 BBR，已跳过（QUIC 协议不受影响）"
    fi
}

svc_running() {
    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box status >/dev/null 2>&1
    else
        local pf="/run/sing-box.pid"
        [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null || echo 0)" 2>/dev/null
    fi
}

svc_start() {
    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box start >/dev/null 2>&1 || true
    fi
}

svc_stop() {
    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box stop >/dev/null 2>&1 || true
    fi
}

svc_restart() {
    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box restart >/dev/null 2>&1 || true
    fi
}

enable_service() {
    command -v rc-update >/dev/null 2>&1 || return 0
    rc-update add sing-box default >/dev/null 2>&1 || true
}

service_pid() {
    local pf="/run/sing-box.pid"
    if [ -f "$pf" ]; then cat "$pf" 2>/dev/null || true; fi
}

# =============================================================================
#  安装后自检与输出
# =============================================================================
install_self() {
    local dest="$SBN_LIB/install.sh"
    mkdir -p "$SBN_LIB"
    if [ -n "$SBN_SELF" ] && [ -f "$SBN_SELF" ]; then
        cp -f "$SBN_SELF" "$dest" 2>/dev/null || true
    fi
    if [ ! -f "$dest" ] && [ -n "$REPO_SLUG" ]; then
        local br
        for br in main master; do
            if fetch_asset "https://raw.githubusercontent.com/${REPO_SLUG}/${br}/install.sh" "$dest" >/dev/null 2>&1 \
               && [ -s "$dest" ]; then
                break
            fi
            rm -f "$dest"
        done
    fi
    if [ ! -f "$dest" ]; then
        warn "无法保存管理脚本（通过管道运行时常见）。请下载 install.sh 到本地后再运行，即可使用 sbx 菜单。"
        return 0
    fi
    chmod 755 "$dest"
    cat > /usr/local/bin/sbx <<EOF
#!/bin/sh
exec /bin/bash "${dest}" "\$@"
EOF
    chmod 755 /usr/local/bin/sbx
    ok "管理命令已就绪：sbx"
}

print_summary() {
    local server base lip nat=0
    server="$PUBLIC_IP"
    [ -n "$server" ] || server="$(local_ipv4)"
    [ -n "$server" ] || server="127.0.0.1"
    base="$(host_for_url "$server")"
    lip="$(local_ipv4)"

    hr
    printf '%s\n' " sing-box 部署完成  (singbox-nat ${SBN_BUILD})"
    hr
    printf ' 服务状态 : %s\n' "$(if svc_running; then echo '运行中'; else echo '未运行'; fi)"
    printf ' sing-box : %s\n' "$("$SBN_BIN" version 2>/dev/null | head -n 1)"
    printf ' 配置文件 : %s\n' "$SBN_CONF"
    printf ' 客户端   : %s\n' "$SBN_CLIENT"
    printf ' 链接文件 : %s\n' "$SBN_LINKS"
    echo
    printf ' %-14s %-6s %-6s %s\n' "协议" "端口" "传输" "说明"
    if has_proto vless; then printf ' %-14s %-6s %-6s %s\n' "VLESS Reality" "$VLESS_PORT" "TCP"  "SNI=${SNI}"; fi
    if has_proto tuic;  then printf ' %-14s %-6s %-6s %s\n' "TUIC v5"        "$TUIC_PORT"  "UDP"  "拥塞控制 BBR"; fi
    if has_proto hy2;   then printf ' %-14s %-6s %-6s %s\n' "Hysteria2"      "$HY2_PORT"   "UDP"  "obfs=$([ "$HY2_OBFS" = "1" ] && echo salamander || echo off)"; fi
    echo
    printf ' 服务器地址: %s\n' "$server"
    if [ -n "$lip" ] && [ "$lip" != "$server" ]; then
        nat=1
        printf ' 内网地址  : %s\n' "$lip"
        warn "检测到 NAT 环境：务必在服务商面板把这几个端口的 TCP/UDP 映射到本机（TCP ${VLESS_PORT:-443} / UDP ${TUIC_PORT:-443},${HY2_PORT:-8443}），否则客户端连不上。"
    fi
    echo
    hr
    printf '%s\n' " 客户端链接（复制到 Hiddify / sing-box / mihomo / NekoBox 等）"
    hr
    sed -e 's/^# /  # /' "$SBN_LINKS" 2>/dev/null || true
    if has_proto tuic || has_proto hy2; then
        echo "  # 自签证书：客户端需允许不安全连接（TUIC / Hysteria2 的 insecure / 跳过证书校验）"
    fi
    hr
    printf ' 管理命令 : %s\n' "sbx            （状态 / 改端口 / 换 SNI / 看日志 / 体检 / 卸载）"
    printf ' 常用命令 : %s\n' "rc-service sing-box {status|restart|stop}   sbx log   sbx doctor"
    hr
}

# =============================================================================
#  安装主流程
# =============================================================================
cmd_install() {
    need_root
    if ! is_alpine; then
        warn "未检测到 Alpine（缺少 /etc/alpine-release 或 apk）。脚本按 Alpine 设计，其他系统请自行适配。"
    fi
    ensure_deps
    mkdir -p "$SBN_ETC"; chmod 700 "$SBN_ETC"

    local have_state=0 fresh=0
    [ -f "$SBN_STATE" ] && have_state=1
    if [ "$DO_RESET" = "1" ]; then
        have_state=0
    fi
    if [ "$have_state" = "1" ]; then
        if load_state; then
            info "检测到已有配置，沿用现有凭证（改端口/换 SNI 不会让老客户端失效）"
        else
            have_state=0
        fi
    fi
    if [ "$have_state" = "0" ]; then fresh=1; fi

    install_binary

    if [ "$fresh" = "1" ]; then
        gen_all_secrets
    fi

    # SNI
    if [ -z "$SNI" ]; then
        SNI="$(pick_sni)"
        if [ -z "$SNI" ]; then
            SNI="www.microsoft.com"
            warn "所有候选 SNI 探测失败（可能网络受限），回退使用 ${SNI}"
        else
            ok "自动选择 SNI：${SNI}"
        fi
    else
        info "使用指定 SNI：${SNI}"
    fi
    if [ -z "$TLS_SERVER_NAME" ]; then TLS_SERVER_NAME="$SNI"; fi

    # 端口交互（首次安装或显式改端口时可交互确认）
    if [ "$ASSUME_YES" != "1" ] && tty_available; then
        echo
        info "端口设置（直接回车保持默认；NAT 机器请填服务商已映射的端口）"
        if has_proto vless; then VLESS_PORT="$(ask '  VLESS Reality 端口(TCP)' "$VLESS_PORT")"; fi
        if has_proto tuic;  then TUIC_PORT="$(ask '  TUIC 端口(UDP)'          "$TUIC_PORT")";  fi
        if has_proto hy2;   then HY2_PORT="$(ask '  Hysteria2 端口(UDP)'     "$HY2_PORT")";   fi
        NODE_NAME="$(ask '  节点名称' "$NODE_NAME")"
    fi

    validate_proto_list
    check_ports
    if has_proto vless; then warn_port_busy "$VLESS_PORT" tcp "VLESS"; fi
    if has_proto tuic;  then warn_port_busy "$TUIC_PORT"  udp "TUIC"; fi
    if has_proto hy2;   then warn_port_busy "$HY2_PORT"   udp "Hysteria2"; fi

    # 公网 IP
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP="$(detect_public_ip || true)"
        [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(local_ipv4)"
        [ -n "$PUBLIC_IP" ] || PUBLIC_IP="127.0.0.1"
    fi

    LISTEN_ADDR="$(detect_listen_addr)"

    # 证书来源：命令行指定 > 状态文件记录 > 自签
    if [ -n "$CUSTOM_CERT" ] || [ -n "$CUSTOM_KEY" ]; then
        if [ -z "$CUSTOM_CERT" ] || [ -z "$CUSTOM_KEY" ]; then
            die "使用自有证书需同时提供 --cert 与 --key"
        fi
        CERT_CUSTOM=1
        CERT_PATH="$CUSTOM_CERT"
        KEY_PATH="$CUSTOM_KEY"
    fi
    if [ "$CERT_CUSTOM" = "1" ]; then
        SBN_CERT="$CERT_PATH"
        SBN_KEY="$KEY_PATH"
    else
        SBN_CERT="$SBN_ETC/cert.pem"
        SBN_KEY="$SBN_ETC/key.pem"
        CERT_PATH="$SBN_CERT"
        KEY_PATH="$SBN_KEY"
    fi

    gen_cert
    gen_server_config
    validate_server_config
    gen_client_config
    gen_links
    save_state

    write_service
    install_logrotate
    if [ "$DAILY_RESTART" = "1" ]; then install_daily_restart; fi
    apply_tuning

    # 启动 / 重启
    if svc_running; then svc_restart; else svc_start; fi
    enable_service

    local i
    for i in 1 2 3; do
        sleep 1
        svc_running && break
    done
    if ! svc_running; then
        echo
        warn "服务未能启动，最近日志："
        tail -n 25 "$SBN_LOG" 2>/dev/null || true
        die "启动失败。常见原因：端口被占用 / 配置校验失败 / openrc 未正确安装。"
    fi

    install_self
    print_summary
    ok "全部完成。保存好 ${SBN_LINKS}（含全部密码与密钥）。"
}

# =============================================================================
#  管理命令
# =============================================================================
require_state() {
    [ -f "$SBN_STATE" ] || die "尚未安装，请先运行：bash install.sh"
    load_state || die "状态文件读取失败，请重新安装（bash install.sh）"
    if [ -z "${SNI:-}" ]; then SNI="${TLS_SERVER_NAME:-www.microsoft.com}"; fi
    if [ -z "${TLS_SERVER_NAME:-}" ]; then TLS_SERVER_NAME="$SNI"; fi
}

rebuild() {  # 重新生成配置 + 链接 + 客户端，并重启
    LISTEN_ADDR="$(detect_listen_addr)"
    gen_cert
    gen_server_config
    validate_server_config
    gen_client_config
    gen_links
    save_state
    write_service
    svc_restart
    sleep 1
    if svc_running; then ok "已重新加载配置并重启服务"; else
        tail -n 25 "$SBN_LOG" 2>/dev/null || true
        die "重启后服务未运行，请查看上面的日志"
    fi
}

cmd_status() {
    require_state
    hr
    printf ' sing-box 状态\n'
    hr
    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box status 2>&1 | sed 's/^/ /' || true
    else
        printf ' 未检测到 openrc（rc-service）\n'
    fi
    local pid; pid="$(service_pid)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        local rss
        rss="$(awk '/VmRSS/{printf "%d MB", $2/1024}' "/proc/$pid/status" 2>/dev/null || echo unknown)"
        printf ' PID      : %s\n' "$pid"
        printf ' 内存占用 : %s\n' "$rss"
        printf ' OOM 保护 : %s\n' "$(cat "/proc/$pid/oom_score_adj" 2>/dev/null || echo unknown)"
        printf ' GOMEMLIMIT: %s\n' "$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | awk -F= '/^GOMEMLIMIT=/{print $2}' || echo unknown)"
    fi
    echo
    printf ' 配置校验 : %s\n' "$(if "$SBN_BIN" check -c "$SBN_CONF" >/dev/null 2>&1; then echo '通过'; else echo '失败'; fi)"
    echo
    printf ' %-14s %-6s %-6s %s\n' "协议" "端口" "传输" "监听"
    if has_proto vless; then printf ' %-14s %-6s %-6s %s\n' "VLESS Reality" "$VLESS_PORT" "TCP" "$(if port_in_use "$VLESS_PORT" tcp; then echo 是; else echo 否; fi)"; fi
    if has_proto tuic;  then printf ' %-14s %-6s %-6s %s\n' "TUIC v5" "$TUIC_PORT" "UDP" "$(if port_in_use "$TUIC_PORT" udp; then echo 是; else echo 否; fi)"; fi
    if has_proto hy2;   then printf ' %-14s %-6s %-6s %s\n' "Hysteria2" "$HY2_PORT" "UDP" "$(if port_in_use "$HY2_PORT" udp; then echo 是; else echo 否; fi)"; fi
    hr
}

cmd_links() {
    require_state
    [ -f "$SBN_LINKS" ] || gen_links
    printf '\n'
    cat "$SBN_LINKS"
    printf '\n提示：TUIC/Hysteria2 使用自签证书，客户端需允许不安全连接。\n'
}

cmd_log() {
    local n="${1:-80}"
    [ -f "$SBN_LOG" ] || die "日志文件不存在：$SBN_LOG"
    tail -n "$n" "$SBN_LOG"
}

cmd_ports() {
    require_state; need_root
    local v="$VLESS_PORT" t="$TUIC_PORT" h="$HY2_PORT"
    echo
    info "修改端口（回车保持不变）"
    if has_proto vless; then v="$(ask '  VLESS Reality 端口(TCP)' "$v")"; fi
    if has_proto tuic;  then t="$(ask '  TUIC 端口(UDP)'          "$t")"; fi
    if has_proto hy2;   then h="$(ask '  Hysteria2 端口(UDP)'     "$h")"; fi
    VLESS_PORT="$v"; TUIC_PORT="$t"; HY2_PORT="$h"
    VLESS_PORT_SET=1; TUIC_PORT_SET=1; HY2_PORT_SET=1
    validate_proto_list; check_ports
    warn "改端口后记得同步服务商的端口映射，并把新链接发给客户端。"
    rebuild
    cmd_links
}

cmd_regen() {
    require_state; need_root
    if ! ask_yes "将重新生成全部凭证，现有客户端全部失效，继续？"; then
        info "已取消"; return 0
    fi
    gen_all_secrets
    rebuild
    ok "凭证已全部更新"
    cmd_links
}

cmd_sni() {
    require_state; need_root
    local s
    s="$(ask '新 SNI（直接回车=自动优选）' '')"
    if [ -z "$s" ]; then
        s="$(pick_sni)"
        [ -n "$s" ] || die "自动优选失败，请手动指定 SNI"
    fi
    SNI="$s"; TLS_SERVER_NAME="$s"
    warn "自签证书的 SAN 会随之更新，客户端仅需改 SNI；若用自有证书请确认域名一致。"
    rebuild
    ok "SNI 已切换为：$s"
}

cmd_update() {
    need_root
    info "检查 sing-box 最新版本…"
    SINGBOX_VERSION=""
    local ver; ver="$(resolve_version)"
    info "目标版本：v${ver}"
    svc_stop
    install_binary
    if "$SBN_BIN" check -c "$SBN_CONF" >/dev/null 2>&1; then
        svc_start; sleep 1
        if svc_running; then ok "更新完成并已启动"; else
            tail -n 25 "$SBN_LOG" 2>/dev/null || true
            die "更新后启动失败，请回滚版本或查看日志"
        fi
    else
        warn "新版对当前配置校验失败，未启动。可尝试 --version 指定旧版本。"
        return 1
    fi
}

cmd_cert() {
    require_state; need_root
    local c k
    c="$(ask '证书文件路径（fullchain.pem）' '')"
    k="$(ask '私钥文件路径（privkey.pem）' '')"
    [ -f "$c" ] || die "证书不存在：$c"
    [ -f "$k" ] || die "私钥不存在：$k"
    CERT_CUSTOM=1
    CERT_PATH="$c"
    KEY_PATH="$k"
    SBN_CERT="$c"
    SBN_KEY="$k"
    info "已切换为自有证书，客户端将不再需要「允许不安全连接」。"
    rebuild
    cmd_links
}

cmd_doctor() {
    hr
    printf ' 体检 / 诊断\n'
    hr
    printf ' 系统        : %s\n' "$(cat /etc/alpine-release 2>/dev/null || uname -s)"
    printf ' 内核        : %s\n' "$(uname -r)"
    printf ' 运行时长    : %s\n' "$(uptime 2>/dev/null | sed 's/.*up //; s/,.*//' || echo unknown)"
    printf ' 内存        : %s\n' "$(free -m 2>/dev/null | awk 'NR==2{printf "总 %sMB / 可用 %sMB", $2, $7}' || echo unknown)"
    printf ' 磁盘(/)     : %s\n' "$(df -h / 2>/dev/null | awk 'NR==2{printf "已用 %s / 共 %s (%s)", $3, $2, $5}' || echo unknown)"
    printf ' 日志大小    : %s\n' "$(du -h "$SBN_LOG" 2>/dev/null | awk '{print $1}' || echo '无')"
    printf ' 拥塞控制    : %s\n' "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo unknown)"
    printf ' UDP rmem_max: %s\n' "$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo unknown)"
    echo
    if command -v rc-service >/dev/null 2>&1; then
        printf ' 服务状态    : %s\n' "$(rc-service sing-box status 2>&1 | head -n 2 | tr '\n' ' ')"
    fi
    local pid; pid="$(service_pid)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf ' PID / RSS   : %s / %s\n' "$pid" "$(awk '/VmRSS/{printf "%d MB", $2/1024}' "/proc/$pid/status" 2>/dev/null || echo unknown)"
        printf ' GOMEMLIMIT  : %s\n' "$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | awk -F= '/^GOMEMLIMIT=/{print $2}' || echo unknown)"
        printf ' oom_score_adj: %s\n' "$(cat "/proc/$pid/oom_score_adj" 2>/dev/null || echo unknown)"
    else
        warn "sing-box 未在运行"
    fi
    echo
    printf ' 配置校验    : %s\n' "$(if "$SBN_BIN" check -c "$SBN_CONF" >/dev/null 2>&1; then echo '通过'; else echo '失败'; fi)"
    if [ -f "$SBN_CLIENT" ]; then
        printf ' 客户端配置  : %s\n' "$(if "$SBN_BIN" check -c "$SBN_CLIENT" >/dev/null 2>&1; then echo '通过'; else echo '失败'; fi)"
    fi
    echo
    printf ' 近期 OOM / 被杀记录（dmesg）：\n'
    if command -v dmesg >/dev/null 2>&1; then
        dmesg 2>/dev/null | grep -iE 'out of memory|killed process|oom-kill' | tail -n 5 | sed 's/^/   /' || true
    else
        printf '   （无 dmesg）\n'
    fi
    echo
    printf ' 端口监听：\n'
    if command -v ss >/dev/null 2>&1; then
        ss -lntu 2>/dev/null | awk -v p1=":${VLESS_PORT}\$" -v p2=":${TUIC_PORT}\$" -v p3=":${HY2_PORT}\$" 'NR==1 || $4 ~ p1 || $4 ~ p2 || $4 ~ p3' | sed 's/^/   /'
    else
        printf '   （无 ss 命令）\n'
    fi
    hr
}

cmd_uninstall() {
    require_state; need_root
    if ! ask_yes "确认卸载 sing-box 及全部配置（不可恢复）？"; then
        info "已取消"; return 0
    fi
    svc_stop
    command -v rc-update >/dev/null 2>&1 && rc-update del sing-box default >/dev/null 2>&1 || true
    rm -f "$SBN_INIT" /usr/local/bin/sbx
    rm -f /etc/periodic/daily/singbox-logrotate /etc/periodic/daily/singbox-restart
    rm -rf "$SBN_ETC" "$SBN_LIB"
    rm -f "$SBN_LOG"
    ok "已卸载。sing-box 二进制保留在 ${SBN_BIN}（如需删除：rm -f ${SBN_BIN}）"
}

cmd_menu() {
    need_root
    tty_available || die "菜单需要交互终端；非交互请用子命令，如：sbx status"
    while :; do
        printf '\n'
        printf '%s\n' "==============================================="
        printf ' sing-box 管理菜单   v%s\n' "$SBN_BUILD"
        printf '%s\n' "==============================================="
        cat <<'EOF'
 1) 运行状态          2) 重启服务
 3) 分享链接          4) 修改端口
 5) 重新生成凭证      6) 重新选择 SNI
 7) 查看日志          8) 更新 sing-box
 9) 体检 / 诊断      10) 更换证书
11) 每日自动重启      0) 卸载
 q) 退出
EOF
        local c
        c="$(ask '请选择' '')"
        case "$c" in
            1) cmd_status ;;
            2) svc_restart; ok "已重启" ;;
            3) cmd_links ;;
            4) cmd_ports ;;
            5) cmd_regen ;;
            6) cmd_sni ;;
            7) cmd_log 120 ;;
            8) cmd_update ;;
            9) cmd_doctor ;;
            10) cmd_cert ;;
            11) install_daily_restart; ok "已安装每日自动重启（Alpine cron 默认 02:00）" ;;
            0) cmd_uninstall && break ;;
            q|Q) break ;;
            '') ;;
            *) warn "无效选择：$c" ;;
        esac
        printf '\n按回车返回菜单…'
        IFS= read -r _ </dev/tty 2>/dev/null || true
    done
}

# =============================================================================
#  参数解析
# =============================================================================
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)        ASSUME_YES=1 ;;
            --sni)           SNI="${2:-}"; SNI_SET=1; shift ;;
            --port|--vless-port) VLESS_PORT="${2:-}"; VLESS_PORT_SET=1; shift ;;
            --tuic-port)     TUIC_PORT="${2:-}"; TUIC_PORT_SET=1; shift ;;
            --hy2-port)      HY2_PORT="${2:-}"; HY2_PORT_SET=1; shift ;;
            --proto)         PROTOS="${2:-}"; PROTOS_SET=1; shift ;;
            --name)          NODE_NAME="${2:-}"; NAME_SET=1; shift ;;
            --public-ip)     PUBLIC_IP="${2:-}"; IP_SET=1; shift ;;
            --obfs)          HY2_OBFS=1; OBFS_SET=1 ;;
            --no-obfs)       HY2_OBFS=0; OBFS_SET=1 ;;
            --cert)          CUSTOM_CERT="${2:-}"; shift ;;
            --key)           CUSTOM_KEY="${2:-}"; shift ;;
            --version)       SINGBOX_VERSION="${2:-}"; shift ;;
            --proxy)         GH_PROXY="${2:-}"; shift ;;
            --repo)          REPO_SLUG="${2:-}"; shift ;;
            --reset)         DO_RESET=1 ;;
            --no-tune)       DO_TUNE=0 ;;
            --daily-restart) DAILY_RESTART=1 ;;
            -h|--help)       usage; exit 0 ;;
            -v|--version)    printf 'singbox-nat %s\n' "$SBN_BUILD"; exit 0 ;;
            *) die "未知参数：$1（用 --help 查看用法）" ;;
        esac
        shift
    done
}

# =============================================================================
#  入口
# =============================================================================
main() {
    local cmd="${1:-install}"
    case "$cmd" in
        install)              shift || true; parse_args "$@"; cmd_install ;;
        menu)                 cmd_menu ;;
        links)                cmd_links ;;
        status)               cmd_status ;;
        log)                  shift || true; cmd_log "${1:-80}" ;;
        ports)                cmd_ports ;;
        regen)                cmd_regen ;;
        sni)                  cmd_sni ;;
        update)               cmd_update ;;
        cert)                 cmd_cert ;;
        doctor)               cmd_doctor ;;
        uninstall)            cmd_uninstall ;;
        start|stop|restart)   need_root; command -v rc-service >/dev/null 2>&1 || die "未检测到 openrc"; rc-service sing-box "$cmd" || true ;;
        help|-h|--help)       usage ;;
        version|-v|--version) printf 'singbox-nat %s\n' "$SBN_BUILD" ;;
        *)                    parse_args "$@"; cmd_install ;;
    esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
    main "$@"
fi

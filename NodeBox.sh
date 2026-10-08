#!/usr/bin/env bash
# NodeBox - Linux proxy core/node manager
# Final Linux release: core management, dynamic source selection, transactional
# node management, Sing-box + Mihomo server protocols, systemd isolation,
# watchdog, port/certificate management, and global `box` command.

set -Eeuo pipefail
IFS=$'\n\t'

readonly NODEBOX_NAME="NodeBox"
readonly NODEBOX_VERSION="1.0.0"
readonly NODEBOX_ROOT="/opt/nodebox"
readonly NODEBOX_ETC="/etc/nodebox"
readonly NODEBOX_BIN="${NODEBOX_ROOT}/bin"
readonly NODEBOX_CORE="${NODEBOX_ROOT}/core"
readonly NODEBOX_TMP="${NODEBOX_ROOT}/tmp"
readonly NODEBOX_LOG="${NODEBOX_ROOT}/logs"
readonly NODEBOX_NODES="${NODEBOX_ETC}/nodes"
readonly NODEBOX_CONFIG="${NODEBOX_ETC}/config"
readonly NODEBOX_STATE="${NODEBOX_ETC}/state"
readonly NODEBOX_LOCK="${NODEBOX_ETC}/nodebox.lock"
readonly NODEBOX_INIT="${NODEBOX_ETC}/.initialized"
readonly NODEBOX_BOX="/usr/local/bin/box"
readonly NODEBOX_WATCHDOG="${NODEBOX_BIN}/nodebox-watchdog"
readonly NODEBOX_WATCHDOG_SERVICE="nodebox-watchdog.service"
readonly NODEBOX_SOURCE_SINGBOX="${NODEBOX_STATE}/core-source-sing-box.json"
readonly NODEBOX_SOURCE_MIHOMO="${NODEBOX_STATE}/core-source-mihomo.json"
readonly NODEBOX_SOURCE_MAX_CANDIDATES="5"
readonly NODEBOX_DEFAULT_PORT="2000"
readonly NODEBOX_DEFAULT_TLS_SNI="genshin.hoyoverse.com"
readonly NODEBOX_MAX_PORT="65535"
readonly NODEBOX_GITHUB_TIMEOUT="30"
readonly NODEBOX_MIHOMO_RELEASES_URL="https://github.com/MetaCubeX/mihomo/releases"
readonly NODEBOX_MIHOMO_REPOSITORY="MetaCubeX/mihomo"
readonly NODEBOX_SCRIPT_URL="${NODEBOX_SCRIPT_URL:-}"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
SELF_PATH=""

# Batch generation context. When enabled, protocol installers reuse the
# single server/SNI entered by the user and auto-generate credentials.
NODEBOX_BATCH_MODE=0
NODEBOX_BATCH_SERVER=""
NODEBOX_BATCH_SNI=""

if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
    SELF_PATH="$(readlink -f -- "${SCRIPT_SOURCE}" 2>/dev/null || printf '%s' "${SCRIPT_SOURCE}")"
fi

# ---------- Global TLS defaults ----------
# All TLS-capable nodes use this SNI/certificate name unless the user explicitly
# enters another value during node installation. It is intentionally independent
# from the server address: the node still connects to the real server IP/domain.

# ---------- UI ----------
msg()  { printf '\033[1;36m[NodeBox]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; }
line() { printf '%s\n' '────────────────────────────────────────────────────────────'; }

pause_back() {
    printf '\n';
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        read -r -n 1 -s -p '按任意键返回上一级...' </dev/tty || true
        printf '\n'
    else
        printf '非交互模式：跳过等待。\n'
    fi
    clear 2>/dev/null || true
}

ask() {
    local prompt="$1" default="${2:-}" answer
    if (( NODEBOX_BATCH_MODE == 1 )); then
        case "$prompt" in
            *服务器地址*) printf '%s' "$NODEBOX_BATCH_SERVER"; return 0 ;;
            *TLS\ SNI*|*证书名称*) printf '%s' "$NODEBOX_BATCH_SNI"; return 0 ;;
            *) printf '%s' "$default"; return 0 ;;
        esac
    fi
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        if [[ -n "$default" ]]; then
            read -r -p "${prompt} [${default}]：" answer </dev/tty || answer=""
            printf '%s' "${answer:-$default}"
        else
            read -r -p "${prompt}：" answer </dev/tty || answer=""
            printf '%s' "$answer"
        fi
    else
        printf '%s' "$default"
    fi
}

confirm() {
    local prompt="$1" default="${2:-N}" answer
    answer="$(ask "${prompt} (y/N)" "$default")"
    [[ "$answer" =~ ^[Yy]$ ]]
}

menu_choice() {
    local prompt="$1" choice
    if [[ ! -r /dev/tty ]]; then
        return 1
    fi
    read -r -p "$prompt" choice </dev/tty || return 1
    printf '%s' "$choice"
}

show_banner() {
    clear 2>/dev/null || true
    printf '\n'
    printf '╔════════════════════════════════════════════════════════════╗\n'
    printf '║                     NodeBox %s                        ║\n' "$NODEBOX_VERSION"
    printf '║              Linux Proxy Node Manager                    ║\n'
    printf '╚════════════════════════════════════════════════════════════╝\n'
    printf '\n'
}

ui_title() {
    local title="$1" subtitle="${2:-}"
    printf '\n╭────────────────────────────────────────────────────────────╮\n'
    printf '│  %-56s │\n' "$title"
    [[ -n "$subtitle" ]] && printf '│  %-56s │\n' "$subtitle"
    printf '╰────────────────────────────────────────────────────────────╯\n'
}

ui_menu_item() { printf '  %-3s %-45s\n' "$1" "$2"; }
ui_status_dot() {
    if [[ "$1" == "ok" ]]; then printf '\033[1;32m●\033[0m'; else printf '\033[1;31m●\033[0m'; fi
}

# ---------- Runtime / safety ----------
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err '请使用 root 运行。'
        err '示例：sudo bash nodebox.sh'
        exit 1
    fi
}

on_error() {
    local rc=$?
    err "脚本发生错误，退出码：${rc}，位置：${BASH_SOURCE[1]:-unknown}:${BASH_LINENO[0]:-0}"
    err "详细日志：${NODEBOX_LOG}/nodebox.log"
    exit "$rc"
}
trap on_error ERR

acquire_lock() {
    mkdir -p "$NODEBOX_ETC"
    if ( set -o noclobber; printf '%s\n' "$$" > "$NODEBOX_LOCK" ) 2>/dev/null; then
        trap 'rm -f -- "$NODEBOX_LOCK" 2>/dev/null || true' EXIT
    else
        local owner='unknown'
        [[ -f "$NODEBOX_LOCK" ]] && owner="$(cat "$NODEBOX_LOCK" 2>/dev/null || printf unknown)"
        err "检测到 NodeBox 正在运行，锁文件：${NODEBOX_LOCK}，PID：${owner}"
        exit 1
    fi
}

log_init() {
    mkdir -p "$NODEBOX_LOG"
    touch "${NODEBOX_LOG}/nodebox.log"
    exec > >(tee -a "${NODEBOX_LOG}/nodebox.log") 2>&1
}

# ---------- OS / dependencies ----------
PKG_MANAGER=""

find_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then PKG_MANAGER='apt'; return; fi
    if command -v dnf >/dev/null 2>&1; then PKG_MANAGER='dnf'; return; fi
    if command -v yum >/dev/null 2>&1; then PKG_MANAGER='yum'; return; fi
    if command -v apk >/dev/null 2>&1; then PKG_MANAGER='apk'; return; fi
    if command -v pacman >/dev/null 2>&1; then PKG_MANAGER='pacman'; return; fi
    if command -v zypper >/dev/null 2>&1; then PKG_MANAGER='zypper'; return; fi
    PKG_MANAGER=''
}

package_for_cmd() {
    case "$1" in
        curl) printf 'curl' ;;
        wget) printf 'wget' ;;
        tar) printf 'tar' ;;
        gzip) printf 'gzip' ;;
        openssl) printf 'openssl' ;;
        systemctl) printf 'systemd' ;;
        ss) printf 'iproute2' ;;
        sha256sum) printf 'coreutils' ;;
        base64) printf 'coreutils' ;;
        pgrep) printf 'procps' ;;
        mktemp|install) printf 'coreutils' ;;
        *) printf '%s' "$1" ;;
    esac
}

install_packages() {
    local -a pkgs=("$@")
    [[ "${#pkgs[@]}" -eq 0 ]] && return 0
    case "$PKG_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y "${pkgs[@]}"
            ;;
        dnf) dnf install -y "${pkgs[@]}" ;;
        yum) yum install -y "${pkgs[@]}" ;;
        apk) apk add --no-cache "${pkgs[@]}" ;;
        pacman) pacman -Sy --noconfirm "${pkgs[@]}" ;;
        zypper) zypper --non-interactive install "${pkgs[@]}" ;;
        *) return 1 ;;
    esac
}

check_dependencies() {
    local -a missing_cmds=()
    local -a missing_pkgs=()
    local cmd pkg
    local required=(curl tar gzip openssl systemctl ss sha256sum awk sed grep find readlink jq pgrep mktemp install)

    find_pkg_manager

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
            pkg="$(package_for_cmd "$cmd")"
            [[ " ${missing_pkgs[*]} " != *" ${pkg} "* ]] && missing_pkgs+=("$pkg")
        fi
    done

    printf '\n'
    line
    printf '首次运行环境依赖检测\n'
    line
    printf '系统：%s\n' "$(. /etc/os-release 2>/dev/null && printf '%s %s' "${PRETTY_NAME:-Linux}" "${VERSION_ID:-}" || printf 'Linux')"
    printf '架构：%s\n' "$(uname -m)"
    printf '包管理器：%s\n\n' "${PKG_MANAGER:-未识别}"

    if [[ "${#missing_cmds[@]}" -eq 0 ]]; then
        ok '全部基础依赖已存在。'
    else
        warn "缺少依赖：${missing_cmds[*]}"
        if [[ -n "$PKG_MANAGER" ]]; then
            printf '待安装软件包：%s\n' "${missing_pkgs[*]}"
            if [[ -f "$NODEBOX_INIT" ]]; then
                warn '初始化标记已存在，但检测到依赖缺失。'
            fi
            if confirm '是否立即安装缺少的依赖' 'Y'; then
                install_packages "${missing_pkgs[@]}"
                local failed=0
                for cmd in "${required[@]}"; do
                    if ! command -v "$cmd" >/dev/null 2>&1; then
                        err "依赖仍然缺失：${cmd}"
                        failed=1
                    fi
                done
                (( failed == 0 )) || exit 1
                ok '依赖安装完成。'
            else
                err '缺少运行依赖，NodeBox 无法继续。'
                exit 1
            fi
        else
            err '无法识别系统包管理器，请手动安装上述依赖后重新运行。'
            exit 1
        fi
    fi

    if [[ ! -f "$NODEBOX_INIT" ]]; then
        touch "$NODEBOX_INIT"
        ok '首次环境初始化完成。'
    fi
    pause_back
}

# ---------- Architecture ----------
normalize_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armv7) printf 'armv7' ;;
        i386|i686|x86) printf '386' ;;
        s390x) printf 's390x' ;;
        *) return 1 ;;
    esac
}

# ---------- Network / GitHub ----------
github_get() {
    local url="$1"
    curl -fsSL --connect-timeout "$NODEBOX_GITHUB_TIMEOUT" --max-time 120 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: NodeBox' "$url"
}

# GitHub is contacted only when a source is not cached or the user explicitly
# requests source re-evaluation. Normal NodeBox startup does not query GitHub.
github_search() {
    local query="$1"
    local encoded
    encoded="$(printf '%s' "$query" | sed 's/ /%20/g; s/+/%2B/g')"
    github_get "https://api.github.com/search/repositories?q=${encoded}&sort=stars&order=desc&per_page=30"
}

source_file() {
    case "$1" in
        sing-box) printf '%s' "$NODEBOX_SOURCE_SINGBOX" ;;
        mihomo) printf '%s' "$NODEBOX_SOURCE_MIHOMO" ;;
        *) return 1 ;;
    esac
}

source_repo() {
    local f
    f="$(source_file "$1")"
    [[ -s "$f" ]] && jq -r '.repository // empty' "$f"
}

source_is_locked() {
    local f
    f="$(source_file "$1")"
    [[ -s "$f" ]] && jq -e '.locked == true and (.repository | type == "string")' "$f" >/dev/null 2>&1
}

source_release_available() {
    local repo="$1" data
    data="$(github_get "https://api.github.com/repos/${repo}/releases?per_page=5")" || return 1
    jq -e '[.[] | select(.draft == false and .prerelease == false)] | length > 0' <<<"$data" >/dev/null 2>&1
}

source_score() {
    local stars="$1" updated="$2" fork="$3"
    local now epoch age score
    now="$(date +%s)"
    epoch="$(date -d "$updated" +%s 2>/dev/null || printf '0')"
    age=999999
    if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )); then
        age=$(( (now - epoch) / 86400 ))
    fi

    # Stars are the primary ranking signal. Recent activity is a secondary
    # signal; a dead repository is excluded rather than selected.
    score="$stars"
    if (( age <= 7 )); then score=$((score + 1000))
    elif (( age <= 30 )); then score=$((score + 700))
    elif (( age <= 90 )); then score=$((score + 400))
    elif (( age <= 180 )); then score=$((score + 100))
    elif (( age > 365 )); then score=$((score - 1000))
    fi
    [[ "$fork" == "true" ]] && score=$((score - 500))
    printf '%s' "$score"
}

core_search_query() {
    case "$1" in
        sing-box) printf 'sing-box in:name fork:false archived:false' ;;
        mihomo) printf 'mihomo in:name fork:false archived:false' ;;
        *) return 1 ;;
    esac
}

select_core_source() {
    local core="$1" force="${2:-0}"
    local file query results rows='' count=0
    file="$(source_file "$core")" || return 1

    # Mihomo always uses the official MetaCubeX Release source. Never perform
    # GitHub repository search for Mihomo; the fixed source is more reliable.
    if [[ "$core" == "mihomo" ]]; then
        if (( force == 0 )) && source_is_locked "$core" && [[ "$(source_repo "$core")" == "$NODEBOX_MIHOMO_REPOSITORY" ]]; then
            printf '%s' "$NODEBOX_MIHOMO_REPOSITORY"
            return 0
        fi
        jq -n \
            --arg core "mihomo" \
            --arg repository "$NODEBOX_MIHOMO_REPOSITORY" \
            --arg releases_url "$NODEBOX_MIHOMO_RELEASES_URL" \
            '{core:$core,repository:$repository,releases_url:$releases_url,source_type:"official-release",locked:true,selected_at:(now|todateiso8601)}' \
            > "${file}.tmp"
        mv -f -- "${file}.tmp" "$file"
        printf '%s' "$NODEBOX_MIHOMO_REPOSITORY"
        return 0
    fi

    if (( force == 0 )) && source_is_locked "$core"; then
        printf '%s' "$(source_repo "$core")"
        return 0
    fi

    query="$(core_search_query "$core")" || return 1
    msg "正在按 GitHub Stars + 更新时间筛选 ${core} 核心仓库..." >&2
    results="$(github_search "$query")" || {
        err "GitHub 仓库搜索失败。"
        return 1
    }

    while IFS=$'\t' read -r full_name stars updated fork archived; do
        [[ -n "$full_name" ]] || continue
        [[ "$archived" == "false" ]] || continue
        local score age
        score="$(source_score "$stars" "$updated" "$fork")"
        age=999999
        local epoch
        epoch="$(date -d "$updated" +%s 2>/dev/null || printf '0')"
        if [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )); then
            age=$(( ($(date +%s) - epoch) / 86400 ))
        fi
        (( age > 365 )) && continue

        # Only the top few candidates are checked for real Release assets.
        if (( count < NODEBOX_SOURCE_MAX_CANDIDATES )); then
            if source_release_available "$full_name"; then
                rows+="${score}\t${full_name}\t${stars}\t${updated}\t${fork}\n"
            fi
        fi
        count=$((count + 1))
        (( count >= NODEBOX_SOURCE_MAX_CANDIDATES )) && break
    done < <(jq -r '.items[] | [ .full_name, (.stargazers_count|tostring), .updated_at, (.fork|tostring), (.archived|tostring) ] | @tsv' <<<"$results")

    [[ -n "$rows" ]] || {
        err "没有找到符合条件且存在稳定 Release 的 ${core} 仓库。"
        return 1
    }

    local selected score repo stars updated fork
    selected="$(printf '%b' "$rows" | sort -t $'\t' -k1,1nr | head -n1)"
    IFS=$'\t' read -r score repo stars updated fork <<<"$selected"

    jq -n \
        --arg core "$core" \
        --arg repository "$repo" \
        --argjson stars "$stars" \
        --arg updated_at "$updated" \
        --argjson score "$score" \
        '{core:$core,repository:$repository,stars:$stars,updated_at:$updated_at,score:$score,locked:true,selected_at:(now|todateiso8601)}' \
        > "${file}.tmp"
    mv -f -- "${file}.tmp" "$file"

    ok "已选择：${repo}" >&2
    printf 'Stars：%s\n' "$stars" >&2
    printf '最近更新：%s\n' "$updated" >&2
    printf '综合评分：%s\n' "$score" >&2
    printf '来源已锁定；以后正常运行不会再次搜索 GitHub。\n' >&2
    printf '%s' "$repo"
}

show_core_sources() {
    printf '\n核心来源（缓存）\n'
    local core file repo stars updated score
    for core in sing-box mihomo; do
        file="$(source_file "$core")"
        if [[ -s "$file" ]]; then
            repo="$(jq -r '.repository' "$file")"
            stars="$(jq -r '.stars' "$file")"
            updated="$(jq -r '.updated_at' "$file")"
            score="$(jq -r '.score' "$file")"
            if [[ "$core" == "mihomo" ]]; then
                printf '%-9s %s\n' "$core" "$NODEBOX_MIHOMO_RELEASES_URL"
            else
                printf '%-9s %s | Stars=%s | 更新=%s | 评分=%s\n' "$core" "$repo" "$stars" "$updated" "$score"
            fi
        else
            printf '%-9s 未选择\n' "$core"
        fi
    done
}

core_source_menu() {
    while true; do
        show_banner
        printf '核心来源管理\n\n'
        show_core_sources
        printf '\n1. 自动选择 Sing-box 来源\n'
        printf '2. 自动选择 Mihomo 来源\n'
        printf '3. 重新评估 Sing-box 来源\n'
        printf '4. 重新评估 Mihomo 来源\n'
        printf '5. 解锁来源并重新选择\n'
        printf '0. 返回\n\n'
        local choice core file
        choice="$(menu_choice '请选择：' || true)"
        case "$choice" in
            1) select_core_source sing-box 0 || true; pause_back ;;
            2) select_core_source mihomo 0 || true; pause_back ;;
            3) select_core_source sing-box 1 || true; pause_back ;;
            4) select_core_source mihomo 1 || true; pause_back ;;
            5)
                core="$(ask '输入核心名称（sing-box/mihomo）')"
                file="$(source_file "$core" 2>/dev/null || true)"
                if [[ -n "$file" ]]; then rm -f -- "$file"; ok "已解锁 $core 来源。"; else err '核心名称无效。'; fi
                pause_back
                ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

# ---------- Core management ----------

core_dir() {
    case "$1" in
        sing-box) printf '%s' "${NODEBOX_CORE}/sing-box" ;;
        mihomo) printf '%s' "${NODEBOX_CORE}/mihomo" ;;
        *) return 1 ;;
    esac
}

core_binary() {
    case "$1" in
        sing-box) printf '%s' "$(core_dir sing-box)/sing-box" ;;
        mihomo) printf '%s' "$(core_dir mihomo)/mihomo" ;;
        *) return 1 ;;
    esac
}

core_version_file() {
    printf '%s/version' "$(core_dir "$1")"
}

installed_core_version() {
    local core="$1" f
    f="$(core_version_file "$core")"
    if [[ -f "$f" ]]; then
        cat "$f"
    elif [[ -x "$(core_binary "$core")" ]]; then
        case "$core" in
            sing-box) "$(core_binary "$core")" version 2>/dev/null | sed -n 's/^sing-box version \([^ ]*\).*/\1/p' | head -n1 ;;
            mihomo) "$(core_binary "$core")" -v 2>/dev/null | sed -n 's/.*version \([^ ]*\).*/\1/p' | head -n1 ;;
        esac
    fi
}

verify_sha256() {
    local file="$1" expected="$2" actual
    [[ -n "$expected" ]] || { warn 'Release 未提供可提取的 SHA256，跳过远程摘要比对。'; return 0; }
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        err 'SHA256 校验失败。'
        err "期望：${expected}"
        err "实际：${actual}"
        return 1
    fi
    ok 'SHA256 校验通过。'
}

registered_services() {
    local f service
    shopt -s nullglob
    for f in "${NODEBOX_NODES}"/*.service; do
        service="$(cat "$f" 2>/dev/null || true)"
        [[ -n "$service" ]] && printf '%s\n' "$service"
    done
    shopt -u nullglob
}

validate_registered_services() {
    local core="$1" f service nodecore
    shopt -s nullglob
    for f in "${NODEBOX_NODES}"/*.json; do
        nodecore="$(jq -r '.core // empty' "$f" 2>/dev/null || true)"
        [[ "$nodecore" == "$core" ]] || continue
        service="$(jq -r '.service // empty' "$f" 2>/dev/null || true)"
        [[ -n "$service" ]] || continue
        if systemctl cat "$service" >/dev/null 2>&1; then
            systemctl restart "$service" || { shopt -u nullglob; return 1; }
            systemctl is-active --quiet "$service" || { shopt -u nullglob; return 1; }
        fi
    done
    shopt -u nullglob
    return 0
}

select_release_asset() {
    local core="$1" repo arch releases tag assets asset url sha shaasset shavalue latest_url
    repo="$(source_repo "$core")" || return 1
    arch="$(normalize_arch)" || return 1

    # Mihomo uses the official Release page directly. This avoids the GitHub
    # repository/release API search path, which is unnecessary for a fixed
    # official source and is more likely to be blocked on some servers.
    if [[ "$core" == "mihomo" ]]; then
        latest_url="$(curl -fsSL --connect-timeout "$NODEBOX_GITHUB_TIMEOUT" --max-time 120 \
            -o /dev/null -w '%{url_effective}' "${NODEBOX_MIHOMO_RELEASES_URL}/latest")" || return 1
        tag="${latest_url##*/}"
        [[ "$tag" =~ ^v[0-9] ]] || return 1
        asset="mihomo-linux-${arch}-${tag}.gz"
        url="${NODEBOX_MIHOMO_RELEASES_URL}/download/${tag}/${asset}"
        # The Release-page path is the source of truth for Mihomo. GitHub's
        # browser page does not expose the asset digest without the API, so
        # install_core will still perform the local binary self-check.
        printf '%s\t%s\t%s\t%s\n' "$tag" "$asset" "$url" ""
        return 0
    fi

    releases="$(github_get "https://api.github.com/repos/${repo}/releases?per_page=10")" || return 1
    while IFS=$'\t' read -r tag; do
        [[ -n "$tag" ]] || continue
        assets="$(github_get "https://api.github.com/repos/${repo}/releases/tags/${tag}")" || continue
        case "$core" in
            sing-box) asset="$(jq -r --arg a "$arch" '.assets[].name | select(test("^sing-box-[0-9].*-linux-" + $a + "\\.tar\\.gz$"))' <<<"$assets" | head -n1)" ;;
            *) return 1 ;;
        esac
        [[ -n "$asset" ]] || continue
        url="$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$assets")"
        sha="$(jq -r --arg n "$asset" '.assets[] | select(.name==$n) | .digest // empty' <<<"$assets" | sed -n 's/^sha256://p' | head -n1)"
        if [[ -z "$sha" ]]; then
            shaasset="$(jq -r '.assets[].name | select(test("(?i)(sha256|checksums?)"))' <<<"$assets" | head -n1)"
            if [[ -n "$shaasset" ]]; then
                shavalue="$(jq -r --arg n "$shaasset" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$assets")"
                if [[ -n "$shavalue" ]]; then
                    sha="$(curl -fsSL --connect-timeout 20 --max-time 60 "$shavalue" 2>/dev/null | awk -v f="$asset" '$0 ~ f {print $1; exit}')"
                fi
            fi
        fi
        printf '%s\t%s\t%s\t%s\n' "$tag" "$asset" "$url" "$sha"
        return 0
    done < <(jq -r '.[] | select(.draft==false and .prerelease==false) | .tag_name' <<<"$releases")
    return 1
}

restore_core_binary() {
    local core="$1" live="$2" old="$3"
    rm -f -- "$live"
    if [[ -f "$old" ]]; then
        mv -- "$old" "$live"
        chmod 0755 "$live"
        ok "${core} 旧核心已恢复。"
    else
        err "找不到旧核心备份：${old}"
        return 1
    fi
}

install_core() {
    local core="$1" arch tag url tmpdir binary targetdir version expected_sha asset repo release_line
    local live old old_version
    arch="$(normalize_arch)" || { err "暂不支持架构：$(uname -m)"; return 1; }
    case "$core" in
        sing-box|mihomo) ;;
        *) err "未知核心：${core}"; return 1 ;;
    esac

    repo="$(select_core_source "$core" 0)" || {
        err "无法确定 ${core} 核心来源。"
        return 1
    }
    msg "正在查询 ${repo} 的最新稳定 Release（仅本次安装/更新请求）..."
    release_line="$(select_release_asset "$core")" || {
        err "无法从 ${repo} 获取适用于 ${arch} 的最新稳定预编译核心。"
        return 1
    }
    IFS=$'\t' read -r tag asset url expected_sha <<< "$release_line"
    [[ -n "$tag" && -n "$asset" && -n "$url" ]] || {
        err 'Release 资产解析失败。'; return 1;
    }
    version="${tag#v}"
    targetdir="$(core_dir "$core")"
    mkdir -p "$targetdir"
    tmpdir="$(mktemp -d "${NODEBOX_TMP}/${core}.XXXXXX")"

    msg "准备下载 ${core} ${tag} (${arch})"
    printf '资产：%s\n' "$asset"
    if ! curl -fL --retry 3 --retry-delay 3 --connect-timeout "$NODEBOX_GITHUB_TIMEOUT" --max-time 600 \
        -o "${tmpdir}/${asset}" "$url"; then
        rm -rf -- "$tmpdir"
        err '核心下载失败。'
        return 1
    fi
    [[ -s "${tmpdir}/${asset}" ]] || {
        rm -rf -- "$tmpdir"
        err '下载文件为空。'
        return 1
    }
    if [[ "$expected_sha" == sha256:* ]]; then expected_sha="${expected_sha#sha256:}"; fi
    if ! verify_sha256 "${tmpdir}/${asset}" "$expected_sha"; then
        rm -rf -- "$tmpdir"
        return 1
    fi

    case "$core" in
        sing-box)
            tar -xzf "${tmpdir}/${asset}" -C "$tmpdir"
            binary="$(find "$tmpdir" -type f -name sing-box -perm -u+x -print -quit)"
            live="${targetdir}/sing-box"
            old="${targetdir}/sing-box.old"
            ;;
        mihomo)
            binary="${tmpdir}/mihomo"
            gzip -dc "${tmpdir}/${asset}" > "$binary"
            chmod 0755 "$binary"
            live="${targetdir}/mihomo"
            old="${targetdir}/mihomo.old"
            ;;
    esac
    if [[ ! -x "${binary:-}" ]]; then
        rm -rf -- "$tmpdir"
        err "未找到 ${core} 可执行文件。"
        return 1
    fi

    case "$core" in
        sing-box) "$binary" version >/dev/null 2>&1 || { rm -rf -- "$tmpdir"; err 'Sing-box 二进制自检失败。'; return 1; } ;;
        mihomo) "$binary" -v >/dev/null 2>&1 || { rm -rf -- "$tmpdir"; err 'Mihomo 二进制自检失败。'; return 1; } ;;
    esac

    old_version="$(installed_core_version "$core" || true)"
    rm -f -- "$old"
    if [[ -f "$live" ]]; then mv -- "$live" "$old"; fi
    install -m 0755 "$binary" "$live"

    # If protocol services already use this core, restart and verify them before
    # deleting the old binary. If any service fails, restore the previous core.
    if ! validate_registered_services "$core"; then
        warn '新核心导致已有服务无法正常运行，正在回滚。'
        restore_core_binary "$core" "$live" "$old" || true
        validate_registered_services "$core" || true
        rm -rf -- "$tmpdir"
        [[ -n "$old_version" ]] && printf '%s\n' "$old_version" > "$(core_version_file "$core")"
        return 1
    fi

    printf '%s\n' "$version" > "$(core_version_file "$core")"
    rm -f -- "$old"
    rm -rf -- "$tmpdir"
    ok "${core} ${version} 已启用。"
    if [[ -n "$old_version" ]]; then
        ok "旧核心 ${old_version} 已在新核心验证成功后删除。"
    fi
    return 0
}

core_process_pids() {
    local core="$1" bin
    bin="$(core_binary "$core")"
    [[ -x "$bin" ]] || return 0
    case "$core" in
        sing-box) pgrep -f -- "${bin} (run|check)" 2>/dev/null || true ;;
        mihomo) pgrep -f -- "${bin}([[:space:]]|$)" 2>/dev/null || true ;;
    esac
}

core_registered_services() {
    local core="$1" f service regcore
    shopt -s nullglob
    for f in "${NODEBOX_NODES}"/*.json; do
        regcore="$(jq -r '.core // empty' "$f" 2>/dev/null || true)"
        [[ "$regcore" == "$core" ]] || continue
        service="$(jq -r '.service // empty' "$f" 2>/dev/null || true)"
        [[ "$service" =~ ^nodebox-[A-Za-z0-9_.@-]+\.service$ ]] || continue
        printf '%s\n' "$service"
    done
    shopt -u nullglob
}

core_is_running() {
    local core="$1" service pid
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        if systemctl is-active --quiet "$service"; then
            pid="$(systemctl show -p MainPID --value "$service" 2>/dev/null || printf '0')"
            if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )) && kill -0 "$pid" 2>/dev/null; then
                return 0
            fi
        fi
    done < <(core_registered_services "$core")
    [[ -n "$(core_process_pids "$core")" ]]
}

core_start_registered() {
    local core="$1" service failed=0
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        if ! systemctl enable --now "$service" >/dev/null 2>&1; then
            err "${core} 节点服务 ${service} 启动失败。"
            failed=1
            continue
        fi
    done < <(core_registered_services "$core")
    systemctl daemon-reload >/dev/null 2>&1 || true
    (( failed == 0 ))
}

core_status() {
    local core="$1" bin version pids pid services active=0 total=0
    bin="$(core_binary "$core")"
    version="$(installed_core_version "$core")"
    if [[ ! -x "$bin" ]]; then
        printf '%-10s 未安装\n' "$core"
        return 0
    fi
    total="$(core_registered_services "$core" | grep -c . || true)"
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        if systemctl is-active --quiet "$service"; then
            ((active+=1))
        fi
    done < <(core_registered_services "$core")
    pids="$(core_process_pids "$core" | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
    if core_is_running "$core"; then
        pid="${pids%% *}"
        printf '%-10s ● 运行中  版本：%s  PID：%s  节点服务：%d/%d\n' "$core" "${version:-未知}" "${pid:-未知}" "$active" "$total"
    else
        printf '%-10s ○ 未运行  版本：%s  节点服务：%d/%d\n' "$core" "${version:-未知}" "$active" "$total"
    fi
}

core_menu() {
    while true; do
        show_banner
        printf '核心管理\n\n'
        core_status sing-box
        core_status mihomo
        printf '\n'
        printf '1. 安装/更新 Sing-box\n'
        printf '2. 安装/更新 Mihomo\n'
        printf '3. 查看核心状态\n'
        printf '0. 返回\n\n'
        local choice
        choice="$(menu_choice '请选择：' || true)"
        case "$choice" in
            1) install_core sing-box; pause_back ;;
            2) install_core mihomo; pause_back ;;
            3) show_banner; core_status sing-box; core_status mihomo; pause_back ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

# ---------- Port manager ----------
port_in_use() {
    local port="$1"
    ss -H -lntu "( sport = :${port} )" 2>/dev/null | grep -q .
}

port_in_use_transport() {
    local port="$1" transport="$2"
    case "$transport" in
        tcp) ss -H -lnt "( sport = :${port} )" 2>/dev/null | grep -q . ;;
        udp) ss -H -lnu "( sport = :${port} )" 2>/dev/null | grep -q . ;;
        both) ss -H -lntu "( sport = :${port} )" 2>/dev/null | grep -q . ;;
        *) return 2 ;;
    esac
}

node_port_in_registry() {
    local port="$1" except_protocol="${2:-}" f p proto
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    shopt -s nullglob
    for f in "${NODEBOX_NODES}"/*.json; do
        [[ -s "$f" ]] || continue
        p="$(jq -r '.port // empty' "$f" 2>/dev/null || true)"
        [[ "$p" == "$port" ]] || continue
        proto="$(jq -r '.protocol // empty' "$f" 2>/dev/null || true)"
        [[ -n "$except_protocol" && "$proto" == "$except_protocol" ]] && continue
        return 0
    done
    shopt -u nullglob
    return 1
}

find_free_port_transport() {
    local transport="$1" start="${2:-$NODEBOX_DEFAULT_PORT}" port
    [[ "$start" =~ ^[0-9]+$ ]] || start="$NODEBOX_DEFAULT_PORT"
    (( start < 1 )) && start=1
    (( start > NODEBOX_MAX_PORT )) && return 1
    # NodeBox uses one global numeric port pool. TCP/UDP and sing-box/Mihomo
    # never share a registered port number.
    for ((port=start; port<=NODEBOX_MAX_PORT; port++)); do
        if ! node_port_in_registry "$port" && ! port_in_use "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done
    return 1
}

find_free_port() {
    local start="${1:-$NODEBOX_DEFAULT_PORT}"
    find_free_port_transport both "$start"
}

port_menu() {
    while true; do
        show_banner
        printf '端口管理\n\n'
        printf '默认自动端口起点：%s\n' "$NODEBOX_DEFAULT_PORT"
        printf '自动策略：从起点开始顺序寻找可用端口\n\n'
        printf '1. 检查指定端口\n'
        printf '2. 查找下一个可用端口\n'
        printf '0. 返回\n\n'
        local choice port free
        choice="$(menu_choice '请选择：' || true)"
        case "$choice" in
            1)
                port="$(ask '输入端口')"
                if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
                    if port_in_use "$port"; then warn "端口 ${port} 已被占用。"; else ok "端口 ${port} 可用。"; fi
                else
                    err '端口必须是 1-65535。'
                fi
                pause_back
                ;;
            2)
                free="$(find_free_port "$NODEBOX_DEFAULT_PORT" || true)"
                [[ -n "$free" ]] && ok "下一个可用端口：${free}" || err '没有找到可用端口。'
                pause_back
                ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

# ---------- Shared node helpers ----------
node_service_name() {
    local protocol="$1"
    printf 'nodebox-%s.service' "$protocol"
}

node_file() {
    local protocol="$1"
    printf '%s/%s.json' "$NODEBOX_NODES" "$protocol"
}

node_service_file() {
    local protocol="$1"
    printf '%s/%s.service' "$NODEBOX_NODES" "$protocol"
}

node_url_encode() {
    # RFC 3986 unreserved characters only.
    printf '%s' "$1" | jq -sRr '@uri'
}

server_address_guess() {
    local addr
    addr="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1 || true)"
    if [[ -n "$addr" ]]; then
        printf '%s' "$addr"
        return 0
    fi
    addr="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep ':' | head -n1 || true)"
    [[ -n "$addr" ]] && printf '%s' "$addr" || printf '127.0.0.1'
}

node_address_for_uri() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

node_registry_remove() {
    local protocol="$1" file service config config_dir
    file="$(node_file "$protocol")"
    service="$(node_service_name "$protocol")"
    config="$(jq -r '.config // empty' "$file" 2>/dev/null || true)"
    config_dir="${NODEBOX_CONFIG}/${protocol}"
    if [[ -n "$config" && "$config" == /etc/nodebox/config/*/config.* ]]; then
        config_dir="$(dirname "$config")"
    fi
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    rm -f -- "/etc/systemd/system/${service}" "$(node_service_file "$protocol")" "$file"
    [[ -d "$config_dir" && "$config_dir" == ${NODEBOX_CONFIG}/* ]] && rm -rf -- "$config_dir"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

node_registry_write() {
    local protocol="$1" config="$2" service="$3" node_uri="$4" host="$5" port="$6" password="$7" sni="$8" core="${9:-sing-box}"
    local file tmp
    file="$(node_file "$protocol")"
    tmp="${file}.tmp"
    jq -n \
        --arg protocol "$protocol" \
        --arg core "$core" \
        --arg config "$config" \
        --arg service "$service" \
        --arg uri "$node_uri" \
        --arg server "$host" \
        --argjson port "$port" \
        --arg password "$password" \
        --arg sni "$sni" \
        '{protocol:$protocol,core:$core,config:$config,service:$service,server:$server,port:$port,password:$password,sni:$sni,uri:$uri,created_at:(now|todateiso8601)}' \
        > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$file"
    printf '%s\n' "$service" > "$(node_service_file "$protocol")"
    chmod 0600 "$(node_service_file "$protocol")"
    # Registration is part of installation success: verify the file immediately.
    [[ -s "$file" ]] || { err "${protocol} 节点注册文件写入失败。"; return 1; }
    [[ "$(jq -r '.protocol // empty' "$file" 2>/dev/null || true)" == "$protocol" ]] || { err "${protocol} 节点注册协议校验失败。"; return 1; }
    [[ "$(jq -r '.uri // empty' "$file" 2>/dev/null || true)" == "$node_uri" ]] || { err "${protocol} 节点 URI 注册校验失败。"; return 1; }
    [[ "$(jq -r '.port // empty' "$file" 2>/dev/null || true)" == "$port" ]] || { err "${protocol} 节点端口注册校验失败。"; return 1; }
    return 0
}

node_status_one() {
    local protocol="$1" file service
    file="$(node_file "$protocol")"
    service="$(node_service_name "$protocol")"
    if [[ ! -s "$file" ]]; then
        printf '%-12s 未安装\n' "$protocol"
        return 0
    fi
    if systemctl is-active --quiet "$service"; then
        printf '%-12s ● 运行中  端口：%s\n' "$protocol" "$(jq -r '.port // "?"' "$file")"
    else
        printf '%-12s ○ 已安装但未运行  端口：%s\n' "$protocol" "$(jq -r '.port // "?"' "$file")"
    fi
}

# ---------- AnyTLS / sing-box protocol ----------
anytls_dir() { printf '%s' "${NODEBOX_CONFIG}/anytls"; }
anytls_config() { printf '%s/config.json' "$(anytls_dir)"; }
anytls_cert() { printf '%s/server.crt' "$(anytls_dir)"; }
anytls_key() { printf '%s/server.key' "$(anytls_dir)"; }

anytls_generate_password() {
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-32
}

is_ip_address() {
    local subject="$1"
    [[ "$subject" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$subject" == *:* ]]
}

anytls_generate_certificate() {
    local dir="$1" subject="$2" ext tmpconf tmpcrt tmpkey
    mkdir -p "$dir"
    if [[ -s "${dir}/server.crt" && -s "${dir}/server.key" ]]; then
        if is_ip_address "$subject"; then
            openssl x509 -in "${dir}/server.crt" -noout -ext subjectAltName 2>/dev/null | grep -Fq "IP Address:${subject}" && return 0
        else
            openssl x509 -in "${dir}/server.crt" -noout -ext subjectAltName 2>/dev/null | grep -Fq "DNS:${subject}" && return 0
        fi
        warn "现有证书与 ${subject} 不匹配，将重新生成。"
    fi
    msg '正在生成 TLS 自签名证书...'
    tmpconf="$(mktemp "${NODEBOX_TMP}/openssl.XXXXXX.cnf")"
    tmpcrt="${dir}/.server.crt.$$.tmp"
    tmpkey="${dir}/.server.key.$$.tmp"
    if is_ip_address "$subject"; then
        ext="IP:${subject}"
    else
        ext="DNS:${subject}"
    fi
    cat > "$tmpconf" <<EOF_CERT
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${subject}
[v3]
subjectAltName = ${ext}
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF_CERT
    if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
        -keyout "$tmpkey" -out "$tmpcrt" \
        -config "$tmpconf" >/dev/null 2>&1; then
        rm -f -- "$tmpconf" "$tmpcrt" "$tmpkey"
        return 1
    fi
    rm -f -- "$tmpconf"
    chmod 0600 "$tmpkey"
    chmod 0644 "$tmpcrt"
    mv -f -- "$tmpkey" "${dir}/server.key"
    mv -f -- "$tmpcrt" "${dir}/server.crt"
}

tls_backup_files() {
    local dir="$1" backup="$2"
    mkdir -p "$backup"
    if [[ -f "${dir}/server.crt" ]]; then
        cp -f -- "${dir}/server.crt" "${backup}/server.crt"
    fi
    if [[ -f "${dir}/server.key" ]]; then
        cp -f -- "${dir}/server.key" "${backup}/server.key"
    fi
    return 0
}

tls_restore_files() {
    local dir="$1" backup="$2"
    if [[ -f "${backup}/server.crt" ]]; then install -m 0644 "${backup}/server.crt" "${dir}/server.crt"; else rm -f -- "${dir}/server.crt"; fi
    if [[ -f "${backup}/server.key" ]]; then install -m 0600 "${backup}/server.key" "${dir}/server.key"; else rm -f -- "${dir}/server.key"; fi
}

anytls_write_config() {
    local config="$1" port="$2" password="$3" cert="$4" key="$5"
    local tmp="${config}.tmp"
    mkdir -p "$(dirname "$config")"
    jq -n \
        --argjson port "$port" \
        --arg password "$password" \
        --arg cert "$cert" \
        --arg key "$key" \
        '{log:{level:"info",timestamp:true},inbounds:[{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,users:[{name:"nodebox",password:$password}],padding_scheme:["stop=8","0=30-30","1=100-400","2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000","3=9-9,500-1000","4=500-1000","5=500-1000","6=500-1000","7=500-1000"],tls:{enabled:true,certificate_path:$cert,key_path:$key}}],outbounds:[{type:"direct",tag:"direct"}]}' \
        > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$config"
}

anytls_validate_config() {
    local config="$1" bin
    bin="$(core_binary sing-box)"
    [[ -x "$bin" ]] || { err 'Sing-box 核心尚未安装。'; return 1; }
    "$bin" check -c "$config" >/dev/null
}

anytls_write_service() {
    local service="$1" config="$2" bin="$3"
    cat > "/etc/systemd/system/${service}" <<EOF_ANYTLS
[Unit]
Description=NodeBox AnyTLS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} run -c ${config}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$(anytls_dir)

[Install]
WantedBy=multi-user.target
EOF_ANYTLS
}

anytls_install() {
    local old_config old_service old_registry old_port old_password old_sni
    local old_config_bak old_cert_bak old_key_bak
    local host domain port password sni server_host uri config cert key service tmpdir
    local had_old=0
    if [[ ! -x "$(core_binary sing-box)" ]]; then
        msg 'AnyTLS 依赖 Sing-box，当前未安装。'
        install_core sing-box || return 1
    fi

    host="$(ask '服务器地址（IP/域名）' "$(server_address_guess)")"
    [[ -n "$host" ]] || { err '服务器地址不能为空。'; return 1; }
    domain="$(ask 'TLS SNI/证书名称' "$NODEBOX_DEFAULT_TLS_SNI")"
    [[ -n "$domain" ]] || domain="$NODEBOX_DEFAULT_TLS_SNI"
    password="$(ask 'AnyTLS 密码（留空自动生成）')"
    [[ -n "$password" ]] || password="$(anytls_generate_password)"

    config="$(anytls_config)"
    cert="$(anytls_cert)"
    key="$(anytls_key)"
    service="$(node_service_name anytls)"
    old_registry="$(node_file anytls)"
    if [[ -s "$old_registry" ]]; then
        had_old=1
        old_port="$(jq -r '.port // empty' "$old_registry")"
        old_password="$(jq -r '.password // empty' "$old_registry")"
        old_sni="$(jq -r '.sni // empty' "$old_registry")"
    fi

    # Reinstalling AnyTLS replaces only the old AnyTLS instance. If the old
    # NodeBox 默认端口池统一从 2000 开始；AnyTLS 不强制使用 443。
    # 重新安装已有节点时，优先保留原端口；只有原端口已被其他进程占用才重新分配。
    if [[ "$had_old" == 1 && "$old_port" =~ ^[0-9]+$ ]]         && ! node_port_in_registry "$old_port" anytls         && ! port_in_use "$old_port"; then
        port="$old_port"
        ok "保留 AnyTLS 原端口 ${port}。"
    else
        port="$(find_free_port_transport tcp "$NODEBOX_DEFAULT_PORT")" || { err '无法找到可用全局端口。'; return 1; }
        ok "AnyTLS 已分配全局端口 ${port}。"
    fi

    server_host="$host"
    uri="anytls://$(node_url_encode "$password")@$(node_address_for_uri "$server_host"):${port}/?sni=$(node_url_encode "$domain")&insecure=1#NodeBox%20AnyTLS"

    tmpdir="$(mktemp -d "${NODEBOX_TMP}/anytls.XXXXXX")"
    old_config_bak="${tmpdir}/old-config.json"
    old_cert_bak="${tmpdir}/old-server.crt"
    old_key_bak="${tmpdir}/old-server.key"

    # Keep rollback material outside the live configuration directory until the
    # new service has passed both configuration validation and listener checks.
    if [[ -f "$config" ]]; then cp -f -- "$config" "$old_config_bak"; fi
    if [[ -f "$cert" ]]; then cp -f -- "$cert" "$old_cert_bak"; fi
    if [[ -f "$key" ]]; then cp -f -- "$key" "$old_key_bak"; fi

    # Generate the certificate at its final path before sing-box validates the
    # temporary configuration. The previous implementation generated the
    # certificate under tmpdir while the config referenced the final path, so
    # sing-box correctly failed with "server.crt: no such file or directory".
    if ! anytls_generate_certificate "$(anytls_dir)" "$domain"; then
        rm -rf -- "$tmpdir"
        err 'TLS 证书生成失败。'
        return 1
    fi
    anytls_write_config "${tmpdir}/config.json" "$port" "$password" "$cert" "$key"
    anytls_validate_config "${tmpdir}/config.json" || {
        # Restore the previous certificate material if validation itself fails.
        if [[ -f "$old_cert_bak" ]]; then install -m 0644 "$old_cert_bak" "$cert"; else rm -f -- "$cert"; fi
        if [[ -f "$old_key_bak" ]]; then install -m 0600 "$old_key_bak" "$key"; else rm -f -- "$key"; fi
        rm -rf -- "$tmpdir"
        err 'AnyTLS 配置检查失败。'
        return 1
    }

    # Stop only the old AnyTLS service before replacing its config. Certificate
    # material has already been validated and is restored on any later failure.
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    install -m 0600 "${tmpdir}/config.json" "$config"
    anytls_write_service "$service" "$config" "$(core_binary sing-box)"
    systemctl daemon-reload

    if ! systemctl enable --now "$service"; then
        warn '新 AnyTLS 服务启动失败，正在恢复旧实例。'
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        if [[ -f "$old_config_bak" ]]; then install -m 0600 "$old_config_bak" "$config"; else rm -f -- "$config"; fi
        if [[ -f "$old_cert_bak" ]]; then install -m 0644 "$old_cert_bak" "$cert"; else rm -f -- "$cert"; fi
        if [[ -f "$old_key_bak" ]]; then install -m 0600 "$old_key_bak" "$key"; else rm -f -- "$key"; fi
        if [[ "$had_old" == 1 ]]; then
            anytls_write_service "$service" "$config" "$(core_binary sing-box)"
            systemctl daemon-reload
            systemctl enable --now "$service" >/dev/null 2>&1 || true
        fi
        rm -rf -- "$tmpdir"
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet "$service" || ! port_in_use "$port"; then
        warn 'AnyTLS 未成功监听新端口，安装失败，正在恢复旧实例。'
        journalctl -u "$service" -n 30 --no-pager >&2 || true
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        if [[ -f "$old_config_bak" ]]; then install -m 0600 "$old_config_bak" "$config"; else rm -f -- "$config"; fi
        if [[ -f "$old_cert_bak" ]]; then install -m 0644 "$old_cert_bak" "$cert"; else rm -f -- "$cert"; fi
        if [[ -f "$old_key_bak" ]]; then install -m 0600 "$old_key_bak" "$key"; else rm -f -- "$key"; fi
        if [[ "$had_old" == 1 ]]; then
            anytls_write_service "$service" "$config" "$(core_binary sing-box)"
            systemctl daemon-reload
            systemctl enable --now "$service" >/dev/null 2>&1 || true
        fi
        rm -rf -- "$tmpdir"
        return 1
    fi

    node_registry_write anytls "$config" "$service" "$uri" "$host" "$port" "$password" "$domain"
    rm -rf -- "$tmpdir"
    ok 'AnyTLS 安装/更新成功。'
    printf '\n协议：AnyTLS\n核心：Sing-box\n服务器：%s\n端口：%s\nSNI：%s\n密码：%s\n服务：%s\n配置：%s\n\n节点 URI：\n%s\n' \
        "$host" "$port" "$domain" "$password" "$service" "$config" "$uri"
}

anytls_menu() {
    while true; do
        show_banner
        printf 'Sing-box / AnyTLS\n\n'
        node_status_one anytls
        printf '\n1. 安装/重新安装 AnyTLS\n'
        printf '2. 启动 AnyTLS\n'
        printf '3. 停止 AnyTLS\n'
        printf '4. 重启 AnyTLS\n'
        printf '5. 查看 AnyTLS 节点信息\n'
        printf '6. 查看 AnyTLS 日志\n'
        printf '7. 删除 AnyTLS\n'
        printf '0. 返回\n\n'
        local choice file service
        choice="$(menu_choice '请选择：' || true)"
        service="$(node_service_name anytls)"
        file="$(node_file anytls)"
        case "$choice" in
            1) anytls_install; pause_back ;;
            2) systemctl start "$service" && ok 'AnyTLS 已启动。' || err '启动失败。'; pause_back ;;
            3) systemctl stop "$service" && ok 'AnyTLS 已停止。' || err '停止失败。'; pause_back ;;
            4) systemctl restart "$service" && ok 'AnyTLS 已重启。' || err '重启失败。'; pause_back ;;
            5)
                if [[ -s "$file" ]]; then
                    jq . "$file"
                else
                    warn 'AnyTLS 尚未安装。'
                fi
                pause_back
                ;;
            6) journalctl -u "$service" -n 100 --no-pager || true; pause_back ;;
            7)
                if [[ -s "$file" ]] && confirm '确认删除 AnyTLS 节点及其服务' 'N'; then
                    node_registry_remove anytls
                    rm -rf -- "$(anytls_dir)"
                    ok 'AnyTLS 已删除。'
                fi
                pause_back
                ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

# ---------- Generic node helpers ----------
node_port_for_protocol() {
    local protocol="$1" old_port="" transport="tcp" service=""
    case "$protocol" in
        mihomo-hysteria2|mihomo-tuic) transport="udp" ;;
    esac
    service="$(node_service_name "$protocol")"
    if [[ -s "$(node_file "$protocol")" ]]; then
        old_port="$(jq -r '.port // empty' "$(node_file "$protocol")" 2>/dev/null || true)"
    fi
    # Reinstalling the same protocol keeps its existing port, but only that
    # protocol may retain it. The global registry prevents cross-protocol reuse.
    if [[ "$old_port" =~ ^[0-9]+$ ]] && ! node_port_in_registry "$old_port" "$protocol"         && ! port_in_use "$old_port"; then
        printf '%s' "$old_port"
        return 0
    fi
    find_free_port_transport "$transport" "$NODEBOX_DEFAULT_PORT"
}

random_password() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-32; }
random_uuid() { cat /proc/sys/kernel/random/uuid; }
random_ss_key() { openssl rand -base64 32 | tr -d '\n'; }

restore_node_backup() {
    local protocol="$1" backup="$2" config="$3" service="$4"
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    if [[ -f "${backup}/config" ]]; then install -m 0600 "${backup}/config" "$config"; else rm -f -- "$config"; fi
    if [[ -f "${backup}/crt" ]]; then install -m 0644 "${backup}/crt" "${NODEBOX_CONFIG}/${protocol}/server.crt"; fi
    if [[ -f "${backup}/key" ]]; then install -m 0600 "${backup}/key" "${NODEBOX_CONFIG}/${protocol}/server.key"; fi
    if [[ -f "${backup}/registry" ]]; then install -m 0600 "${backup}/registry" "$(node_file "$protocol")"; else rm -f -- "$(node_file "$protocol")"; fi
    if [[ -f "${backup}/service" ]]; then install -m 0644 "${backup}/service" "/etc/systemd/system/${service}"; fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ -f "/etc/systemd/system/${service}" ]]; then systemctl enable --now "$service" >/dev/null 2>&1 || true; fi
}

backup_node() {
    local protocol="$1" dir="$2" config="$3" service="$4"
    mkdir -p "$dir"
    [[ -f "$config" ]] && cp -f -- "$config" "${dir}/config"
    [[ -f "${NODEBOX_CONFIG}/${protocol}/server.crt" ]] && cp -f -- "${NODEBOX_CONFIG}/${protocol}/server.crt" "${dir}/crt"
    [[ -f "${NODEBOX_CONFIG}/${protocol}/server.key" ]] && cp -f -- "${NODEBOX_CONFIG}/${protocol}/server.key" "${dir}/key"
    [[ -f "$(node_file "$protocol")" ]] && cp -f -- "$(node_file "$protocol")" "${dir}/registry"
    [[ -f "/etc/systemd/system/${service}" ]] && cp -f -- "/etc/systemd/system/${service}" "${dir}/service"
}

node_print_result() {
    local protocol="$1" uri="$2" host="$3" port="$4" credential="$5" sni="$6" core="$7"
    printf '\n协议：%s\n核心：%s\n服务器：%s\n端口：%s\nSNI：%s\n认证：%s\n服务：%s\n配置：%s\n\n节点 URI：\n%s\n' \
        "$protocol" "$core" "$host" "$port" "$sni" "$credential" "$(node_service_name "$protocol")" \
        "$(node_file "$protocol")" "$uri"
}

singbox_service_write() {
    local protocol="$1" config="$2" service bin
    service="$(node_service_name "$protocol")"; bin="$(core_binary sing-box)"
    cat > "/etc/systemd/system/${service}" <<EOF_SB
[Unit]
Description=NodeBox Sing-box ${protocol}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} run -c ${config}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$(dirname "$config")

[Install]
WantedBy=multi-user.target
EOF_SB
}

singbox_transactional_install() {
    local protocol="$1" config="$2" tmpconfig="$3" uri="$4" host="$5" port="$6" credential="$7" sni="$8" extra_json="${9:-{}}"
    local service backup had_old=0
    service="$(node_service_name "$protocol")"
    [[ -s "$(node_file "$protocol")" ]] && had_old=1
    backup="$(mktemp -d "${NODEBOX_TMP}/rollback-${protocol}.XXXXXX")"
    backup_node "$protocol" "$backup" "$config" "$service"
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$config")"
    install -m 0600 "$tmpconfig" "$config"
    singbox_service_write "$protocol" "$config"
    systemctl daemon-reload
    if ! systemctl enable --now "$service" >/dev/null 2>&1; then
        err "${protocol} 启动失败，正在回滚。"
        restore_node_backup "$protocol" "$backup" "$config" "$service"
        rm -rf -- "$backup"; return 1
    fi
    sleep 1
    local check_transport="tcp"
    [[ "$protocol" == "hysteria2" || "$protocol" == "tuic" ]] && check_transport="udp"
    if ! systemctl is-active --quiet "$service" || ! port_in_use_transport "$port" "$check_transport"; then
        journalctl -u "$service" -n 30 --no-pager >&2 || true
        err "${protocol} 未成功监听端口，正在回滚。"
        restore_node_backup "$protocol" "$backup" "$config" "$service"
        rm -rf -- "$backup"; return 1
    fi
    if ! node_registry_write "$protocol" "$config" "$service" "$uri" "$host" "$port" "$credential" "$sni"; then
        err "${protocol} 节点注册失败，正在回滚。"
        restore_node_backup "$protocol" "$backup" "$config" "$service"
        rm -rf -- "$backup"
        return 1
    fi
    if [[ "$extra_json" != "{}" ]]; then
        if ! jq --argjson x "$extra_json" '. + $x' "$(node_file "$protocol")" > "$(node_file "$protocol").tmp"; then
            err "${protocol} 扩展注册信息写入失败，正在回滚。"
            rm -f -- "$(node_file "$protocol").tmp"
            restore_node_backup "$protocol" "$backup" "$config" "$service"
            rm -rf -- "$backup"
            return 1
        fi
        mv -f -- "$(node_file "$protocol").tmp" "$(node_file "$protocol")"
    fi
    if ! core_is_running sing-box || ! systemctl is-active --quiet "$service"; then
        err "${protocol} 安装后核心/服务状态校验失败，正在回滚。"
        restore_node_backup "$protocol" "$backup" "$config" "$service"
        rm -rf -- "$backup"
        return 1
    fi
    rm -rf -- "$backup"
    ok "${protocol} 安装/更新成功，核心已运行。"
    return 0
}

singbox_prepare_core() {
    if [[ ! -x "$(core_binary sing-box)" ]]; then
        msg '当前节点需要 Sing-box，正在安装/更新核心...'
        install_core sing-box || return 1
    fi
}


singbox_install_dispatch() {
    local protocol="$1"
    case "$protocol" in
        anytls) anytls_install ;;
        hysteria2) hysteria2_install ;;
        tuic) tuic_install ;;
        *) err "Sing-box 当前仅支持 AnyTLS / Hysteria2 / TUIC。"; return 2 ;;
    esac
}

mihomo_install_mixed() {
    local protocol=mixed host port user password dir config tmpdir uri service backup
    mihomo_prepare_core || return 1
    host="$(ask '服务器地址（IP/域名）' "$(server_address_guess)")"; [[ -n "$host" ]] || return 1
    port="$(node_port_for_protocol "mihomo-mixed")" || { err '无法找到全局唯一可用端口。'; return 1; }
    dir="$(mihomo_dir mixed)"; config="${dir}/config.yaml"; mkdir -p "$dir"
    user="$(ask '用户名（留空则无认证）')"; password="$(ask '密码（留空则无认证）')"
    uri="mixed://$(node_address_for_uri "$host"):${port}#NodeBox%20Mihomo%20Mixed"
    tmpdir="$(mktemp -d "${NODEBOX_TMP}/mihomo-mixed.XXXXXX")"
    if [[ -n "$user" ]]; then
        cat > "${tmpdir}/config.yaml" <<EOF_MHCFG
mode: rule
listeners:
  - name: mixed-in
    type: mixed
    port: ${port}
    listen: "::"
    users:
      - username: "${user}"
        password: "${password}"
    proxy: DIRECT
EOF_MHCFG
    else
        cat > "${tmpdir}/config.yaml" <<EOF_MHCFG
mode: rule
listeners:
  - name: mixed-in
    type: mixed
    port: ${port}
    listen: "::"
    users: []
    proxy: DIRECT
EOF_MHCFG
    fi
    if ! "$(core_binary mihomo)" -d "$tmpdir" -f "${tmpdir}/config.yaml" -t 2>"${tmpdir}/check.log"; then
        cat "${tmpdir}/check.log" >&2 || true; rm -rf -- "$tmpdir"; err 'Mihomo Mixed 配置检查失败。'; return 1
    fi
    service="$(node_service_name "mihomo-mixed")"
    backup="$(mktemp -d "${NODEBOX_TMP}/rollback-mihomo-mixed.XXXXXX")"
    [[ -f "$config" ]] && cp -f -- "$config" "${backup}/config"
    [[ -f "$(node_file mihomo-mixed)" ]] && cp -f -- "$(node_file mihomo-mixed)" "${backup}/registry"
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    install -m 0600 "${tmpdir}/config.yaml" "$config"
    mihomo_service_write mixed "$config"
    systemctl daemon-reload
    if ! systemctl enable --now "$service" >/dev/null 2>&1; then
        journalctl -u "$service" -n 40 --no-pager >&2 || true
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        [[ -f "${backup}/config" ]] && install -m 0600 "${backup}/config" "$config" || rm -f -- "$config"
        [[ -f "${backup}/config" ]] && systemctl enable --now "$service" >/dev/null 2>&1 || true
        rm -rf -- "$tmpdir" "$backup"; err 'Mihomo Mixed 启动失败，已回滚。'; return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet "$service" || ! port_in_use "$port"; then
        journalctl -u "$service" -n 40 --no-pager >&2 || true
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        [[ -f "${backup}/config" ]] && install -m 0600 "${backup}/config" "$config" || rm -f -- "$config"
        [[ -f "${backup}/config" ]] && systemctl enable --now "$service" >/dev/null 2>&1 || true
        rm -rf -- "$tmpdir" "$backup"; err 'Mihomo Mixed 未成功监听端口，已回滚。'; return 1
    fi
    if ! node_registry_write 'mihomo-mixed' "$config" "$service" "$uri" "$host" "$port" "${user:-无认证}" '' mihomo; then
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        [[ -f "${backup}/config" ]] && install -m 0600 "${backup}/config" "$config" || rm -f -- "$config"
        [[ -f "${backup}/registry" ]] && install -m 0600 "${backup}/registry" "$(node_file mihomo-mixed)" || rm -f -- "$(node_file mihomo-mixed)"
        [[ -f "${backup}/config" ]] && systemctl enable --now "$service" >/dev/null 2>&1 || true
        rm -rf -- "$tmpdir" "$backup"; err 'Mihomo Mixed 节点注册失败，已回滚。'; return 1
    fi
    if [[ -n "$user" ]]; then
        jq --arg u "$user" --arg p "$password" '. + {core:"mihomo",username:$u,password:$p}' "$(node_file mihomo-mixed)" > "$(node_file mihomo-mixed).tmp"
        mv -f -- "$(node_file mihomo-mixed).tmp" "$(node_file mihomo-mixed)"
    fi
    if ! systemctl is-active --quiet "$service" || ! core_is_running mihomo; then
        err 'Mihomo Mixed 安装后核心/服务状态校验失败。'; journalctl -u "$service" -n 30 --no-pager >&2 || true
        rm -rf -- "$tmpdir" "$backup"; return 1
    fi
    rm -rf -- "$tmpdir" "$backup"
    ok 'Mihomo Mixed 安装/更新成功，核心已运行。'
    node_print_result 'mihomo-mixed' "$uri" "$host" "$port" "${user:-无认证}${password:+ / $password}" '' 'Mihomo'
}

mihomo_install_dispatch() {
    local protocol="$1"
    case "$protocol" in
        anytls|hysteria2|tuic|vless|trojan|shadowsocks|vmess) mihomo_install_listener "$protocol" "$protocol" ;;
        mixed) mihomo_install_mixed ;;
        *) return 2 ;;
    esac
}

print_core_nodes() {
    local core="$1" protocol nodekey f nodecore port transport uri server sni service count=0
    local protocols=()
    if [[ "$core" == "sing-box" ]]; then
        protocols=(anytls hysteria2 tuic)
    else
        protocols=(anytls hysteria2 tuic vless trojan shadowsocks vmess mixed)
    fi
    printf '\n╭────────────────────────────────────────────────────────────╮\n'
    printf '│  %-56s │\n' "${core} 节点链接"
    printf '╰────────────────────────────────────────────────────────────╯\n'
    for protocol in "${protocols[@]}"; do
        nodekey="$protocol"
        [[ "$core" == "mihomo" ]] && nodekey="mihomo-${protocol}"
        f="$(node_file "$nodekey")"
        [[ -s "$f" ]] || continue
        nodecore="$(jq -r '.core // empty' "$f" 2>/dev/null || true)"
        [[ "$nodecore" == "$core" ]] || continue
        port="$(jq -r '.port // "?"' "$f" 2>/dev/null || true)"
        server="$(jq -r '.server // "?"' "$f" 2>/dev/null || true)"
        sni="$(jq -r '.sni // empty' "$f" 2>/dev/null || true)"
        service="$(jq -r '.service // "?"' "$f" 2>/dev/null || true)"
        uri="$(jq -r '.uri // empty' "$f" 2>/dev/null || true)"
        transport="tcp"
        if [[ "$protocol" == hysteria2 || "$protocol" == tuic ]]; then transport="udp"; fi
        ((count+=1))
        printf '\n  [%s] %s  %s %s\n' "$count" "$protocol" "$port" "$transport"
        printf '      服务器：%s\n' "$server"
        if [[ -n "$sni" ]]; then printf '      SNI：%s\n' "$sni"; fi
        printf '      服务：%s\n' "$service"
        printf '      URI：%s\n' "$uri"
    done
    if (( count == 0 )); then
        printf '  暂无已安装节点。\n'
    else
        printf '\n  共 %d 个 %s 节点。\n' "$count" "$core"
    fi
}

print_core_node_uris() {
    local core="$1" protocol nodekey f nodecore uri count=0
    local protocols=()
    if [[ "$core" == "sing-box" ]]; then
        protocols=(anytls hysteria2 tuic)
    else
        protocols=(anytls hysteria2 tuic vless trojan shadowsocks vmess mixed)
    fi
    printf '\n╭────────────────────────────────────────────────────────────╮\n'
    printf '│  %-56s │\n' "节点连接（可直接复制）"
    printf '╰────────────────────────────────────────────────────────────╯\n'
    for protocol in "${protocols[@]}"; do
        nodekey="$protocol"
        [[ "$core" == "mihomo" ]] && nodekey="mihomo-${protocol}"
        f="$(node_file "$nodekey")"
        [[ -s "$f" ]] || continue
        nodecore="$(jq -r '.core // empty' "$f" 2>/dev/null || true)"
        [[ "$nodecore" == "$core" ]] || continue
        uri="$(jq -r '.uri // empty' "$f" 2>/dev/null || true)"
        [[ -n "$uri" ]] || continue
        ((count+=1))
        printf '\n  %s\n' "$uri"
    done
    if (( count == 0 )); then
        printf '  暂无已安装节点。\n'
    else
        printf '\n  共 %d 个节点连接。\n' "$count"
    fi
}

batch_generate() {
    local core="$1" server sni protocols protocol fn output ok_count=0 fail_count=0 skip_count=0 total
    if [[ "$core" == "sing-box" ]]; then
        protocols=(anytls hysteria2 tuic)
    else
        protocols=(anytls hysteria2 tuic vless trojan shadowsocks vmess mixed)
    fi
    total="${#protocols[@]}"
    show_banner
    ui_title "一键生成全部节点" "${core} · 自动安装 ${total} 个协议"
    server="$(ask '服务器地址（IP/域名）' "$(server_address_guess)")"
    [[ -n "$server" ]] || { err '服务器地址不能为空。'; return 1; }
    sni="$(ask 'TLS SNI/证书名称' "$NODEBOX_DEFAULT_TLS_SNI")"
    [[ -n "$sni" ]] || sni="$NODEBOX_DEFAULT_TLS_SNI"
    printf '\n服务器：%s\n默认 SNI：%s\n' "$server" "$sni"
    printf '\n说明：已有节点保留并跳过；新节点自动生成认证信息。\n'
    confirm '开始批量生成' 'Y' || return 0

    NODEBOX_BATCH_MODE=1
    NODEBOX_BATCH_SERVER="$server"
    NODEBOX_BATCH_SNI="$sni"
    for protocol in "${protocols[@]}"; do
        local nodekey="$protocol"
        if [[ "$core" == "mihomo" ]]; then nodekey="mihomo-$protocol"; fi
        printf '\n  [%d/%d] %-14s' "$((ok_count+fail_count+skip_count+1))" "$total" "$protocol"
        if [[ -s "$(node_file "$nodekey")" ]] && [[ "$(jq -r '.core // empty' "$(node_file "$nodekey")" 2>/dev/null || true)" == "$core" ]]; then
            printf '  已存在，跳过
'
            ((skip_count+=1))
            continue
        fi
        if [[ "$core" == "sing-box" ]]; then fn=singbox_install_dispatch; else fn=mihomo_install_dispatch; fi
        if output="$($fn "$protocol" 2>&1)"; then
            if [[ -s "$(node_file "$nodekey")" ]] && [[ "$(jq -r '.core // empty' "$(node_file "$nodekey")" 2>/dev/null || true)" == "$core" ]] && [[ -n "$(jq -r '.uri // empty' "$(node_file "$nodekey")" 2>/dev/null || true)" ]]; then
                printf '  ✓ 成功
'
                ((ok_count+=1))
            else
                printf '  ✗ 失败（节点注册信息缺失）
'
                ((fail_count+=1))
                [[ -n "$output" ]] && printf '      %s
' "$(printf '%s
' "$output" | tail -n 5 | tr '
' ' ')"
            fi
        else
            printf '  ✗ 失败
'
            ((fail_count+=1))
            if [[ -n "$output" ]]; then printf '      %s
' "$(printf '%s
' "$output" | tail -n 5 | tr '
' ' ')"; fi
        fi
    done
    NODEBOX_BATCH_MODE=0
    NODEBOX_BATCH_SERVER=""
    NODEBOX_BATCH_SNI=""

    printf '\n╭────────────────────────────────────────────────────────────╮\n'
    printf '│  批量生成完成                                             │\n'
    printf '╰────────────────────────────────────────────────────────────╯\n'
    printf '  成功：%d    跳过：%d    失败：%d\n' "$ok_count" "$skip_count" "$fail_count"
    local registered=0 expected=$((ok_count + skip_count))
    local summary_protocol summary_key summary_file summary_core
    if [[ "$core" == "sing-box" ]]; then
        for summary_protocol in anytls hysteria2 tuic; do
            summary_key="$summary_protocol"
            summary_file="$(node_file "$summary_key")"
            [[ -s "$summary_file" ]] || continue
            summary_core="$(jq -r '.core // empty' "$summary_file" 2>/dev/null || true)"
            [[ "$summary_core" == "$core" ]] && ((registered+=1))
        done
    else
        for summary_protocol in anytls hysteria2 tuic vless trojan shadowsocks vmess mixed; do
            summary_key="mihomo-$summary_protocol"
            summary_file="$(node_file "$summary_key")"
            [[ -s "$summary_file" ]] || continue
            summary_core="$(jq -r '.core // empty' "$summary_file" 2>/dev/null || true)"
            [[ "$summary_core" == "$core" ]] && ((registered+=1))
        done
    fi
    if (( registered != expected )); then
        warn "节点注册表校验异常：批量结果应有 ${expected} 个，当前仅找到 ${registered} 个。"
    fi
    if (( expected > 0 )); then
        printf '\n核心运行检查：\n'
        if core_start_registered "$core" && core_is_running "$core"; then
            ok "${core} 核心已启动并确认正在运行。"
        else
            err "${core} 核心启动/运行检查失败。"
            printf '  请进入“核心运行状态”查看具体服务状态。\n'
        fi
    fi
    print_core_node_uris "$core"
    return 0
}

node_uninstall_one() {
    local protocol="$1" file="$(node_file "$1")" port transport
    [[ -s "$file" ]] || { warn "节点 ${protocol} 未安装。"; return 1; }
    port="$(jq -r '.port // empty' "$file" 2>/dev/null || true)"
    transport="tcp"
    if [[ "$protocol" == hysteria2 || "$protocol" == tuic || "$protocol" == mihomo-hysteria2 || "$protocol" == mihomo-tuic ]]; then transport="udp"; fi
    if ! confirm "确认卸载 ${protocol}（端口 ${port}/${transport}）" 'N'; then return 0; fi
    node_registry_remove "$protocol"
    ok "${protocol} 已卸载，端口 ${port}/${transport} 已释放。"
}

node_uninstall_all() {
    local core="$1" f protocol nodecore count=0
    shopt -s nullglob
    local files=("${NODEBOX_NODES}"/*.json)
    shopt -u nullglob
    for f in "${files[@]}"; do
        nodecore="$(jq -r '.core // empty' "$f" 2>/dev/null || true)"
        [[ "$nodecore" == "$core" ]] || continue
        ((count+=1))
    done
    (( count > 0 )) || { warn "${core} 没有已安装节点。"; return 0; }
    if ! confirm "确认卸载 ${core} 的全部 ${count} 个节点" 'N'; then return 0; fi
    for f in "${files[@]}"; do
        nodecore="$(jq -r '.core // empty' "$f" 2>/dev/null || true)"
        [[ "$nodecore" == "$core" ]] || continue
        protocol="$(jq -r '.protocol // empty' "$f")"
        node_registry_remove "$protocol"
        ok "已卸载 ${protocol}"
    done
}

node_lifecycle_menu() {
    local core="$1" f protocol file service action
    while true; do
        show_banner
        ui_title "节点管理" "$core · 生命周期管理"
        print_core_nodes "$core"
        printf '\n'
        ui_menu_item 1 '查看节点详情'
        ui_menu_item 2 '启动节点'
        ui_menu_item 3 '停止节点'
        ui_menu_item 4 '重启节点'
        ui_menu_item 5 '查看节点日志'
        ui_menu_item 6 '卸载指定节点'
        ui_menu_item 7 '卸载全部节点'
        ui_menu_item 8 '重新生成指定节点'
        ui_menu_item 0 '返回'
        printf '\n'
        local choice; choice="$(menu_choice '请选择：' || true)"
        case "$choice" in
            1)
                protocol="$(ask '输入协议名称')"
                if [[ "$core" == mihomo && "$protocol" != mihomo-* ]]; then protocol="mihomo-$protocol"; fi
                file="$(node_file "$protocol")"
                if [[ -s "$file" ]]; then jq . "$file"; else warn '未找到该节点。'; fi; pause_back ;;
            2|3|4|5)
                protocol="$(ask '输入协议名称')"
                if [[ "$core" == mihomo && "$protocol" != mihomo-* ]]; then protocol="mihomo-$protocol"; fi
                file="$(node_file "$protocol")"; service="$(node_service_name "$protocol")"
                [[ -s "$file" ]] || { warn '未找到该节点。'; pause_back; continue; }
                case "$choice" in
                    2) systemctl start "$service" && ok "${protocol} 已启动。" || err '启动失败。' ;;
                    3) systemctl stop "$service" && ok "${protocol} 已停止。" || err '停止失败。' ;;
                    4) systemctl restart "$service" && ok "${protocol} 已重启。" || err '重启失败。' ;;
                    5) journalctl -u "$service" -n 100 --no-pager || true ;;
                esac
                pause_back ;;
            6)
                protocol="$(ask '输入要卸载的协议')"
                if [[ "$core" == mihomo && "$protocol" != mihomo-* ]]; then protocol="mihomo-$protocol"; fi
                node_uninstall_one "$protocol"; pause_back ;;
            7) node_uninstall_all "$core"; pause_back ;;
            8)
                protocol="$(ask '输入要重新生成的协议')"
                if [[ "$core" == mihomo && "$protocol" != mihomo-* ]]; then protocol="mihomo-$protocol"; fi
                file="$(node_file "$protocol")"
                if [[ ! -s "$file" ]]; then warn '未找到该节点。'; pause_back; continue; fi
                local oldserver old_sni
                oldserver="$(jq -r '.server // empty' "$file")"; old_sni="$(jq -r '.sni // empty' "$file")"
                NODEBOX_BATCH_MODE=1; NODEBOX_BATCH_SERVER="$oldserver"; NODEBOX_BATCH_SNI="${old_sni:-$NODEBOX_DEFAULT_TLS_SNI}"
                if [[ "$core" == "sing-box" ]]; then output="$(singbox_install_dispatch "$protocol" 2>&1)"; else output="$(mihomo_install_dispatch "${protocol#mihomo-}" 2>&1)"; fi
                NODEBOX_BATCH_MODE=0; NODEBOX_BATCH_SERVER=""; NODEBOX_BATCH_SNI=""
                if [[ -n "$output" ]]; then printf '%s\n' "$output" | tail -n 3; fi
                pause_back ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

# ---------- Node registry ----------
list_nodes() {
    local f
    printf '已保存节点：\n\n'
    shopt -s nullglob
    local files=("$NODEBOX_NODES"/*.json)
    shopt -u nullglob
    if [[ "${#files[@]}" -eq 0 ]]; then
        printf '暂无节点。\n'
        return 0
    fi
    for f in "${files[@]}"; do
        local protocol port server service
        protocol="$(jq -r '.protocol // "unknown"' "$f")"
        port="$(jq -r '.port // "?"' "$f")"
        server="$(jq -r '.server // "?"' "$f")"
        service="$(jq -r '.service // "?"' "$f")"
        printf '%-12s server=%s  port=%s  service=%s\n' "$protocol" "$server" "$port" "$service"
    done
}

node_menu() {
    while true; do
        show_banner
        printf '节点管理\n\n'
        list_nodes
        printf '\n1. 删除指定协议节点\n0. 返回\n\n'
        local choice protocol file service
        choice="$(menu_choice '请选择：' || true)"
        case "$choice" in
            1)
                protocol="$(ask '输入节点协议（例如 anytls）')"
                file="${NODEBOX_NODES}/${protocol}.json"
                service="$(node_service_name "$protocol")"
                if [[ -f "$file" ]]; then
                    if confirm "确认删除 ${protocol} 节点及服务" 'N'; then
                        node_registry_remove "$protocol"
                        ok "已删除 ${protocol} 节点。"
                    fi
                else
                    warn '未找到该节点。'
                fi
                pause_back
                ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

# ---------- Hysteria2 / TUIC ----------
singbox_choose_port() {
    local protocol="$1" old_port='' service=""
    service="$(node_service_name "$protocol")"
    if [[ -s "$(node_file "$protocol")" ]]; then
        old_port="$(jq -r '.port // empty' "$(node_file "$protocol")" 2>/dev/null || true)"
    fi
    # NodeBox uses one global numeric port pool. TCP/UDP never share a number.
    if [[ "$old_port" =~ ^[0-9]+$ ]] && ! node_port_in_registry "$old_port" "$protocol" \
        && ! port_in_use "$old_port"; then
        printf '%s' "$old_port"
        return 0
    fi
    find_free_port_transport both "$NODEBOX_DEFAULT_PORT"
}

singbox_quic_service_write() {
    local protocol="$1" config="$2" service bin
    service="$(node_service_name "$protocol")"
    bin="$(core_binary sing-box)"
    cat > "/etc/systemd/system/${service}" <<EOF_SINGBOX_QUIC
[Unit]
Description=NodeBox ${protocol}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${bin} run -c ${config}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$(dirname "$config")

[Install]
WantedBy=multi-user.target
EOF_SINGBOX_QUIC
}

singbox_quic_tls_files() {
    local protocol="$1" dir
    dir="${NODEBOX_CONFIG}/${protocol}"
    mkdir -p "$dir"
    anytls_generate_certificate "$dir" "$2"
}

hysteria2_install() {
    local protocol=hysteria2 host domain port password config cert key service uri tmpdir oldreg had_old=0
    if [[ ! -x "$(core_binary sing-box)" ]]; then
        msg 'Hysteria2 使用 Sing-box 核心，当前未安装。'
        install_core sing-box || return 1
    fi
    host="$(ask '服务器地址（IP/域名）' "$(server_address_guess)")"
    domain="$(ask 'TLS SNI/证书名称' "$NODEBOX_DEFAULT_TLS_SNI")"; [[ -n "$domain" ]] || domain="$NODEBOX_DEFAULT_TLS_SNI"
    password="$(ask 'Hysteria2 密码（留空自动生成）')"; [[ -n "$password" ]] || password="$(anytls_generate_password)"
    port="$(singbox_choose_port "$protocol")" || { err '无法找到可用端口。'; return 1; }
    ok "Hysteria2 已分配 UDP 端口 ${port}。"
    config="${NODEBOX_CONFIG}/${protocol}/config.json"
    cert="${NODEBOX_CONFIG}/${protocol}/server.crt"
    key="${NODEBOX_CONFIG}/${protocol}/server.key"
    service="$(node_service_name "$protocol")"
    uri="hysteria2://$(node_url_encode "$password")@$(node_address_for_uri "$host"):${port}/?sni=$(node_url_encode "$domain")&insecure=1#NodeBox%20Hysteria2"
    tmpdir="$(mktemp -d "${NODEBOX_TMP}/${protocol}.XXXXXX")"
    tls_backup_files "$(dirname "$config")" "$tmpdir/tls-backup"
    if ! singbox_quic_tls_files "$protocol" "$domain"; then
        tls_restore_files "$(dirname "$config")" "$tmpdir/tls-backup"; rm -rf -- "$tmpdir"; err 'Hysteria2 TLS 证书生成失败。'; return 1
    fi
    cert="${NODEBOX_CONFIG}/${protocol}/server.crt"; key="${NODEBOX_CONFIG}/${protocol}/server.key"
    jq -n --argjson port "$port" --arg password "$password" --arg cert "$cert" --arg key "$key" \
        '{log:{level:"info",timestamp:true},inbounds:[{type:"hysteria2",tag:"hysteria2-in",listen:"::",listen_port:$port,users:[{name:"nodebox",password:$password}],tls:{enabled:true,certificate_path:$cert,key_path:$key}}],outbounds:[{type:"direct",tag:"direct"}]}' > "${tmpdir}/config.json"
    if ! "$(core_binary sing-box)" check -c "${tmpdir}/config.json" >/dev/null; then tls_restore_files "$(dirname "$config")" "$tmpdir/tls-backup"; rm -rf -- "$tmpdir"; err 'Hysteria2 配置检查失败。'; return 1; fi
    oldreg="$(node_file "$protocol")"; [[ -s "$oldreg" ]] && had_old=1
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$config")"
    install -m 0600 "${tmpdir}/config.json" "$config"
    singbox_quic_service_write "$protocol" "$config"
    systemctl daemon-reload
    if ! systemctl enable --now "$service"; then
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        tls_restore_files "$(dirname "$config")" "$tmpdir/tls-backup"
        rm -rf -- "$tmpdir"
        err 'Hysteria2 启动失败。'
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet "$service" || ! port_in_use_transport "$port" udp; then
        journalctl -u "$service" -n 30 --no-pager >&2 || true
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        tls_restore_files "$(dirname "$config")" "$tmpdir/tls-backup"
        rm -rf -- "$tmpdir"
        err 'Hysteria2 未成功监听端口。'
        return 1
    fi
    node_registry_write "$protocol" "$config" "$service" "$uri" "$host" "$port" "$password" "$domain"
    rm -rf -- "$tmpdir"
    ok 'Hysteria2 安装/更新成功。'
    printf '\n协议：Hysteria2\n核心：Sing-box\n服务器：%s\n端口：%s/UDP\nSNI：%s\n密码：%s\n服务：%s\n配置：%s\n\n节点 URI：\n%s\n' "$host" "$port" "$domain" "$password" "$service" "$config" "$uri"
}

tuic_install() {
    local protocol=tuic host domain port password uuid config cert key service uri tmpdir
    if [[ ! -x "$(core_binary sing-box)" ]]; then
        msg 'TUIC 使用 Sing-box 核心，当前未安装。'
        install_core sing-box || return 1
    fi
    host="$(ask '服务器地址（IP/域名）' "$(server_address_guess)")"
    domain="$(ask 'TLS SNI/证书名称' "$NODEBOX_DEFAULT_TLS_SNI")"; [[ -n "$domain" ]] || domain="$NODEBOX_DEFAULT_TLS_SNI"
    password="$(ask 'TUIC 密码（留空自动生成）')"; [[ -n "$password" ]] || password="$(anytls_generate_password)"
    uuid="$(ask 'TUIC UUID（留空自动生成）')"; [[ -n "$uuid" ]] || uuid="$(cat /proc/sys/kernel/random/uuid)"
    port="$(singbox_choose_port "$protocol")" || { err '无法找到可用端口。'; return 1; }
    ok "TUIC 已分配 UDP 端口 ${port}。"
    config="${NODEBOX_CONFIG}/${protocol}/config.json"
    cert="${NODEBOX_CONFIG}/${protocol}/server.crt"; key="${NODEBOX_CONFIG}/${protocol}/server.key"
    service="$(node_service_name "$protocol")"
    uri="tuic://$(node_url_encode "$uuid"):$(node_url_encode "$password")@$(node_address_for_uri "$host"):${port}/?sni=$(node_url_encode "$domain")&insecure=1#NodeBox%20TUIC"
    tmpdir="$(mktemp -d "${NODEBOX_TMP}/${protocol}.XXXXXX")"
    tls_backup_files "$(dirname "$config")" "$tmpdir/tls-backup"
    if ! singbox_quic_tls_files "$protocol" "$domain"; then
        tls_restore_files "$(dirname "$config")" "$tmpdir/tls-backup"; rm -rf -- "$tmpdir"; err 'TUIC TLS 证书生成失败。'; return 1
    fi
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --arg cert "$cert" --arg key "$key" \
        '{log:{level:"info",timestamp:true},inbounds:[{type:"tuic",tag:"tuic-in",listen:"::",listen_port:$port,users:[{name:"nodebox",uuid:$uuid,password:$password}],congestion_control:"bbr",auth_timeout:"3s",zero_rtt_handshake:false,heartbeat:"10s",tls:{enabled:true,certificate_path:$cert,key_path:$key}}],outbounds:[{type:"direct",tag:"direct"}]}' > "${tmpdir}/config.json"
    if ! "$(core_binary sing-box)" check -c "${tmpdir}/config.json" >/dev/null; then tls_restore_files "$(dirname "$config")" "$tmpdir/tls-backup"; rm -rf -- "$tmpdir"; err 'TUIC 配置检查失败。'; return 1; fi
    systemctl disable --now "$service" >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$config")"
    install -m 0600 "${tmpdir}/config.json" "$config"
    singbox_quic_service_write "$protocol" "$config"
    systemctl daemon-reload
    if ! systemctl enable --now "$service"; then
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        tls_restore_files "$(dirname "$config")" "$tmpdir/tls-backup"
        rm -rf -- "$tmpdir"
        err 'TUIC 启动失败。'
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet "$service" || ! port_in_use_transport "$port" udp; then
        journalctl -u "$service" -n 30 --no-pager >&2 || true
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        tls_restore_files "$(dirname "$config")" "$tmpdir/tls-backup"
        rm -rf -- "$tmpdir"
        err 'TUIC 未成功监听 UDP 端口。'
        return 1
    fi
    node_registry_write "$protocol" "$config" "$service" "$uri" "$host" "$port" "$password" "$domain"
    # Keep UUID in the node registry as an additional protocol-specific field.
    jq --arg uuid "$uuid" '. + {uuid:$uuid}' "$(node_file "$protocol")" > "$(node_file "$protocol").tmp"
    mv -f -- "$(node_file "$protocol").tmp" "$(node_file "$protocol")"
    rm -rf -- "$tmpdir"
    ok 'TUIC 安装/更新成功。'
    printf '\n协议：TUIC\n核心：Sing-box\n服务器：%s\n端口：%s/UDP\nSNI：%s\nUUID：%s\n密码：%s\n服务：%s\n配置：%s\n\n节点 URI：\n%s\n' "$host" "$port" "$domain" "$uuid" "$password" "$service" "$config" "$uri"
}

singbox_extra_menu() {
    while true; do
        show_banner
        ui_title "Sing-box 节点中心" "一键生成 · 手动安装 · 节点管理"
        printf '
核心：'; core_status sing-box
        printf '
'
        ui_menu_item 1 '一键生成全部节点'
        ui_menu_item 2 '手动安装节点'
        ui_menu_item 3 '节点管理'
        ui_menu_item 4 '查看全部节点链接'
        ui_menu_item 5 '核心状态'
        ui_menu_item 0 '返回'
        printf '
'
        local choice protocol
        choice="$(menu_choice '请选择：' || true)"
        case "$choice" in
            1) batch_generate sing-box; pause_back ;;
            2)
                show_banner; ui_title '手动安装节点' '选择一个协议单独配置'
                printf '
'; ui_menu_item 1 'AnyTLS'; ui_menu_item 2 'Hysteria2'; ui_menu_item 3 'TUIC v5'; ui_menu_item 0 '返回'
                protocol="$(menu_choice '请选择：' || true)"
                case "$protocol" in
                    1) anytls_menu ;; 2) singbox_protocol_menu hysteria2 ;; 3) singbox_protocol_menu tuic ;; esac ;;
            3) node_lifecycle_menu sing-box ;;
            4) show_banner; print_core_nodes sing-box; pause_back ;;
            5) show_banner; core_status sing-box; pause_back ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

singbox_protocol_menu() {
    local protocol="$1" service="$(node_service_name "$1")" file="$(node_file "$1")"
    while true; do
        show_banner
        printf '%s\n\n' "$protocol"
        node_status_one "$protocol"
        printf '\n1. 安装/重新安装\n2. 启动\n3. 停止\n4. 重启\n5. 查看节点信息\n6. 查看日志\n7. 删除\n0. 返回\n\n'
        local choice
        choice="$(menu_choice '请选择：' || true)"
        case "$choice" in
            1)
                case "$protocol" in
                    hysteria2) hysteria2_install ;;
                    tuic) tuic_install ;;
                            esac
                pause_back
                ;;
            2) systemctl start "$service" && ok '服务已启动。' || err '启动失败。'; pause_back ;;
            3) systemctl stop "$service" && ok '服务已停止。' || err '停止失败。'; pause_back ;;
            4) systemctl restart "$service" && ok '服务已重启。' || err '重启失败。'; pause_back ;;
            5) [[ -s "$file" ]] && jq . "$file" || warn '节点尚未安装。'; pause_back ;;
            6) journalctl -u "$service" -n 100 --no-pager || true; pause_back ;;
            7) if [[ -s "$file" ]] && confirm "确认删除 ${protocol} 节点及服务" 'N'; then node_registry_remove "$protocol"; rm -rf -- "${NODEBOX_CONFIG}/${protocol}"; ok "${protocol} 已删除。"; fi; pause_back ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

# ---------- Mihomo server protocols ----------
mihomo_dir() { printf '%s/mihomo/%s' "$NODEBOX_CONFIG" "$1"; }
mihomo_config() { printf '%s/config.yaml' "$(mihomo_dir "$1")"; }
mihomo_cert() { printf '%s/server.crt' "$(mihomo_dir "$1")"; }
mihomo_key() { printf '%s/server.key' "$(mihomo_dir "$1")"; }

mihomo_prepare_core() {
    if [[ ! -x "$(core_binary mihomo)" ]]; then
        msg '当前节点需要 Mihomo，正在安装/更新核心...'
        install_core mihomo || return 1
    fi
}

mihomo_service_write() {
    local protocol="$1" config="$2" service bin dir
    service="$(node_service_name "mihomo-${protocol}")"; bin="$(core_binary mihomo)"; dir="$(dirname "$config")"
    cat > "/etc/systemd/system/${service}" <<EOF_MH
[Unit]
Description=NodeBox Mihomo ${protocol}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${dir}
ExecStart=${bin} -d ${dir} -f ${config}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${dir}

[Install]
WantedBy=multi-user.target
EOF_MH
}

mihomo_install_listener() {
    local protocol="$1" type="$2" host domain port credential uuid config dir cert key tmpdir uri extra='{}' service mhcfg
    mihomo_prepare_core || return 1
    host="$(ask '服务器地址（IP/域名）' "$(server_address_guess)")"; [[ -n "$host" ]] || return 1
    domain="$(ask 'TLS SNI/证书名称' "$NODEBOX_DEFAULT_TLS_SNI")"; [[ -n "$domain" ]] || domain="$NODEBOX_DEFAULT_TLS_SNI"
    port="$(node_port_for_protocol "mihomo-${protocol}")" || { err '无法找到全局唯一可用端口。'; return 1; }
    dir="$(mihomo_dir "$protocol")"; config="${dir}/config.yaml"; cert="${dir}/server.crt"; key="${dir}/server.key"
    mkdir -p "$dir"
    tmpdir="$(mktemp -d "${NODEBOX_TMP}/mihomo-${protocol}.XXXXXX")"
    tls_backup_files "$dir" "$tmpdir/tls-backup"

    if ! anytls_generate_certificate "$dir" "$domain"; then
        tls_restore_files "$dir" "$tmpdir/tls-backup"; rm -rf -- "$tmpdir"
        err "Mihomo ${protocol} TLS 证书生成失败。"; return 1
    fi

    case "$type" in
        anytls)
            credential="$(ask 'AnyTLS 密码（留空自动生成）')"; [[ -n "$credential" ]] || credential="$(random_password)"
            uri="anytls://$(node_url_encode "$credential")@$(node_address_for_uri "$host"):${port}/?sni=$(node_url_encode "$domain")&insecure=1#NodeBox%20Mihomo%20AnyTLS"
            cat > "${tmpdir}/config.yaml" <<EOF_MHCFG
mode: rule
listeners:
  - name: anytls-in
    type: anytls
    port: ${port}
    listen: "::"
    users:
      nodebox: "${credential}"
    certificate: "./server.crt"
    private-key: "./server.key"
    proxy: DIRECT
rules:
  - MATCH,DIRECT
EOF_MHCFG
            extra="{\"password\":\"$credential\"}"
            ;;
        hysteria2)
            credential="$(ask 'Hysteria2 密码（留空自动生成）')"; [[ -n "$credential" ]] || credential="$(random_password)"
            uri="hysteria2://$(node_url_encode "$credential")@$(node_address_for_uri "$host"):${port}/?sni=$(node_url_encode "$domain")&insecure=1#NodeBox%20Mihomo%20Hysteria2"
            cat > "${tmpdir}/config.yaml" <<EOF_MHCFG
mode: rule
listeners:
  - name: hysteria2-in
    type: hysteria2
    port: ${port}
    listen: "::"
    users:
      nodebox: "${credential}"
    certificate: "./server.crt"
    private-key: "./server.key"
    alpn:
      - h3
    proxy: DIRECT
rules:
  - MATCH,DIRECT
EOF_MHCFG
            ;;
        tuic)
            uuid="$(ask 'TUIC UUID（留空自动生成）')"; [[ -n "$uuid" ]] || uuid="$(random_uuid)"
            credential="$(ask 'TUIC 密码（留空自动生成）')"; [[ -n "$credential" ]] || credential="$(random_password)"
            uri="tuic://$(node_url_encode "$uuid"):$(node_url_encode "$credential")@$(node_address_for_uri "$host"):${port}/?sni=$(node_url_encode "$domain")&insecure=1#NodeBox%20Mihomo%20TUIC"
            cat > "${tmpdir}/config.yaml" <<EOF_MHCFG
mode: rule
listeners:
  - name: tuic-in
    type: tuic
    port: ${port}
    listen: "::"
    users:
      ${uuid}: "${credential}"
    certificate: "./server.crt"
    private-key: "./server.key"
    congestion-controller: bbr
    authentication-timeout: 1000
    max-idle-time: 15000
    alpn:
      - h3
    max-udp-relay-packet-size: 1500
    proxy: DIRECT
rules:
  - MATCH,DIRECT
EOF_MHCFG
            extra="{\"uuid\":\"$uuid\"}"
            ;;
        vless)
            uuid="$(ask 'VLESS UUID（留空自动生成）')"; [[ -n "$uuid" ]] || uuid="$(random_uuid)"; credential="$uuid"
            uri="vless://${uuid}@$(node_address_for_uri "$host"):${port}/?encryption=none&security=tls&type=tcp&sni=$(node_url_encode "$domain")&allowInsecure=1#NodeBox%20Mihomo%20VLESS"
            cat > "${tmpdir}/config.yaml" <<EOF_MHCFG
mode: rule
listeners:
  - name: vless-in
    type: vless
    port: ${port}
    listen: "::"
    users:
      - username: nodebox
        uuid: ${uuid}
    certificate: "./server.crt"
    private-key: "./server.key"
    proxy: DIRECT
rules:
  - MATCH,DIRECT
EOF_MHCFG
            extra="{\"uuid\":\"$uuid\"}"
            ;;
        trojan)
            credential="$(ask 'Trojan 密码（留空自动生成）')"; [[ -n "$credential" ]] || credential="$(random_password)"
            uri="trojan://$(node_url_encode "$credential")@$(node_address_for_uri "$host"):${port}/?security=tls&sni=$(node_url_encode "$domain")&allowInsecure=1#NodeBox%20Mihomo%20Trojan"
            cat > "${tmpdir}/config.yaml" <<EOF_MHCFG
mode: rule
listeners:
  - name: trojan-in
    type: trojan
    port: ${port}
    listen: "::"
    users:
      - username: nodebox
        password: "${credential}"
    certificate: "./server.crt"
    private-key: "./server.key"
    proxy: DIRECT
rules:
  - MATCH,DIRECT
EOF_MHCFG
            ;;
        vmess)
            uuid="$(ask 'VMess UUID（留空自动生成）')"; [[ -n "$uuid" ]] || uuid="$(random_uuid)"; credential="$uuid"
            local vmj vm64
            vmj="$(jq -nc --arg v "2" --arg ps "NodeBox VMess" --arg add "$host" --arg port "$port" --arg id "$uuid" --arg aid "0" --arg net "tcp" --arg type "none" --arg hostx "$domain" --arg path "/" --arg tls "tls" '{v:$v,ps:$ps,add:$add,port:$port,id:$id,aid:$aid,scy:"auto",net:$net,type:$type,host:$hostx,path:$path,tls:$tls}')"
            vm64="$(printf '%s' "$vmj" | base64 -w0 2>/dev/null || printf '%s' "$vmj" | base64 | tr -d '\n')"
            uri="vmess://${vm64}"
            cat > "${tmpdir}/config.yaml" <<EOF_MHCFG
mode: rule
listeners:
  - name: vmess-in
    type: vmess
    port: ${port}
    listen: "::"
    users:
      - username: nodebox
        uuid: ${uuid}
        alterId: 0
    certificate: "./server.crt"
    private-key: "./server.key"
    proxy: DIRECT
rules:
  - MATCH,DIRECT
EOF_MHCFG
            extra="{\"uuid\":\"$uuid\"}"
            ;;
        shadowsocks)
            credential="$(ask 'Shadowsocks 密钥（留空自动生成）')"; [[ -n "$credential" ]] || credential="$(random_ss_key)"
            uri="ss://$(printf '%s' "2022-blake3-aes-256-gcm:${credential}" | base64 -w0 2>/dev/null || printf '%s' "2022-blake3-aes-256-gcm:${credential}" | base64 | tr -d '\n')@$(node_address_for_uri "$host"):${port}#NodeBox%20Mihomo%20Shadowsocks"
            cat > "${tmpdir}/config.yaml" <<EOF_MHCFG
mode: rule
listeners:
  - name: ss-in
    type: shadowsocks
    port: ${port}
    listen: "::"
    cipher: 2022-blake3-aes-256-gcm
    password: "${credential}"
    udp: true
    proxy: DIRECT
rules:
  - MATCH,DIRECT
EOF_MHCFG
            ;;
        *) err 'Mihomo 内部协议类型错误。'; rm -rf -- "$tmpdir"; return 1 ;;
    esac

    service="$(node_service_name "mihomo-${protocol}")"
    # The parser runs inside the temporary working directory. TLS files referenced
    # by relative paths must therefore exist there before validation.
    if [[ -f "$cert" && -f "$key" ]]; then
        install -m 0600 "$cert" "${tmpdir}/server.crt"
        install -m 0600 "$key" "${tmpdir}/server.key"
    fi
    # Validate with the real Mihomo parser before replacing the live config.
    if ! "$(core_binary mihomo)" -d "$tmpdir" -f "${tmpdir}/config.yaml" -t 2>"${tmpdir}/check.log"; then
        cat "${tmpdir}/check.log" >&2 || true
        tls_restore_files "$dir" "$tmpdir/tls-backup"; rm -rf -- "$tmpdir"
        err "Mihomo ${protocol} 配置检查失败。"; return 1
    fi

    local backup="$(mktemp -d "${NODEBOX_TMP}/rollback-mihomo-${protocol}.XXXXXX")"
    [[ -f "$config" ]] && cp -f -- "$config" "${backup}/config"
    [[ -f "$cert" ]] && cp -f -- "$cert" "${backup}/crt"
    [[ -f "$key" ]] && cp -f -- "$key" "${backup}/key"
    [[ -f "$(node_file "mihomo-${protocol}")" ]] && cp -f -- "$(node_file "mihomo-${protocol}")" "${backup}/registry"

    systemctl disable --now "$service" >/dev/null 2>&1 || true
    install -m 0600 "${tmpdir}/config.yaml" "$config"
    # Keep the certificate/key beside the config; relative paths are resolved by WorkingDirectory.
    mihomo_service_write "$protocol" "$config"
    systemctl daemon-reload
    if ! systemctl enable --now "$service" >/dev/null 2>&1; then
        journalctl -u "$service" -n 40 --no-pager >&2 || true
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        [[ -f "${backup}/config" ]] && install -m 0600 "${backup}/config" "$config" || rm -f -- "$config"
        tls_restore_files "$dir" "$tmpdir/tls-backup"
        systemctl daemon-reload
        [[ -f "${backup}/config" ]] && systemctl enable --now "$service" >/dev/null 2>&1 || true
        rm -rf -- "$backup" "$tmpdir"; err "Mihomo ${protocol} 启动失败，已回滚。"; return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet "$service" || ! port_in_use "$port"; then
        journalctl -u "$service" -n 40 --no-pager >&2 || true
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        [[ -f "${backup}/config" ]] && install -m 0600 "${backup}/config" "$config" || rm -f -- "$config"
        tls_restore_files "$dir" "$tmpdir/tls-backup"
        systemctl daemon-reload
        [[ -f "${backup}/config" ]] && systemctl enable --now "$service" >/dev/null 2>&1 || true
        rm -rf -- "$backup" "$tmpdir"; err "Mihomo ${protocol} 未成功监听端口，已回滚。"; return 1
    fi

    if ! node_registry_write "mihomo-${protocol}" "$config" "$service" "$uri" "$host" "$port" "$credential" "$domain" mihomo; then
        err "Mihomo ${protocol} 节点注册失败，正在回滚。"
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        [[ -f "${backup}/config" ]] && install -m 0600 "${backup}/config" "$config" || rm -f -- "$config"
        tls_restore_files "$dir" "$tmpdir/tls-backup"
        [[ -f "${backup}/registry" ]] && install -m 0600 "${backup}/registry" "$(node_file "mihomo-${protocol}")" || rm -f -- "$(node_file "mihomo-${protocol}")"
        systemctl daemon-reload
        [[ -f "${backup}/config" ]] && systemctl enable --now "$service" >/dev/null 2>&1 || true
        rm -rf -- "$backup" "$tmpdir"; return 1
    fi
    if [[ "$extra" != '{}' ]]; then
        jq --argjson x "$extra" '. + $x + {core:"mihomo"}' "$(node_file "mihomo-${protocol}")" > "$(node_file "mihomo-${protocol}").tmp"
    else
        jq '. + {core:"mihomo"}' "$(node_file "mihomo-${protocol}")" > "$(node_file "mihomo-${protocol}").tmp"
    fi
    mv -f -- "$(node_file "mihomo-${protocol}").tmp" "$(node_file "mihomo-${protocol}")"
    if [[ ! -s "$(node_file "mihomo-${protocol}")" ]] || [[ "$(jq -r '.core // empty' "$(node_file "mihomo-${protocol}")" 2>/dev/null || true)" != 'mihomo' ]] || [[ "$(jq -r '.uri // empty' "$(node_file "mihomo-${protocol}")" 2>/dev/null || true)" != "$uri" ]]; then
        err "Mihomo ${protocol} 节点注册校验失败，正在回滚。"
        rm -f -- "$(node_file "mihomo-${protocol}")"
        [[ -f "${backup}/registry" ]] && install -m 0600 "${backup}/registry" "$(node_file "mihomo-${protocol}")" || true
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        [[ -f "${backup}/config" ]] && install -m 0600 "${backup}/config" "$config" || true
        tls_restore_files "$dir" "$tmpdir/tls-backup"
        systemctl daemon-reload
        [[ -f "${backup}/config" ]] && systemctl enable --now "$service" >/dev/null 2>&1 || true
        rm -rf -- "$backup" "$tmpdir"; return 1
    fi
    if ! systemctl is-active --quiet "$service" || ! core_is_running mihomo; then
        err "Mihomo ${protocol} 安装后核心/服务状态校验失败。"
        journalctl -u "$service" -n 30 --no-pager >&2 || true
        rm -rf -- "$backup" "$tmpdir"; return 1
    fi
    rm -rf -- "$backup" "$tmpdir"
    ok "Mihomo ${protocol} 安装/更新成功，核心已运行。"
    node_print_result "mihomo-${protocol}" "$uri" "$host" "$port" "$credential" "$domain" 'Mihomo'
}

mihomo_menu() {
    while true; do
        show_banner
        ui_title "Mihomo 节点中心" "一键生成 · 手动安装 · 节点管理"
        printf '
核心：'; core_status mihomo
        printf '
'
        ui_menu_item 1 '一键生成全部节点'
        ui_menu_item 2 '手动安装节点'
        ui_menu_item 3 '节点管理'
        ui_menu_item 4 '查看全部节点链接'
        ui_menu_item 5 '核心状态'
        ui_menu_item 0 '返回'
        printf '
'
        local choice protocol
        choice="$(menu_choice '请选择：' || true)"
        case "$choice" in
            1) batch_generate mihomo; pause_back ;;
            2)
                show_banner; ui_title '手动安装节点' '选择一个协议单独配置'
                printf '
'; ui_menu_item 1 'AnyTLS'; ui_menu_item 2 'Hysteria2'; ui_menu_item 3 'TUIC v5'; ui_menu_item 4 'VLESS'; ui_menu_item 5 'Trojan'; ui_menu_item 6 'Shadowsocks'; ui_menu_item 7 'VMess'; ui_menu_item 8 'Mixed'; ui_menu_item 0 '返回'
                protocol="$(menu_choice '请选择：' || true)"
                case "$protocol" in
                    1) mihomo_install_listener anytls anytls; pause_back ;; 2) mihomo_install_listener hysteria2 hysteria2; pause_back ;; 3) mihomo_install_listener tuic tuic; pause_back ;; 4) mihomo_install_listener vless vless; pause_back ;; 5) mihomo_install_listener trojan trojan; pause_back ;; 6) mihomo_install_listener shadowsocks shadowsocks; pause_back ;; 7) mihomo_install_listener vmess vmess; pause_back ;; 8) mihomo_install_mixed; pause_back ;; esac ;;
            3) node_lifecycle_menu mihomo ;;
            4) show_banner; print_core_nodes mihomo; pause_back ;;
            5) show_banner; core_status mihomo; pause_back ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

# ---------- System / watchdog ----------
write_watchdog() {
    cat > "$NODEBOX_WATCHDOG" <<'WATCHDOG'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="/opt/nodebox"
ETC="/etc/nodebox"
LOG="${ROOT}/logs/watchdog.log"
NODES="${ETC}/nodes"
mkdir -p "${ROOT}/logs" "${NODES}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

# Protocol services will be registered here by later protocol modules.
check_registered_services() {
    local f service
    shopt -s nullglob
    for f in "${NODES}"/*.service; do
        service="$(cat "$f" 2>/dev/null || true)"
        [[ -n "$service" ]] || continue
        if ! systemctl is-active --quiet "$service"; then
            log "服务异常：${service}，尝试重启"
            systemctl restart "$service" || log "重启失败：${service}"
        fi
    done
    shopt -u nullglob
}

check_core_processes() {
    local core bin
    for core in sing-box mihomo; do
        case "$core" in
            sing-box) bin="${ROOT}/core/sing-box/sing-box" ;;
            mihomo) bin="${ROOT}/core/mihomo/mihomo" ;;
        esac
        [[ -x "$bin" ]] || continue
        # The core may be idle when no protocol service has registered it, so
        # absence of a process is informational rather than an error here.
        if pgrep -xo -f "^${bin}([[:space:]]|$)" >/dev/null 2>&1; then
            continue
        fi
    done
}

while true; do
    check_registered_services
    check_core_processes
    sleep 30
done
WATCHDOG
    chmod 0755 "$NODEBOX_WATCHDOG"
}

install_watchdog_service() {
    cat > "/etc/systemd/system/${NODEBOX_WATCHDOG_SERVICE}" <<EOF_SERVICE
[Unit]
Description=NodeBox Core/Protocol Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NODEBOX_WATCHDOG}
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload
    systemctl enable --now "$NODEBOX_WATCHDOG_SERVICE"
}

install_box_command() {
    cat > "$NODEBOX_BOX" <<'BOX'
#!/usr/bin/env bash
exec /opt/nodebox/nodebox.sh "$@"
BOX
    chmod 0755 "$NODEBOX_BOX"
    ok "全局快捷命令已安装：box"
}

persist_self() {
    local target="${NODEBOX_ROOT}/nodebox.sh"
    if [[ -n "$SELF_PATH" && -f "$SELF_PATH" && "$SELF_PATH" != "$target" ]]; then
        install -m 0755 "$SELF_PATH" "$target"
    elif [[ ! -f "$target" ]]; then
        cat > "$target" <<ONLINE
#!/usr/bin/env bash
set -Eeuo pipefail
URL="${NODEBOX_SCRIPT_URL}"
if [[ -z "\$URL" ]]; then
    echo '[NodeBox] 在线运行模式需要设置 NODEBOX_SCRIPT_URL 后才能持久化更新。' >&2
    exit 1
fi
tmp="\$(mktemp)"
trap 'rm -f "\$tmp"' EXIT
curl -fsSL --connect-timeout 30 --max-time 120 "\$URL" -o "\$tmp"
exec bash "\$tmp" "\$@"
ONLINE
        chmod 0755 "$target"
        warn '当前脚本来自在线管道，无法从 stdin 自持久化；发布到 GitHub 后可设置 NODEBOX_SCRIPT_URL。'
    fi
}

# ---------- NodeBox complete uninstall ----------
uninstall_nodebox_all() {
    show_banner
    ui_title '卸载 NodeBox' '删除 NodeBox 自身及其创建的节点'
    printf '以下内容将被永久删除：\n\n'
    printf '  • NodeBox 安装目录：/opt/nodebox/\n'
    printf '  • NodeBox 节点数据：/etc/nodebox/\n'
    printf '  • NodeBox 自己创建的 systemd 服务：nodebox-*.service\n'
    printf '  • /usr/local/bin/box 全局快捷命令\n'
    printf '\n'
    printf '明确不会删除：\n'
    printf '  • 系统公共依赖（curl、openssl、jq 等）\n'
    printf '  • 其他项目或其他目录\n'
    printf '  • 其他项目的 systemd 服务\n'
    printf '\n'
    warn '卸载范围严格限定为 NodeBox 自身及 NodeBox 创建的节点/服务。'
    if ! confirm '确认完整卸载 NodeBox' 'N'; then
        msg '已取消卸载。'
        return 0
    fi

    printf '\n'
    msg '正在停止并删除 NodeBox 自己创建的 systemd 服务 ...'
    local service
    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        systemctl stop "$service" >/dev/null 2>&1 || true
        systemctl disable "$service" >/dev/null 2>&1 || true
        rm -f -- "/etc/systemd/system/$service"
    done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^nodebox-[^ ]+\\.service$/ {print $1}')
    systemctl daemon-reload >/dev/null 2>&1 || true

    msg '正在删除 NodeBox 节点数据 /etc/nodebox/ ...'
    rm -rf -- "$NODEBOX_ETC"
    msg '正在删除 NodeBox 安装目录 /opt/nodebox/ ...'
    rm -rf -- "$NODEBOX_ROOT"
    msg '正在删除全局快捷命令 box ...'
    rm -f -- "$NODEBOX_BOX"

    printf '\n'
    ok 'NodeBox 已完整卸载。'
    printf '  已删除：/opt/nodebox/、/etc/nodebox/、NodeBox 自己的 systemd 服务、/usr/local/bin/box\n'
    printf '  已保留：系统公共依赖、其他项目及其他项目的 systemd 服务。\n'
    printf '\n'
    clear 2>/dev/null || true
    exit 0
}

# ---------- Initialization ----------

initialize_dirs() {
    mkdir -p "$NODEBOX_ROOT" "$NODEBOX_BIN" "$NODEBOX_CORE" "$NODEBOX_TMP" \
        "$NODEBOX_LOG" "$NODEBOX_ETC" "$NODEBOX_NODES" "$NODEBOX_CONFIG" "$NODEBOX_STATE"
    chmod 0700 "$NODEBOX_TMP" "$NODEBOX_ETC" "$NODEBOX_NODES" "$NODEBOX_CONFIG" "$NODEBOX_STATE"
}

show_system_info() {
    show_banner
    printf '系统信息\n\n'
    printf '系统：%s\n' "$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Linux}" || printf 'Linux')"
    printf '内核：%s\n' "$(uname -sr)"
    printf '架构：%s (%s)\n' "$(uname -m)" "$(normalize_arch 2>/dev/null || printf unsupported)"
    printf 'IPv4：%s\n' "$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -n1 || printf '未检测到')"
    printf 'IPv6：%s\n' "$(hostname -I 2>/dev/null | tr ' ' '\n' | grep ':' | head -n1 || printf '未检测到')"
    printf 'NodeBox：%s\n' "$NODEBOX_VERSION"
    pause_back
}

settings_menu() {
    while true; do
        show_banner
        printf 'NodeBox 设置\n\n'
        printf '脚本版本：%s\n' "$NODEBOX_VERSION"
        printf '核心下载源：Mihomo 官方 Release：%s\n' "$NODEBOX_MIHOMO_RELEASES_URL"
        printf '默认端口起点：%s\n' "$NODEBOX_DEFAULT_PORT"
        printf '核心自动保留：新版本验证成功后删除旧核心\n'
        printf '节点保存：同协议重新安装时替换旧节点\n'
        printf '\n1. 系统信息\n2. 查看日志\n0. 返回\n\n'
        local choice
        choice="$(menu_choice '请选择：' || true)"
        case "$choice" in
            1) show_system_info ;;
            2) less "${NODEBOX_LOG}/nodebox.log" 2>/dev/null || cat "${NODEBOX_LOG}/nodebox.log"; pause_back ;;
            0|q|Q|'') clear 2>/dev/null || true; return ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        show_banner
        ui_title '主控制台' 'Proxy Core & Node Manager'
        printf '
'
        printf '  核心状态\n'
        printf '  '; core_status sing-box
        printf '  '; core_status mihomo
        printf '
'
        ui_menu_item 1 'Sing-box 节点中心'
        ui_menu_item 2 'Mihomo 节点中心'
        ui_menu_item 3 '全部节点管理'
        ui_menu_item 4 '核心管理'
        ui_menu_item 5 '核心来源管理'
        ui_menu_item 6 '域名 / SSL'
        ui_menu_item 7 '端口管理'
        ui_menu_item 8 '核心运行状态'
        ui_menu_item 9 '日志查看'
        ui_menu_item 10 '系统 / NodeBox 设置'
        ui_menu_item 11 '完整卸载 NodeBox'
        ui_menu_item 0 '退出'
        printf '
'
        local choice
        choice="$(menu_choice '请输入选项：' || true)"
        case "$choice" in
            1) singbox_extra_menu ;;
            2) mihomo_menu ;;
            3)
                show_banner; ui_title '全部节点管理' '跨核心统一管理'
                printf '
'; ui_menu_item 1 'Sing-box 节点管理'; ui_menu_item 2 'Mihomo 节点管理'; ui_menu_item 3 '查看全部节点链接'; ui_menu_item 0 '返回'; printf '
'
                choice="$(menu_choice '请选择：' || true)"
                case "$choice" in 1) node_lifecycle_menu sing-box ;; 2) node_lifecycle_menu mihomo ;; 3) show_banner; print_core_nodes sing-box; print_core_nodes mihomo; pause_back ;; esac ;;
            4) core_menu ;;
            5) core_source_menu ;;
            6) show_banner; ui_title '域名 / SSL'; printf '  TLS 默认 SNI：%s\n' "$NODEBOX_DEFAULT_TLS_SNI"; printf '  证书：OpenSSL 自签名\n'; pause_back ;;
            7) port_menu ;;
            8) show_banner; ui_title '核心运行状态'; core_status sing-box; core_status mihomo; pause_back ;;
            9) show_banner; ui_title 'NodeBox 日志'; less "${NODEBOX_LOG}/nodebox.log" 2>/dev/null || cat "${NODEBOX_LOG}/nodebox.log"; pause_back ;;
            10) settings_menu ;;
            11) uninstall_nodebox_all ;;
            0|q|Q) clear 2>/dev/null || true; exit 0 ;;
            *) warn '无效选项。'; sleep 1 ;;
        esac
    done
}

prune_removed_singbox_protocols() {
    local protocol
    for protocol in vless trojan vmess shadowsocks naive; do
        if [[ -s "$(node_file "$protocol")" ]]; then
            warn "清理已移除的 Sing-box 协议：${protocol}"
            node_registry_remove "$protocol" || true
        fi
    done
}

bootstrap() {
    require_root
    initialize_dirs
    log_init
    acquire_lock
    normalize_arch >/dev/null 2>&1 || { err "不支持的 Linux 架构：$(uname -m)"; exit 1; }

    if [[ ! -f "$NODEBOX_INIT" ]]; then
        check_dependencies
    else
        # Lightweight verification on subsequent launches. No package installation
        # is performed unless a required dependency is actually missing.
        local cmd
        for cmd in curl tar gzip openssl systemctl ss sha256sum awk sed grep find readlink; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                warn "运行时依赖 ${cmd} 缺失。进入依赖修复流程。"
                check_dependencies
                break
            fi
        done
    fi

    persist_self
    install_box_command
    prune_removed_singbox_protocols
    write_watchdog
    install_watchdog_service
}

cli_self_test() {
    printf 'NodeBox 自检 %s\n' "$NODEBOX_VERSION"
    bash -n "${SELF_PATH:-$0}"
    ok 'Bash 语法检查通过。'
    normalize_arch >/dev/null 2>&1 && ok "架构识别：$(normalize_arch)" || warn "当前架构暂不在核心下载映射中。"
    local free
    free="$(find_free_port "$NODEBOX_DEFAULT_PORT" 2>/dev/null || true)"
    [[ -n "$free" ]] && ok "端口池可用，当前第一个可用端口：${free}" || warn '当前无法找到可用端口。'
    ok '自检完成。'
}

cli_service_action() {
    local action="$1" protocol="${2:-}" service
    [[ -n "$protocol" ]] || { err '请指定协议。'; return 1; }
    case "$protocol" in
        anytls|hysteria2|tuic) service="$(node_service_name "$protocol")" ;;
        mihomo-anytls|mihomo-hysteria2|mihomo-tuic|mihomo-vless|mihomo-trojan|mihomo-vmess|mihomo-shadowsocks|mihomo-mixed) service="$(node_service_name "$protocol")" ;;
        *) err "未知协议：${protocol}"; return 1 ;;
    esac
    case "$action" in
        start) systemctl start "$service" ;;
        stop) systemctl stop "$service" ;;
        restart) systemctl restart "$service" ;;
        logs) journalctl -u "$service" -n 100 --no-pager ;;
        *) err "未知操作：${action}"; return 1 ;;
    esac
}

cli_node_list() { initialize_dirs; list_nodes; }

if [[ "${1:-}" == '--version' ]]; then
    printf '%s %s\n' "$NODEBOX_NAME" "$NODEBOX_VERSION"
    exit 0
fi
if [[ "${1:-}" == '--help' ]]; then
    cat <<HELP
NodeBox ${NODEBOX_VERSION}

用法：
  bash nodebox.sh          进入交互菜单
  box                      全局快捷启动
  box --status             查看核心和节点状态
  box --nodes              列出已保存节点
  box --start <协议>       启动节点服务
  box --stop <协议>        停止节点服务
  box --restart <协议>     重启节点服务
  box --logs <协议>        查看节点日志
  box --self-test          执行本地自检
  box --version            查看版本

说明：正常启动不查询 GitHub；首次选择核心来源或用户主动重新评估时，才按 Stars + 更新时间筛选仓库。
HELP
    exit 0
fi
if [[ "${1:-}" == '--status' ]]; then
    require_root
    initialize_dirs
    core_status sing-box
    core_status mihomo
    list_nodes 2>/dev/null || true
    exit 0
fi
if [[ "${1:-}" == '--nodes' ]]; then
    require_root
    initialize_dirs
    list_nodes
    exit 0
fi
if [[ "${1:-}" == '--start' || "${1:-}" == '--stop' || "${1:-}" == '--restart' || "${1:-}" == '--logs' ]]; then
    require_root
    initialize_dirs
    case "$1" in
        --start) cli_service_action start "${2:-}" ;;
        --stop) cli_service_action stop "${2:-}" ;;
        --restart) cli_service_action restart "${2:-}" ;;
        --logs) cli_service_action logs "${2:-}" ;;
    esac
    exit $?
fi
if [[ "${1:-}" == '--self-test' ]]; then
    require_root
    initialize_dirs
    cli_self_test
    exit 0
fi

bootstrap
main_menu

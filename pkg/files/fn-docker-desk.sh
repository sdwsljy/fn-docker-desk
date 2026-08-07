#!/usr/bin/env bash
# ============================================================
# fn-docker-desk.sh
# 飞牛 OS (fnOS) Docker 桌面图标工具
# ------------------------------------------------------------
# 功能：自动发现飞牛 NAS 上的 Docker 容器，解析端口映射，
#       自动匹配图标，把容器应用一键添加到飞牛 Web 桌面。
#
# 原理：基于社区验证成熟的前端注入方案（cqfnsh/fn-icon 同源思路）
#       - 向 /usr/trim/www/index.html 注入 JS 脚本（幂等）
#       - JS 在桌面渲染后动态向图标容器追加 <a> 图标
#       - systemd 服务保证重启后自动重放
#
# 用法：
#   ./fn-docker-desk.sh list                 # 列出容器及推断的访问地址
#   ./fn-docker-desk.sh add <容器名>          # 添加容器到桌面（自动解析URL/图标）
#   ./fn-docker-desk.sh add <容器名> --name 标题 --port 端口 --icon 图标URL
#   ./fn-docker-desk.sh add-custom --title 标题 --url 链接 [--icon 图标URL]
#   ./fn-docker-desk.sh remove <序号|标题>    # 移除桌面图标
#   ./fn-docker-desk.sh ls                    # 查看当前桌面自定义图标
#   ./fn-docker-desk.sh backups               # 查看系统文件备份列表
#   ./fn-docker-desk.sh apply                 # 应用配置到桌面（注入+持久化）
#   ./fn-docker-desk.sh status                # 查看工具状态
#   ./fn-docker-desk.sh restore               # 一键还原原始飞牛桌面
# ============================================================
set -euo pipefail

# ---------------- 路径与常量 ----------------
readonly APP_VERSION="1.0.8"                     # 应用版本（与 manifest 保持一致）
readonly FN_WWW="/usr/trim/www"                 # 飞牛 Web 根目录
readonly INDEX_HTML="${FN_WWW}/index.html"
readonly CONF_DIR="/usr/fn-docker-desk"          # 工具配置目录（root 专属，不受 www 重建影响）
readonly CONF_JSON="${CONF_DIR}/icons.json"      # 主配置（增删改查）
readonly IMAGE_DIR="${CONF_DIR}/icons"           # 图标图片（不再放 www/userimg，避免被重建清空）
readonly DEST_JSON="${CONF_DIR}/desktop.json"    # 桌面可读配置（由 web.py 静态/API 提供）
readonly LEGACY_JSON="${FN_WWW}/userimg/fn-docker-desk.json"  # 旧路径兼容发布
readonly BACKUP_DIR="${CONF_DIR}/backup"         # index.html 备份
readonly LOG_FILE="/var/log/fn-docker-desk.log"  # 操作日志（排障用）
readonly APPDATA_DIR="${TRIM_APPDEST_VOL:-/usr/local/apps/@appdata}/fn-docker-desk"  # 持久卷备份（升级/卸载保留）
readonly RESTORED_FLAG="${CONF_DIR}/.restored"    # 还原态标记：一键还原后阻止自动注入/生成图标
readonly INJECT_JS_FILE="${CONF_DIR}/desktop-inject.js"  # 桌面注入 JS（独立文件，便于维护）
readonly MARKER_START="<!-- fn-docker-desk:start -->"
readonly MARKER_END="<!-- fn-docker-desk:end -->"
readonly SERVICE_NAME="fn-docker-desk.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly RESTORE_SCRIPT="/usr/local/bin/fn-docker-desk-restore.sh"
readonly APP_USER="${TRIM_USERNAME:-fn-docker-desk}"  # 专用包用户（privilege 配置中定义）

# 内置常见应用的图标 URL 映射（键为镜像名关键字，值为图标 URL）
declare -A ICON_MAP=(
  [jellyfin]="https://raw.githubusercontent.com/jellyfin/jellyfin-ux/master/branding/SVG/jellyfin.svg"
  [emby]="https://raw.githubusercontent.com/MediaBrowser/Emby/master/MediaBrowser.Server/Emby.Web/Images/app/favicon.ico"
  [plex]="https://raw.githubusercontent.com/plexinc/pms-docker/master/.github/plex.png"
  [alist]="https://raw.githubusercontent.com/alist-org/alist-web/main/docs/logo.svg"
  [qbittorrent]="https://raw.githubusercontent.com/qbittorrent/qBittorrent/master/src/icons/qbittorrent.svg"
  [transmission]="https://raw.githubusercontent.com/transmission/transmission/main/extras/transmission.svg"
  [aria2]="https://raw.githubusercontent.com/aria2/aria2/master/doc/aria2.svg"
  [portainer]="https://raw.githubusercontent.com/portainer/portainer/develop/app/assets/images/portainer-grayscale.png"
  [nginx]="https://raw.githubusercontent.com/nginx/nginx/master/docs/logo_small.svg"
  [mysql]="https://raw.githubusercontent.com/docker-library/docs/master/mysql/logo.png"
  [mariadb]="https://raw.githubusercontent.com/docker-library/docs/master/mariadb/logo.png"
  [postgres]="https://raw.githubusercontent.com/docker-library/docs/master/postgres/logo.png"
  [redis]="https://raw.githubusercontent.com/docker-library/docs/master/redis/logo.png"
  [mongodb]="https://raw.githubusercontent.com/docker-library/docs/master/mongo/logo.png"
  [nextcloud]="https://raw.githubusercontent.com/nextcloud/trademark/main/logo/logo.svg"
  [homeassistant]="https://raw.githubusercontent.com/home-assistant/brands/master/core_integrations/homeassistant/icon.png"
  [n8n]="https://raw.githubusercontent.com/n8n-io/n8n/master/packages/editor-ui/public/favicon.svg"
  [gitea]="https://raw.githubusercontent.com/go-gitea/gitea/main/public/img/favicon.svg"
  [gitlab]="https://raw.githubusercontent.com/gitlabhq/gitlab/master/app/assets/images/gitlab_logo.svg"
  [grafana]="https://raw.githubusercontent.com/grafana/grafana/main/public/img/grafana_icon.svg"
  [prometheus]="https://raw.githubusercontent.com/prometheus/prometheus/main/documentation/images/prometheus-logo.svg"
  [uptime]="https://raw.githubusercontent.com/upptime/status-page/master/public/logo.svg"
  [vaultwarden]="https://raw.githubusercontent.com/dani-garcia/vaultwarden/main/resources/vaultwarden-icon.svg"
  [immich]="https://raw.githubusercontent.com/immich-app/immich/main/design/immich-logo.svg"
  [photoprism]="https://raw.githubusercontent.com/photoprism/photoprism/develop/assets/static/img/logo.svg"
  [syncthing]="https://raw.githubusercontent.com/syncthing/syncthing/main/assets/logo.svg"
  [frp]="https://raw.githubusercontent.com/fatedier/frp/master/doc/pic/frp-logo.png"
  [ddns]="https://raw.githubusercontent.com/jeessy2/ddns-go/master/web/static/img/logo.png"
  [watchtower]="https://raw.githubusercontent.com/containrrr/watchtower/master/logo.svg"
  [code-server]="https://raw.githubusercontent.com/coder/code-server/main/static/logo.svg"
  [jenkins]="https://raw.githubusercontent.com/jenkinsci/jenkins/master/core/src/main/resources/jenkins-256.png"
  [sonarr]="https://raw.githubusercontent.com/Sonarr/Sonarr/develop/Logo/Sonarr.png"
  [radarr]="https://raw.githubusercontent.com/Radarr/Radarr/develop/Logo/Radarr.png"
  [nastool]="https://raw.githubusercontent.com/NAStool/nas-tools/master/web/app/images/logo.svg"
)

# ---------------- 工具函数 ----------------
# 日志：终端输出 + 追加到 LOG_FILE（排障）
_log_file() {
    [ -n "${LOG_FILE:-}" ] || return 0
    printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}
log_info()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; _log_file "[INFO] $*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; _log_file "[WARN] $*"; }
log_err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; _log_file "[ERROR] $*"; }
die()       { log_err "$*"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限运行，请使用: sudo $0 $*"
}

require_env() {
    [ -d "${FN_WWW}" ] || die "未检测到飞牛 Web 目录 ${FN_WWW}，请在飞牛 OS 上运行本脚本"
    command -v docker >/dev/null 2>&1 || die "未检测到 docker 命令"
    command -v jq >/dev/null 2>&1 || die "缺少 jq，请先安装: apt install -y jq"
    command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装: apt install -y curl"
}

init_dirs() {
    mkdir -p "${CONF_DIR}" "${IMAGE_DIR}" "${BACKUP_DIR}"
    chmod -R 755 "${CONF_DIR}"
    [ -f "${CONF_JSON}" ] || echo '[]' > "${CONF_JSON}"
}

# 获取 NAS 局域网 IP
get_nas_ip() {
    local ip
    ip=$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -z "${ip}" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "${ip}" ] && ip="<NAS_IP>"
    echo "${ip}"
}

# 系统路径白名单校验，避免误写非预期系统文件（失败返回 1，不中断调用方）
require_exact_path() {
    local actual="$1" expected="$2"
    [ "${actual}" = "${expected}" ] || return 1
    return 0
}

require_under_path() {
    local actual="$1" base="$2"
    case "${actual}" in
        "${base}"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# 从 docker 端口映射字符串提取第一个宿主端口
parse_host_port() {
    local ports="$1"
    # 匹配形如 0.0.0.0:8080->80/tcp 或 8080->80/tcp 或 [::]:8080->80/tcp
    echo "${ports}" | grep -oE '[0-9]+->' | head -1 | sed 's/->//'
}

# 从镜像名推断应用关键字
image_keyword() {
    local image="$1"
    local kw
    kw=$(basename "${image%%:*}")
    echo "${kw}" | tr '[:upper:]' '[:lower:]'
}

# 匹配内置图标 URL
match_builtin_icon() {
    local kw="$1"
    for key in "${!ICON_MAP[@]}"; do
        if echo "${kw}" | grep -qi "${key}"; then
            echo "${ICON_MAP[$key]}"
            return 0
        fi
    done
    return 1
}

# 下载图标（自动尝试镜像源，返回相对路径）
# 快速失败策略：单个 URL 最多 8s，总耗时超 25s 立即降级，避免卡死添加流程
download_icon() {
    local url="$1" name="$2" ext="" local_path rel_path total_start now
    ext=$(echo "${url##*.}" | tr '[:upper:]' '[:lower:]' | cut -d'?' -f1)
    [[ "${ext}" =~ ^(jpg|jpeg|png|gif|bmp|webp|svg|ico)$ ]] || ext="png"
    local_path="${IMAGE_DIR}/${name}.${ext}"
    rel_path="icons/${name}.${ext}"

    # 镜像列表：原地址 > ghproxy 加速 > jsdelivr
    local urls=("${url}")
    if echo "${url}" | grep -q '^https://raw.githubusercontent.com/'; then
        local rest="${url#https://raw.githubusercontent.com/}"
        urls+=("https://ghproxy.net/${url}")
        urls+=("https://cdn.jsdelivr.net/gh/${rest}")
        urls+=("https://raw.gitmirror.com/${rest}")
    fi
    total_start=$(date +%s)
    local u
    for u in "${urls[@]}"; do
        if curl -fsSL --connect-timeout 4 -m 8 -o "${local_path}" "${u}" 2>/dev/null \
           && [ -s "${local_path}" ]; then
            log_info "图标下载成功: ${u}"
            echo "${rel_path}"
            return 0
        fi
        now=$(date +%s)
        if [ $((now - total_start)) -ge 25 ]; then
            log_warn "图标下载超过 25s，放弃并降级占位图标: ${url}"
            break
        fi
    done
    rm -f "${local_path}"
    return 1
}

# 提取容器自带图标（优先从容器文件系统直接提取，再 HTTP 抓取 favicon）
grab_container_favicon() {
    local name="$1" host_port="$2" file ext
    file="${IMAGE_DIR}/${name}.ico"
    # 1. 直接从容器内文件系统提取常见图标路径（最可靠，无需 HTTP）
    local cpaths=(
        "/usr/share/nginx/html/favicon.ico" "/usr/share/nginx/html/favicon.png"
        "/app/favicon.ico" "/app/favicon.png" "/app/public/favicon.ico"
        "/app/static/favicon.ico" "/app/assets/favicon.ico"
        "/usr/share/nginx/html/static/favicon.ico" "/usr/share/nginx/html/assets/favicon.ico"
        "/opt/favicon.ico" "/home/app/favicon.ico" "/data/favicon.ico"
    )
    local cp
    for cp in "${cpaths[@]}"; do
        if docker cp "${name}:${cp}" "${file}" 2>/dev/null && [ -s "${file}" ]; then
            ext=$(echo "${cp##*.}" | tr '[:upper:]' '[:lower:]')
            [ "${ext}" = "ico" ] || [ "${ext}" = "png" ] || ext="png"
            mv "${file}" "${IMAGE_DIR}/${name}.${ext}"
            echo "icons/${name}.${ext}"
            return 0
        fi
    done
    # 2. HTTP 抓取 favicon（更多常见路径）
    [ -z "${host_port}" ] && return 1
    local paths=("favicon.ico" "favicon.png" "static/favicon.ico" "assets/favicon.ico" "public/favicon.ico" "images/favicon.ico")
    local p
    for p in "${paths[@]}"; do
        if curl -fsSL --connect-timeout 5 -m 10 -o "${file}" "http://127.0.0.1:${host_port}/${p}" 2>/dev/null \
           && [ -s "${file}" ]; then
            echo "icons/${name}.ico"
            return 0
        fi
    done
    rm -f "${file}"
    return 1
}

# 生成首字母 SVG 占位图标（无需网络）
gen_fallback_icon() {
    local name="$1" letter
    letter=$(printf '%s' "${name}" | cut -c1 | tr '[:lower:]' '[:upper:]')
    [ -z "${letter}" ] && letter="D"
    local file="${IMAGE_DIR}/${name}.svg"
    cat > "${file}" <<SVGEOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0%" stop-color="#1677ff"/><stop offset="100%" stop-color="#13c2c2"/>
  </linearGradient></defs>
  <rect width="256" height="256" rx="48" fill="url(#g)"/>
  <text x="128" y="128" font-family="Arial, sans-serif" font-size="120" font-weight="bold"
        fill="#ffffff" text-anchor="middle" dominant-baseline="central">${letter}</text>
</svg>
SVGEOF
    echo "icons/${name}.svg"
}

# 查找容器：支持名称或 ID 前缀
resolve_container() {
    local query="$1" found
    found=$(docker ps --format '{{.Names}}' | grep -x "${query}" || true)
    if [ -z "${found}" ]; then
        found=$(docker ps --format '{{.Names}}' | grep "^${query}" | head -1 || true)
    fi
    [ -z "${found}" ] && die "未找到运行中的容器: ${query}（用 list 命令查看）"
    echo "${found}"
}

# ---------------- JSON 配置操作 ----------------
next_seq() {
    jq -r '[.[]."序号"] | if length == 0 then 1 else (max + 1) end' "${CONF_JSON}"
}

icon_exists() {
    local title="$1"
    jq -e --arg t "$title" 'any(.[]; ."标题" == $t)' "${CONF_JSON}" >/dev/null 2>&1
}

add_icon() {
    local title="$1" url="$2" image_rel="$3" container="$4" type="${5:-docker}" seq
    seq=$(next_seq)
    jq --arg seq "$seq" --arg title "$title" --arg url "$url" --arg img "$image_rel" --arg c "$container" --arg t "$type" \
       '. + [{"序号": ($seq|tonumber), "标题": $title, "跳转URL": $url, "图片URL": $img, "容器名": $c, "类型": $t}]' \
       "${CONF_JSON}" > "${CONF_JSON}.tmp" && mv "${CONF_JSON}.tmp" "${CONF_JSON}"
    echo "${seq}"
}

remove_icon() {
    local key="$1"
    local count
    count=$(jq -e --arg k "$key" '.[] | select((.["序号"]|tostring) == $k or ."标题" == $k)' "${CONF_JSON}" | wc -l || true)
    if [ "${count}" -eq 0 ]; then
        die "未找到匹配的图标（序号或标题）: ${key}"
    fi
    jq --arg k "$key" 'del(.[] | select((.["序号"]|tostring) == $k or ."标题" == $k))' \
       "${CONF_JSON}" > "${CONF_JSON}.tmp" && mv "${CONF_JSON}.tmp" "${CONF_JSON}"
    log_info "已移除: ${key}"
}

# ---------------- 桌面注入 ----------------
# 注入 fnOS 桌面：patch /usr/trim/share/.restore/www.zip 源包 + 当前运行目录
# 失败不中断调用方（返回 1），由调用方决定是否告警
apply_inject() {
    if [ ! -f "${INDEX_HTML}" ]; then
        log_warn "未找到 ${INDEX_HTML}，跳过注入"
        return 1
    fi
    local restore_zip="/usr/trim/share/.restore/www.zip"
    if ! require_exact_path "${restore_zip}" "/usr/trim/share/.restore/www.zip"; then
        log_warn "路径安全校验失败: ${restore_zip}"
        return 1
    fi
    if [ ! -f "${restore_zip}" ]; then
        log_warn "未找到 ${restore_zip}，跳过源包注入（桌面图标可能无法持久化）"
        return 1
    fi
    if ! command -v zip >/dev/null 2>&1; then
        log_warn "缺少 zip 命令，无法 patch fnOS Web 源包"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "缺少 python3，无法注入桌面脚本"
        return 1
    fi

    local tmproot asset
    tmproot="$(mktemp -d /tmp/fn-docker-desk.XXXXXX)"
    trap 'rm -rf "${tmproot:-}" 2>/dev/null || true' RETURN

    asset=$(python3 - "${INDEX_HTML}" <<'PYEOF'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text('utf-8', errors='replace')
m = re.search(r'src="(/assets/index-[^"?]+\.js)(?:\?[^"]*)?"', s)
print(m.group(1).lstrip('/') if m else '')
PYEOF
)
    if [ -z "${asset}" ]; then
        log_warn "未找到 fnOS 主前端 JS（index.html 结构可能变化），跳过注入"
        return 1
    fi
    if ! require_under_path "${FN_WWW}/${asset}" "${FN_WWW}/assets"; then
        log_warn "路径安全校验失败: ${FN_WWW}/${asset}"
        return 1
    fi

    mkdir -p "${tmproot}/$(dirname "${asset}")"
    cp "${INDEX_HTML}" "${tmproot}/index.html"
    cp "${FN_WWW}/${asset}" "${tmproot}/${asset}"

    # 读取注入 JS（优先独立文件，回退脚本同目录）
    local inject_src=""
    if [ -f "${INJECT_JS_FILE}" ]; then
        inject_src="${INJECT_JS_FILE}"
    elif [ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/desktop-inject.js" ]; then
        inject_src="$(dirname "${BASH_SOURCE[0]:-$0}")/desktop-inject.js"
    else
        log_warn "未找到注入 JS 文件: ${INJECT_JS_FILE}，跳过注入"
        return 1
    fi
    if ! python3 - "${tmproot}/index.html" "${tmproot}/${asset}" "${inject_src}" "${APP_VERSION}" <<'PYEOF'
import pathlib, re, sys
index = pathlib.Path(sys.argv[1])
asset = pathlib.Path(sys.argv[2])
inject_file = pathlib.Path(sys.argv[3])
app_version = sys.argv[4]
idx = index.read_text('utf-8', errors='replace')
idx = re.sub(r'src="(/assets/index-[^"?]+\.js)(?:\?[^"]*)?"',
             r'src="\1?v=fndesk14"', idx, count=1)
index.write_text(idx, 'utf-8')

js = asset.read_text('utf-8', errors='replace')
js = re.split(r';/\* fn-docker-desk asset injection v[01]\.[0-9.]+ \*/', js)[0].rstrip()
inject = inject_file.read_text('utf-8', errors='replace')
inject = inject.replace('__VERSION__', app_version)
asset.write_text(js + "\n" + inject + "\n", 'utf-8')
PYEOF
    then
        log_warn "前端 JS 注入脚本执行失败，跳过注入"
        return 1
    fi

    if [ ! -f "${BACKUP_DIR}/index.html.runtime.orig" ]; then
        cp -f "${INDEX_HTML}" "${BACKUP_DIR}/index.html.runtime.orig" 2>/dev/null || true
        log_info "已备份当前运行 index.html: ${BACKUP_DIR}/index.html.runtime.orig"
    fi
    if [ ! -f "${BACKUP_DIR}/$(basename "${asset}").runtime.orig" ]; then
        cp -f "${FN_WWW}/${asset}" "${BACKUP_DIR}/$(basename "${asset}").runtime.orig" 2>/dev/null || true
        log_info "已备份当前运行 JS: ${BACKUP_DIR}/$(basename "${asset}").runtime.orig"
    fi
    if ! cp -f "${tmproot}/index.html" "${INDEX_HTML}" 2>/dev/null; then
        log_warn "写入当前运行 index.html 失败: ${INDEX_HTML}"
        return 1
    fi
    if ! cp -f "${tmproot}/${asset}" "${FN_WWW}/${asset}" 2>/dev/null; then
        log_warn "写入当前运行 JS 失败: ${FN_WWW}/${asset}"
        return 1
    fi
    chmod 644 "${INDEX_HTML}" "${FN_WWW}/${asset}" 2>/dev/null || true
    log_info "已 patch 当前运行目录 /usr/trim/www，刷新后立即生效"

    if [ ! -f "${restore_zip}.fndesk.orig" ]; then
        cp -f "${restore_zip}" "${restore_zip}.fndesk.orig"
        log_info "已备份 fnOS Web 源包: ${restore_zip}.fndesk.orig"
    fi
    cp -f "${restore_zip}" "${restore_zip}.fndesk.bak.$(date +%Y%m%d%H%M%S)"
    if ! (cd "${tmproot}" && zip -q -u "${restore_zip}" index.html "${asset}") 2>/dev/null; then
        log_warn "更新 fnOS Web 源包失败（当前运行目录已生效，但系统重启后图标可能丢失）"
        return 1
    fi

    systemctl restart trim_nginx.service >/dev/null 2>&1 || true
    log_info "已 patch fnOS Web 源包并重启 trim_nginx"
}

# 生成桌面可读的 JSON（主数据在 /usr/fn-docker-desk，兼容旧 userimg 路径）
publish_json() {
    # 备份当前发布文件（首次发布时备份原始 index.html 之外的配置）
    if [ -f "${DEST_JSON}" ] && [ ! -f "${BACKUP_DIR}/fn-docker-desk.json.bak" ]; then
        cp "${DEST_JSON}" "${BACKUP_DIR}/fn-docker-desk.json.bak"
        log_info "已备份发布配置: ${BACKUP_DIR}/fn-docker-desk.json.bak"
    fi
    if [ -f "${CONF_JSON}" ] && [ ! -f "${BACKUP_DIR}/icons.json.bak" ]; then
        cp "${CONF_JSON}" "${BACKUP_DIR}/icons.json.bak"
        log_info "已备份主配置: ${BACKUP_DIR}/icons.json.bak"
    fi
    if ! cp -f "${CONF_JSON}" "${DEST_JSON}" 2>/dev/null; then
        log_err "发布桌面配置失败: ${DEST_JSON}"
        return 1
    fi
    chmod 644 "${DEST_JSON}"
    # 兼容旧版注入：userimg 目录存在则顺带发布一份
    if [ -d "${FN_WWW}/userimg" ]; then
        cp -f "${CONF_JSON}" "${LEGACY_JSON}" 2>/dev/null || true
    fi
    # 图标目录权限
    chmod -R 755 "${IMAGE_DIR}"
    log_info "配置已发布: ${DEST_JSON}"
}

# ---------------- 持久化 ----------------
install_persistence() {
    # 还原脚本：开机时重放注入，并确保 Web 管理服务运行
    cat > "${RESTORE_SCRIPT}" <<EOF
#!/usr/bin/env bash
# fn-docker-desk 开机重放（由 systemd 调用）
set -euo pipefail
if [ -f "${CONF_DIR}/fn-docker-desk.sh" ]; then
    bash "${CONF_DIR}/fn-docker-desk.sh" apply --quiet || true
fi
# 确保 Web 管理服务运行（以 root 运行，需调用主脚本 + 访问 docker）
if [ -f "${CONF_DIR}/web.py" ] && ! pgrep -f "web.py --port ${SVC_PORT:-5558}" >/dev/null 2>&1; then
    touch /var/log/fn-docker-desk-web.log 2>/dev/null || true
    chmod 644 /var/log/fn-docker-desk-web.log 2>/dev/null || true
    setsid nohup python3 -u "${CONF_DIR}/web.py" --port ${SVC_PORT:-5558} >>/var/log/fn-docker-desk-web.log 2>&1 < /dev/null &
fi
EOF
    chmod +x "${RESTORE_SCRIPT}"

    # 把主脚本复制到配置目录（保证还原脚本能找到）
    if [ -f "${BASH_SOURCE[0]:-$0}" ]; then
        cp -f "${BASH_SOURCE[0]:-$0}" "${CONF_DIR}/fn-docker-desk.sh"
        chmod +x "${CONF_DIR}/fn-docker-desk.sh"
    fi
    # 同步最新 web.py 到配置目录
    if [ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/web.py" ]; then
        cp -f "$(dirname "${BASH_SOURCE[0]:-$0}")/web.py" "${CONF_DIR}/web.py" 2>/dev/null || true
    fi
    # 同步注入 JS 到配置目录
    if [ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/desktop-inject.js" ]; then
        cp -f "$(dirname "${BASH_SOURCE[0]:-$0}")/desktop-inject.js" "${INJECT_JS_FILE}" 2>/dev/null || true
    fi

    # systemd 服务
    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=fn-docker-desk desktop icon persistence
After=network.target

[Service]
Type=oneshot
ExecStart=${RESTORE_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    log_info "已安装开机自启服务 ${SERVICE_NAME}"
}

uninstall_persistence() {
    # 参数 --keep-web：仅用于一键还原，保留 Web 管理面板（pkill 会误杀调用方的 web.py）
    local keep_web=0
    if [ "${1:-}" = "--keep-web" ]; then
        keep_web=1
    fi
    systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SERVICE_FILE}"
    rm -f "${RESTORE_SCRIPT}"
    if [ "${keep_web}" -eq 0 ]; then
        pkill -f "web.py --port ${SVC_PORT:-5558}" 2>/dev/null || true
    fi
    systemctl daemon-reload
    log_info "已移除自启服务"
}

# ---------------- 功能命令 ----------------
cmd_list() {
    local nas_ip
    nas_ip=$(get_nas_ip)
    log_info "NAS IP: ${nas_ip}"
    printf '%-28s %-28s %-14s %s\n' "容器名" "镜像" "宿主端口" "推断访问地址"
    printf '%s\n' "--------------------------------------------------------------------------------------------------"
    docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}' | while IFS=$'\t' read -r name image ports; do
        local port kw
        port=$(parse_host_port "${ports}")
        if [ -n "${port}" ]; then
            printf '%-28s %-28s %-14s http://%s:%s/\n' "${name}" "${image}" "${port}" "${nas_ip}" "${port}"
        else
            printf '%-28s %-28s %-14s %s\n' "${name}" "${image}" "-" "(无端口映射或非Web服务)"
        fi
    done
}

cmd_add() {
    require_root
    require_env
    init_dirs
    # 用户主动添加图标 = 重新启用（清除还原态标记）
    rm -f "${RESTORED_FLAG}"
    local container="$1" url="" icon="" title="" custom_port=""
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --url)   url="${2:-}"; shift 2 ;;
            --icon)  icon="${2:-}"; shift 2 ;;
            --title) title="${2:-}"; shift 2 ;;
            --name)  title="${2:-}"; shift 2 ;;
            --port)  custom_port="${2:-}"; shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done
    local cname
    cname=$(resolve_container "${container}")
    local image ports nas_ip
    image=$(docker inspect -f '{{.Config.Image}}' "${cname}")
    ports=$(docker inspect -f '{{range $p, $conf := .NetworkSettings.Ports}}{{$p}} {{end}}' "${cname}")
    nas_ip=$(get_nas_ip)
    [ -z "${title}" ] && title="${cname}"

    # 解析 URL（优先使用用户指定的 --port）
    if [ -z "${url}" ]; then
        local host_port=""
        if [ -n "${custom_port}" ]; then
            # 校验端口格式
            [[ "${custom_port}" =~ ^[0-9]+$ ]] || die "端口号格式无效: ${custom_port}"
            host_port="${custom_port}"
        else
            # 自动解析：优先用 docker port（输出如: 8080/tcp -> 0.0.0.0:8080）
            host_port=$(docker port "${cname}" 2>/dev/null | head -1 | sed -n 's/.*->.*:\([0-9]*\)$/\1/p')
            # 兜底：解析 docker ps Ports 字段
            if [ -z "${host_port}" ]; then
                host_port=$(parse_host_port "$(docker ps --filter "name=${cname}" --format '{{.Ports}}')")
            fi
        fi
        if [ -n "${host_port}" ]; then
            url="http://${nas_ip}:${host_port}/"
        else
            die "无法自动解析容器端口，请用 --port 或 --url 手动指定"
        fi
    fi

    # 解析图标（优先级：--icon > 容器 label > 容器自身 favicon > 内置映射 > 占位图）
    local image_rel="" host_port="${host_port:-}"
    if [ -n "${icon}" ]; then
        image_rel=$(download_icon "${icon}" "${cname}") || true
    fi
    if [ -z "${image_rel}" ]; then
        local lbl
        lbl=$(docker inspect -f '{{index .Config.Labels "fn.docker.desk.icon"}}' "${cname}" 2>/dev/null || true)
        [ -z "${lbl}" ] && lbl=$(docker inspect -f '{{index .Config.Labels "fn.icon"}}' "${cname}" 2>/dev/null || true)
        if [ -n "${lbl}" ]; then
            image_rel=$(download_icon "${lbl}" "${cname}") || true
        fi
    fi
    # 从容器自身 Web 服务抓取 favicon（本地直连，无需外网）
    if [ -z "${image_rel}" ] && [ -n "${host_port}" ]; then
        image_rel=$(grab_container_favicon "${cname}" "${host_port}") || true
        [ -n "${image_rel}" ] && log_info "已从容器抓取 favicon"
    fi
    # 内置常见应用图标映射
    if [ -z "${image_rel}" ]; then
        local kw builtin
        kw=$(image_keyword "${image}")
        builtin=$(match_builtin_icon "${kw}" || true)
        if [ -n "${builtin}" ]; then
            image_rel=$(download_icon "${builtin}" "${cname}") || true
        fi
    fi
    if [ -z "${image_rel}" ]; then
        image_rel=$(gen_fallback_icon "${cname}")
        log_warn "未获取到图标，已生成占位图标（可用 --icon 指定）"
    fi

    if icon_exists "${title}"; then
        log_warn "标题「${title}」已存在，跳过（如需更换请先 remove）"
    else
        local seq
        seq=$(add_icon "${title}" "${url}" "${image_rel}" "${cname}")
        publish_json
        log_info "已添加: 序号=${seq} 标题=${title} URL=${url}"
    fi
    # 注入失败不阻塞添加：图标配置已保存，稍后可点「应用配置」重试
    if ! apply_inject; then
        log_warn "注入未生效：图标配置已保存，请在管理面板点「应用配置」重试（日志: ${LOG_FILE}）"
    fi
    install_persistence || true
    # 同步备份到持久卷，保证升级/卸载后配置不丢
    backup_data_to_appdata
    log_info "完成！刷新浏览器（Ctrl+Shift+R）即可在桌面看到图标"
}

# 自定义图标：自己输入标题与链接（可选图标 URL）添加到桌面，无需 Docker 容器
cmd_add_custom() {
    require_root
    require_env
    init_dirs
    # 用户主动添加自定义图标 = 重新启用（清除还原态标记）
    rm -f "${RESTORED_FLAG}"
    local title="" url="" icon="" safe
    while [ $# -gt 0 ]; do
        case "$1" in
            --title) title="${2:-}"; shift 2 ;;
            --url)   url="${2:-}";   shift 2 ;;
            --icon)  icon="${2:-}";  shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done
    [ -n "${title}" ] || die "缺少标题，请用 --title 指定"
    [ -n "${url}" ] || die "缺少链接，请用 --url 指定"
    # 只允许 http/https，防止 javascript: 等危险协议
    [[ "${url}" =~ ^https?:// ]] || die "链接必须以 http:// 或 https:// 开头: ${url}"

    # 图标文件名使用安全名（标题清洗），避免路径问题
    safe=$(echo "${title}" | tr -c 'a-zA-Z0-9_-' '_' | cut -c1-60)
    [ -n "${safe}" ] || safe="custom"

    local image_rel=""
    if [ -n "${icon}" ]; then
        image_rel=$(download_icon "${icon}" "${safe}") || true
    fi
    if [ -z "${image_rel}" ]; then
        image_rel=$(gen_fallback_icon "${safe}")
        log_warn "未指定图标或下载失败，已生成占位图标（可用 --icon 指定）"
    fi

    if icon_exists "${title}"; then
        log_warn "标题「${title}」已存在，跳过（如需更换请先 remove）"
    else
        local seq
        seq=$(add_icon "${title}" "${url}" "${image_rel}" "" "custom")
        publish_json
        log_info "已添加自定义图标: 序号=${seq} 标题=${title} URL=${url}"
    fi
    # 注入失败不阻塞添加：图标配置已保存，稍后可点「应用配置」重试
    if ! apply_inject; then
        log_warn "注入未生效：图标配置已保存，请在管理面板点「应用配置」重试（日志: ${LOG_FILE}）"
    fi
    install_persistence || true
    # 同步备份到持久卷，保证升级/卸载后配置不丢
    backup_data_to_appdata
    log_info "完成！刷新浏览器（Ctrl+Shift+R）即可在桌面看到图标"
}

cmd_remove() {
    require_root
    require_env
    init_dirs
    # 用户主动移除图标 = 重新启用（清除还原态标记）
    rm -f "${RESTORED_FLAG}"
    remove_icon "$1"
    publish_json
    # 同步备份到持久卷，保证升级/卸载后配置不丢
    backup_data_to_appdata
    log_info "已从桌面移除（浏览器刷新后生效）"
}

cmd_ls() {
    require_env
    init_dirs
    local count
    count=$(jq 'length' "${CONF_JSON}")
    if [ "${count}" -eq 0 ]; then
        log_info "当前没有自定义图标"
        return 0
    fi
    log_info "当前桌面自定义图标（共 ${count} 个）:"
    jq -r 'sort_by(.["序号"])[] | "  [\(.["序号"])] \(.["标题"])  \(.["跳转URL"])  \(.["容器名"] // "-")"' "${CONF_JSON}"
}

cmd_apply() {
    require_root
    require_env
    init_dirs
    # 还原态锁定：一键还原后，应用启动/开机自启触发的 apply 不注入、不生成图标，
    # 直到用户主动添加/移除图标（add/remove/add-custom 会清除标记）重新启用
    if [ -f "${RESTORED_FLAG}" ]; then
        log_warn "已处于还原态：跳过注入与图标生成（如需重新启用，请在管理面板添加图标）"
        return 0
    fi
    # 升级/重装后自愈：配置被清空时从持久卷恢复（保证图标数据不丢）
    restore_data_from_appdata
    if [ "${1:-}" != "--quiet" ]; then
        log_info "应用配置到桌面..."
    fi
    # 管理面板自身图标由 fnOS 应用中心（desktop_applaunchname）管理，不再写入 icons.json
    # （icons.json 仅存用户自定义/容器图标；一键还原清空 icons.json 不影响应用自身图标）
    publish_json
    if ! apply_inject; then
        log_err "注入失败，请查看日志: ${LOG_FILE}"
        return 1
    fi
    install_persistence || true
    # 同步备份到持久卷，保证升级/卸载后配置不丢
    backup_data_to_appdata
    [ "${1:-}" != "--quiet" ] && log_info "完成！刷新浏览器生效"
}

cmd_status() {
    log_info "飞牛 Web 目录: ${FN_WWW} ($([ -d "${FN_WWW}" ] && echo OK || echo MISSING))"
    log_info "注入状态: $(grep -q 'fndesk' "${INDEX_HTML}" 2>/dev/null && echo 已注入 || echo 未注入)"
    log_info "自启服务: $(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || echo 未安装)"
    log_info "自定义图标数: $(jq 'length' "${CONF_JSON}" 2>/dev/null || echo 0)"
    log_info "NAS IP: $(get_nas_ip)"
    docker ps --format '运行中容器: {{.Names}}' 2>/dev/null | sed 's/^/  /' || true
}

cmd_backups() {
    require_env
    if [ ! -d "${BACKUP_DIR}" ]; then
        log_info "暂无备份目录"
        return 0
    fi
    local files
    files=$(ls -1t "${BACKUP_DIR}" 2>/dev/null || true)
    if [ -z "${files}" ]; then
        log_info "暂无备份文件"
        return 0
    fi
    log_info "备份文件（${BACKUP_DIR}）:"
    echo "${files}" | while read -r f; do
        [ -n "${f}" ] && printf '  %s  (%s bytes)\n' "${f}" "$(stat -c%s "${BACKUP_DIR}/${f}" 2>/dev/null || echo 0)"
    done
}

# 精准反注入 fnOS Web 源包：只删除本工具写入的 JS 片段与缓存参数，不回滚其他系统变更
precise_restore_web_zip() {
    local restore_zip="$1"
    [ -f "${restore_zip}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    command -v zip >/dev/null 2>&1 || return 1

    python3 - "${restore_zip}" <<'PYEOF'
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

zip_path = pathlib.Path(sys.argv[1])
tmp = pathlib.Path(tempfile.mkdtemp(prefix="fn-docker-desk-restore."))
changed = []
try:
    with zipfile.ZipFile(zip_path, "r") as z:
        names = set(z.namelist())
        if "index.html" not in names:
            print("index.html not found in www.zip", file=sys.stderr)
            sys.exit(1)

        index = z.read("index.html").decode("utf-8", "replace")
        m = re.search(r'src="(/assets/index-[^"?]+\.js)(?:\?[^"]*)?"', index)
        if not m:
            print("main asset not found in index.html", file=sys.stderr)
            sys.exit(1)

        asset_name = m.group(1).lstrip("/")
        if asset_name not in names:
            print("main asset not found in www.zip: %s" % asset_name, file=sys.stderr)
            sys.exit(1)

        new_index = re.sub(
            r'src="(/assets/index-[^"?]+\.js)\?v=fndesk[0-9]+"',
            r'src="\1"',
            index,
            count=1,
        )
        if new_index != index:
            (tmp / "index.html").write_text(new_index, "utf-8")
            changed.append("index.html")

        js = z.read(asset_name).decode("utf-8", "replace")
        parts = re.split(r';/\* fn-docker-desk asset injection v[01]\.[0-9.]+ \*/', js, maxsplit=1)
        if len(parts) > 1:
            new_js = parts[0].rstrip() + "\n"
            out = tmp / asset_name
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(new_js, "utf-8")
            changed.append(asset_name)

    if not changed:
        print("no fn-docker-desk injection found")
        sys.exit(0)

    bak = zip_path.with_name(zip_path.name + ".fndesk.restore.bak")
    shutil.copy2(zip_path, bak)
    subprocess.run(["zip", "-q", "-u", str(zip_path), *changed], cwd=str(tmp), check=True)
    print("precise restore updated: " + ", ".join(changed))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PYEOF
}

precise_restore_runtime_web() {
    [ -f "${INDEX_HTML}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "${INDEX_HTML}" <<'PYEOF'
import pathlib
import re
import sys

index = pathlib.Path(sys.argv[1])
idx = index.read_text("utf-8", errors="replace")
m = re.search(r'src="(/assets/index-[^"?]+\.js)(?:\?[^"]*)?"', idx)
if not m:
    print("main asset not found in runtime index.html", file=sys.stderr)
    sys.exit(1)
asset = pathlib.Path("/usr/trim/www") / m.group(1).lstrip("/")
new_idx = re.sub(r'src="(/assets/index-[^"?]+\.js)\?v=fndesk[0-9]+"', r'src="\1"', idx, count=1)
if new_idx != idx:
    index.write_text(new_idx, "utf-8")
changed = new_idx != idx
if asset.exists():
    js = asset.read_text("utf-8", errors="replace")
    parts = re.split(r';/\* fn-docker-desk asset injection v[01]\.[0-9.]+ \*/', js, maxsplit=1)
    if len(parts) > 1:
        asset.write_text(parts[0].rstrip() + "\n", "utf-8")
        changed = True
print("runtime precise restore " + ("updated" if changed else "no injection found"))
PYEOF
}

# 仅从备份 zip 恢复本工具改动的文件（index.html 与主 JS），不整体覆盖 www.zip，
# 避免把 fnOS 应用商城后续安装的应用图标一并还原掉
restore_our_files_from_zip() {
    local dst="$1" src="$2"
    [ -f "${dst}" ] && [ -f "${src}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    command -v zip >/dev/null 2>&1 || return 1
    python3 - "${dst}" "${src}" <<'PYEOF'
import pathlib
import re
import subprocess
import sys
import tempfile
import zipfile

dst, src = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    names = set(z.namelist())
    if "index.html" not in names:
        print("backup zip has no index.html", file=sys.stderr)
        sys.exit(1)
    index = z.read("index.html").decode("utf-8", "replace")
    m = re.search(r'src="(/assets/index-[^"?]+\.js)(?:\?[^"]*)?"', index)
    if not m or m.group(1).lstrip("/") not in names:
        print("backup zip main asset not found", file=sys.stderr)
        sys.exit(1)
    asset = m.group(1).lstrip("/")
tmp = tempfile.mkdtemp(prefix="fn-docker-desk-restore.")
try:
    with zipfile.ZipFile(src) as z:
        for name in ("index.html", asset):
            p = pathlib.Path(tmp) / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(z.read(name))
    subprocess.run(["zip", "-q", "-u", dst, "index.html", asset], cwd=tmp, check=True)
    print("restored our files: index.html + " + asset)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PYEOF
}

cmd_restore() {
    require_root
    log_warn "开始还原到原始飞牛桌面..."

    # 1. 兼容 v0.2 旧方案：如果运行目录 index.html 里仍有标记，先删除标记块
    if [ -f "${INDEX_HTML}" ] && grep -q "${MARKER_START}" "${INDEX_HTML}"; then
        if command -v python3 >/dev/null 2>&1; then
            python3 - "${INDEX_HTML}" <<'PYEOF'
import sys
path = sys.argv[1]
ms = '<!-- fn-docker-desk:start -->'
me = '<!-- fn-docker-desk:end -->'
with open(path, encoding='utf-8') as f:
    content = f.read()
s = content.find(ms); e = content.find(me)
if s != -1 and e != -1 and e > s:
    content = content[:s] + content[e + len(me):]
with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print('legacy injection removed')
PYEOF
            log_info "已移除旧版 index.html 注入脚本"
        else
            log_warn "缺少 python3，跳过旧版 index.html 精确清理"
        fi
    fi

    # 2. 移除开机重放服务，避免还原后再次注入（保留 Web 面板，避免 pkill 误杀调用方）
    uninstall_persistence --keep-web

    # 3. 优先精准反注入当前运行目录与 www.zip；失败时仅从备份恢复本工具改动的文件
    precise_restore_runtime_web >/dev/null 2>&1 || true
    local restore_zip="/usr/trim/share/.restore/www.zip"
    local restored=0
    if [ -f "${restore_zip}" ] && precise_restore_web_zip "${restore_zip}"; then
        restored=1
        systemctl restart trim_nginx.service >/dev/null 2>&1 || true
        log_info "已精准移除 fnOS Web 源包中的 fn-docker-desk 注入"
    else
        log_warn "精准反注入失败，从备份恢复本工具改动的文件（不整体覆盖，保护应用商城已装应用）"
        if [ -f "${restore_zip}.fndesk.orig" ] && restore_our_files_from_zip "${restore_zip}" "${restore_zip}.fndesk.orig"; then
            restored=1
            systemctl restart trim_nginx.service >/dev/null 2>&1 || true
            log_info "已从本工具原始备份恢复改动文件: index.html + 主 JS"
        elif [ -f "/usr/trim/share/.restore/www.bak" ] && restore_our_files_from_zip "${restore_zip}" "/usr/trim/share/.restore/www.bak"; then
            restored=1
            systemctl restart trim_nginx.service >/dev/null 2>&1 || true
            log_warn "未找到本工具原始备份，已从外部 Fndesk www.bak 恢复改动文件"
        else
            log_warn "未找到可用的还原备份，仅清理本工具配置"
        fi
    fi

    # 4. 彻底清除本工具生成的用户/容器图标配置与图片
    #    管理面板自身图标（manager）由 fnOS 应用中心管理，保留，不在 icons.json 中记录
    if [ -f "${CONF_JSON}" ]; then
        # 仅移除用户自定义/容器图标，保留应用自身图标（若存在）
        if jq -e 'length > 0' "${CONF_JSON}" >/dev/null 2>&1; then
            jq '[.[] | select((."类型" // "docker") != "manager" and ."标题" != "飞牛桌面图标")]' \
               "${CONF_JSON}" > "${CONF_JSON}.tmp" 2>/dev/null && mv "${CONF_JSON}.tmp" "${CONF_JSON}" || \
               echo '[]' > "${CONF_JSON}"
        fi
        chmod 644 "${CONF_JSON}"
        log_info "已清空用户/容器图标配置（应用自身图标保留）: ${CONF_JSON}"
    fi
    rm -f "${DEST_JSON}"
    rm -f "${LEGACY_JSON}"
    log_info "已删除桌面配置发布文件"
    # 删除用户/容器图标图片，保留管理面板自身图标图片
    if [ -d "${IMAGE_DIR}" ]; then
        find "${IMAGE_DIR}" -maxdepth 1 -type f ! -name 'fn-docker-desk-manager.svg' -delete 2>/dev/null || true
        log_info "已删除用户/容器图标图片（管理面板自身图标保留）: ${IMAGE_DIR}"
    fi

    # 5. 彻底清除应用内图标设置：持久卷备份 + 备份目录中的用户配置备份
    if [ -d "${APPDATA_DIR}" ]; then
        rm -rf "${APPDATA_DIR}"
        log_info "已清除持久卷备份: ${APPDATA_DIR}"
    fi
    # 删除用户图标配置备份（icons.json.bak / fn-docker-desk.json.bak），保留系统文件备份
    rm -f "${BACKUP_DIR}/icons.json.bak" "${BACKUP_DIR}/fn-docker-desk.json.bak"
    log_info "已清除应用内图标配置备份: ${BACKUP_DIR}"

    # 6. 写入还原态标记：此后应用启动/开机自启触发的 apply 不再注入、不再生成用户图标，
    #    直到用户主动添加/移除图标重新启用；管理面板自身图标由应用中心管理，不受影响
    mkdir -p "${CONF_DIR}"
    touch "${RESTORED_FLAG}"
    chmod 644 "${RESTORED_FLAG}" 2>/dev/null || true
    log_info "已进入还原态：重新启动应用不会再生成本工具图标（管理面板自身图标保留）"

    if [ "${restored}" -eq 1 ]; then
        log_info "还原完成！已移除本工具生成的 Docker 桌面图标并彻底清除应用内图标设置，不回滚应用商城后续安装的应用图标；重新启动本应用不会再生成图标（如需启用请重新添加）。"
    else
        log_warn "还原完成，但未能确认 fnOS Web 源包已恢复；如仍异常，可手动恢复 www.zip 备份。"
    fi
    log_info "备份文件保留在: ${BACKUP_DIR}（可用 backups 查看）"
}

# ---------------- 数据持久化（升级/卸载不丢配置） ----------------
# 备份用户数据到 @appdata 持久卷（升级/卸载时调用）
backup_data_to_appdata() {
    mkdir -p "${APPDATA_DIR}" 2>/dev/null || true
    local ok=0
    if [ -f "${CONF_JSON}" ]; then
        cp -f "${CONF_JSON}" "${APPDATA_DIR}/icons.json" 2>/dev/null && ok=1
    fi
    if [ -f "${DEST_JSON}" ]; then
        cp -f "${DEST_JSON}" "${APPDATA_DIR}/desktop.json" 2>/dev/null
    fi
    if [ -d "${IMAGE_DIR}" ]; then
        rm -rf "${APPDATA_DIR}/icons" 2>/dev/null || true
        cp -rf "${IMAGE_DIR}" "${APPDATA_DIR}/icons" 2>/dev/null
    fi
    chmod -R 755 "${APPDATA_DIR}" 2>/dev/null || true
    if [ "${ok}" -eq 1 ]; then
        log_info "已备份配置到持久卷: ${APPDATA_DIR}"
    else
        log_warn "暂无配置可备份: ${APPDATA_DIR}"
    fi
}

# 升级/重装后自愈：主配置丢失时从持久卷恢复（图标数据不丢）
restore_data_from_appdata() {
    [ -f "${APPDATA_DIR}/icons.json" ] || return 0
    # 仅在当前配置为空/不存在时恢复，避免覆盖用户新数据
    local need=0
    if [ ! -f "${CONF_JSON}" ]; then
        need=1
    else
        local cnt
        cnt=$(jq 'length' "${CONF_JSON}" 2>/dev/null || echo 0)
        [ "${cnt}" -eq 0 ] && need=1
    fi
    if [ "${need}" -eq 1 ]; then
        mkdir -p "${CONF_DIR}"
        cp -f "${APPDATA_DIR}/icons.json" "${CONF_JSON}" 2>/dev/null || true
        [ -f "${APPDATA_DIR}/desktop.json" ] && cp -f "${APPDATA_DIR}/desktop.json" "${DEST_JSON}" 2>/dev/null || true
        if [ -d "${APPDATA_DIR}/icons" ]; then
            mkdir -p "${IMAGE_DIR}"
            cp -rf "${APPDATA_DIR}/icons/." "${IMAGE_DIR}/" 2>/dev/null || true
            chmod -R 755 "${IMAGE_DIR}" 2>/dev/null || true
        fi
        chmod 644 "${CONF_JSON}" 2>/dev/null || true
        log_info "已从持久卷恢复图标配置: ${APPDATA_DIR}"
    fi
}

# 温和卸载：只移除注入与自启服务，不清空用户图标数据（供 uninstall_callback 调用）
cmd_uninstall() {
    require_root
    log_warn "开始温和卸载（保留用户配置）..."
    # 1. 备份数据到持久卷
    backup_data_to_appdata
    # 2. 移除注入（运行目录 + 源包）
    precise_restore_runtime_web >/dev/null 2>&1 || true
    precise_restore_web_zip "/usr/trim/share/.restore/www.zip" >/dev/null 2>&1 || true
    systemctl restart trim_nginx.service >/dev/null 2>&1 || true
    # 3. 移除自启注入服务
    uninstall_persistence
    # 4. 停止并清理 web 托管服务（fn-docker-desk-web.service）
    systemctl stop fn-docker-desk-web.service >/dev/null 2>&1 || true
    systemctl disable fn-docker-desk-web.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/fn-docker-desk-web.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    pkill -f "web.py --port ${SVC_PORT:-5558}" 2>/dev/null || true
    log_info "温和卸载完成：已移除注入与自启服务，用户图标配置已备份到 ${APPDATA_DIR}"
}

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------- 入口 ----------------
main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true
    case "${cmd}" in
        list|ls-con)   cmd_list ;;
        add)           cmd_add "$@" ;;
        add-custom)    cmd_add_custom "$@" ;;
        remove|rm)     cmd_remove "$@" ;;
        ls)            cmd_ls ;;
        backups|bak)   cmd_backups ;;
        apply)         cmd_apply "$@" ;;
        status)        cmd_status ;;
        restore)       cmd_restore ;;
        uninstall)     cmd_uninstall ;;
        help|-h|--help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"

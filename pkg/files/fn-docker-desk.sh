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

# ---------------- 路径与常量（与飞牛 fnOS 官方规范对齐） ----------------
# 官方：应用安装到 /var/apps/{appname} 下，通过 TRIM_* 环境变量访问。
# - TRIM_APPDEST = /var/apps/{appname}/target   : 运行文件（每次升级覆盖）
# - TRIM_PKGVAR  = /var/apps/{appname}/var      : 持久数据（升级/重装保留）
# - TRIM_PKGETC  = /var/apps/{appname}/etc      : 应用配置目录
# 命令行独立调用（非生命周期上下文）时可能未注入 TRIM_*，提供默认兜底。
readonly APP_VERSION="2.0.1"                               # 应用版本（与 manifest 保持一致）
readonly FN_WWW="/usr/trim/www"                            # 飞牛 Web 根目录（系统级，不受升级影响）
readonly INDEX_HTML="${FN_WWW}/index.html"

# 应用名（与 manifest.appname 一致），用于默认路径兜底
readonly _APPNAME="fn-docker-desk"
# 注意：bash nounset 模式下不能直接对未设置变量使用 %/* 修饰。
# 先对 TRIM_PKGMETA 提供默认值（已含 /meta 后缀），再剥离最后一层得到 APP_ROOT。
_TMP_PKGMETA="${TRIM_PKGMETA:-/var/apps/${_APPNAME}/meta}"
readonly APP_ROOT="${_TMP_PKGMETA%/*}"
readonly APP_DIR="${APP_ROOT:-/var/apps/${_APPNAME}}"
unset _TMP_PKGMETA

# target：已安装的运行文件（升级会被新 app.tgz 覆盖）
readonly PKG_APP="${TRIM_APPDEST:-${APP_DIR}/target}"
# var：用户持久数据（升级/重装保留，官方建议用于图标配置、备份等）
readonly PKG_VAR="${TRIM_PKGVAR:-${APP_DIR}/var}"
# etc：应用配置目录
readonly PKG_ETC="${TRIM_PKGETC:-${APP_DIR}/etc}"

# 运行数据与配置（官方：持久化数据放在 TRIM_PKGVAR 下）
readonly CONF_DIR="${PKG_VAR}"                            # 主数据目录（持久化）
readonly CONF_JSON="${CONF_DIR}/icons.json"               # 主配置（用户图标列表）
readonly IMAGE_DIR="${CONF_DIR}/icons"                    # 图标图片目录
readonly DEST_JSON="${PKG_ETC}/desktop.json"              # 桌面读取的发布配置（放在 etc 下更规范）
readonly LEGACY_JSON="${FN_WWW}/userimg/fn-docker-desk.json"  # 旧路径兼容发布
readonly BACKUP_DIR="${PKG_VAR}/backup"                   # 系统文件自动备份（持久化）
readonly LOG_FILE="/var/log/fn-docker-desk.log"           # 操作日志（排障用）
# @appdata 兜底备份（TRIM_APPDEST_VOL 定义的存储卷；通常无需使用，仅作双重保险）
readonly APPDATA_DIR="${TRIM_APPDEST_VOL:-/usr/local/apps/@appdata}/${_APPNAME}"
readonly RESTORED_FLAG="${PKG_VAR}/.restored"             # 还原态标记（持久化）
# 注入 JS 为不可变资源，放 target 下随安装包分发
readonly INJECT_JS_FILE="${PKG_APP}/desktop-inject.js"

# v2.0 升级迁移标记：每个版本独立（带版本号），保证 v1.x → v2.0.0 一定跑过一遍，
# 后续同版本重复 apply 不会反复做"删除备份/剥离+重写注入"的冗余 IO。
readonly UPGRADE_MIGRATION_MARKER="${PKG_VAR}/.upgrade_migrated_v${APP_VERSION}"

readonly MARKER_START="<!-- fn-docker-desk:start -->"
readonly MARKER_END="<!-- fn-docker-desk:end -->"
readonly SERVICE_NAME="fn-docker-desk.service"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly RESTORE_SCRIPT="/usr/local/bin/fn-docker-desk-restore.sh"
readonly APP_USER="${TRIM_USERNAME:-${_APPNAME}}"         # 专用包用户（privilege 配置中定义）
readonly SVC_PORT="${TRIM_SERVICE_PORT:-5558}"            # Web 管理服务端口（与 manifest service_port 对齐）
# 本 CLI 入口：优先用 usr-local-linker 注册的稳定命令，否则指向 target/bin
readonly CLI_ENTRY="/usr/local/bin/${_APPNAME}"

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
# 注意：LOG_FILE 是 readonly；不能重赋值。当 /var/log/fn-docker-desk.log 不可写（非 root 调 CLI），
# 在 _log_file 内部用本地可写的 PKG_VAR/log/*.log 兜底。同时 stderr 必须先于 >> 重定向，
# 否则 bash 打开 stdout 重定向文件失败时的错误消息会直接打印到控制台。
_log_file() {
    [ -n "${LOG_FILE:-}" ] || return 0
    local _target="${LOG_FILE}"
    # 如果主日志路径不存在或当前用户不可写 → 尝试 PKG_VAR/log 下的持久备用日志
    if [ ! -e "${_target}" ] || [ ! -w "${_target}" ]; then
        local alt_dir="${PKG_VAR}/log"
        mkdir -p "${alt_dir}" 2>/dev/null || true
        local alt_file="${alt_dir}/fn-docker-desk.log"
        if ( : >> "${alt_file}" ) 2>/dev/null; then
            _target="${alt_file}"
        else
            return 0  # 两个位置都写不了 → 静默跳过
        fi
    fi
    { printf '%s %s\n' "$(date '+%F %T' 2>/dev/null)" "$*"; } 2>/dev/null >> "${_target}" || true
}
log_info()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; _log_file "[INFO] $*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; _log_file "[WARN] $*"; }
log_err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; _log_file "[ERROR] $*"; }
die()       { log_err "$*"; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限运行，请使用 sudo 执行本脚本"
}

require_env() {
    [ -d "${FN_WWW}" ] || die "未检测到飞牛 Web 目录 ${FN_WWW}，请在飞牛 OS 上运行本脚本"
    command -v docker >/dev/null 2>&1 || die "未检测到 docker 命令"
    command -v jq >/dev/null 2>&1 || die "缺少 jq，请先安装: apt install -y jq"
    command -v curl >/dev/null 2>&1 || die "缺少 curl，请先安装: apt install -y curl"
}

init_dirs() {
    mkdir -p "${CONF_DIR}" "${IMAGE_DIR}" "${BACKUP_DIR}" "${PKG_ETC}"
    chmod 755 "${CONF_DIR}" "${PKG_ETC}" 2>/dev/null || true
    chmod 755 "${IMAGE_DIR}" "${BACKUP_DIR}" 2>/dev/null || true
    [ -f "${CONF_JSON}" ] || echo '[]' > "${CONF_JSON}"
    # 从旧版非官方路径（/usr/fn-docker-desk）一次性迁移现有数据（幂等：仅在新目录为空时执行）
    migrate_legacy_paths
    # 自愈：修复 v1.1.7 之前 remove_icon bug 留下的损坏结构
    # （保留项外层多了 key/value 字段，导致 标题/跳转URL/图片URL 丢失）
    normalize_icons_json
}

# 自愈：修复 v1.1.7 之前 remove_icon 函数 jq bug 产生的损坏 icons.json
# 损坏结构形如：{"key":N, "value":{"序号":X,"标题":..., ...}, "序号":Y}
# 正常结构形如：{"序号":X, "标题":..., "跳转URL":..., "图片URL":..., ...}
# 修复策略：对每个元素，若同时含 key 与 value 字段则取 .value，否则保留原值；
#           然后统一按数组位置重算 序号（1-based），保证紧凑无空洞。
# 幂等：数据已是正常结构时，至多重算一次序号，不影响内容；损坏数据则一次性修复。
normalize_icons_json() {
    [ -f "${CONF_JSON}" ] || return 0
    # 先检测是否需要修复（避免对正常数据每次都做写操作，减少磁盘 IO 与并发风险）
    local need_fix=0
    need_fix=$(jq -r '
        if type != "array" then 0
        else (map(select(has("key") and has("value"))) | length)
        end
    ' "${CONF_JSON}" 2>/dev/null || echo 0)
    [ "${need_fix}" -gt 0 ] || return 0
    log_warn "检测到 icons.json 含损坏结构（${need_fix} 项），开始自动修复..."
    local tmp="${CONF_JSON}.normalize.$$"
    if jq '
        [ .[] | (if (has("key") and has("value")) then .value else . end) ]
        | to_entries
        | map(.value + {"序号": (.key + 1)})
    ' "${CONF_JSON}" > "${tmp}" 2>/dev/null; then
        # 校验输出是合法 JSON 数组后再覆盖（失败则保留原文件，避免损坏加剧）
        if jq -e 'type == "array"' "${tmp}" >/dev/null 2>&1; then
            mv -f "${tmp}" "${CONF_JSON}"
            chmod 644 "${CONF_JSON}" 2>/dev/null || true
            log_info "icons.json 已修复：所有图标结构恢复正常并重排序号"
            # 同步发布到桌面读取的 DEST_JSON，让前端立即拿到正确数据
            cp -f "${CONF_JSON}" "${DEST_JSON}" 2>/dev/null || true
            [ -d "${FN_WWW}/userimg" ] && cp -f "${CONF_JSON}" "${LEGACY_JSON}" 2>/dev/null || true
        else
            rm -f "${tmp}" 2>/dev/null
            log_err "icons.json 修复失败：规范化后非合法数组，保留原文件"
        fi
    else
        rm -f "${tmp}" 2>/dev/null
        log_err "icons.json 修复失败：jq 处理异常，保留原文件"
    fi
}

# 升级到官方路径结构：旧版本使用 /usr/fn-docker-desk 存放全部数据；
# 新版按规范拆分：运行文件 → target（TRIM_APPDEST），用户数据 → var（TRIM_PKGVAR），配置 → etc（TRIM_PKGETC）。
migrate_legacy_paths() {
    local legacy="/usr/fn-docker-desk"
    [ -d "${legacy}" ] || return 0
    # 🔴 修复还原→添加→旧图标复活：还原态下绝不迁移旧数据（还原=刻意清空配置，迁回就是复活旧图标）
    if [ -f "${RESTORED_FLAG}" ] || [ -f "${APPDATA_DIR}/.restored" ]; then
        # 即使处于还原态，仍写入迁移标记，避免再次触发判定
        touch "${PKG_VAR}/.migrated_from_usr_fndesk" 2>/dev/null
        touch "${APPDATA_DIR}/.migrated_from_usr_fndesk" 2>/dev/null
        return 0
    fi
    # 🔴 修复：迁移标记双路径识别（PKG_VAR 或 APPDATA_DIR 任一处有标记均视为已迁移）
    [ -f "${PKG_VAR}/.migrated_from_usr_fndesk" ] && return 0
    [ -f "${APPDATA_DIR}/.migrated_from_usr_fndesk" ] && return 0

    local migrated=0
    # icons.json：仅当新配置为空或不存在时迁移
    if [ -f "${legacy}/icons.json" ]; then
        local cur_cnt=0
        cur_cnt=$(jq 'length' "${CONF_JSON}" 2>/dev/null || echo 0)
        if [ "${cur_cnt}" -eq 0 ]; then
            cp -f "${legacy}/icons.json" "${CONF_JSON}" 2>/dev/null && migrated=1
        fi
    fi
    # desktop.json
    if [ -f "${legacy}/desktop.json" ] && [ ! -f "${DEST_JSON}" ]; then
        cp -f "${legacy}/desktop.json" "${DEST_JSON}" 2>/dev/null && migrated=1
    fi
    # icons/
    if [ -d "${legacy}/icons" ]; then
        mkdir -p "${IMAGE_DIR}"
        # 只拷贝目标目录不存在的文件（不覆盖新产生的）
        for f in "${legacy}/icons/"*; do
            [ -e "${f}" ] || continue
            local bn
            bn=$(basename "${f}")
            if [ ! -e "${IMAGE_DIR}/${bn}" ]; then
                cp -rf "${f}" "${IMAGE_DIR}/${bn}" 2>/dev/null && migrated=1
            fi
        done
    fi
    # backup/
    if [ -d "${legacy}/backup" ]; then
        mkdir -p "${BACKUP_DIR}"
        for f in "${legacy}/backup/"*; do
            [ -e "${f}" ] || continue
            local bn
            bn=$(basename "${f}")
            if [ ! -e "${BACKUP_DIR}/${bn}" ]; then
                cp -rf "${f}" "${BACKUP_DIR}/${bn}" 2>/dev/null && migrated=1
            fi
        done
    fi
    # .restored 还原态标记
    if [ -f "${legacy}/.restored" ] && [ ! -f "${RESTORED_FLAG}" ]; then
        cp -f "${legacy}/.restored" "${RESTORED_FLAG}" 2>/dev/null && migrated=1
    fi

    if [ "${migrated}" -eq 1 ]; then
        chmod 755 "${CONF_DIR}" "${IMAGE_DIR}" "${BACKUP_DIR}" "${PKG_ETC}" 2>/dev/null || true
        chmod 644 "${CONF_JSON}" "${DEST_JSON}" 2>/dev/null || true
        log_info "已从旧路径 ${legacy} 迁移图标与备份数据到官方规范目录 ${PKG_VAR}"
    fi
    touch "${PKG_VAR}/.migrated_from_usr_fndesk" 2>/dev/null || true
    # 🔴 修复：迁移标记同步写 APPDATA_DIR，双路径都能识别
    mkdir -p "${APPDATA_DIR}" 2>/dev/null
    touch "${APPDATA_DIR}/.migrated_from_usr_fndesk" 2>/dev/null || true
}

# 检测运行时是否含 v1.x 历史 marker（即 v2.0 反注入升级前的老注入）
# 返回 0 = 发现旧注入；非 0 = 未发现
v1x_injection_present() {
    # index.html 内有 fndesk 缓存参数（任意 v1.x 格式）
    if [ -f "${INDEX_HTML}" ] && grep -q '?v=fndesk[0-9]\+' "${INDEX_HTML}" 2>/dev/null; then
        return 0
    fi
    # 主 JS 文件尾含任意 v1 / v2 marker（但 marker 版本 ≠ 本 APP_VERSION，即老版本残留）
    if [ -d "${FN_WWW}/assets" ]; then
        local fstamp=";/* fn-docker-desk asset injection v1."
        local fstamp_any=";/* fn-docker-desk asset injection v"
        local cur_marker=";/* fn-docker-desk asset injection v${APP_VERSION} */"
        local f
        f=$(grep -rlF "${fstamp_any}" "${FN_WWW}/assets/" 2>/dev/null | head -1)
        if [ -n "${f}" ]; then
            # 包含 v1.x，或者包含任意旧版本 marker（非当前版本）
            if grep -qF "${fstamp}" "${f}" 2>/dev/null; then return 0; fi
            if ! grep -qF "${cur_marker}" "${f}" 2>/dev/null; then return 0; fi
        fi
    fi
    return 1
}

# 检测 www.zip 是否含 v1.x 历史 marker 或非当前版本注入（旧残留）
restore_zip_has_legacy_injection() {
    local restore_zip="/usr/trim/share/.restore/www.zip"
    [ -f "${restore_zip}" ] || return 1
    command -v unzip >/dev/null 2>&1 || return 1
    local cur_marker=";/* fn-docker-desk asset injection v${APP_VERSION} */"
    # 快速检查：-l 列表中是否存在注入过的资产痕迹？
    if unzip -p "${restore_zip}" index.html 2>/dev/null | grep -q '?v=fndesk[0-9]\+' 2>/dev/null; then
        local js_content=""
        local asset=""
        asset=$(unzip -p "${restore_zip}" index.html 2>/dev/null \
                | grep -oE 'src="(/assets/[^"?]+\.js)(?:\?[^"]*)?"' 2>/dev/null \
                | head -1 | sed 's|^src="/||; s|".*||')
        if [ -n "${asset}" ]; then
            js_content=$(unzip -p "${restore_zip}" "${asset}" 2>/dev/null)
            # 含 v1.x marker 或含非当前版本 marker（即含 injection 前缀，但 marker 不同）
            if echo "${js_content}" | grep -qF ';/* fn-docker-desk asset injection v1.' 2>/dev/null; then return 0; fi
            if echo "${js_content}" | grep -qF ';/* fn-docker-desk asset injection v' 2>/dev/null \
               && ! echo "${js_content}" | grep -qF "${cur_marker}" 2>/dev/null; then return 0; fi
        fi
    fi
    return 1
}

# 检测到 v1.x → v2.0 升级场景时，执行：
#   1) 彻底删除 BACKUP_DIR/* 历史遗留备份 + www.zip.fndesk.orig / www.zip.fndesk.bak.*
#   2) 精准剥离运行时旧注入（index.html + assets JS）
#   3) 精准剥离 www.zip 源包旧注入
#   4) 自愈 icons.json（v1.x remove_icon 的 jq 三层嵌套 bug 可能导致序号错乱 / 结构嵌套）
# 目的：从旧版升级后，立刻把用户现有的图标"推倒重来 + 自愈" —— 防止新代码遇到旧注入格式时
#       出现 marker 不识别 / 前端注入加载失败 / 图标损坏等不兼容表现。
# 注意：还原态锁定下不执行（用户还原后本来就不希望自动重建）
upgrade_migration_cleanup_and_recreate() {
    # 还原态：明确是用户要求清空所有图标 & 注入，任何重建都属于越权，直接跳过
    [ ! -f "${RESTORED_FLAG}" ] || return 0

    # ---- 判断迁移必要性（两层防御，避免假阴性） ----
    # (a) PKG_VAR/backup 下是否有遗留（不管 migration marker 是什么），
    #     只要有旧备份文件就必须清理 —— 防止手动覆盖安装 / 非标准升级流程导致 marker 失效。
    local have_legacy_backups=0
    if [ -d "${BACKUP_DIR}" ] && [ -n "$(ls -A "${BACKUP_DIR}" 2>/dev/null)" ]; then
        have_legacy_backups=1
    fi
    # (b) APPDATA_DIR/backup 下是否有遗留备份副本（从 v1.x 可能同步过来的）
    if [ -d "${APPDATA_DIR}/backup" ] && [ -n "$(ls -A "${APPDATA_DIR}/backup" 2>/dev/null)" ]; then
        have_legacy_backups=1
    fi
    # (c) /usr/trim/share/.restore/ 下是否遗留 www.zip.fndesk.* 备份
    if ls /usr/trim/share/.restore/www.zip.fndesk.* >/dev/null 2>&1; then
        have_legacy_backups=1
    fi
    # (d) 运行时/源包是否含 v1.x marker（或非当前版本 marker）
    local have_legacy_injection=0
    v1x_injection_present && have_legacy_injection=1
    restore_zip_has_legacy_injection && have_legacy_injection=1
    # (e) 迁移 marker 是否还没写过（本版本第一次触发）
    local marker_missing=0
    [ ! -f "${UPGRADE_MIGRATION_MARKER}" ] && marker_missing=1

    # 没有任何遗留 & marker 已存在 & 无旧 marker → 直接跳过（节省 IO 扫描）
    if [ "${have_legacy_backups}" -eq 0 ] && [ "${have_legacy_injection}" -eq 0 ] && [ "${marker_missing}" -eq 0 ]; then
        return 0
    fi

    init_dirs 2>/dev/null || true

    local migrated_any=0
    local restore_zip="/usr/trim/share/.restore/www.zip"

    # ------ Step 1：删除 BACKUP_DIR/* 遗留备份 + APPDATA_DIR/backup 副本（双向清除！） ------
    if [ -d "${BACKUP_DIR}" ] && [ -n "$(ls -A "${BACKUP_DIR}" 2>/dev/null)" ]; then
        log_warn "[upgrade] 检测到 BACKUP_DIR (${BACKUP_DIR}) 下有 v1.x 遗留备份，立即删除..."
        if rm -rf "${BACKUP_DIR:?}/"* 2>/dev/null; then
            migrated_any=1
            log_info "[upgrade] 已删除 PKG_VAR 下的旧备份（${BACKUP_DIR}） —— v2.0 零备份依赖"
        fi
    fi
    if [ -d "${APPDATA_DIR}/backup" ] && [ -n "$(ls -A "${APPDATA_DIR}/backup" 2>/dev/null)" ]; then
        log_warn "[upgrade] 检测到 APPDATA_DIR/backup 下有备份副本，删除以防 restore 时重新复活..."
        if rm -rf "${APPDATA_DIR:?}/backup/"* 2>/dev/null; then
            migrated_any=1
            log_info "[upgrade] 已删除 APPDATA_DIR 下的备份副本（${APPDATA_DIR}/backup）"
        fi
        # 若 backup/ 已空，把目录本身也删掉（免得 ls -A 继续触发）
        rmdir "${APPDATA_DIR}/backup" 2>/dev/null || true
    fi

    # ------ Step 2：删除 www.zip.fndesk.orig / www.zip.fndesk.bak.* 源包遗留备份 ------
    if [ -f "/usr/trim/share/.restore/www.zip.fndesk.orig" ]; then
        if rm -f "/usr/trim/share/.restore/www.zip.fndesk.orig" 2>/dev/null; then
            migrated_any=1
            log_info "[upgrade] 已删除遗留备份: /usr/trim/share/.restore/www.zip.fndesk.orig"
        fi
    fi
    local bak
    for bak in /usr/trim/share/.restore/www.zip.fndesk.bak.*; do
        [ -e "${bak}" ] || continue
        if rm -f "${bak}" 2>/dev/null; then
            migrated_any=1
            log_info "[upgrade] 已删除遗留备份: ${bak}"
        fi
    done
    # 极端兜底：APPDATA_DIR 或 PKG_VAR 根目录若不小心遗留了 www.zip.fndesk.* 备份文件也一起清
    # （之前某版本可能 backup 到了错误路径；这里扫一遍，防止残留）
    local stray
    for stray in "${APPDATA_DIR}"/*.fndesk.orig "${APPDATA_DIR}"/www.zip.fndesk.bak.* \
                 "${PKG_VAR}"/*.fndesk.orig "${PKG_VAR}"/www.zip.fndesk.bak.*; do
        [ -e "${stray}" ] || continue
        if rm -f "${stray}" 2>/dev/null; then
            migrated_any=1
            log_info "[upgrade] 已清除路径外遗留备份: ${stray}"
        fi
    done

    # ------ Step 3：自愈 icons.json（v1.x remove_icon jq 三层嵌套 bug → 序号/结构错乱） ------
    if [ -f "${CONF_JSON}" ]; then
        local before_cnt=0 nested_bad=0
        before_cnt=$(jq 'length' "${CONF_JSON}" 2>/dev/null || echo 0)
        # 先检测：是否仍有条目是 {"key":N,"value":{标题,跳转URL}} 的三层嵌套损坏结构
        if jq -e 'any(.[]; type == "object" and has("key") and has("value"))' "${CONF_JSON}" >/dev/null 2>&1; then
            nested_bad=1
        fi
        normalize_icons_json
        local after_cnt=0
        after_cnt=$(jq 'length' "${CONF_JSON}" 2>/dev/null || echo 0)
        if [ "${before_cnt}" != "${after_cnt}" ] || [ "${nested_bad}" -eq 1 ]; then
            migrated_any=1
            log_info "[upgrade] icons.json 已完成自愈 (条目数 ${before_cnt} → ${after_cnt})，保证 v2.0 注入逻辑可正确读取"
        fi
    fi

    # ------ Step 4：剥离运行时旧注入（发现旧 marker 或缓存参数时） ------
    if v1x_injection_present; then
        log_warn "[upgrade] 检测到运行时 ${FN_WWW} 含 v1.x / 旧版本注入 —— 精准剥离旧注入后从头重写 v${APP_VERSION} 注入"
        if command -v python3 >/dev/null 2>&1; then
            local curasset=""
            curasset=$(python3 - "${INDEX_HTML}" <<'PYEOF'
import re, pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text('utf-8', errors='replace')
m = re.search(r'src="(/assets/index-[^"?]+\.js)(?:\?[^"]*)?"', s)
if not m:
    m = re.search(r'src="(/assets/[^"?]+\.js)(?:\?[^"]*)?"', s)
print(m.group(1).lstrip('/') if m else '')
PYEOF
            )
            if [ -n "${curasset}" ] && [ -f "${FN_WWW}/${curasset}" ]; then
                # 3.4.1 index.html 缓存参数剥离
                if grep -q '?v=fndesk[0-9]\+' "${INDEX_HTML}" 2>/dev/null; then
                    local tmpidx="/tmp/fn-docker-desk.idx.upg.$$"
                    python3 - "${INDEX_HTML}" "${tmpidx}" <<'PYEOF'
import pathlib, re, sys
src, dst = sys.argv[1], sys.argv[2]
s = pathlib.Path(src).read_text('utf-8', errors='replace')
s2 = re.sub(r'src="(/assets/[^"?]+\.js)(?:\?v=fndesk[0-9]+){1,2}"', r'src="\1"', s)
pathlib.Path(dst).write_text(s2, 'utf-8')
PYEOF
                    if [ -s "${tmpidx}" ] && ! cmp -s "${tmpidx}" "${INDEX_HTML}" 2>/dev/null; then
                        if mv -f "${tmpidx}" "${INDEX_HTML}" 2>/dev/null; then
                            chmod 644 "${INDEX_HTML}" 2>/dev/null || true
                            migrated_any=1
                            log_info "[upgrade] index.html: 已剥离旧 fndesk 缓存参数"
                        else
                            rm -f "${tmpidx}" 2>/dev/null || true
                        fi
                    else
                        rm -f "${tmpidx}" 2>/dev/null || true
                    fi
                fi

                # 3.4.2 JS 尾部 marker 精准剥离（v1.x 或任何非当前版本 marker → 一刀切）
                local tmpjs="/tmp/fn-docker-desk.js.upg.$$"
                if python3 - "${FN_WWW}/${curasset}" "${tmpjs}" <<'PYEOF'
import pathlib, re, sys
src, dst = sys.argv[1], sys.argv[2]
s = pathlib.Path(src).read_text('utf-8', errors='replace')
s2 = re.split(r';/\* fn-docker-desk asset injection v[0-9]+\.[0-9.]+ \*/', s, maxsplit=1)[0].rstrip()
pathlib.Path(dst).write_text(s2 + "\n", 'utf-8')
PYEOF
                then
                    if [ -s "${tmpjs}" ] && ! cmp -s "${tmpjs}" "${FN_WWW}/${curasset}" 2>/dev/null; then
                        if mv -f "${tmpjs}" "${FN_WWW}/${curasset}" 2>/dev/null; then
                            chmod 644 "${FN_WWW}/${curasset}" 2>/dev/null || true
                            migrated_any=1
                            log_info "[upgrade] assets JS: 已精准剥离 v1.x 注入代码块"
                        else
                            rm -f "${tmpjs}" 2>/dev/null || true
                        fi
                    else
                        rm -f "${tmpjs}" 2>/dev/null || true
                    fi
                else
                    rm -f "${tmpjs}" 2>/dev/null || true
                fi
            fi
        fi
    fi

    # ------ Step 5：剥离 www.zip 源包旧注入（发现旧 marker 或非当前版本 marker 时） ------
    if [ -f "${restore_zip}" ] && restore_zip_has_legacy_injection; then
        log_warn "[upgrade] 检测到源包 ${restore_zip} 含 v1.x / 旧版本注入 —— 调用精准反注入剥离"
        local rc=0
        precise_restore_web_zip "${restore_zip}" || rc=$?
        case "${rc}" in
            0) migrated_any=1; log_info "[upgrade] 已剥离 ${restore_zip} 内的旧注入条目" ;;
            2) log_info "[upgrade] ${restore_zip} 已经干净（未发现注入）" ;;
            *) log_warn "[upgrade] 剥离 ${restore_zip} 失败（可能 zip 结构异常），本次忽略：rc=${rc}" ;;
        esac
    fi

    # ------ 收尾：写迁移标记 + 持久卷备份固化"空状态" ------
    if [ "${migrated_any}" -eq 1 ]; then
        log_warn "[upgrade] v1.x → v${APP_VERSION} 迁移完成：清理备份 + 自愈图标 + 精准剥离旧注入，接下来将从头重写注入（保证与新代码 100% 兼容）"
    else
        # 虽然本次没改动，但为了让下次 apply 不再反复检测，仍写一次标记（节省一次 IO 扫描）
        log_info "[upgrade] 未发现 v1.x 遗留备份或旧注入，跳过迁移"
    fi
    mkdir -p "$(dirname "${UPGRADE_MIGRATION_MARKER}")" 2>/dev/null || true
    touch "${UPGRADE_MIGRATION_MARKER}" 2>/dev/null || true
    # APPDATA_DIR 也同步写一个（防止 PKG_VAR 与 APPDATA_DIR 不同路径时误判重入）
    mkdir -p "${APPDATA_DIR}" 2>/dev/null || true
    touch "${APPDATA_DIR}/.upgrade_migrated_v${APP_VERSION}" 2>/dev/null || true
    # 关键：把"BACKUP_DIR/备份副本已清空 + icons.json 已自愈"的结果立刻同步到 APP卷。
    # 否则下一次触发"配置为空 → restore_data_from_appdata" 时，旧版本 icons.json 或
    # APPDATA 下残留 backup/ 副本可能会把"刚删掉的备份/旧图标"又复活出来。
    if [ "${migrated_any}" -eq 1 ]; then
        backup_data_to_appdata >/dev/null 2>&1 || true
    fi
    return 0
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
    # 仅允许 http/https 远程地址；已是本地 icons/ 相对路径（管理面板上传）则直接引用。
    # 防止 file:// 等危险协议读取本地文件或触发 SSRF。
    if [[ "${url}" =~ ^icons/ ]]; then
        echo "${url}"
        return 0
    fi
    [[ "${url}" =~ ^https?:// ]] || { log_warn "图标 URL 协议不允许（仅 http/https）: ${url}" >&2; return 1; }
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
            # 日志走 stderr，避免污染 stdout 返回的 rel_path（调用方用 $(...) 捕获）
            log_info "图标下载成功: ${u}" >&2
            echo "${rel_path}"
            return 0
        fi
        now=$(date +%s)
        if [ $((now - total_start)) -ge 25 ]; then
            log_warn "图标下载超过 25s，放弃并降级占位图标: ${url}" >&2
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
    # XML 转义首字符，避免 & < > 破坏 SVG
    letter=${letter//&/&amp;}
    letter=${letter//</&lt;}
    letter=${letter//>/&gt;}
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
    # 用 -F 固定字符串匹配，避免容器名中的 . 等被当作正则元字符
    found=$(docker ps --format '{{.Names}}' | grep -Fx "${query}" || true)
    if [ -z "${found}" ]; then
        found=$(docker ps --format '{{.Names}}' | awk -v q="${query}" 'index($0,q)==1{print; exit}' || true)
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
    # 三种匹配：①存储序号(tostring) ②标题 ③位置序号(1-based，数组下标+1)
    count=$(jq -e --arg k "$key" '
        to_entries | map(
            select(
                (.value["序号"]|tostring) == $k or
                (.value["标题"]) == $k or
                ((.key + 1)|tostring) == $k
            )
        ) | length
    ' "${CONF_JSON}" 2>/dev/null || echo 0)
    if [ "${count}" -eq 0 ] || [ "${count}" = "0" ]; then
        die "未找到匹配的图标（序号/位置序号/标题）: ${key}"
    fi
    # 🔴 修复 v1.1.7 之前的 bug：旧代码末尾多了一个 to_entries，
    #   把已经清理过的 [{key,value}] 再转一次 entries，导致保留项变成
    #   {key, value:{...}, 序号} 三层结构，外层丢失 标题/跳转URL/图片URL，
    #   表现为"删除某个图标后其它图标全部损坏"。
    # 正确做法：先过滤保留项 → 提取 .value → 重新 to_entries 得到新索引 → 重算序号。
    jq --arg k "$key" '
        [ to_entries[]
          | select(
              (.value["序号"]|tostring) != $k and
              (.value["标题"]) != $k and
              ((.key + 1)|tostring) != $k
            )
          | .value
        ]
        | to_entries
        | map(.value + {"序号": (.key + 1)})
    ' "${CONF_JSON}" > "${CONF_JSON}.tmp" && mv "${CONF_JSON}.tmp" "${CONF_JSON}"
    log_info "已移除: ${key}"
}

# ---------------- 桌面注入：安全写入工具 ----------------
# safe_install_file <src> <dst>
#   安全安装文件到 /usr/trim/www 下（或任意被文件监听器守护的路径）：
#   ① 先 cmp 字节比对 → 完全相同则直接 return 0，不碰 dst（不触发 inotify）
#   ② 不同则 mv src → dst（同文件系统是原子 rename，不产生中间写入）
#   返回 0=未变更，1=已替换，>1=失败
safe_install_file() {
    local src="$1" dst="$2"
    [ -f "${src}" ] || return 2
    [ -f "${dst}" ] || return 2
    if cmp -s "${src}" "${dst}" 2>/dev/null; then
        return 0
    fi
    if mv -f "${src}" "${dst}" 2>/dev/null; then
        chmod 644 "${dst}" 2>/dev/null || true
        return 1
    fi
    return 3
}

# runtime_injection_is_current <index_html> <asset_js_path> <expected_app_version>
#   幂等前置检查：快速判断当前运行时 www 是否已处于「期望注入状态」
#   通过两道签名判断：
#     (1) index.html 里是否含 ?v=fndesk 缓存参数（说明已经 patch 过 <script src>）
#     (2) asset 主 JS 末尾是否有匹配 expected_app_version 的 fn-docker-desk 注入标记
#   两项都满足 → 返回 0（已注入且版本匹配，跳过所有写入，避免 trim_nginx STOP）
runtime_injection_is_current() {
    local index_html="$1" asset_js="$2" expected_ver="$3"
    [ -f "${index_html}" ] || return 1
    [ -f "${asset_js}" ] || return 1
    # 检查 1：index.html 已经 patch 过缓存参数 ?v=fndesk
    grep -q '?v=fndesk[0-9]\+"' "${index_html}" 2>/dev/null || return 1
    # 检查 2：主 JS 末尾含匹配版本的注入标记
    local marker=";/* fn-docker-desk asset injection v${expected_ver} */"
    tail -c 16384 "${asset_js}" 2>/dev/null | grep -qF "${marker}" 2>/dev/null || return 1
    return 0
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
# 优先匹配 fnOS 传统主入口 index-*.js，失败时回退 assets 下第一个 js（兼容新版桌面结构）
m = re.search(r'src="(/assets/index-[^"?]+\.js)(?:\?[^"]*)?"', s)
if not m:
    m = re.search(r'src="(/assets/[^"?]+\.js)(?:\?[^"]*)?"', s)
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

    # =====================================================================
    # 防线 1：幂等前置检查 —— 如果当前运行时已注入且版本匹配，
    #    直接跳过所有对 /usr/trim/www 的写入，完全不触发 trim_nginx STOP。
    #    （开机自启 apply --quiet、反复按「应用配置」、连加图标都会命中这里）
    # =====================================================================
    if runtime_injection_is_current "${INDEX_HTML}" "${FN_WWW}/${asset}" "${APP_VERSION}"; then
        log_info "运行时已注入且版本匹配 (${APP_VERSION})，跳过写 /usr/trim/www (避免 nginx 重启)"
        # 源包 www.zip 仍尝试 patch 一次（保证系统重建桌面后不丢），但不 reload
        # （v2.0 精准反注入式还原：不再创建 .fndesk.orig / .fndesk.bak 等备份文件）
        mkdir -p "${tmproot}/$(dirname "${asset}")"
        cp "${INDEX_HTML}" "${tmproot}/index.html"
        cp "${FN_WWW}/${asset}" "${tmproot}/${asset}"
        (cd "${tmproot}" && zip -q -u "${restore_zip}" index.html "${asset}") 2>/dev/null || true
        log_info "已 patch fnOS Web 源包（跳过 reload：运行时未变更，避免断开现有连接）"
        return 0
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
             r'src="\1?v=fndesk15"', idx, count=1)
index.write_text(idx, 'utf-8')

js = asset.read_text('utf-8', errors='replace')
# 兼容 v1.x 与 v2.x 所有历史注入标记（下次升级能精准剥离旧注入再重写）
js = re.split(r';/\* fn-docker-desk asset injection v[0-9]+\.[0-9.]+ \*/', js)[0].rstrip()
inject = inject_file.read_text('utf-8', errors='replace')
inject = inject.replace('__VERSION__', app_version)
asset.write_text(js + "\n" + inject + "\n", 'utf-8')
PYEOF
    then
        log_warn "前端 JS 注入脚本执行失败，跳过注入"
        return 1
    fi

    # 不再备份 runtime.orig 到 BACKUP_DIR（v2.0 精准反注入式还原零备份依赖）

    # =====================================================================
    # 防线 2 & 3：safe_install_file = cmp 字节比较 + 原子 mv
    #   结果 idx_changed / js_changed：0=未变更  1=已替换  >1=失败
    #   只有真的改了文件才会把写入事件送到 trim_nginx 文件监听器
    # =====================================================================
    local idx_changed=0 js_changed=0
    local idx_tmp js_tmp
    idx_tmp="${tmproot}/index.html.to_install.$$"
    js_tmp="${tmproot}/$(dirname "${asset}")/$(basename "${asset}").to_install.$$"
    cp -f "${tmproot}/index.html" "${idx_tmp}" 2>/dev/null
    cp -f "${tmproot}/${asset}" "${js_tmp}" 2>/dev/null

    safe_install_file "${idx_tmp}" "${INDEX_HTML}" 2>/dev/null || idx_changed=$?
    if [ "${idx_changed}" -ge 3 ]; then
        log_warn "写入当前运行 index.html 失败 (safe_install rc=${idx_changed}): ${INDEX_HTML}"
        return 1
    fi

    safe_install_file "${js_tmp}" "${FN_WWW}/${asset}" 2>/dev/null || js_changed=$?
    if [ "${js_changed}" -ge 3 ]; then
        log_warn "写入当前运行 JS 失败 (safe_install rc=${js_changed}): ${FN_WWW}/${asset}"
        return 1
    fi

    if [ "${idx_changed}" -eq 1 ] || [ "${js_changed}" -eq 1 ]; then
        log_info "已 patch 当前运行目录 /usr/trim/www (index_changed=${idx_changed}, js_changed=${js_changed})，刷新后立即生效"
    else
        log_info "运行时已为最新注入 (${APP_VERSION})，跳过写 /usr/trim/www (避免 nginx 重启)"
    fi

    # ------- 源包 patch（/usr/trim/share/.restore/www.zip 不在 www 目录，不触发监听器） -------
    # （v2.0 精准反注入式还原：不再创建 .fndesk.orig / .fndesk.bak.* 备份文件
    #   每次直接 zip -u 增量写入，单个 www.zip 的字节写入只影响我们改的 2 个条目）
    if ! (cd "${tmproot}" && zip -q -u "${restore_zip}" index.html "${asset}") 2>/dev/null; then
        log_warn "更新 fnOS Web 源包失败（当前运行目录已生效，但系统重启后图标可能丢失）"
        return 1
    fi

    # =====================================================================
    # 防线 4：reload trim_nginx 仅在「至少一个运行时文件真的被替换」时才执行
    #   若 idx_changed=0 && js_changed=0 → 没碰磁盘 → 不需要 reload → 不会引起任何副作用
    # =====================================================================
    if [ "${idx_changed}" -eq 1 ] || [ "${js_changed}" -eq 1 ]; then
        systemctl reload trim_nginx.service 2>/dev/null || true
        log_info "已 patch fnOS Web 源包并 reload trim_nginx"
    else
        log_info "已 patch fnOS Web 源包（跳过 reload：运行时未变更，避免断开现有连接）"
    fi
    return 0
}

# 发布桌面 JSON：从主配置 CONF_JSON 生成桌面端读取的 DEST_JSON（并兼容旧 userimg 路径）
publish_json() {
    # v2.0 改变：备份不再放在 BACKUP_DIR（即 PKG_VAR/backup/）下，避免用户把"配置安全备份"
    # 与 v1.x 的"系统文件 .runtime.orig 备份"混淆 —— 清空系统文件备份后又出现 .bak 会误以为
    # 升级没清干净。现在把 icons/desktop json 备份放在 PKG_VAR 根目录（名称带前缀），
    # 同时备份失败也不阻塞发布成功判定。
    if [ -f "${DEST_JSON}" ] && [ ! -f "${PKG_VAR}/.fn-dd-desktop.json.bak" ]; then
        cp "${DEST_JSON}" "${PKG_VAR}/.fn-dd-desktop.json.bak" 2>/dev/null || true
        log_info "已备份发布配置: ${PKG_VAR}/.fn-dd-desktop.json.bak"
    fi
    if [ -f "${CONF_JSON}" ] && [ ! -f "${PKG_VAR}/.fn-dd-icons.json.bak" ]; then
        cp "${CONF_JSON}" "${PKG_VAR}/.fn-dd-icons.json.bak" 2>/dev/null || true
        log_info "已备份主配置: ${PKG_VAR}/.fn-dd-icons.json.bak"
    fi
    # 迁移收尾：扫一次 BACKUP_DIR，若仍残留旧版 fn-docker-desk.json.bak / icons.json.bak 则立刻清
    # （防止上面路径没迁之前 publish_json 写出了旧位置，然后用户看到备份又"复活"）
    if [ -f "${BACKUP_DIR}/fn-docker-desk.json.bak" ]; then
        rm -f "${BACKUP_DIR}/fn-docker-desk.json.bak" 2>/dev/null || true
    fi
    if [ -f "${BACKUP_DIR}/icons.json.bak" ]; then
        rm -f "${BACKUP_DIR}/icons.json.bak" 2>/dev/null || true
    fi
    if ! cp -f "${CONF_JSON}" "${DEST_JSON}" 2>/dev/null; then
        log_err "发布桌面配置失败: ${DEST_JSON}"
        return 1
    fi
    chmod 644 "${DEST_JSON}" 2>/dev/null || true
    # 兼容旧版注入：userimg 目录存在则顺带发布一份
    if [ -d "${FN_WWW}/userimg" ]; then
        cp -f "${CONF_JSON}" "${LEGACY_JSON}" 2>/dev/null || true
    fi
    # 图标目录权限（非致命：失败不阻塞发布成功判定，set -e 下加 || true）
    chmod -R 755 "${IMAGE_DIR}" 2>/dev/null || true
    log_info "配置已发布: ${DEST_JSON}"
}

# ---------------- 持久化 ----------------
install_persistence() {
    # 还原脚本：开机时重放注入，并确保 Web 管理服务运行
    cat > "${RESTORE_SCRIPT}" <<EOF
#!/usr/bin/env bash
# fn-docker-desk 开机重放（由 systemd 调用）
set -euo pipefail
# 通过 usr-local-linker 注册的稳定命令入口（官方 /usr/local/bin/fn-docker-desk）
CLI="${CLI_ENTRY}"
[ -x "\${CLI}" ] || CLI="${PKG_APP}/bin/fn-docker-desk"
if [ -x "\${CLI}" ]; then
    bash "\${CLI}" apply --quiet || true
fi
# 确保 Web 管理服务运行（以 root 运行，需调用主脚本 + 访问 docker）
WEB_PY="${PKG_APP}/web.py"
if [ -f "\${WEB_PY}" ] && ! pgrep -f "web.py --port ${SVC_PORT:-5558}" >/dev/null 2>&1; then
    touch /var/log/fn-docker-desk-web.log 2>/dev/null || true
    chmod 644 /var/log/fn-docker-desk-web.log 2>/dev/null || true
    setsid nohup python3 -u "\${WEB_PY}" --port ${SVC_PORT:-5558} >>/var/log/fn-docker-desk-web.log 2>&1 < /dev/null &
fi
EOF
    chmod +x "${RESTORE_SCRIPT}"

    # 注入 JS 已是 PKG_APP/desktop-inject.js（随包分发，无需再 copy）

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
    return 0
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
    # 同步备份到持久卷，保证升级/卸载后配置不丢（备份失败不阻塞添加成功判定，防止 set -e 非零退出让前端误判）
    backup_data_to_appdata || true
    log_info "完成！刷新浏览器（Ctrl+Shift+R）即可在桌面看到图标"
    return 0
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
    # 同步备份到持久卷，保证升级/卸载后配置不丢（备份失败不阻塞添加成功判定，防止 set -e 非零退出让前端误判）
    backup_data_to_appdata || true
    log_info "完成！刷新浏览器（Ctrl+Shift+R）即可在桌面看到图标"
    return 0
}

cmd_remove() {
    require_root
    require_env
    init_dirs
    # 用户主动移除图标 = 重新启用（清除还原态标记）
    rm -f "${RESTORED_FLAG}"
    remove_icon "$1"
    publish_json
    # 同步备份到持久卷，保证升级/卸载后配置不丢（备份失败不阻塞移除成功判定，防止 set -e 非零退出让前端误判）
    backup_data_to_appdata || true
    log_info "已从桌面移除（浏览器刷新后生效）"
    return 0
}

cmd_ls() {
    require_env
    init_dirs
    local count
    count=$(jq 'length' "${CONF_JSON}" 2>/dev/null || echo 0)
    if [ "${count}" -eq 0 ]; then
        log_info "当前没有自定义图标"
        return 0
    fi
    log_info "当前桌面自定义图标（共 ${count} 个）:  [序号]=位置序号(1-based)，亦可用存储序号/标题删除"
    # 显示位置序号 + 存储序号（括号中），按存储序号排序保证展示顺序稳定
    jq -r '
        sort_by(.["序号"] | tonumber? // .["序号"]) |
        to_entries[] |
        "  [\(.key + 1)] (存=\(.value["序号"])) \(.value["标题"])  \(.value["跳转URL"])  \(.value["容器名"] // "-")"
    ' "${CONF_JSON}"
    return 0
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
    # 升级/重装后自愈：配置被清空时先从持久卷恢复（保证图标数据不丢）
    restore_data_from_appdata
    # v2.0+ 升级迁移：必须放在 restore_data_from_appdata 之后！
    # 原因：restore_data 会从 APPDATA_DIR 把旧的 icons.json / desktop.json / icons/ 恢复回来，
    # 更关键的是，如果 APPDATA_DIR/backup 下遗留了旧备份副本，restore 不会恢复它们（但可能之前
    # 同步 APP卷时被打包进去过），所以必须在 restore 之后再扫一遍并彻底清理，
    # 然后 upgrade_migration 内部会再 backup_data_to_appdata，把"BACKUP_DIR/备份副本 已清空"
    # 的结果立刻固化回 APP 持久卷 —— 彻底杜绝"加一个 Docker 图标，旧备份又出现"的问题。
    # 升级迁移逻辑：检测旧版遗留备份（BACKUP_DIR/* / APPDATA_DIR/backup / www.zip.fndesk.*）
    # 与 v1.x marker，自动删除旧备份、自愈 icons.json 损坏数据、精准剥离运行时+源包旧注入。
    upgrade_migration_cleanup_and_recreate || true
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
    # 同步备份到持久卷，保证升级/卸载后配置不丢（备份失败不阻塞应用配置成功判定，防止 set -e 非零退出）
    backup_data_to_appdata || true
    # 注意：此处必须用 { cond && cmd; } || true 包裹，不能裸写 `[ cond ] && cmd`：
    # 当 cond 为 false（比如 `apply --quiet`）时，裸写的 && 表达式整体 rc=1，
    # 而该语句是函数最后一条命令 → 会把 rc=1 泄漏到函数返回值，
    # web.py 按 subprocess.returncode≠0 直接判失败（即使一切都成功）。
    # 加上 { ...; } || true 保证无论分支是否执行，本段 rc 恒为 0。
    { [ "${1:-}" != "--quiet" ] && log_info "完成！刷新浏览器生效"; } || true
    return 0
}

cmd_status() {
    log_info "飞牛 Web 目录: ${FN_WWW} ($([ -d "${FN_WWW}" ] && echo OK || echo MISSING))"
    log_info "注入状态: $(grep -q 'fndesk' "${INDEX_HTML}" 2>/dev/null && echo 已注入 || echo 未注入)"
    log_info "自启服务: $(systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || echo 未安装)"
    log_info "自定义图标数: $(jq 'length' "${CONF_JSON}" 2>/dev/null || echo 0)"
    log_info "NAS IP: $(get_nas_ip)"
    docker ps --format '运行中容器: {{.Names}}' 2>/dev/null | sed 's/^/  /' || true
    return 0
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
    return 0
}

# 精准反注入 fnOS Web 源包：只删除本工具写入的 JS 片段与缓存参数，不回滚其他系统变更
# 全程不依赖任何备份文件，不做任何整体覆盖，不会影响应用商城后续安装的应用图标
precise_restore_web_zip() {
    local restore_zip="$1"
    [ -f "${restore_zip}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    command -v zip >/dev/null 2>&1 || return 1

    # 返回值：0=已更新；2=未发现注入（已干净）；非0=处理失败
    # 注意：fnOS 新版桌面 www.zip 含加密条目，zipfile 全量重写会失败，
    #       因此只读取/更新 index.html 与主 JS，用 zip -u 增量写回（不触碰其他条目）
    python3 - "${restore_zip}" <<'PYEOF'
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

zip_path = pathlib.Path(sys.argv[1])
# 兼容 v1.x 与 v2.x 所有历史版本的注入标记
marker = re.compile(r';/\* fn-docker-desk asset injection v[0-9]+\.[0-9.]+ \*/')
tmp = pathlib.Path(tempfile.mkdtemp(prefix="fn-docker-desk-restore."))
try:
    with zipfile.ZipFile(zip_path, "r") as z:
        names = set(z.namelist())
        if "index.html" not in names:
            print("index.html not found in www.zip", file=sys.stderr)
            sys.exit(1)
        index = z.read("index.html").decode("utf-8", "replace")
        # 兼容所有历史注入版本的缓存参数（fndesk1~fndesk99）
        new_index = re.sub(r'\?v=fndesk[0-9]+"', '"', index)
        changed = []
        if new_index != index:
            (tmp / "index.html").write_text(new_index, "utf-8")
            changed.append("index.html")
        # 主 JS：优先 index-*.js，回退 assets 下第一个 js
        m = re.search(r'src="(/assets/index-[^"?]+\.js)(?:\?[^"]*)?"', index)
        if not m:
            m = re.search(r'src="(/assets/[^"?]+\.js)(?:\?[^"]*)?"', index)
        if m:
            asset = m.group(1).lstrip("/")
            if asset in names and asset.endswith(".js"):
                js = z.read(asset).decode("utf-8", "replace")
                parts = marker.split(js, maxsplit=1)
                if len(parts) > 1:
                    out = tmp / asset
                    out.parent.mkdir(parents=True, exist_ok=True)
                    out.write_text(parts[0].rstrip() + "\n", "utf-8")
                    changed.append(asset)
    # v0.2 兼容：清除 index.html 中的旧 HTML 注入块（MARKER_START..MARKER_END）
    if changed:
        cur_idx_p = tmp / "index.html"
        if not cur_idx_p.exists():
            cur_idx_p.write_text(new_index, "utf-8")
        text = cur_idx_p.read_text("utf-8")
        ms = "<!-- fn-docker-desk:start -->"
        me = "<!-- fn-docker-desk:end -->"
        s = text.find(ms); e = text.find(me)
        if s != -1 and e != -1 and e > s:
            text = text[:s] + text[e + len(me):]
            cur_idx_p.write_text(text, "utf-8")
            if "index.html" not in changed:
                changed.append("index.html")
    if not changed:
        print("no fn-docker-desk injection found")
        sys.exit(2)
    # 不创建 .fndesk.orig / .fndesk.restore.bak 这类备份文件
    # 精准反注入式还原 = 0 备份依赖，所有回退只基于 marker 精确剥离
    subprocess.run(["zip", "-q", "-u", str(zip_path), *changed], cwd=str(tmp), check=True)
    print("precise restore updated: " + ", ".join(changed))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PYEOF
}

precise_restore_runtime_web() {
    [ -f "${INDEX_HTML}" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    # 写入策略（避免触发 trim_nginx 文件监听器）：
    #   - 所有内容改动先写到 /tmp 临时文件
    #   - cmp 字节比对目标文件：相同则丢弃临时文件，不碰原文件；不同再原子 mv
    # 返回值：0=已更新；2=未发现注入（已干净）；非0=处理失败
    # 全程零备份依赖：仅通过 marker 精确剥离
    python3 - "${INDEX_HTML}" <<'PYEOF'
import filecmp
import os
import pathlib
import re
import shutil
import sys
import tempfile

idx_path = pathlib.Path(sys.argv[1])
idx = idx_path.read_text("utf-8", errors="replace")
# 0. 先清除 v0.2 遗留的 HTML 注入块（<!-- fn-docker-desk:start --> ... <!-- fn-docker-desk:end -->）
MS = "<!-- fn-docker-desk:start -->"
ME = "<!-- fn-docker-desk:end -->"
s = idx.find(MS); e = idx.find(ME)
if s != -1 and e != -1 and e > s:
    idx = idx[:s] + idx[e + len(ME):]
# 1. 清除 index.html 中所有 fndesk 版本参数（兼容 v1~v99，不依赖特定 JS 文件名）
new_idx = re.sub(r'\?v=fndesk[0-9]+"', '"', idx)
changed = False
if new_idx != idx:
    _t = pathlib.Path(tempfile.mkstemp(prefix="fndesk-runtime-idx-", suffix=".html")[1])
    _t.write_text(new_idx, "utf-8")
    try:
        if not filecmp.cmp(str(_t), str(idx_path), shallow=False):
            shutil.move(str(_t), str(idx_path))
            os.chmod(str(idx_path), 0o644)
            changed = True
        else:
            _t.unlink(missing_ok=True)
    except Exception as e:
        _t.unlink(missing_ok=True)
        print("safe_install failed for index.html: %s" % e, file=sys.stderr)
        sys.exit(1)

# 2. 遍历 assets 下所有 js，清除 fn-docker-desk 注入代码
#    marker 兼容 v1.x 与 v2.x（历史/未来大版本）
marker = re.compile(r';/\* fn-docker-desk asset injection v[0-9]+\.[0-9.]+ \*/')
assets_dir = pathlib.Path("/usr/trim/www/assets")
if assets_dir.is_dir():
    for js_path in sorted(assets_dir.glob("*.js")):
        try:
            js = js_path.read_text("utf-8", errors="replace")
        except Exception:
            continue
        parts = marker.split(js, maxsplit=1)
        if len(parts) > 1:
            cleaned = parts[0].rstrip() + "\n"
            try:
                _t = pathlib.Path(tempfile.mkstemp(prefix="fndesk-runtime-js-", suffix=".js")[1])
                _t.write_text(cleaned, "utf-8")
                try:
                    if not filecmp.cmp(str(_t), str(js_path), shallow=False):
                        shutil.move(str(_t), str(js_path))
                        os.chmod(str(js_path), 0o644)
                        changed = True
                    else:
                        _t.unlink(missing_ok=True)
                except Exception as e:
                    _t.unlink(missing_ok=True)
                    print("safe_install failed: %s -> %s: %s" % (_t, js_path, e), file=sys.stderr)
                    sys.exit(1)
            except Exception as e:
                print("failed to clean: %s: %s" % (js_path, e), file=sys.stderr)
print("runtime precise restore " + ("updated" if changed else "no injection found"))
sys.exit(0 if changed else 2)
PYEOF
}

# (restore_our_files_from_zip 已在 v2.0 删除：改用精准反注入 + marker 剥离，不再依赖任何备份文件)

cmd_restore() {
    require_root
    log_warn "开始还原到原始飞牛桌面（精准反注入式，零备份依赖）..."

    # 1. 移除开机重放服务，避免还原后再次注入（保留 Web 面板进程避免误杀调用方）
    uninstall_persistence --keep-web

    # 2. 精准反注入当前运行目录（index.html 缓存参数 + assets JS 注入片段 + v0.2 HTML 注入块）
    #    （返回值：0=已更新；2=无注入已干净；1/其他=处理失败；|| 避免 set -e 中断）
    local runtime_rc=2 zip_rc=2
    if command -v python3 >/dev/null 2>&1; then
        precise_restore_runtime_web >/dev/null 2>&1 || runtime_rc=$?
    else
        log_warn "缺少 python3，跳过运行时目录精准反注入"
    fi

    # 3. 精准反注入 fnOS Web 源包 www.zip（marker 剥离 + zip -u 增量写回，不破坏其他应用条目）
    local restore_zip="/usr/trim/share/.restore/www.zip"
    if [ -f "${restore_zip}" ] && command -v python3 >/dev/null 2>&1 && command -v zip >/dev/null 2>&1; then
        precise_restore_web_zip "${restore_zip}" >/dev/null 2>&1 || zip_rc=$?
    elif [ -f "${restore_zip}" ]; then
        log_warn "缺少 python3 或 zip，跳过 www.zip 精准反注入（系统重建桌面后注入可能复活）"
    fi

    # 4. 判定结果 & 按需 reload（reload 仅当至少一次实际发生反注入更新时执行）
    local any_changed=0
    [ "${runtime_rc}" -eq 0 ] && any_changed=1
    [ "${zip_rc}" -eq 0 ] && any_changed=1

    # 5. 二次校验：index.html 与 www.zip 是否已完全干净（仍含 fndesk 关键词则警告）
    local dirty=0
    if [ -f "${INDEX_HTML}" ] && grep -qiE "fndesk|fn-docker-desk" "${INDEX_HTML}"; then
        log_warn "校验不通过：运行时 index.html 仍含 fndesk 关键词，建议检查 / 手动清理"
        dirty=1
    fi
    if [ -f "${restore_zip}" ] && command -v unzip >/dev/null 2>&1; then
        if unzip -p "${restore_zip}" index.html 2>/dev/null | grep -qiE "fndesk|fn-docker-desk"; then
            log_warn "校验不通过：www.zip 内 index.html 仍含 fndesk 关键词，重启桌面后注入可能复活"
            dirty=1
        fi
    fi

    if [ "${any_changed}" -eq 1 ] && [ "${dirty}" -eq 0 ]; then
        systemctl reload trim_nginx.service 2>/dev/null || true
        log_info "精准反注入完成：运行目录 + www.zip 已剥离所有 fn-docker-desk 注入（不依赖任何备份）"
    elif [ "${any_changed}" -eq 1 ]; then
        systemctl reload trim_nginx.service 2>/dev/null || true
        log_warn "精准反注入已执行，但仍残留 fndesk 关键词（见上方告警），若刷新后仍异常请联系维护者或手动检查 index.html"
    else
        # runtime_rc=2 && zip_rc=2 → 已经干净
        log_info "运行目录与 www.zip 均未发现 fn-docker-desk 注入，已为干净状态"
    fi

    # 6. 彻底清除本工具生成的用户/容器图标配置与图片（精准反注入只清理 JS/HTML，不碰业务数据）
    if [ -f "${CONF_JSON}" ]; then
        echo '[]' > "${CONF_JSON}"
        chmod 644 "${CONF_JSON}" 2>/dev/null || true
        log_info "已清空用户/容器图标配置（应用自身图标保留）: ${CONF_JSON}"
    fi
    rm -f "${DEST_JSON}" "${LEGACY_JSON}"
    log_info "已删除桌面配置发布文件"
    if [ -d "${IMAGE_DIR}" ]; then
        find "${IMAGE_DIR}" -maxdepth 1 -type f ! -name 'fn-docker-desk-manager.svg' -delete 2>/dev/null || true
        log_info "已删除用户/容器图标图片（管理面板自身图标保留）: ${IMAGE_DIR}"
    fi

    # 7. 彻底清除用户配置备份/持久卷/旧路径（避免 migrate_legacy_paths 再次迁回）
    #    注意：从此不再依赖 / 删除任何 www.zip / index.html 相关的 .fndesk.orig / .bak 备份文件，
    #         只清理用户数据备份
    if [ -d "${APPDATA_DIR}" ]; then
        rm -rf "${APPDATA_DIR}"
        log_info "已清除持久卷备份: ${APPDATA_DIR}"
    fi
    # v2.0：配置 .json.bak 已迁到 PKG_VAR 根目录（带前缀隐藏式命名），这里新旧两处都清；
    # 同时保留 BACKUP_DIR 旧路径的清除（兼容用户手动回滚到旧版 publish_json 行为）
    rm -f "${BACKUP_DIR}/icons.json.bak" "${BACKUP_DIR}/fn-docker-desk.json.bak"
    rm -f "${PKG_VAR}/.fn-dd-icons.json.bak" "${PKG_VAR}/.fn-dd-desktop.json.bak"
    # APPDATA_DIR 同步清除备份副本（上面 purge APPDATA 不会清 .bak，因为它们不在 icons.json 模式里）
    rm -f "${APPDATA_DIR}/icons.json.bak" "${APPDATA_DIR}/fn-docker-desk.json.bak"
    rm -f "${APPDATA_DIR}/.fn-dd-icons.json.bak" "${APPDATA_DIR}/.fn-dd-desktop.json.bak"
    log_info "已清除应用内图标配置备份: ${PKG_VAR} + ${BACKUP_DIR} + ${APPDATA_DIR}"
    # 清理 v0.2 /usr/fn-docker-desk 旧路径下的业务数据
    local legacy="/usr/fn-docker-desk"
    if [ -d "${legacy}" ]; then
        local _c=0
        [ -f "${legacy}/icons.json" ] && { rm -f "${legacy}/icons.json" && _c=$((_c+1)); }
        [ -f "${legacy}/desktop.json" ] && { rm -f "${legacy}/desktop.json" && _c=$((_c+1)); }
        [ -d "${legacy}/icons" ] && { find "${legacy}/icons" -maxdepth 1 -type f ! -name 'fn-docker-desk-manager.svg' -delete 2>/dev/null; _c=$((_c+1)); }
        [ -f "${legacy}/.restored" ] && rm -f "${legacy}/.restored"
        [ -d "${legacy}/backup" ] && rm -f "${legacy}/backup/icons.json.bak" "${legacy}/backup/fn-docker-desk.json.bak" 2>/dev/null
        [ "${_c}" -gt 0 ] && log_info "已清除旧路径 ${legacy} 下的用户/容器图标配置与图片 (避免再次迁移复活旧图标)"
    fi
    # 同步迁移标记，确保 migrate_legacy_paths 不会因任何残留再次触发迁回
    mkdir -p "${PKG_VAR}"
    touch "${PKG_VAR}/.migrated_from_usr_fndesk"
    chmod 644 "${PKG_VAR}/.migrated_from_usr_fndesk" 2>/dev/null || true
    mkdir -p "${APPDATA_DIR}" 2>/dev/null
    touch "${APPDATA_DIR}/.migrated_from_usr_fndesk" 2>/dev/null
    chmod 644 "${APPDATA_DIR}/.migrated_from_usr_fndesk" 2>/dev/null || true

    # 8. 写入还原态标记：此后应用启动/开机触发的 apply 不再注入
    mkdir -p "${CONF_DIR}"
    touch "${RESTORED_FLAG}"
    chmod 644 "${RESTORED_FLAG}" 2>/dev/null || true
    touch "${APPDATA_DIR}/.restored" 2>/dev/null
    chmod 644 "${APPDATA_DIR}/.restored" 2>/dev/null || true
    log_info "已进入还原态：重启应用不会再生成本工具图标（如需再次启用请重新添加 / 应用配置）"

    log_info "还原完成！已精准剥离所有 fn-docker-desk 注入（运行目录 + www.zip）+ 清除图标业务数据。全程零备份依赖，未触碰应用商城已安装的任何应用。"
}

# ---------------- 数据持久化（升级/卸载不丢配置） ----------------
# 备份用户数据到 @appdata 持久卷（升级/卸载时调用）
backup_data_to_appdata() {
    mkdir -p "${APPDATA_DIR}" 2>/dev/null || true
    local ok=0
    # 重要：fnOS 上 TRIM_PKGVAR 可能直接指向 @appdata 卷（即 PKG_VAR 与 APPDATA_DIR
    # 子路径一致或完全重合），此时把 CONF_JSON → APPDATA_DIR/icons.json 是同一个文件
    # 的自我复制，GNU cp 会报错「same file」；更严重的是 IMAGE_DIR = APPDATA_DIR/icons
    # 时先 rm -rf APPDATA_DIR/icons 再 cp -r IMAGE_DIR → 直接把源目录清空！
    # 因此这里先做路径归一化比较，同路径下直接跳过复制。
    local cur_conf cur_dest cur_img
    cur_conf=$(readlink -f "${CONF_JSON}" 2>/dev/null || echo "${CONF_JSON}")
    cur_dest=$(readlink -f "${DEST_JSON}" 2>/dev/null || echo "${DEST_JSON}")
    cur_img=$(readlink -f "${IMAGE_DIR}" 2>/dev/null || echo "${IMAGE_DIR}")
    local target_icons="${APPDATA_DIR}/icons.json"
    local target_dest="${APPDATA_DIR}/desktop.json"
    local target_imgd="${APPDATA_DIR}/icons"
    local tgt_icons tgt_dest tgt_imgd
    tgt_icons=$(readlink -f "${target_icons}" 2>/dev/null || echo "${target_icons}")
    tgt_dest=$(readlink -f "${target_dest}" 2>/dev/null || echo "${target_dest}")
    tgt_imgd=$(readlink -f "${target_imgd}" 2>/dev/null || echo "${target_imgd}")

    if [ -f "${CONF_JSON}" ]; then
        if [ "${cur_conf}" != "${tgt_icons}" ]; then
            # 注意：用 set -euo pipefail 时不能裸 cp，rc≠0 会让整个函数/脚本非零退出
            if cp -f "${CONF_JSON}" "${target_icons}" 2>/dev/null; then
                ok=1
            else
                # 🔴 修复：cp 失败不再静默吞掉 + 不与"暂无配置"混淆
                log_warn "backup: 备份主配置到持久卷失败 (${CONF_JSON} → ${target_icons})，检查权限/磁盘/路径后重试"
            fi
        else
            # 源与目标本来就是同一文件（已经在持久卷上了），视为备份成功
            ok=1
        fi
    fi
    if [ -f "${DEST_JSON}" ] && [ "${cur_dest}" != "${tgt_dest}" ]; then
        # 非致命：copy desktop.json 失败不影响主流程判定，但打 warn
        if ! cp -f "${DEST_JSON}" "${target_dest}" 2>/dev/null; then
            log_warn "backup: 备份桌面发布配置失败 (${DEST_JSON} → ${target_dest})"
        fi
    fi
    if [ -d "${IMAGE_DIR}" ]; then
        if [ "${cur_img}" = "${tgt_imgd}" ]; then
            # IMAGE_DIR 就是持久卷本身，不用 rm + cp 自找麻烦（否则会把自己删掉！）
            :
        else
            rm -rf "${target_imgd}" 2>/dev/null || true
            # 非致命：copy 整个 icons 子目录失败（特殊属性/符号链接/瞬时锁）不阻塞主流程，但打 warn
            if ! cp -rf "${IMAGE_DIR}" "${target_imgd}" 2>/dev/null; then
                log_warn "backup: 备份图标图片目录失败 (${IMAGE_DIR} → ${target_imgd})"
            fi
        fi
    fi
    chmod -R 755 "${APPDATA_DIR}" 2>/dev/null || true
    if [ "${ok}" -eq 1 ]; then
        log_info "已备份配置到持久卷: ${APPDATA_DIR}"
    elif [ ! -f "${CONF_JSON}" ]; then
        log_warn "暂无配置可备份: ${APPDATA_DIR}"
    else
        # CONF_JSON 存在但备份失败（上面已打 warn），这里仅兜底提示
        log_warn "备份未完成: 主配置存在但持久卷写入失败 (详见上方 warn)"
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
        # 修复：jq 解析失败/文件损坏 ≠ 空配置，不能盲目从 APPDATA 备份恢复
        # （否则会把备份中已被用户删除的旧图标重新拉回来 → 出现"删了又回来"）
        local cnt="" jq_rc=0 fsize
        cnt=$(jq 'length' "${CONF_JSON}" 2>/dev/null) || jq_rc=$?
        fsize=$(wc -c <"${CONF_JSON}" 2>/dev/null || echo 99999)
        if [ "${jq_rc}" != "0" ]; then
            log_warn "restore: 主配置 jq 解析失败 rc=${jq_rc}，跳过从持久卷恢复（避免覆盖用户新数据）"
            return 0
        fi
        # 只有：解析成功且 (数组为空 或 文件基本为空 size<4) 时才判定需要恢复
        if [ -z "${cnt}" ] || [ "${cnt}" -eq 0 ] || [ "${fsize}" -lt 4 ]; then
            need=1
        fi
    fi
    if [ "${need}" -eq 1 ]; then
        mkdir -p "${CONF_DIR}"
        if cp -f "${APPDATA_DIR}/icons.json" "${CONF_JSON}" 2>/dev/null; then
            [ -f "${APPDATA_DIR}/desktop.json" ] && cp -f "${APPDATA_DIR}/desktop.json" "${DEST_JSON}" 2>/dev/null || true
            if [ -d "${APPDATA_DIR}/icons" ]; then
                mkdir -p "${IMAGE_DIR}"
                cp -rf "${APPDATA_DIR}/icons/." "${IMAGE_DIR}/" 2>/dev/null || true
                chmod -R 755 "${IMAGE_DIR}" 2>/dev/null || true
            fi
            chmod 644 "${CONF_JSON}" 2>/dev/null || true
            log_info "已从持久卷恢复图标配置: ${APPDATA_DIR}"
        else
            log_warn "restore: 从持久卷复制 icons.json 失败（${APPDATA_DIR}/icons.json → ${CONF_JSON}）"
        fi
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
    systemctl reload trim_nginx.service 2>/dev/null || true
    # 3. 移除自启注入服务（顺带停止 web.py 进程 + daemon-reload）
    uninstall_persistence
    log_info "温和卸载完成：已移除注入与自启服务，用户图标配置已备份到 ${APPDATA_DIR}"
}

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

print_version() {
    printf 'fn-docker-desk %s\n' "${APP_VERSION}"
    printf 'Copyright (C) 2025 fn-docker-desk contributors\n'
    printf 'License: MIT\n'
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
        -v|-V|--version) print_version; exit 0 ;;
        help|-h|--help) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
    # 兜底：所有成功路径都显式 exit 0，避免最后一条语句 rc 泄漏为脚本整体 exit code
    exit 0
}

main "$@"
# 防御性兜底：防止 main 的 case 分支未来加新命令忘记写 return 0
exit $?

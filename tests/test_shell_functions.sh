#!/usr/bin/env bash
# ============================================================
# fn-docker-desk.sh Shell 单元测试
# ------------------------------------------------------------
# 测试纯函数逻辑（不依赖 Docker / fnOS 运行环境）：
#   parse_host_port / image_keyword / match_builtin_icon /
#   gen_fallback_icon / require_exact_path / require_under_path
#
# 用法：
#   bash tests/test_shell_functions.sh
#
# 退出码：0=全部通过，1=有失败
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MAIN_SCRIPT="$PROJECT_ROOT/pkg/files/fn-docker-desk.sh"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
FAILED_TESTS=()

# 断言函数
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  ✓${NC} %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
        printf "${RED}  ✗${NC} %s\n" "$desc"
        printf "    期望: '%s'\n" "$expected"
        printf "    实际: '%s'\n" "$actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        printf "${GREEN}  ✓${NC} %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
        printf "${RED}  ✗${NC} %s\n" "$desc"
        printf "    期望包含: '%s'\n" "$needle"
        printf "    实际: '%s'\n" "$haystack"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -qE "$pattern"; then
        PASS=$((PASS + 1))
        printf "${GREEN}  ✓${NC} %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
        printf "${RED}  ✗${NC} %s\n" "$desc"
        printf "    期望匹配: /%s/\n" "$pattern"
        printf "    实际: '%s'\n" "$actual"
    fi
}

assert_return_code() {
    local desc="$1" expected_rc="$2" actual_rc="$3"
    if [ "$expected_rc" = "$actual_rc" ]; then
        PASS=$((PASS + 1))
        printf "${GREEN}  ✓${NC} %s (rc=%s)\n" "$desc" "$actual_rc"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
        printf "${RED}  ✗${NC} %s\n" "$desc"
        printf "    期望返回码: %s\n" "$expected_rc"
        printf "    实际返回码: %s\n" "$actual_rc"
    fi
}

# ---- 加载被测脚本（阻止 main 执行）----
# 技巧：定义一个空的 main 函数覆盖原脚本的 main，使 source 不会执行入口逻辑
main() { :; }
# shellcheck source=/dev/null
source "$MAIN_SCRIPT"

# 临时目录用于文件相关测试
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ==================== parse_host_port ====================
echo ""
echo "${YELLOW}=== parse_host_port ===${NC}"

assert_eq "标准端口映射 0.0.0.0:8080->80/tcp" \
    "8080" "$(parse_host_port '0.0.0.0:8080->80/tcp')"

assert_eq "无 IP 绑定 8080->80/tcp" \
    "8080" "$(parse_host_port '8080->80/tcp')"

assert_eq "IPv6 映射 [::]:3000->3000/tcp" \
    "3000" "$(parse_host_port '[::]:3000->3000/tcp')"

assert_eq "多端口映射取第一个 0.0.0.0:8080->80/tcp, 0.0.0.0:8443->443/tcp" \
    "8080" "$(parse_host_port '0.0.0.0:8080->80/tcp, 0.0.0.0:8443->443/tcp')"

assert_eq "无端口映射返回空" \
    "" "$(parse_host_port '6379/tcp')"

assert_eq "空字符串返回空" \
    "" "$(parse_host_port '')"

# ==================== image_keyword ====================
echo ""
echo "${YELLOW}=== image_keyword ===${NC}"

assert_eq "jellyfin/jellyfin:latest -> jellyfin" \
    "jellyfin" "$(image_keyword 'jellyfin/jellyfin:latest')"

assert_eq "redis:7 -> redis" \
    "redis" "$(image_keyword 'redis:7')"

assert_eq "大写转小写 Jellyfin/Jellyfin -> jellyfin" \
    "jellyfin" "$(image_keyword 'Jellyfin/Jellyfin:latest')"

assert_eq "带 registry 前缀 registry.cn/nginx:1.25 -> nginx" \
    "nginx" "$(image_keyword 'registry.cn/nginx:1.25')"

assert_eq "无 tag 的镜像 nginx -> nginx" \
    "nginx" "$(image_keyword 'nginx')"

# ==================== match_builtin_icon ====================
echo ""
echo "${YELLOW}=== match_builtin_icon ===${NC}"

assert_contains "jellyfin 匹配内置图标" \
    "$(match_builtin_icon 'jellyfin' || true)" "jellyfin"

assert_contains "emby 匹配内置图标" \
    "$(match_builtin_icon 'emby' || true)" "emby"

assert_contains "portainer 匹配内置图标" \
    "$(match_builtin_icon 'portainer' || true)" "portainer"

assert_contains "grafana 匹配内置图标" \
    "$(match_builtin_icon 'grafana' || true)" "grafana"

# 不存在的关键字应返回失败
match_builtin_icon "nonexistent-app-xyz" >/dev/null 2>&1 && \
    { FAIL=$((FAIL + 1)); FAILED_TESTS+=("不存在的关键字应返回失败"); printf "${RED}  ✗${NC} 不存在的关键字应返回失败\n"; } || \
    { PASS=$((PASS + 1)); printf "${GREEN}  ✓${NC} 不存在的关键字正确返回失败\n"; }

# ==================== gen_fallback_icon ====================
echo ""
echo "${YELLOW}=== gen_fallback_icon ===${NC}"

# gen_fallback_icon 写入 IMAGE_DIR，需要设置临时目录
ORIG_IMAGE_DIR="${IMAGE_DIR:-}"
IMAGE_DIR="$TMPDIR_TEST/icons"
mkdir -p "$IMAGE_DIR"

result=$(gen_fallback_icon "testapp")
assert_eq "返回相对路径 icons/testapp.svg" \
    "icons/testapp.svg" "$result"

assert_eq "生成 SVG 文件存在" \
    "1" "$([ -f "$IMAGE_DIR/testapp.svg" ] && echo 1 || echo 0)"

assert_contains "SVG 包含 <svg> 标签" \
    "$(cat "$IMAGE_DIR/testapp.svg")" "<svg"

assert_contains "SVG 包含首字母 T (大写)" \
    "$(cat "$IMAGE_DIR/testapp.svg")" ">T<"

# 空名称生成默认字母 D
result=$(gen_fallback_icon "")
assert_contains "空名称生成默认字母 D" \
    "$(cat "$IMAGE_DIR/.svg" 2>/dev/null || echo '')" ">D<"

# 恢复
IMAGE_DIR="$ORIG_IMAGE_DIR"

# ==================== require_exact_path ====================
echo ""
echo "${YELLOW}=== require_exact_path ===${NC}"

require_exact_path "/usr/trim/www/index.html" "/usr/trim/www/index.html"
assert_return_code "路径完全匹配返回 0" "0" "$?"

require_exact_path "/usr/trim/www/../etc/passwd" "/usr/trim/www/index.html"
assert_return_code "路径不匹配返回 1" "1" "$?"

require_exact_path "/different/path" "/expected/path"
assert_return_code "完全不同的路径返回 1" "1" "$?"

# ==================== require_under_path ====================
echo ""
echo "${YELLOW}=== require_under_path ===${NC}"

require_under_path "/usr/trim/www/assets/index.js" "/usr/trim/www/assets"
assert_return_code "子路径在校验目录下返回 0" "0" "$?"

require_under_path "/usr/trim/www/index.html" "/usr/trim/www/assets"
assert_return_code "不在指定子目录下返回 1" "1" "$?"

require_under_path "/etc/passwd" "/usr/trim/www"
assert_return_code "完全不同路径返回 1" "1" "$?"

require_under_path "/usr/trim/www/assets/sub/deep/file.js" "/usr/trim/www/assets"
assert_return_code "深层子路径在校验目录下返回 0" "0" "$?"

# ==================== next_seq ====================
echo ""
echo "${YELLOW}=== next_seq ===${NC}"

# next_seq 依赖 CONF_JSON，使用临时文件
ORIG_CONF_JSON="${CONF_JSON:-}"
CONF_JSON="$TMPDIR_TEST/test_icons.json"
echo '[]' > "$CONF_JSON"

assert_eq "空数组第一个序号为 1" \
    "1" "$(next_seq)"

echo '[{"序号": 1, "标题": "app1"}]' > "$CONF_JSON"
assert_eq "已有1个图标，下一个序号为 2" \
    "2" "$(next_seq)"

echo '[{"序号": 1, "标题": "a"}, {"序号": 5, "标题": "b"}]' > "$CONF_JSON"
assert_eq "已有序号1和5，下一个序号为 6" \
    "6" "$(next_seq)"

CONF_JSON="$ORIG_CONF_JSON"

# ==================== icon_exists ====================
echo ""
echo "${YELLOW}=== icon_exists ===${NC}"

ORIG_CONF_JSON="${CONF_JSON:-}"
CONF_JSON="$TMPDIR_TEST/test_exists.json"
echo '[{"序号": 1, "标题": "Jellyfin", "跳转URL": "http://test", "图片URL": "icons/test.svg", "容器名": "jellyfin", "类型": "docker"}]' > "$CONF_JSON"

icon_exists "Jellyfin"
assert_return_code "已存在的标题返回 0" "0" "$?"

icon_exists "NotExist"
assert_return_code "不存在的标题返回非 0" "1" "$?"

CONF_JSON="$ORIG_CONF_JSON"

# ==================== 版本号一致性 ====================
echo ""
echo "${YELLOW}=== 版本号一致性 ===${NC}"

manifest_version=$(grep '^version' "$PROJECT_ROOT/pkg/fnos/manifest" | awk -F'=' '{print $2}' | tr -d ' ')
script_version="$APP_VERSION"

assert_eq "manifest 版本与脚本版本一致" \
    "$manifest_version" "$script_version"

# ==================== 结果汇总 ====================
echo ""
echo "================================"
if [ "$FAIL" -eq 0 ]; then
    printf "${GREEN}全部通过: %d 个测试${NC}\n" "$PASS"
    echo "================================"
    exit 0
else
    printf "${RED}失败 %d / 共 %d${NC}\n" "$FAIL" "$((PASS + FAIL))"
    echo ""
    echo "失败用例:"
    for t in "${FAILED_TESTS[@]}"; do
        printf "  ${RED}- %s${NC}\n" "$t"
    done
    echo "================================"
    exit 1
fi

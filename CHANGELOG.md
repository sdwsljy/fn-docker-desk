# Changelog

## 1.2.0

- **【致命】修复「任何写入操作（加图/删图/应用/开机自启）都会立刻让飞牛桌面断开连接」的根因 —— `trim_nginx.service` 的内置文件监听器会在 `/usr/trim/www/index.html` 被写入时执行**完整 STOP + START**（不是优雅 reload），所有 WebSocket 长连接瞬间被关闭：
  - **排查证据链**：对 192.168.31.205 的 systemd journal 回溯 14 小时，发现 17 次 `trim_nginx.service` 完整重启，每次开头都一模一样：
    `nginx will stop serve because some file has been modified: /usr/trim/www/index.html` →
    `Stopping trim_nginx.service...` →
    `trim_nginx.service: Deactivated successfully.` →
    `Started trim_nginx.service - trim nginx service.`
  - 最密集的一次：2026-08-15 `02:12:14 → 02:12:18 → 02:12:29 → 02:12:33 → 02:12:41`，**27 秒内 trim_nginx 连续完全重启 5 次**，对应用户连续添加 5 个图标时每次 `apply_inject` 都直接 `cp` 覆盖 `/usr/trim/www/index.html`
  - 旧代码 `apply_inject` 末尾日志写的是「reload trim_nginx（不断开现有连接）」，但**真正导致断开的根本不是这行 `systemctl reload`，而是前面 13 行的 `cp -f ${tmproot}/index.html ${INDEX_HTML}`**——写入动作一发生，trim_nginx 的监听器比 systemctl reload 先启动，直接把整个 nginx STOP+START 了一轮。日志里的那句话是「以为在 reload，实际已经被监听器硬停+重启过一次」的误导性信息。
  - **修复采取四道防线**（全部在本应用内部实现，**不修改任何飞牛原生配置 / systemd / 监听器**）：
    1. **防线 1（幂等前置拦截，命中 99% 调用）**：新增 `runtime_injection_is_current`，`apply_inject` 开头立刻检查：① index.html 是否已含 `?v=fndesk15` 缓存参数、② 主 JS 末尾注入标记版本是否匹配 `APP_VERSION`。两项都满足 → 直接跳过所有 `/usr/trim/www` 写入，仅保留 `www.zip` 源包 patch 后 return 0。**开机自启 apply --quiet、反复点「应用配置」、连加第 2~N 个图标都会命中这里 → 0 次写盘 → 0 次 nginx 重启**。
    2. **防线 2（cmp 字节比较前置）**：新增通用 helper `safe_install_file <src> <dst>`，替换原先的裸 `cp`。实现：先用 `cmp -s` 字节级比较临时文件与目标文件 → 完全相同则 return 0，**绝对不碰 dst（不产生任何 inotify 事件）**；只有真的不同才 `mv` 过去（同文件系统为原子 rename，不产生中间写入窗口）。返回值 `0=未变更 / 1=已替换 / >1=失败`，供上游决定是否 reload。
    3. **防线 3（写入路径改到 /tmp + 原子 mv）**：`apply_inject`、`precise_restore_runtime_web`、`cmd_restore` 旧注入清理三段都把原本 `path.write_text(目标路径)` 或直接 `cp` 目标的写法改为：先写入 `/tmp/fndesk-*.tmp` → 交给 `safe_install_file` 或 Python 端 `filecmp.cmp + shutil.move` 语义处理后再决定是否替换目标，彻底消除无关写入。
    4. **防线 4（按需 reload）**：`apply_inject` 末尾仅当 `idx_changed=1 || js_changed=1`（即真的替换了至少一个运行时文件）时才执行 `systemctl reload trim_nginx.service`，否则直接跳过 reload，完全消除副作用。
  - 附带收益：`precise_restore_runtime_web` 原本在「反注入后 index.html / assets JS 已经干净」的情况下仍会 `write_text` 相同内容 → 同样触发 STOP，现在同样被 cmp 拦截，**一键还原也只会在真的有旧注入时才写盘**。

## 1.1.18

- 修复「删除任一图标后其它图标全部损坏（标题/链接/图片丢失，仅显示 D 占位图标）」的致命 bug：
  - **根因**：`remove_icon` 末尾的 jq 表达式多写了一个 `to_entries`，把已经清理过的 `[{key,value}]` 又转了一次 entries → 输出变成 `[{key, value:{key, value:原对象}, 序号}]` 三层嵌套，外层丢失了 `标题`/`跳转URL`/`图片URL` 等业务字段，`desktop-inject.js` 渲染时这些图标标题为空、URL 为空、图片为空，看起来就是「全部损坏」
  - 新添加的图标用的是 `. + [...]` 直接追加，结构正常，所以表现为「多次添加图标后之前添加的全部损坏」
  - **修复①**：重写 `remove_icon` 的 jq 表达式：先用 `to_entries[] + select` 过滤出保留项，再 `.value` 提取，最后 `to_entries + map` 重算序号
  - **修复②**：新增 `normalize_icons_json` 自愈函数，在 `init_dirs` 中调用，自动检测并修复 v1.1.7 之前 bug 留下的损坏结构（含 `key+value` 字段的元素自动取 `.value`，再统一重排序号）；升级后首次启动即自动修复现有损坏数据，无需用户手动操作；同步把修复后的数据发布到 `DEST_JSON` 与 `LEGACY_JSON`，刷新浏览器即可看到图标恢复正常

## 1.1.17

- 修复 3 处致命/高危漏洞：
  - **【致命】一键还原后旧图标复活**：`cmd_restore` 仅清空 PKG_VAR 官方路径 `icons.json`，但未清理 v0.2 遗留 `/usr/fn-docker-desk` 旧路径下的 `icons.json`/`desktop.json`/图标图片，也未写入 `.migrated_from_usr_fndesk` 迁移标记；随后 `cmd_add` 调用 `init_dirs` → `migrate_legacy_paths` 判定「新配置为空且旧路径有数据」→ 把旧路径 icons.json（满是已被用户删除的旧图标）整包迁移回 CONF_JSON → 旧图标 + 新图标一起出现。修复采用三道防线：
    1. `cmd_restore` 步骤 5 新增清理逻辑：`rm -f /usr/fn-docker-desk/icons.json`、`/usr/fn-docker-desk/desktop.json`、`/usr/fn-docker-desk/.restored`，清空 `/usr/fn-docker-desk/icons` 下所有用户图标图片与 backup 目录下用户配置备份
    2. `cmd_restore` 同步写 PKG_VAR 与 APPDATA_DIR 双路径迁移标记 `.migrated_from_usr_fndesk`，确保还原后 `migrate_legacy_paths` 不触发
    3. `migrate_legacy_paths` 函数开头新增还原态防御：若 `PKG_VAR/.restored` 或 `APPDATA_DIR/.restored` 存在则直接 return 0，绝不从旧路径迁回任何数据
  - **【高危】restore_data_from_appdata 误判空配置**：`jq` 解析主配置失败时原用 `|| echo 0` 兜底，会误判为「主配置为空」→ 触发从 APPDATA_DIR 备份恢复旧图标（即使备份里是用户已删除的旧数据），导致 apply 时旧图标复活。修复：`jq` 解析失败时不再 echo 0 伪装空数组，而是 log_warn + return 0 跳过恢复；新增文件 size<4 辅助判空（只有真正 0 字节/空数组才恢复）；cp 失败时独立打 warn 不再与成功路径混淆
  - **【日志可观测性】** `backup_data_to_appdata` 内部 3 处 cp 操作原本 `|| true` 静默吞错，与「暂无配置」case 混淆打印相同日志，排查时无法判断备份是否真的失败；修复后对 `icons.json`/`desktop.json`/`icons` 目录 3 处 cp 失败全部独立打 `[WARN]` 日志，末尾 ok 判定区分「真暂无配置」与「存在但备份失败」

## 1.1.16

- 修复从任意旧版本（1.1.11/1.1.13）无法通过飞牛应用商店一键升级到 1.1.15 的致命问题。应用中心升级流程在 `set -e` 严格模式下对任一子命令非零 rc 零容忍，而 v1.1.15 中 CLI 共有 3 处 rc 泄漏导致升级整体被判失败：
  1. CLI 主入口 case 未处理 `--version`/`-v`/`-V` 查询版本参数，命中 `*)` 分支 → usage 打印 banner 后 `exit 1`（应用中心任何版本校验触发非零退出）
  2. `cmd_list`/`cmd_ls`/`cmd_backups`/`cmd_status` 四个只读命令未显式 `return 0`，`while read` 循环末尾 EOF 的 read rc=1 泄漏为函数返回值
  3. `cmd_ls` 中 `jq` 读取 icons.json 缺失兜底，空配置时 `jq exit 4` → set -e 直接中断
- 同时修复潜在图标目录删除高危问题：fnOS 上 `TRIM_PKGVAR` 可能指向 `/usr/local/apps/@appdata/fn-docker-desk`，与 `APPDATA_DIR` 完全重合，导致 `backup_data_to_appdata` 里「先 rm -rf APPDATA_DIR/icons 再 cp -rf IMAGE_DIR APPDATA_DIR/icons」= 先删除真正的图标目录再复制不存在的源。修复：内部先 `readlink -f` 归一化源/目标路径，重合时直接跳过复制并视为成功

## 1.1.15

- 修复 web 界面打开后一直卡在「加载中…」、容器/图标/备份信息不显示的致命体验问题：
  - Python 端未重写 `BaseHTTPRequestHandler.handle_error`：`do_GET`/`do_POST` 内任一步抛异常时，Python 默认输出 HTML 500 页而非前端期望的 JSON。Handler 新增 `handle_error()` 重写，统一返回 JSON 500（含友好错误摘要）
  - 前端 `api()` 直接 `r.json()`，遇到 HTML 响应抛 SyntaxError。改为先 `r.text()` 再 `try JSON.parse(text)`，非 JSON 时自动剥离 HTML 标签、截取 200 字摘要并打包成 `{ok:false, output:...}`
  - PAGE 字符串拼接 `v""" + APP_VERSION + """` 使后半段 HTML/JS 退化为普通字符串，内含 JS 正则触发 Python SyntaxWarning。改为 `PAGE_TEMPLATE.replace("__APP_VERSION__", APP_VERSION)`，全程 raw string
  - `refreshAll()` 外层新增全局 try-catch，致命异常时替换所有仍含「加载中」的 DOM 为红色错误提示（含日志路径）

## 1.1.13

- 在 v1.1.12 双层防御基础上再补两道防线，彻底解决「实际成功，但 web.py subprocess.returncode≠0 判为失败 → [web] 命令失败/前端 toast 红字失败」的 rc 泄漏问题
- `cmd_apply` 的末句原是裸写 `[ "$1" != "--quiet" ] && log_info ...`，当 `apply --quiet` 调用（升级/安装生命周期内部调用）时条件为假导致整条语句 rc=1，又因为是函数最后一条命令 → 函数返回 rc=1（实际全部成功）。修复改用 `{ [ cond ] && log_info; } || true` 包裹，并给 `cmd_add`/`cmd_add_custom`/`cmd_remove`/`cmd_apply` 四个写入口函数末显式写 `return 0` 兜底

## 1.1.12

- 修复「添加/删除/应用配置/一键还原」写操作成功但前端提示「移除失败/添加失败」并把 [INFO] 成功日志拼进失败文案的 bug：
  - 根因是脚本启用 `set -euo pipefail` 后，`backup_data_to_appdata` 内两处裸 cp 在遇到瞬时文件锁/特殊属性/SELinux 拦截返回非零时，直接导致整个 shell 脚本以 rc≠0 退出
  - 脚本层：`publish_json` 中首次备份 cp、`chmod 644`/`-R 755` 全部加 `2>/dev/null || true`；`backup_data_to_appdata` 内部裸 cp 改为 `|| true` 或 if 包裹
  - 前端层：新增 `failReason(output)` 工具函数，从后端原始 output 中仅抽取 [ERR]/[ERROR]/错误关键词行作为失败文案，无错误行时用清晰兜底文案（含日志路径）

## 1.1.11

- 修复从飞牛桌面打开管理面板时，「添加/删除/应用配置/一键还原」全部写接口 403「跨站请求已拦截」的问题
- fnOS 桌面站点（:80/:443）与本管理面板（manifest 默认 :5558）分属不同端口，原先 CSRF 严格比较 netloc 含端口导致合法调用被误杀。现放宽为仅比较 Origin/Referer 与 Host 头的主机名（hostname，不含端口/协议），同时保留对跨主机（如 evil.com）Origin 的 403 拦截

## 1.1.10

- 修复 usr-local-linker 路径 CLI 在非 root 用户（如 SSH admin）下调用时，`log_message` 写 `/var/log/fn-docker-desk.log` 权限不足而向 stderr 泄漏 `Permission denied` 警告的问题
- `_log_file` 先检测主日志可写性，不可写时自动兜底到 `PKG_VAR/log/fn-docker-desk.log`；并修正 shell 重定向顺序 `{ printf ...; } 2>/dev/null >> file` 保证重定向打开失败时消息不泄漏控制台

## 1.1.9

- 修复 usr-local-linker 命令在非生命周期上下文（SSH 直连或外部调用）独立执行时，因 bash nounset 模式导致 `TRIM_PKGMETA: unbound variable` 崩溃
- 同步对齐打包路径 usr-local-linker `bin/fn-docker-desk`、官方 `/var/apps/{appname}/target|var|etc` 结构与旧路径自动迁移

## 1.1.8

- 修复 HTTP 状态码语义错误：CSRF/10MB/上传超限返回 403/400 而非 200，并修正上传接口异常分支未透传非 2xx 问题

## 1.1.7

- 全部 POST 新增 CSRF 同源校验 + 10MB 请求体上限
- 修复 SVC_PORT 未定义
- banner 版本号统一引用 APP_VERSION

## 1.1.6

- 安全与稳定性修复（不加鉴权，保持内网工具定位）：
  - **升级后 Web 面板失效修复**：`upgrade_callback` 误用 `runuser` 降权运行 web.py，导致 add/remove/apply/restore 触发主脚本 `require_root` 全部失败；现统一以 root 启动，与 `main`/`install_callback` 一致
  - **图标 URL scheme 校验**：`download_icon` 与 web.py 入口强制 `^https?://`（本地 `icons/` 上传路径直接引用），防止 `file://` 读取本地文件与 SSRF；顺带修复上传图标从未生效的问题
  - **CORS 收窄**：仅 `/api/icons` 放行跨域（注入桌面 JS 需要），写接口不再 `Access-Control-Allow-Origin: *`，消除跨站驱动式调用
  - **写接口并发锁**：`ThreadingHTTPServer` 下用 `WRITE_LOCK` 串行化 add/add-custom/remove/apply/restore，保护 `icons.json` 读改写
  - **上传图片校验**：`handle_upload` 增加 magic bytes 判定，拒绝非图片数据
  - **死代码清理**：移除从未创建的 `fn-docker-desk-web.service` 全部引用
  - **容器名匹配**：`resolve_container` 改固定字符串匹配，避免 `.` 等被当正则元字符
  - **SVG 占位转义**：`gen_fallback_icon` 对首字符做 XML 转义
  - **打包脚本**：`add_file` 按 shebang 判定可执行位，取代硬编码文件名清单

## 1.1.5

- 修复一键还原后桌面图标无法移除：
  - **根因**：注入 JS 的 `render()` 在图标配置为空数组（一键还原已清空配置）时直接返回，不进入差异渲染，导致已渲染到桌面的 fn-docker-desk 图标 DOM 永远不会被移除
  - **修复**：空数据时立即调用 `clearAll()` 移除全部已渲染的 fn-docker-desk 图标（`data-fndesk-icon` 标记元素），无需刷新页面即自动清理

## 1.1.4

- 修复一键还原失效：
  - **根因**：反注入逻辑依赖 `index-*.js` 前端文件名正则，fnOS 桌面结构变化（或注入状态异常）时运行时目录反注入失败且无兜底，错误被静默忽略，导致“还原成功”但桌面图标残留
  - **修复**：反注入不再依赖特定 JS 文件名 —— 清除 `index.html` 中全部 `?v=fndesk*` 参数，并遍历 `assets/` 下所有 js 清除注入代码；`cmd_restore` 合并运行时与 www.zip 双重校验，未完全生效时自动从备份兜底并准确提示

## 1.1.3

- 按飞牛官方 fnpack 规范修复应用中心手动安装报错：
  - **移除 manifest 中多余的 `checksum` 空字段**：官方 manifest 规范无此字段，空值可能在应用中心 "Verifying files" 完整性校验阶段触发失败
  - **`os_min_version` 从 0.9.0 调整为 1.1.8**：与 `platform = all` 的最低支持系统版本（fnOS V1.1.8+）对齐，避免旧系统误判“应用包格式不符合系统版本要求”

## 1.1.2

- 修复 `download_icon()` 日志污染图标路径的 bug：
  - **根因**：`download_icon()` 中 `log_info`/`log_warn` 输出到 stdout，与 `echo "${rel_path}"` 混在同一个命令替换 `$(...)` 中，导致 `图片URL` 字段被 `[INFO] 图标下载成功: ...` 前缀污染，桌面注入 JS 无法识别路径，图标回退显示首字母
  - **修复**：日志输出重定向到 stderr（`>&2`），stdout 仅保留路径返回值；失败路径的 `log_warn` 同样重定向，避免 `image_rel` 被污染导致后续回退逻辑被跳过
  - 排查确认其他被命令替换捕获的函数（`grab_container_favicon`/`gen_fallback_icon`/`resolve_container`/`next_seq`/`match_builtin_icon`）无同类问题

## 1.1.1

- 修复桌面图标反复闪烁问题，重构 `desktop-inject.js` 渲染逻辑：
  - **排序前置**：先 sort 再算数据签名，消除 API 返回顺序波动导致的误判
  - **差异渲染**：只增删变化的图标，不触碰未变化的，避免全量闪烁
  - **DOM 存活检查**：签名匹配时仍检查图标是否在 DOM 中，React 重渲染移除后自动恢复
  - **简化轮询**：去掉激进的前 5 次每秒轮询，改为 15 秒保活检查
  - **防抖提升**：MutationObserver 防抖从 400ms 提升到 500ms
  - 注入版本标记升级 `fndesk14` → `fndesk15`，强制浏览器加载新 JS

## 1.1.0

- 修复添加图标时飞牛OS断开连接的问题：`apply_inject` 中 `systemctl restart trim_nginx.service` 会强制重启 nginx 导致所有 WebSocket 连接和 HTTP 会话断开
- 改用 `systemctl reload trim_nginx.service` 优雅重载，不中断现有连接
- 所有 `restart trim_nginx` 调用统一改为 `reload`（apply_inject / restore / uninstall）

## 1.0.9
- 修复管理面板 JavaScript 语法错误：`onerror` 属性中的单引号转义在 Python 原始字符串中丢失反斜杠，导致 `SyntaxError: Unexpected identifier 'none'`，管理面板无法加载容器和图标数据
- 改用 HTML 实体 `&#39;` 替代 JavaScript 转义 `\'`，彻底解决跨语言字符串转义问题

## 1.0.8

- 修复 1.0.7 降权运行导致的严重问题：
  - Docker 容器无法读取（非 root 用户无权访问 Docker socket）
  - 桌面图标无法创建（非 root 用户无权修改 `/usr/trim/www` 系统文件）
  - Web 管理服务恢复以 root 运行，确保 Docker 访问和桌面注入正常工作
- 保留 1.0.7 其他代码质量改进（JS 独立化、路径安全校验、死代码清理等）

## 1.0.7

- 代码质量改进：
  - 按官方文档优化 `manifest`/`privilege`/`resource` 配置（`ctl_stop`、`disable_authorization_path`、专用用户/组、`docker` join-group、`usr-local-linker`）。
  - Web 管理服务降权运行（`runuser` 专用包用户，回退 root）。
  - 注入 JS 独立为 `desktop-inject.js`，便于维护。
  - 移除死代码（`ensure_manager_icon`），统一版本号，增加路径安全校验。
  - `web.py` 增加动态版本号、CORS 预检支持、输入校验。
- 测试与 CI：
  - 新增 57 个 Python 单元测试（`pytest`），覆盖核心函数、HTTP 路由、安全校验、打包一致性。
  - 新增 Shell 单元测试脚本，覆盖 6 个纯函数（端口解析、图标匹配、路径安全等）。
  - CI 拆分为 `lint` / `test` / `build` 三阶段，集成 ShellCheck、flake8、pytest、fpk 打包验证和 artifact 上传。

## 1.0.6

- 修复应用自身图标不生成：按飞牛官方 fnpack 标准打包，`ui/config` 随 `app.tgz` 安装。
- 应用中心正式注册桌面入口，安装完成后生成「飞牛桌面图标」。
- 修复脚本 CRLF 换行符问题。

## 1.0.5

- 一键还原不再删除本应用自身图标，仅清理用户添加的图标。
- 管理面板不再显示或管理应用自身图标。

## 1.0.4

- 修复管理面板一键还原误杀自身进程。
- 还原后彻底清理配置并锁定还原态。

## 1.0.3

- 还原时清理应用内图标设置，包括配置、持久卷和备份。

## 1.0.2

- 还原不再整体覆盖系统源包，避免影响应用商城已装应用。
- 清除持久卷备份。

## 1.0.1

- 修复桌面图标点击被浏览器弹窗拦截。

## 0.x

- 初始版本：容器发现、图标提取、桌面注入和一键还原。

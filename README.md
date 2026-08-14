# fn-docker-desk · 飞牛桌面图标

把 Docker 容器应用一键添加到飞牛 OS（fnOS）桌面。通过飞牛应用中心安装 `.fpk` 应用包后，桌面出现「飞牛桌面图标」入口，可视化地把任意 Docker 容器"钉"到桌面，点击直达服务页面。

- 当前版本：**v1.1.17**
- 支持平台：fnOS（x86 / ARM，需 V1.1.8+）
- 开发维护：胖啥胖

## 功能特性

- **应用中心安装**：`.fpk` 包手动安装，系统自动注册桌面入口（官方 `app_service` 机制），安装完成桌面即出现应用图标
- **Web 管理面板**：可视化操作，无需 SSH（`http://<NAS_IP>:5558/`，或直接点击桌面图标在 fnOS 内打开）
  - 列出所有运行中的 Docker 容器及映射端口
  - 一键「添加到桌面」/「移除」
  - 自定义图标：输入图片 URL，或上传本地图片
  - 自定义名称、端口号
  - 操作日志、系统文件备份列表、一键还原
- **图标自动提取**，按优先级回退：
  1. 容器内文件系统提取 favicon（`docker cp` 常见路径）
  2. Web 服务 favicon（HTTP 抓取）
  3. 内置常见应用图标映射（ghproxy / jsdelivr 加速）
  4. 首字母渐变占位图标
- **桌面注入鲁棒**：多版本选择器兼容 + 特征探测兜底，MutationObserver 持续监控，React 重渲染后自动恢复图标
- **修改前自动备份**：每次修改系统 Web 文件前备份到 `/var/apps/fn-docker-desk/var/backup/`
- **开机持久化**：systemd 服务保证重启后注入自动恢复
- **一键还原安全**：还原时保留本应用自身图标，仅清理用户添加的图标；不再整体覆盖系统源包（保护应用商城已装应用）；还原后进入"还原态"，重新启动应用不会自动生成图标，重新添加即恢复
- **SSH 兼容**：通过 usr-local-linker 注册稳定命令 `/usr/local/bin/fn-docker-desk`，可在任意上下文调用

## 安装

### 应用中心手动安装（推荐）

1. 下载 `fn-docker-desk_1.1.17_all.fpk`
2. 登录飞牛 NAS 桌面 → 打开「应用中心」→ 左下角「手动安装」
3. 选择 fpk 文件上传，确认安装
4. 安装完成后桌面出现「飞牛桌面图标」，点击打开管理面板
5. 若应用未自动启动，在应用中心找到该应用点「启动」

> 应用需要 root 权限（修改系统 Web 文件以注入桌面图标），应用中心安装时会请求相关权限。

### 命令行安装（可选）

```bash
sudo appcenter-cli install-fpk /path/to/fn-docker-desk_1.1.17_all.fpk --volume 1
sudo appcenter-cli start fn-docker-desk
```

## 快速开始

### Web 管理面板

打开 `http://<NAS_IP>:5558/`，面板包含三个栏目：

| 栏目 | 功能 |
|------|------|
| 运行中的容器 | 容器名 / 镜像 / 端口，点「添加到桌面」弹出配置窗口 |
| 桌面图标 | 已添加图标列表，点「移除」删除 |
| 系统文件备份 | 修改系统文件前的备份记录，可下载查看 |

顶部按钮：**应用配置**（重新发布并注入）、**一键还原原始桌面**、**刷新**。

添加/移除图标后，在飞牛桌面按 `Ctrl+Shift+R` 强制刷新即可看到变化。

### SSH 命令行

CLI 已通过 usr-local-linker 注册到 `/usr/local/bin/fn-docker-desk`，安装后可直接调用：

```bash
# 列出运行中的容器
fn-docker-desk list

# 添加容器（自动解析端口与图标）
fn-docker-desk add jellyfin

# 添加容器（自定义名称 / 端口 / 图标）
fn-docker-desk add jellyfin --name "我的影视" --port 8096 --icon https://example.com/jellyfin.png

# 添加自定义链接图标
fn-docker-desk add-custom --title "导航页" --url http://192.168.31.200:8080

# 查看已添加图标 / 备份列表 / 一键还原
fn-docker-desk ls
fn-docker-desk backups
fn-docker-desk restore
```

### 命令参考

| 命令 | 说明 |
|------|------|
| `list` | 列出运行中的容器及推断的访问地址 |
| `add <容器名> [--name 标题] [--port 端口] [--icon 图标URL]` | 添加容器到桌面 |
| `add-custom --title 标题 --url 链接 [--icon 图标URL]` | 添加自定义链接图标 |
| `remove <序号\|标题>` | 移除桌面图标 |
| `ls` | 查看当前桌面图标 |
| `backups` | 查看系统文件备份列表 |
| `apply` | 应用配置到桌面（注入 + 持久化） |
| `status` | 查看工具状态 |
| `restore` | 一键还原原始飞牛桌面 |

## 技术原理

飞牛桌面是 Web 应用（React + Tailwind），官方应用中心安装的应用注册到 PostgreSQL `appcenter` 库才会出现在桌面，Docker 自建应用官方不支持直接上桌面。本应用通过前端注入实现：

1. 应用安装时按 fnOS 官方规范（fnpack）打包，`ui/config` 随 `app.tgz` 安装到 target，应用中心据此在 `app_service` 表注册桌面入口，生成「飞牛桌面图标」应用图标
2. 工具启动时向 `/usr/trim/www/index.html` 注入 JS 脚本（幂等，带版本标记 `?v=fndesk15`），同时 patch `/usr/trim/share/.restore/www.zip` 源包，避免系统刷新后丢失
3. 注入的 JS 在桌面渲染后读取图标配置，动态创建与原生图标同结构的 `<a>` 元素；配置优先从同源 `/userimg/fn-docker-desk.json` 读取，失败时回退到面板 `/api/icons`
4. systemd 服务（`fn-docker-desk.service`）开机重放注入，保证持久化；数据同步备份到持久卷 `/usr/local/apps/@appdata/fn-docker-desk`，升级/重装后自动恢复

## 文件与目录

按飞牛 fnOS 官方规范布局：

| 路径 | 说明 |
|------|------|
| `/var/apps/fn-docker-desk/target/bin/fn-docker-desk` | CLI 主脚本（由 usr-local-linker 链接至 `/usr/local/bin/fn-docker-desk`） |
| `/var/apps/fn-docker-desk/target/web.py` | Web 管理面板（Python 标准库，端口 5558） |
| `/var/apps/fn-docker-desk/target/desktop-inject.js` | 桌面注入 JS |
| `/var/apps/fn-docker-desk/var/icons.json` | 主配置（用户图标列表，持久化） |
| `/var/apps/fn-docker-desk/var/icons/` | 图标图片目录（持久化） |
| `/var/apps/fn-docker-desk/var/backup/` | 系统文件自动备份（持久化） |
| `/var/apps/fn-docker-desk/etc/desktop.json` | 发布给桌面读取的配置 |
| `/usr/local/apps/@appdata/fn-docker-desk` | 持久卷（升级/重装自动恢复） |
| `/etc/systemd/system/fn-docker-desk.service` | 开机自启服务 |
| `/var/log/fn-docker-desk.log` | 操作日志 |

## 系统要求

- 飞牛 OS（fnOS，路径 `/usr/trim/www`），**需 V1.1.8+**（`platform = all` 要求）
- Docker（必装）
- Python 3（系统自带）
- 命令行工具需要 `jq`、`curl`（`sudo apt install -y jq curl`）

## 常见问题

1. **图标不显示？** 99% 是浏览器缓存，强制刷新 `Ctrl+Shift+R`。
2. **fnOS 系统升级后注入丢失？** 系统升级可能覆盖注入，重新打开应用（或执行 `apply`）即可恢复。
3. **桌面重构后图标失效？** 注入依赖桌面前端类名，飞牛大版本更新后若桌面重构，需要适配新选择器。
4. **一键还原后想重新启用？** 还原进入"还原态"，在管理面板添加任意图标即恢复正常。

## 注意事项

- 本应用修改飞牛系统 Web 文件（`/usr/trim/www/index.html`），属于非官方深度定制
- Web 管理面板无鉴权（内网工具），建议仅在受信任内网使用；`restore` 可随时完全还原
- 一键还原保留本应用自身图标，仅清理用户添加的图标，不影响应用商城已装应用

## 打包与开发

遵循飞牛官方 fnpack 规范（[官方文档](https://developer.fnnas.com/docs/core-concepts/manifest/)）：

```
fn-docker-desk_1.1.17_all.fpk (tar.gz)
├── manifest              # 应用清单（appname/version/service_port/desktop_uidir...）
├── ICON.PNG / ICON_256.PNG
├── app.tgz               # 应用文件，解压到 target
│   ├── bin/fn-docker-desk   # CLI 主脚本（usr-local-linker 注册到 /usr/local/bin/）
│   ├── web.py               # Web 管理面板
│   ├── desktop-inject.js    # 桌面注入 JS
│   └── ui/
│       ├── config           # 桌面入口（desktop_applaunchname 对应）
│       └── images/          # icon_64.png / icon_256.png
├── cmd/                  # 生命周期脚本（main/install_callback/upgrade_callback/uninstall_callback）
└── config/               # privilege（run-as: root）+ resource（usr-local-linker）
```

本地重打包可运行项目内脚本：

```bash
python scripts/build_fpk.py
```

脚本只依赖 Python 标准库，输出文件位于 `dist/fn-docker-desk_1.1.17_all.fpk`。

## 开发与测试

### 项目结构

```
fn-docker-desk/
├── pkg/files/               # 应用核心文件（打包进 app.tgz）
│   ├── fn-docker-desk.sh    # 主脚本（容器发现/图标提取/桌面注入/还原），打包为 bin/fn-docker-desk
│   ├── web.py               # Web 管理面板后端（Python 标准库）
│   └── desktop-inject.js    # 桌面注入 JS（独立文件，便于维护）
├── pkg/fnos/                # fnOS 应用配置
│   ├── manifest             # 应用清单
│   ├── cmd/                 # 生命周期脚本（main/install_callback/upgrade_callback/uninstall_callback）
│   ├── config/              # privilege + resource（usr-local-linker）
│   └── ui/                  # 桌面入口（config + 图标）
├── scripts/build_fpk.py     # 打包脚本
├── tests/                   # 单元测试
│   ├── test_web.py          # web.py 测试
│   ├── test_build_fpk.py    # build_fpk.py 测试
│   └── test_shell_functions.sh  # Shell 函数测试
├── .github/workflows/       # CI（lint + test + build）
└── .flake8                  # Python 代码风格配置
```

### 运行测试

```bash
# 安装测试依赖
pip install -r tests/requirements-test.txt

# Python 单元测试（57 个）
python -m pytest tests/ -v

# Shell 单元测试
bash tests/test_shell_functions.sh

# Python 代码风格检查
flake8 pkg/files/web.py scripts/build_fpk.py tests/ \
  --max-line-length=120 --extend-ignore=E501,W503,E402,W605

# Shell 语法检查
bash -n pkg/files/fn-docker-desk.sh
```

### CI 流水线

GitHub Actions（`.github/workflows/validate.yml`）在 push/PR 时自动运行：

| 阶段 | 内容 |
|------|------|
| `lint` | flake8（Python linting）+ ShellCheck（shell linting）+ 语法检查 |
| `test` | pytest（Python 单元测试）+ shell 单元测试 |
| `build` | 打包 fpk + 校验包内容 + 上传 artifact |

`lint` 和 `test` 并行执行，`build` 依赖两者通过。

## 版本历史

| 版本 | 内容 |
|------|------|
| 1.1.17 | 修复一键还原后旧图标复活（清理旧路径 + 写迁移标记 + migrate 还原态防御）；修复 restore_data_from_appdata 误判空配置导致图标复活；backup_data_to_appdata 三处 cp 失败独立打 warn 提升可观测性 |
| 1.1.16 | 修复从任意旧版本无法通过应用商店一键升级到 1.1.15 的 rc 泄漏（未处理 --version、只读命令未 return 0、cmd_ls jq 兜底）；修复 TRIM_PKGVAR 与 APPDATA_DIR 重合时图标目录被误删 |
| 1.1.15 | 修复 web 界面卡在「加载中」：重写 handle_error 统一返回 JSON 500；前端 api() 改 r.text + JSON.parse 兜底；PAGE 改 raw string 替换消除 SyntaxWarning；refreshAll 全局 try-catch |
| 1.1.13 | 修复 cmd_apply 末句裸 && 在 --quiet 时 rc=1 泄漏（改 `{ ...; } \|\| true`）；4 个写入口函数显式 return 0 兜底 |
| 1.1.12 | 修复写操作成功但前端提示失败：set -e 下裸 cp 失败致整体 rc≠0；新增 failReason() 仅抽取错误行作为失败文案 |
| 1.1.11 | 修复从飞牛桌面打开面板时写接口全部 403：CSRF 放宽为仅比较 hostname（忽略端口），保留跨主机拦截 |
| 1.1.10 | 修复非 root 用户调用 CLI 时 /var/log 写权限不足向 stderr 泄漏 Permission denied；_log_file 兜底到 PKG_VAR/log/ |
| 1.1.9 | 修复非生命周期上下文（SSH 直连）下 TRIM_PKGMETA unbound variable 崩溃；对齐官方路径与 usr-local-linker 打包 |
| 1.1.8 | 修复 HTTP 状态码语义：CSRF/10MB/上传超限返回 403/400 而非 200 |
| 1.1.7 | 全部 POST 新增 CSRF 同源校验 + 10MB 请求体上限；修复 SVC_PORT 未定义 |
| 1.1.6 | 安全与稳定性修复：升级后 Web 面板降权失效（恢复 root）；图标 URL 强制 http/https 防 file:// 读取与 SSRF；CORS 收窄至 /api/icons；写接口加锁防并发竞态；上传图片 magic bytes 校验；清理死代码；容器名固定匹配；SVG 占位转义 |
| 1.1.5 | 修复一键还原后桌面图标无法移除：注入 JS 空数据时立即清理全部已渲染图标 |
| 1.1.4 | 修复一键还原失效：反注入兼容 fnOS 桌面结构变化（清除全部 fndesk 参数 + 遍历 assets js 清除注入），运行时/www.zip 双重校验 + 备份兜底 |
| 1.1.3 | 按官方 fnpack 规范修复应用中心手动安装报错：移除 manifest 多余 checksum 空字段；os_min_version 与 platform=all 对齐（fnOS 1.1.8+） |
| 1.1.2 | 修复 download_icon 日志污染图标路径（日志改走 stderr），避免图标回退首字母 |
| 1.1.1 | 修复桌面图标反复闪烁：排序前置+差异渲染+DOM存活检查，简化轮询，防抖提升 |
| 1.1.0 | 修复添加图标时 nginx 重启导致飞牛 OS 断开连接，改用 reload 优雅重载 |
| 1.0.9 | 修复管理面板 JavaScript 语法错误（onerror 属性单引号转义丢失导致面板无法加载数据），改用 HTML 实体替代 JS 转义 |
| 1.0.8 | 修复 1.0.7 降权运行导致 Docker 容器无法读取和桌面图标无法创建的问题；Web 管理服务恢复以 root 运行 |
| 1.0.7 | 代码质量改进（配置优化/JS独立化/死代码清理）；新增 57 个单元测试 + CI 三阶段流水线（lint/test/build） |
| 1.0.6 | 修复应用自身图标不生成：按官方 fnpack 标准打包，ui/config 随 app.tgz 安装，应用中心正式注册桌面入口；修复脚本 CRLF 换行符问题 |
| 1.0.5 | 一键还原不再删除本应用自身图标，仅清理用户图标；管理面板不再显示/管理应用自身图标 |
| 1.0.4 | 修复管理面板一键还原误杀自身进程；还原彻底清理配置并锁定还原态 |
| 1.0.3 | 还原彻底清理应用内图标设置（配置/持久卷/备份） |
| 1.0.2 | 还原不再整体覆盖系统源包（保护应用商城应用），清除持久卷备份 |
| 1.0.1 | 修复桌面图标点击被浏览器弹窗拦截 |
| 0.x | 初始版本：容器发现、图标提取、桌面注入、一键还原 |

## License

MIT

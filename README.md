# fn-docker-desk · 飞牛桌面图标

把 Docker 容器应用一键添加到飞牛 OS（fnOS）桌面。通过飞牛应用中心安装 `.fpk` 应用包后，桌面出现「飞牛桌面图标」入口，可视化地把任意 Docker 容器"钉"到桌面，点击直达服务页面。

- 当前版本：**v2.0.1**（建议生产直接使用 **v2.0.1**；v2.0.0 为里程碑基准，不做独立升级推荐）
- 最新发布：[v2.0.1 GitHub Release](https://github.com/sdwsljy/fn-docker-desk/releases/tag/v2.0.1) · [v2.0.0 GitHub Release](https://github.com/sdwsljy/fn-docker-desk/releases/tag/v2.0.0)
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
- **v2.0 WebUI 重新设计**：顶部标题栏版本徽标、容器卡片圆角/渐变按钮/响应式栅格对齐，错误 Toast 仅抽取 ERR/ERROR 行（不再把 INFO 成功日志拼进"失败"红色提示）
- **修改前自动备份 + v2.0 精准反注入式还原（零备份依赖）**：v1.x 采用"备份系统文件再还原"策略（备份到 `/var/apps/fn-docker-desk/var/backup/`）；v2.0 升级为基于注入标记 `<!-- fn-docker-desk:start -->` / `<!-- fn-docker-desk:end -->` **精准剥离**：① 运行时 `index.html` 的缓存参数与 assets JS 注入、② `www.zip` 源包对应条目的注入、③ `icons.json` / `desktop.json` 用户图标配置，一键还原 **100% 成功**，不再依赖任何备份文件。
- **v2.0.1 升级迁移 & 旧备份清理**：从 v1.x / v2.0.0 覆盖升级后，应用首次启动会自动触发迁移：清理 PKG_VAR/backup 与 APP 持久卷下的所有历史遗留备份（含 stray `*.fndesk.orig` / `www.zip.fndesk.bak.*`）、自愈损坏的 `icons.json`、精准剥离 v1.x/v2.0.0 运行时/源包旧注入，并将"备份已清空"状态同步回持久卷，杜绝"加一个 Docker 图标，旧备份又出现"的循环复活问题。
- **四道飞牛桌面断开连接防线**（继承 v1.2.0，v2.0 继续加强）：`trim_nginx.service` 内置监听器会因 `/usr/trim/www/index.html` 任何写入执行 **完整 STOP+START** 导致 WebSocket 心跳超时断开桌面。四道防线：① **幂等前置拦截（命中 99% 调用）**：`runtime_injection_is_current` 检查当前版本标记+缓存参数，命中则完全跳过写盘（开机自启、重复点"应用配置"、连加第 2~N 个图标都 0 写入→0 次 nginx 重启）；② **cmp 字节比较前置**：`safe_install_file` 先 `cmp -s` 比较目标内容，相同则绝对不碰 dst（无 inotify 事件），不同才原子 mv；③ **写入路径改 /tmp + 原子 mv**：杜绝中间写入窗口产生的无关事件；④ **按需 reload**：仅当 `idx_changed || js_changed` 时才 `systemctl reload trim_nginx`，跳过完全无副作用路径。
- **开机持久化**：systemd 服务保证重启后注入自动恢复（写盘使用上述四道防线，不再触发 trim_nginx STOP+START）
- **一键还原安全**：还原时保留本应用自身图标，仅清理用户添加的图标；不再整体覆盖系统源包（保护应用商城已装应用）；还原后进入"还原态"，重新启动应用不会自动生成图标，重新添加即恢复
- **SSH 兼容**：通过 usr-local-linker 注册稳定命令 `/usr/local/bin/fn-docker-desk`，可在任意上下文调用

## 安装

> **下载地址**（从 GitHub Release 获取对应 fpk 安装包）：
> - ✅ **推荐生产版本 v2.0.1**：[`fn-docker-desk_2.0.1_all.fpk`](https://github.com/sdwsljy/fn-docker-desk/releases/download/v2.0.1/fn-docker-desk_2.0.1_all.fpk)（**79,243 bytes**，修复「升级后旧备份循环复活」完整版本）
> - 里程碑版本 v2.0.0（精准反注入+WebUI重做基准）：[`fn-docker-desk_2.0.0_all.fpk`](https://github.com/sdwsljy/fn-docker-desk/releases/download/v2.0.0/fn-docker-desk_2.0.0_all.fpk)（78,121 bytes）
> - 历史稳定版 v1.2.0（四道 nginx 断开连接防线基准）：[v1.2.0 Release](https://github.com/sdwsljy/fn-docker-desk/releases/tag/v1.2.0)

### 应用中心手动安装（推荐）

1. 下载 `fn-docker-desk_2.0.1_all.fpk`（推荐）或 `fn-docker-desk_2.0.0_all.fpk`
2. 登录飞牛 NAS 桌面 → 打开「应用中心」→ 左下角「手动安装」
3. 选择 fpk 文件上传，确认安装
4. 安装完成后桌面出现「飞牛桌面图标」，点击打开管理面板
5. 若应用未自动启动，在应用中心找到该应用点「启动」

> 应用需要 root 权限（修改系统 Web 文件以注入桌面图标），应用中心安装时会请求相关权限。

### 从 v1.x / v2.0.0 升级（直接覆盖安装，无需卸载）

1. 按上方手动安装流程上传并安装 v2.0.1 的 fpk，**无需先卸载旧版本**
2. 升级时生命周期会自动清除任意旧版本的 `.upgrade_migrated_v*` 标记，保证新迁移逻辑生效
3. 启动应用后首次 `apply` 会触发 v2.0.1 升级迁移：
   - 清理 PKG_VAR/backup 与 APP 持久卷 APPDATA_DIR 下的所有历史遗留备份（含 stray *.fndesk.orig / www.zip.fndesk.bak.*）
   - 自愈损坏 `icons.json`（v1.1.18 前 remove_icon jq bug 遗留的三层嵌套损坏结构）
   - 精准剥离运行时 + 源包 v1.x/v2.0.0 旧注入
   - 将"备份已清空"状态同步回 APPDATA_DIR 持久卷，杜绝"升级后加一个 Docker 图标，旧备份又出现"的循环复活
4. 升级完成后建议手动刷新一次浏览器（Ctrl+Shift+R）即可看到新 WebUI 与已恢复的图标

### 命令行安装（可选）

```bash
sudo appcenter-cli install-fpk /path/to/fn-docker-desk_2.0.1_all.fpk --volume 1
sudo appcenter-cli start fn-docker-desk
```

## 快速开始

### Web 管理面板

打开 `http://<NAS_IP>:5558/`，面板包含三个栏目：

| 栏目 | 功能 |
|------|------|
| 运行中的容器 | 容器名 / 镜像 / 端口，点「添加到桌面」弹出配置窗口 |
| 桌面图标 | 已添加图标列表，点「移除」删除 |
| 系统文件备份 | v1.x 版本的系统文件备份列表；**v2.0 改为精准反注入式还原，零备份依赖**，备份列表仅用于排查/参考（不影响一键还原正常工作） |

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
2. 工具启动时向 `/usr/trim/www/index.html` 注入 JS 脚本（幂等，带版本标记 `?v=fndesk15` 与 `APP_VERSION` marker），同时 patch `/usr/trim/share/.restore/www.zip` 源包，避免系统刷新后丢失；**写入走四道防线**：① `runtime_injection_is_current` 幂等前置拦截 → ② `safe_install_file` 做 `cmp -s` 字节比较（相同直接跳过，不同才 `/tmp` 临时文件 + 原子 `mv`）→ ③ 仅当 `idx_changed || js_changed` 才 `systemctl reload trim_nginx`（**绝对不触发 trim_nginx STOP+START，完全杜绝飞牛桌面 WebSocket 心跳超时断开**）
3. 注入的 JS 在桌面渲染后读取图标配置，动态创建与原生图标同结构的 `<a>` 元素；配置优先从同源 `/userimg/fn-docker-desk.json` 读取，失败时回退到面板 `/api/icons`
4. **v2.0 一键还原（精准反注入式，零备份依赖）**：还原操作基于标记 `<!-- fn-docker-desk:start -->` / `<!-- fn-docker-desk:end -->` 精准剥离运行时 index.html 缓存参数、assets JS 注入代码、`www.zip` 源包对应条目注入、以及 icons/desktop 用户图标配置；**不需要任何 BACKUP_DIR 备份或 `www.zip.fndesk.orig` 备份存在也能 100% 成功**
5. systemd 服务（`fn-docker-desk.service`）开机重放注入，保证持久化；数据同步备份到持久卷 `/usr/local/apps/@appdata/fn-docker-desk`，升级/重装后自动恢复；**v2.0.1 升级迁移在首次 apply 时清理旧备份并同步持久卷，防止 APP 持久卷上旧备份副本循环复活**

## 文件与目录

按飞牛 fnOS 官方规范布局：

| 路径 | 说明 |
|------|------|
| `/var/apps/fn-docker-desk/target/bin/fn-docker-desk` | CLI 主脚本（由 usr-local-linker 链接至 `/usr/local/bin/fn-docker-desk`） |
| `/var/apps/fn-docker-desk/target/web.py` | Web 管理面板（Python 标准库，端口 5558） |
| `/var/apps/fn-docker-desk/target/desktop-inject.js` | 桌面注入 JS |
| `/var/apps/fn-docker-desk/var/icons.json` | 主配置（用户图标列表，持久化） |
| `/var/apps/fn-docker-desk/var/icons/` | 图标图片目录（持久化） |
| `/var/apps/fn-docker-desk/var/backup/` | v1.x 系统文件备份目录；**v2.0 零备份依赖**（不再存系统运行时 `.runtime.orig` / `.orig` 备份；配置安全备份以隐藏文件形式放在 PKG_VAR 根目录），v2.0.1 迁移自动清理该目录历史遗留 |
| `/var/apps/fn-docker-desk/var/.fn-dd-icons.json.bak` | v2.0+ 主配置安全备份（隐藏文件，不再出现在 BACKUP_DIR 列表） |
| `/var/apps/fn-docker-desk/var/.fn-dd-desktop.json.bak` | v2.0+ 发布配置安全备份（隐藏文件） |
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
2. **fnOS 系统升级后注入丢失？** 系统升级可能覆盖注入，重新打开应用（或执行 `apply`）即可恢复；v2.0+ 升级迁移会自动清理旧备份并剥离旧注入，自动重写与新版本 100% 兼容的注入。
3. **桌面重构后图标失效？** 注入依赖桌面前端类名，飞牛大版本更新后若桌面重构，需要适配新选择器。
4. **一键还原后想重新启用？** 还原进入"还原态"，在管理面板添加任意图标即恢复正常。
5. **添加/删除图标时飞牛桌面会断开连接吗？** **v1.2.0+ 不会（四道 nginx 断开连接防线）**：v1.2.0 之前直接写 `/usr/trim/www/index.html` 会触发 `trim_nginx.service` 内置监听器做 **完整 STOP+START**（WebSocket 心跳超时→断开桌面），从 v1.2.0 起实现幂等前置 + cmp 字节比较 + /tmp 写入后原子 mv + 按需 reload，连加第 2~N 个图标时 99% 调用 0 次写盘，**完全不会触发 nginx 重启**。
6. **升级 v2.0.1 后，为什么不再看到备份列表里新增 .json.bak？** **这是 v2.0.1 的正确行为**：之前 publish_json 每次发布配置都会往 BACKUP_DIR/ 写 `icons.json.bak + fn-docker-desk.json.bak`，导致"升级明明清了备份，一加图标又出现"。v2.0.1 已把两个安全备份迁到 PKG_VAR 根目录隐藏命名：`${PKG_VAR}/.fn-dd-icons.json.bak` 与 `.fn-dd-desktop.json.bak`（不出现在 BACKUP_DIR 列表），并在 apply 迁移时立刻同步 APPDATA_DIR 持久卷的空状态。
7. **从 v1.x 升级后仍看到旧备份文件？** 如果升级前备份副本已经同步到 APP 持久卷 `APPDATA_DIR/backup/`，v1.x→v2.0.0 时可能有残留；**升级到 v2.0.1 即可自动彻底清理**：v2.0.1 迁移逻辑使用「5 维综合判定」（BACKUP_DIR 非空 / APPDATA_DIR/backup 非空 / www.zip.fndesk.* stray 存在 / v1x marker / marker 缺失），任一路命中就强制清理，然后立刻 `backup_data_to_appdata` 把"清空态"固化回持久卷，杜绝下次恢复时再拉回旧副本。

## 注意事项

- 本应用修改飞牛系统 Web 文件（`/usr/trim/www/index.html`），属于非官方深度定制
- Web 管理面板无鉴权（内网工具），建议仅在受信任内网使用；`restore` 可随时完全还原
- 一键还原保留本应用自身图标，仅清理用户添加的图标，不影响应用商城已装应用

## 打包与开发

遵循飞牛官方 fnpack 规范（[官方文档](https://developer.fnnas.com/docs/core-concepts/manifest/)）：

```
fn-docker-desk_2.0.1_all.fpk (tar.gz)
├── manifest              # 应用清单（appname/version/service_port/desktop_uidir...）
├── ICON.PNG / ICON_256.PNG
├── app.tgz               # 应用文件，解压到 target
│   ├── bin/fn-docker-desk   # CLI 主脚本（usr-local-linker 注册到 /usr/local/bin/）
│   ├── web.py               # Web 管理面板
│   ├── desktop-inject.js    # 桌面注入 JS
│   └── ui/
│       ├── config           # 桌面入口（desktop_applaunchname 对应）
│       └── images/          # icon_64.png / icon_256.png
├── cmd/                  # 生命周期脚本（main/install_callback/upgrade_callback/uninstall_callback/upgrade_init...）
└── config/               # privilege（run-as: root）+ resource（usr-local-linker）
```

本地重打包可运行项目内脚本（Windows 下主用 PowerShell，Linux/macOS 可用 Python 版本）：

```powershell
# Windows PowerShell（当前 CI 打包主路径，产物 Gzip/Tar 头严格对齐 fnOS 官方规范）
powershell -ExecutionPolicy Bypass -File scripts/build_fpk.ps1
```

```bash
# 跨平台 Python 脚本（标准库依赖，仅验证场景用）
python scripts/build_fpk.py
```

脚本输出文件位于：
- PowerShell 版：`dist/fn-docker-desk_2.0.1_all.fpk`
- Python 版：`dist/fn-docker-desk_2.0.1_all.fpk`

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
| **2.0.1** | 【致命修复】彻底消灭「升级后旧备份循环复活」：① cmd_apply 顺序漏洞（先清备份→后 restore 从 APPDATA_DIR 拉回）修复为 restore_data → upgrade_migration → backup_data；② migrate 判定升级为 5 维综合（BACKUP_DIR/APPDATA_DIR/backup/www.zip.fndesk.* 任一项非空 / v1x marker / marker 缺失，任一路命中强制清理，不再只看 marker）；③ 真正元凶 publish_json 每次写 BACKUP_DIR 两个 .json.bak → 迁到 PKG_VAR 隐藏命名 `.fn-dd-icons.json.bak` / `.fn-dd-desktop.json.bak`（不再出现在 BACKUP_DIR 列表）；publish_json 内顺手 rm 旧路径两个 .bak；cmd_restore 清理扩展到 BACKUP_DIR+PKG_VAR+APPDATA_DIR 三路径 8 个目标；④ migrate 末立刻 backup_data_to_appdata 固化"清空态"到 APPDATA_DIR |
| **2.0.0** | 【里程碑】还原逻辑重构为精准反注入式还原（基于 marker 精准剥离 index.html 缓存参数 / assets JS 注入 / www.zip 源包对应条目 / 用户图标配置，零备份依赖）；WebUI 重新设计（版本徽标/圆角卡片/渐变按钮/错误 Toast 仅抽 ERR 行）；升级迁移：upgrade_init 清除任意旧版本 `.upgrade_migrated_v*`；cmd_apply 新增 upgrade_migration_cleanup_and_recreate（清 BACKUP_DIR 遗留 + APPDATA_DIR 备份副本 + stray `*.fndesk.orig` + 自愈损坏 icons.json + 精准剥离 v1.x 旧注入）；保留 v1.2.0 四道 nginx 断开连接防线 |
| **1.2.0** | 【致命修复】任何写入操作都导致飞牛桌面断开连接根因：`trim_nginx.service` 内置监听器对 `/usr/trim/www/index.html` 任何写入执行完整 STOP+START → WebSocket 心跳超时。四道防线：① `runtime_injection_is_current` 幂等前置拦截（99% 调用 0 写盘）；② `safe_install_file` cmp 字节比较前置；③ 写入改 /tmp+原子 mv；④ 仅 idx_changed||js_changed 才 reload（避免 STOP+START） |
| **1.1.19** | v1.1.18 fpk 打包兼容性修复（Tar GNU magic / Gzip 头 FNAME+best+OS=0xFF / entry 顺序 / 补齐 5 个 cmd 生命周期脚本）；推送至 GitHub 并创建 release |
| **1.1.18** | 修复「删除任一图标后其它图标全部损坏」：remove_icon 末 jq 多写 to_entries 导致三层嵌套（标题/跳转/图片丢失）；新增 normalize_icons_json 自愈损坏结构并自动发布修复生效 |
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

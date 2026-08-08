# Changelog

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

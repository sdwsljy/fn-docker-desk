#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
飞牛桌面图标 v1.1.7 - Web 管理界面
================================
把 Docker 容器应用一键添加到飞牛桌面的管理面板。

v0.4 新增：
- 添加图标支持自定义名称 / 端口号 / 图标 URL
- 修改飞牛系统文件前自动备份，可查看备份列表
- 一键恢复到原始飞牛桌面按钮
- 支持两种打开方式：飞牛桌面图标内部打开、外部浏览器通过端口访问

纯 Python 标准库实现，无第三方依赖。通过调用主脚本
（usr-local-linker 注册的 /usr/local/bin/fn-docker-desk，或 target/bin 入口）完成实际操作。

用法:
    python3 web.py --port <应用内部端口>

API:
    GET  /                  管理页面
    GET  /api/containers    运行中容器列表
    GET  /api/icons         当前桌面图标列表
    GET  /api/backups       系统文件备份列表
    GET  /api/ip            NAS IP
    POST /api/add           添加图标（container/name/port/icon）
    POST /api/remove?id=    移除图标
    POST /api/apply         应用配置
    POST /api/restore       一键还原原始飞牛桌面
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

# 飞牛 fnOS 官方路径规范（始终通过 TRIM_* 环境变量访问）：
#   TRIM_APPDEST = /var/apps/{appname}/target   : 运行文件（升级覆盖）
#   TRIM_PKGVAR  = /var/apps/{appname}/var      : 持久数据（升级保留）
#   TRIM_PKGETC  = /var/apps/{appname}/etc      : 配置目录
# 当在非生命周期上下文（如 pytest、手动调式）中运行时，提供默认兜底。
_APPNAME = "fn-docker-desk"
_APP_ROOT = os.path.dirname(os.environ.get("TRIM_PKGMETA") or f"/var/apps/{_APPNAME}/meta")
_PKG_APP = os.environ.get("TRIM_APPDEST") or os.path.join(_APP_ROOT, "target")
_PKG_VAR = os.environ.get("TRIM_PKGVAR") or os.path.join(_APP_ROOT, "var")
_PKG_ETC = os.environ.get("TRIM_PKGETC") or os.path.join(_APP_ROOT, "etc")

# CLI 入口：优先用 usr-local-linker 注册的稳定命令（官方 /usr/local/bin），再兜底 target/bin
SCRIPT = "/usr/local/bin/" + _APPNAME
if not os.path.exists(SCRIPT):
    SCRIPT = os.path.join(_PKG_APP, "bin", _APPNAME)

# 用户持久数据（官方：TRIM_PKGVAR）
CONF = os.path.join(_PKG_VAR, "icons.json")
BACKUP_DIR = os.path.join(_PKG_VAR, "backup")
ICON_DIR = os.path.join(_PKG_VAR, "icons")
# 桌面端读取的发布配置（etc 下更规范）
DEST_JSON = os.path.join(_PKG_ETC, "desktop.json")

LOG_FILE = "/var/log/fn-docker-desk.log"
DEFAULT_PORT = 5558
APP_VERSION = "1.2.0"

# 写操作互斥锁：ThreadingHTTPServer 并发请求下保护 icons.json 读改写
WRITE_LOCK = threading.Lock()

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def clean_output(s):
    """去掉脚本输出里的 ANSI 颜色码，便于界面/日志阅读"""
    return ANSI_RE.sub("", s or "")


def valid_icon(icon):
    """图标地址仅允许 http/https 远程地址或本地 icons/ 相对路径（防 file:// / SSRF）"""
    if not icon:
        return True
    return icon.startswith("icons/") or bool(re.match(r"^https?://", icon))


def _is_image(raw):
    """通过 magic bytes 判断是否为常见图片格式（防上传伪装的可执行/任意文件）"""
    if not raw:
        return False
    if raw.startswith(b"\x89PNG\r\n\x1a\n"):
        return True
    if raw.startswith(b"\xff\xd8\xff"):
        return True
    if raw.startswith((b"GIF87a", b"GIF89a")):
        return True
    if raw.startswith(b"BM"):
        return True
    if raw[:4] == b"RIFF" and raw[8:12] == b"WEBP":
        return True
    if raw[:4] in (b"\x00\x00\x01\x00", b"\x00\x00\x02\x00"):
        return True
    head = raw[:512].lstrip().lower()
    if head.startswith(b"<?xml") or head.startswith(b"<svg") or b"<svg" in head:
        return True
    return False


def run_script(*args, timeout=120):
    """调用主脚本，返回 (returncode, output)；输出已剥离 ANSI 色码"""
    try:
        r = subprocess.run(
            ["bash", SCRIPT] + list(args),
            capture_output=True, text=True, timeout=timeout,
        )
        out = clean_output((r.stdout or "") + (r.stderr or ""))
        if r.returncode != 0:
            try:
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write("[web] 命令失败 (%s): %s\n" % (" ".join(args), out[-1500:]))
            except Exception:  # noqa: BLE001
                pass
        return r.returncode, out
    except subprocess.TimeoutExpired:
        return -1, "执行超时（超过 %ds）" % timeout
    except Exception as e:  # noqa: BLE001
        return -1, "执行错误: %s" % e


def get_logs():
    """读取主脚本操作日志尾部（排障用）"""
    try:
        if not os.path.isfile(LOG_FILE):
            return []
        with open(LOG_FILE, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        return lines[-100:]
    except Exception:  # noqa: BLE001
        return []


def get_containers():
    """获取运行中容器列表"""
    try:
        r = subprocess.run(
            ["docker", "ps", "--format", "{{json .}}"],
            capture_output=True, text=True, timeout=15,
        )
        out = []
        for line in r.stdout.strip().splitlines():
            try:
                item = json.loads(line)
                ports_raw = item.get("Ports", "")
                host_port = ""
                m = re.search(r"0\.0\.0\.0:(\d+)->", ports_raw)
                if m:
                    host_port = m.group(1)
                elif re.search(r"(\d+)->", ports_raw):
                    m2 = re.search(r"(\d+)->", ports_raw)
                    host_port = m2.group(1)
                item["HostPort"] = host_port
                item["GuessURL"] = ("http://<NAS_IP>:%s/" % host_port) if host_port else ""
                out.append(item)
            except Exception:  # noqa: BLE001
                continue
        return out
    except Exception:  # noqa: BLE001
        return []


def get_icons():
    """读取当前桌面图标配置（过滤掉管理面板自身图标，仅返回用户自定义/容器图标）"""
    try:
        with open(CONF, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, list):
            return []
        # manager 类型为管理面板自身入口，由 fnOS 应用中心管理，不在面板中展示/管理
        return [i for i in data if (i or {}).get("类型") != "manager"]
    except Exception:  # noqa: BLE001
        return []


def get_backups():
    """列出备份目录内容"""
    try:
        if not os.path.isdir(BACKUP_DIR):
            return []
        files = []
        for f in sorted(os.listdir(BACKUP_DIR), reverse=True):
            p = os.path.join(BACKUP_DIR, f)
            if os.path.isfile(p):
                files.append({"name": f, "size": os.path.getsize(p)})
        return files
    except Exception:  # noqa: BLE001
        return []


def get_nas_ip():
    """获取 NAS 局域网 IP（尽力而为）"""
    try:
        r = subprocess.run(
            ["ip", "-4", "route", "get", "1"],
            capture_output=True, text=True, timeout=5,
        )
        parts = r.stdout.split()
        for i, tok in enumerate(parts):
            if tok == "src" and i + 1 < len(parts):
                ip = parts[i + 1]
                if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
                    return ip
    except Exception:  # noqa: BLE001
        pass
    try:
        r = subprocess.run(
            ["hostname", "-I"],
            capture_output=True, text=True, timeout=5,
        )
        for ip in r.stdout.split():
            if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip) and not ip.startswith("127."):
                return ip
    except Exception:  # noqa: BLE001
        pass
    return ""


PAGE_TEMPLATE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>飞牛桌面图标 - 管理面板 v__APP_VERSION__</title>
<style>
:root {
  --bg0:#070a10; --bg1:#0a0f17; --panel:#0c131f;
  --card:rgba(16,24,38,.68); --card2:#121c2c; --card3:#182438;
  --line:#1c2a40; --line2:#2a3d5c;
  --txt:#dbe7f6; --dim:#7187a8; --faint:#46597a;
  --acc:#22c7ee; --acc2:#2dd4a7; --ok:#34d399; --warn:#fbbf24; --err:#f87171;
  --mono:ui-monospace,"Cascadia Code","JetBrains Mono",Consolas,"Courier New",monospace;
  --sans:-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei","Noto Sans CJK SC",sans-serif;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { min-height: 100%; }
body {
  background:
    radial-gradient(900px 480px at 12% -8%, rgba(34,199,238,.10), transparent 60%),
    radial-gradient(820px 460px at 96% 0%, rgba(45,212,167,.08), transparent 55%),
    linear-gradient(var(--bg0), var(--bg1));
  background-attachment: fixed;
  color: var(--txt);
  font-family: var(--sans);
}
body::before {
  content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 0;
  background-image:
    linear-gradient(rgba(120,160,220,.05) 1px, transparent 1px),
    linear-gradient(90deg, rgba(120,160,220,.05) 1px, transparent 1px);
  background-size: 34px 34px;
  -webkit-mask-image: radial-gradient(ellipse at 50% 0%, #000 25%, transparent 82%);
  mask-image: radial-gradient(ellipse at 50% 0%, #000 25%, transparent 82%);
}
.shell { position: relative; z-index: 1; max-width: 1180px; margin: 26px auto 48px; padding: 0 16px; }
.term { background: var(--panel); border: 1px solid var(--line); border-radius: 16px; overflow: hidden; box-shadow: 0 26px 80px rgba(0,0,0,.5); }
.term-bar { display: flex; align-items: center; gap: 12px; padding: 12px 18px; background: linear-gradient(#131c2c, #0e1624); border-bottom: 1px solid var(--line); }
.dots { display: flex; gap: 7px; flex-shrink: 0; }
.dots i { width: 11px; height: 11px; border-radius: 50%; }
.dots i:nth-child(1) { background: #ff5f57; } .dots i:nth-child(2) { background: #febc2e; } .dots i:nth-child(3) { background: #28c840; }
.term-title { font-family: var(--mono); font-size: 12.5px; color: var(--dim); letter-spacing: .02em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.term-title b { color: var(--acc2); font-weight: 600; }
.term-title .ver { color: var(--acc); background: rgba(34,199,238,.1); border: 1px solid rgba(34,199,238,.25); padding: 1px 7px; border-radius: 8px; font-size: 11px; margin-left: 6px; }
.term-addr { margin-left: auto; font-family: var(--mono); font-size: 12px; color: var(--faint); flex-shrink: 0; }
.term-addr b { color: var(--acc2); font-weight: 500; }
.term-body { padding: 20px 22px 26px; }
.stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 14px; }
@media (max-width: 720px) { .stats { grid-template-columns: repeat(2, 1fr); } }
.stat { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; position: relative; overflow: hidden; transition: border-color .2s, transform .2s; }
.stat:hover { border-color: var(--line2); transform: translateY(-2px); }
.stat::before { content: ""; position: absolute; left: 0; top: 0; bottom: 0; width: 3px; background: var(--tc, var(--acc)); box-shadow: 0 0 12px var(--tc, var(--acc)); }
.stat .label { font-size: 11px; color: var(--dim); letter-spacing: .1em; }
.stat .num { font-family: var(--mono); font-size: 25px; font-weight: 700; margin-top: 5px; color: var(--txt); }
.stat .num small { font-size: 12px; color: var(--faint); font-weight: 500; }
.stat .svc { font-family: var(--mono); font-size: 15px; font-weight: 700; margin-top: 10px; color: var(--ok); }
.tools { display: flex; gap: 10px; flex-wrap: wrap; margin: 18px 0; }
.btn { border: 1px solid transparent; border-radius: 9px; padding: 9px 17px; font-size: 13px; cursor: pointer; transition: all .18s; font-weight: 500; font-family: var(--sans); }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn-primary { background: linear-gradient(135deg, #16a9d6, #12b8a8); color: #04121c; font-weight: 700; box-shadow: 0 6px 22px rgba(34,199,238,.25); }
.btn-primary:hover:not(:disabled) { filter: brightness(1.12); transform: translateY(-1px); }
.btn-primary:active:not(:disabled) { transform: translateY(0); }
.btn-ghost { background: var(--card2); color: var(--txt); border-color: var(--line); }
.btn-ghost:hover:not(:disabled) { border-color: var(--acc); color: var(--acc); }
.btn-danger { background: transparent; color: var(--err); border-color: rgba(248,113,113,.4); }
.btn-danger:hover:not(:disabled) { background: rgba(248,113,113,.1); }
.btn-sm { padding: 5px 11px; font-size: 12px; border-radius: 7px; }
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }
@media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px 18px 14px; backdrop-filter: blur(6px); }
.card-h { display: flex; align-items: center; gap: 9px; margin-bottom: 14px; }
.card-t { font-size: 14.5px; font-weight: 600; letter-spacing: .02em; }
.card-t::before { content: "// "; color: var(--acc); font-family: var(--mono); }
.chip { font-size: 11px; color: var(--acc2); background: rgba(45,212,167,.1); border: 1px solid rgba(45,212,167,.22); padding: 1px 8px; border-radius: 20px; font-family: var(--mono); }
.item { display: flex; align-items: center; gap: 12px; padding: 10px 12px; border-radius: 10px; background: var(--card2); border: 1px solid transparent; margin-bottom: 8px; transition: border-color .18s, background .18s; animation: rise .3s ease both; }
.item:hover { border-color: var(--line2); background: var(--card3); }
.item .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ok); flex-shrink: 0; box-shadow: 0 0 8px rgba(52,211,153,.7); }
.item .ic { width: 38px; height: 38px; border-radius: 9px; overflow: hidden; flex-shrink: 0; background: #0b1320; border: 1px solid var(--line); display: flex; align-items: center; justify-content: center; }
.item .ic img { width: 100%; height: 100%; object-fit: cover; }
.item .info { flex: 1; min-width: 0; }
.item .info .name { font-size: 14px; font-weight: 600; font-family: var(--mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.item .info .meta { font-size: 11.5px; color: var(--dim); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: var(--mono); }
.badge { font-family: var(--mono); font-size: 11px; color: var(--acc); background: rgba(34,199,238,.1); border: 1px solid rgba(34,199,238,.22); padding: 2px 8px; border-radius: 20px; flex-shrink: 0; }
.badge.off { color: var(--faint); background: transparent; border-color: var(--line); }
.item .ops { display: flex; gap: 6px; flex-shrink: 0; }
.empty { color: var(--dim); font-size: 13px; text-align: center; padding: 26px 0; font-family: var(--mono); }
.bakitem { display: flex; align-items: center; gap: 10px; padding: 8px 12px; border-radius: 8px; background: var(--card2); margin-bottom: 6px; font-size: 12px; animation: rise .3s ease both; }
.bakitem .bname { flex: 1; font-family: var(--mono); color: #8fd8b8; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.bakitem .bsize { color: var(--dim); font-family: var(--mono); font-size: 11px; }
.backup-card { margin-top: 16px; }
.hint { font-size: 11px; color: var(--dim); margin-top: 8px; line-height: 1.7; }
.hint code { color: var(--acc2); font-family: var(--mono); }
.log-card { margin-bottom: 18px; }
.logbox { background: #080d15; border: 1px solid var(--line); border-radius: 10px; padding: 12px; font-family: var(--mono); font-size: 12px; line-height: 1.65; color: #7fd8b0; max-height: 320px; overflow: auto; white-space: pre-wrap; word-break: break-all; }
.tip { display: flex; align-items: flex-start; gap: 10px; background: rgba(34,199,238,.06); border: 1px solid rgba(34,199,238,.18); border-radius: 10px; padding: 11px 15px; margin-bottom: 18px; font-size: 12px; color: var(--dim); line-height: 1.7; }
.tip .tmark { font-family: var(--mono); color: var(--acc); flex-shrink: 0; }
.tip b { color: var(--txt); font-weight: 600; }
.tip code { color: var(--acc2); font-family: var(--mono); }
.modal-mask { position: fixed; inset: 0; background: rgba(4,8,14,.7); backdrop-filter: blur(4px); display: none; align-items: center; justify-content: center; z-index: 100; }
.modal-mask.show { display: flex; animation: fadein .18s ease both; }
.modal { background: var(--panel); border: 1px solid var(--line2); border-radius: 16px; width: 440px; max-width: 92vw; padding: 22px; box-shadow: 0 30px 90px rgba(0,0,0,.6); animation: pop .22s ease both; }
.modal-h { font-size: 15px; font-weight: 700; margin-bottom: 18px; font-family: var(--mono); }
.modal-h .term-sym { color: var(--acc2); margin-right: 4px; }
.form-row { margin-bottom: 14px; }
.form-row > label { display: block; font-size: 11.5px; color: var(--dim); margin-bottom: 6px; letter-spacing: .04em; }
.form-row input[type="text"] { width: 100%; background: var(--card2); border: 1px solid var(--line); border-radius: 9px; padding: 10px 13px; color: var(--txt); font-size: 13px; outline: none; font-family: var(--mono); transition: border-color .18s, box-shadow .18s; }
.form-row input[type="text"]:focus { border-color: var(--acc); box-shadow: 0 0 0 3px rgba(34,199,238,.12); }
.form-row input[disabled] { opacity: .55; }
.form-row .hint { font-size: 11px; color: var(--faint); margin-top: 5px; }
.radio-item { display: flex; align-items: center; gap: 9px; font-size: 13px; cursor: pointer; padding: 7px 10px; border-radius: 8px; margin-bottom: 4px; transition: background .15s; }
.radio-item:hover { background: var(--card2); }
.radio-item input { accent-color: var(--acc); }
.modal-ops { display: flex; justify-content: flex-end; gap: 10px; margin-top: 20px; }
#toast { position: fixed; bottom: 28px; left: 50%; transform: translate(-50%, 16px); background: #0d1522; color: var(--txt); padding: 11px 20px; border-radius: 11px; font-size: 13px; opacity: 0; pointer-events: none; z-index: 999; max-width: 82vw; box-shadow: 0 12px 44px rgba(0,0,0,.55); border: 1px solid var(--line2); font-family: var(--mono); transition: opacity .22s, transform .22s; }
#toast.show { opacity: 1; transform: translate(-50%, 0); }
#toast.ok { border-left: 3px solid var(--ok); }
#toast.err { border-left: 3px solid var(--err); }
.spin { display: inline-block; width: 13px; height: 13px; border: 2px solid rgba(255,255,255,.35); border-top-color: #fff; border-radius: 50%; animation: r .7s linear infinite; vertical-align: -2px; }
@keyframes r { to { transform: rotate(360deg); } }
@keyframes rise { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }
@keyframes fadein { from { opacity: 0; } to { opacity: 1; } }
@keyframes pop { from { opacity: 0; transform: scale(.96) translateY(8px); } to { opacity: 1; transform: none; } }
</style>
</head>
<body>
<div class="shell">
  <div class="term">
    <div class="term-bar">
      <div class="dots"><i></i><i></i><i></i></div>
      <div class="term-title"><b>fn-docker-desk</b> · 桌面图标管理 <span class="ver">v__APP_VERSION__</span></div>
      <div class="term-addr">NAS&nbsp;<b id="externalUrl">检测中…</b></div>
    </div>
    <div class="term-body">
      <div class="stats">
        <div class="stat" style="--tc:#22c7ee"><div class="label">RUNNING 容器</div><div class="num" id="cCount">0</div></div>
        <div class="stat" style="--tc:#2dd4a7"><div class="label">桌面图标</div><div class="num" id="iCount">0</div></div>
        <div class="stat" style="--tc:#fbbf24"><div class="label">系统备份</div><div class="num" id="bCount">0</div></div>
        <div class="stat" style="--tc:#34d399"><div class="label">服务状态</div><div class="svc" id="svcState">● 运行中</div></div>
      </div>

      <div class="tools">
        <button class="btn btn-primary" onclick="openCustom()">自定义图标</button>
        <button class="btn btn-ghost" onclick="doApi('apply','应用配置')">应用配置</button>
        <button class="btn btn-ghost" onclick="showLogs()">查看日志</button>
        <button class="btn btn-ghost" onclick="refreshAll()">刷新</button>
        <button class="btn btn-danger" onclick="doRestore()">一键还原原始桌面</button>
      </div>

      <div class="card log-card" id="logCard" style="display:none">
        <div class="card-h"><span class="card-t">操作日志</span><span class="chip">tail -100</span></div>
        <div class="logbox" id="logs"><div class="empty">日志加载中...</div></div>
        <div class="hint">对应 NAS 文件：<code>/var/log/fn-docker-desk.log</code>（web 请求见 <code>/var/log/fn-docker-desk-web.log</code>）</div>
      </div>

      <div class="tip"><span class="tmark">$</span><span>添加图标后若桌面未显示，请<b>强制刷新飞牛桌面页面</b>（浏览器 Ctrl+Shift+R）。仍不显示请在 F12 控制台查看 <code>fn-docker-desk</code> 日志。</span></div>

      <div class="grid">
        <div class="card">
          <div class="card-h"><span class="card-t">运行中的容器</span><span class="chip" id="cChip">0</span></div>
          <div id="containers"><div class="empty">加载中...</div></div>
        </div>
        <div class="card">
          <div class="card-h"><span class="card-t">桌面图标</span><span class="chip" id="iChip">0</span></div>
          <div id="icons"><div class="empty">加载中...</div></div>
          <div class="card backup-card">
            <div class="card-h"><span class="card-t">系统文件备份</span><span class="chip" id="bChip">0</span></div>
            <div id="backups"><div class="empty">暂无备份</div></div>
            <div class="hint">修改飞牛系统文件前自动备份，还原后可在此查看。</div>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>

<!-- 添加图标弹窗 -->
<div class="modal-mask" id="modal" onclick="if(event.target===this)closeModal()">
  <div class="modal">
    <div class="modal-h"><span class="term-sym">›</span> 添加到飞牛桌面</div>
    <input type="hidden" id="fContainer">
    <div class="form-row">
      <label>容器名</label>
      <input type="text" id="fContainerShow" disabled>
    </div>
    <div class="form-row">
      <label>图标名称（桌面显示标题）</label>
      <input type="text" id="fName" placeholder="例如：我的影视">
      <div class="hint">留空则使用容器名</div>
    </div>
    <div class="form-row">
      <label>端口号</label>
      <input type="text" id="fPort" placeholder="例如：8080">
      <div class="hint">留空则自动识别容器映射端口</div>
    </div>
    <div class="form-row">
      <label>图标来源</label>
      <label class="radio-item"><input type="radio" name="iconMode" value="auto" checked onchange="toggleIconMode()"> 自动提取容器图标</label>
      <label class="radio-item"><input type="radio" name="iconMode" value="upload" onchange="toggleIconMode()"> 上传本地图片</label>
      <label class="radio-item"><input type="radio" name="iconMode" value="custom" onchange="toggleIconMode()"> 自定义图标 URL</label>
      <input type="text" id="fIcon" placeholder="https://example.com/icon.png" style="margin-top:8px;display:none">
      <div id="uploadRow" style="margin-top:8px;display:none">
        <input type="file" id="fIconFile" accept="image/*" onchange="uploadIconFile()">
        <div class="hint">自动缩放为 256x256 PNG</div>
      </div>
      <div class="hint" id="iconHint">自动提取：容器内 favicon → Web favicon → 内置图标库 → 占位图标</div>
    </div>
    <div class="modal-ops">
      <button class="btn btn-ghost" onclick="closeModal()">取消</button>
      <button class="btn btn-primary" id="fSubmit" onclick="submitAdd()">添加到桌面</button>
    </div>
  </div>
</div>

<!-- 自定义图标弹窗 -->
<div class="modal-mask" id="customModal" onclick="if(event.target===this)closeCustom()">
  <div class="modal">
    <div class="modal-h"><span class="term-sym">›</span> 自定义桌面图标</div>
    <div class="form-row">
      <label>图标名称（桌面显示标题）</label>
      <input type="text" id="cName" placeholder="例如：我的网盘">
    </div>
    <div class="form-row">
      <label>链接地址（点击图标跳转）</label>
      <input type="text" id="cUrl" placeholder="http://192.168.31.200:8080/">
      <div class="hint">必须以 http:// 或 https:// 开头</div>
    </div>
    <div class="form-row">
      <label>图标图片 URL（可选）</label>
      <input type="text" id="cIcon" placeholder="https://example.com/icon.png">
      <div class="hint">留空则自动生成首字母占位图标；图片会下载保存到本地</div>
    </div>
    <div class="modal-ops">
      <button class="btn btn-ghost" onclick="closeCustom()">取消</button>
      <button class="btn btn-primary" id="cSubmit" onclick="submitCustom()">添加到桌面</button>
    </div>
  </div>
</div>

<div id="toast"></div>

<script>
let editingContainer = null;

async function api(path, opts) {
  let r;
  try {
    r = await fetch(path, opts);
  } catch (e) {
    return { ok: false, output: '网络请求失败: ' + e.message };
  }
  let text = '';
  try {
    text = await r.text();
  } catch (e) {
    return { ok: false, output: '读取响应失败: ' + e.message };
  }
  try {
    return JSON.parse(text);
  } catch (e) {
    // 后端返回非 JSON（例如 Python 默认 500 HTML 错误页），打包成错误对象
    const snippet = text.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);
    return {
      ok: false,
      output: '后端响应异常（HTTP ' + r.status + '）：' + (snippet || '空响应') + '，请查看 /var/log/fn-docker-desk.log'
    };
  }
}

function toast(msg, type) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'show ' + (type || 'ok');
  setTimeout(() => { t.className = ''; }, 3200);
}

/**
 * 从后端 output（含多行 [INFO]/[WARN]/[ERR] 混合日志）中抽取真正的失败原因：
 * - 仅保留 [ERR]/[ERROR]/error:/Error:/Exception:/Traceback 等错误线索行
 * - 剥离 [INFO]/[WARN] 成功性提示，避免「移除失败：[INFO] 已移除: 3 ...」这种误导
 * - 没发现错误线索时，给用户清晰的兜底文案 + 日志路径
 */
function failReason(output, fallback) {
  const raw = String(output == null ? '' : output);
  if (!raw) return fallback || '后端返回异常，请查看 /var/log/fn-docker-desk.log';
  const errLines = raw.split(/\r?\n/).filter(line => {
    const s = line.trim();
    if (!s) return false;
    if (/^\[(ERR|ERROR|FATAL)\]/i.test(s)) return true;
    if (/\b(error|exception|traceback|failed|failure|失败|拒绝|权限)\b/i.test(s)) return true;
    return false;
  });
  if (errLines.length === 0) return fallback || '后端返回异常，请查看 /var/log/fn-docker-desk.log';
  return errLines.slice(0, 3).join(' | ');
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function renderContainers(list) {
  const box = document.getElementById('containers');
  document.getElementById('cCount').textContent = list.length;
  document.getElementById('cChip').textContent = list.length;
  if (!list.length) { box.innerHTML = '<div class="empty">没有运行中的容器</div>'; return; }
  box.innerHTML = list.map(c => {
    const name = c.Names || '';
    const img = c.Image || '';
    const port = c.HostPort || '';
    const badge = port ? '<span class="badge">:' + port + '</span>' : '<span class="badge off">无端口</span>';
    return '<div class="item" data-add="' + esc(name) + '"><span class="dot"></span><div class="info"><div class="name">' + esc(name) + '</div><div class="meta">' + esc(img) + '</div></div>' + badge +
           '<div class="ops"><button class="btn btn-primary btn-sm">添加到桌面</button></div></div>';
  }).join('');
}

function renderIcons(list) {
  const box = document.getElementById('icons');
  document.getElementById('iCount').textContent = list.length;
  document.getElementById('iChip').textContent = list.length;
  if (!list.length) { box.innerHTML = '<div class="empty">还没有自定义图标<br>在左侧选择容器「添加到桌面」</div>'; return; }
  box.innerHTML = list.map(it => {
    const seq = it['序号'], title = it['标题'], url = it['跳转URL'], img = it['图片URL'] || '';
    return '<div class="item" data-rm="' + seq + '"><div class="ic"><img src="' + esc(img) + '" onerror="this.style.display=&#39;none&#39;"></div>' +
           '<div class="info"><div class="name">' + esc(title) + '</div><div class="meta">' + esc(url) + '</div></div>' +
           '<div class="ops"><button class="btn btn-danger btn-sm">移除</button></div></div>';
  }).join('');
}

function renderBackups(list) {
  const box = document.getElementById('backups');
  document.getElementById('bCount').textContent = list.length;
  document.getElementById('bChip').textContent = list.length;
  if (!list.length) { box.innerHTML = '<div class="empty">暂无备份（修改系统文件后自动生成）</div>'; return; }
  box.innerHTML = list.map(b => {
    const kb = b.size > 1024 ? (b.size / 1024).toFixed(1) + ' KB' : b.size + ' B';
    return '<div class="bakitem"><span class="bname">' + esc(b.name) + '</span><span class="bsize">' + kb + '</span></div>';
  }).join('');
}

function openModal(name) {
  editingContainer = name;
  uploadedIcon = '';
  document.getElementById('fContainerShow').value = name;
  document.getElementById('fName').value = '';
  document.getElementById('fPort').value = '';
  document.getElementById('fIcon').value = '';
  document.getElementById('fIconFile').value = '';
  const auto = document.querySelector('input[name="iconMode"][value="auto"]');
  if (auto) auto.checked = true;
  toggleIconMode();
  document.getElementById('modal').classList.add('show');
}

let uploadedIcon = '';

function toggleIconMode() {
  const mode = document.querySelector('input[name="iconMode"]:checked');
  const v = mode && mode.value;
  document.getElementById('fIcon').style.display = v === 'custom' ? 'block' : 'none';
  document.getElementById('uploadRow').style.display = v === 'upload' ? 'block' : 'none';
  document.getElementById('iconHint').textContent =
    v === 'custom' ? '使用指定的图标 URL'
    : v === 'upload' ? '选择本地图片，自动缩放为 256x256 PNG 后上传'
    : '自动提取：容器内 favicon → Web favicon → 内置图标库 → 占位图标';
}

function convertBlobToPng(file, maxSize) {
  maxSize = maxSize || 256;
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        let w = img.width, h = img.height;
        if (w > maxSize || h > maxSize) {
          const r = maxSize / Math.max(w, h);
          w = Math.round(w * r); h = Math.round(h * r);
        }
        const canvas = document.createElement('canvas');
        canvas.width = w; canvas.height = h;
        const ctx = canvas.getContext('2d');
        ctx.clearRect(0, 0, w, h);
        ctx.drawImage(img, 0, 0, w, h);
        const tryQuality = (q) => {
          canvas.toBlob(blob => {
            if (!blob) return reject(new Error('PNG 转换失败'));
            if (blob.size > 1048576 && q > 0.1) return tryQuality(q - 0.1);
            resolve(blob);
          }, 'image/png', q);
        };
        tryQuality(1);
      };
      img.onerror = () => reject(new Error('图片加载失败'));
      img.src = reader.result;
    };
    reader.onerror = () => reject(new Error('文件读取失败'));
    reader.readAsDataURL(file);
  });
}

async function uploadIconFile() {
  const file = document.getElementById('fIconFile').files[0];
  if (!file) return;
  try {
    const blob = await convertBlobToPng(file);
    const b64 = await new Promise((res, rej) => {
      const r = new FileReader();
      r.onload = () => res(String(r.result).split(',')[1]);
      r.onerror = () => rej(new Error('编码失败'));
      r.readAsDataURL(blob);
    });
    const name = (editingContainer || 'icon').replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 60);
    const rr = await api('/api/upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: name, data: b64 })
    });
    if (rr.ok) { uploadedIcon = rr.rel; toast('图标已上传：' + rr.rel, 'ok'); }
    else { toast('上传失败：' + failReason(rr.output), 'err'); uploadedIcon = ''; }
  } catch (e) {
    toast('上传失败：' + e.message, 'err');
    uploadedIcon = '';
  }
}

function closeModal() {
  document.getElementById('modal').classList.remove('show');
}

function openCustom() {
  document.getElementById('cName').value = '';
  document.getElementById('cUrl').value = '';
  document.getElementById('cIcon').value = '';
  document.getElementById('customModal').classList.add('show');
}

function closeCustom() {
  document.getElementById('customModal').classList.remove('show');
}

async function submitCustom() {
  const name = document.getElementById('cName').value.trim();
  const url = document.getElementById('cUrl').value.trim();
  const icon = document.getElementById('cIcon').value.trim();
  if (!name) { toast('请输入图标名称', 'err'); return; }
  if (!/^https?:\/\//.test(url)) { toast('链接必须以 http:// 或 https:// 开头', 'err'); return; }
  const btn = document.getElementById('cSubmit');
  btn.disabled = true; btn.innerHTML = '<span class="spin"></span>';
  const q = new URLSearchParams({ title: name, url: url });
  if (icon) q.set('icon', icon);
  const r = await api('/api/add-custom?' + q.toString(), { method: 'POST' });
  btn.disabled = false; btn.textContent = '添加到桌面';
  closeCustom();
  toast(r.ok ? '已添加「' + name + '」，刷新浏览器查看桌面' : '添加失败：' + failReason(r.output), r.ok ? 'ok' : 'err');
  refreshAll();
}

async function submitAdd() {
  const name = document.getElementById('fName').value.trim();
  const port = document.getElementById('fPort').value.trim();
  const mode = document.querySelector('input[name="iconMode"]:checked');
  const v = mode && mode.value;
  const icon = v === 'custom' ? document.getElementById('fIcon').value.trim()
             : v === 'upload' ? uploadedIcon : '';
  if (port && !/^\d+$/.test(port)) { toast('端口号格式无效', 'err'); return; }
  const btn = document.getElementById('fSubmit');
  btn.disabled = true; btn.innerHTML = '<span class="spin"></span>';
  const q = new URLSearchParams({ container: editingContainer });
  if (name) q.set('name', name);
  if (port) q.set('port', port);
  if (icon) q.set('icon', icon);
  const r = await api('/api/add?' + q.toString(), { method: 'POST' });
  btn.disabled = false; btn.textContent = '添加到桌面';
  closeModal();
  toast(r.ok ? '已添加「' + (name || editingContainer) + '」，刷新浏览器查看桌面' : '添加失败：' + failReason(r.output), r.ok ? 'ok' : 'err');
  refreshAll();
}

async function removeIcon(seq) {
  if (!confirm('确认移除图标 #' + seq + ' ？')) return;
  const r = await api('/api/remove?id=' + seq, { method: 'POST' });
  toast(r.ok ? '已移除' : '移除失败：' + failReason(r.output), r.ok ? 'ok' : 'err');
  refreshAll();
}

async function doApi(act, label) {
  const r = await api('/api/' + act, { method: 'POST' });
  toast(r.ok ? label + '完成' : label + '失败：' + failReason(r.output), r.ok ? 'ok' : 'err');
  refreshAll();
}

async function doRestore() {
  if (!confirm('确认一键还原？将移除全部桌面图标注入，并彻底清除应用内的图标设置（图标配置、持久卷备份、配置备份），恢复到原始飞牛系统桌面。还原后应用商城已装应用不受影响；重新启动本应用不会再生成本工具图标，需重新添加图标才会启用。')) return;
  const r = await api('/api/restore', { method: 'POST' });
  toast(r.ok ? '已还原到原始飞牛桌面' : '还原失败：' + failReason(r.output), r.ok ? 'ok' : 'err');
  refreshAll();
}

async function showLogs() {
  const card = document.getElementById('logCard');
  card.style.display = card.style.display === 'none' ? 'block' : 'none';
  if (card.style.display === 'none') return;
  const box = document.getElementById('logs');
  box.innerHTML = '<div class="empty">日志加载中...</div>';
  try {
    const r = await api('/api/logs');
    const arr = (r.logs || []);
    if (!arr.length) { box.textContent = '(暂无日志，执行一次「添加」或「应用配置」后重试)'; return; }
    box.textContent = arr.join('');
    box.scrollTop = box.scrollHeight;
  } catch (e) {
    box.textContent = '日志读取失败：' + e;
  }
}

async function refreshAll() {
  try {
    let cs = {}, ic = {}, bk = {}, ip = {};
    try { cs = await api('/api/containers'); } catch (e) { console.error('containers:', e); }
    try { ic = await api('/api/icons'); } catch (e) { console.error('icons:', e); }
    try { bk = await api('/api/backups'); } catch (e) { console.error('backups:', e); }
    try { ip = await api('/api/ip'); } catch (e) { console.error('ip:', e); }
    const nasIp = (ip && ip.ip) || '';
    document.getElementById('externalUrl').textContent = nasIp ? ('http://' + nasIp + ':5558/') : '请从飞牛桌面图标打开';
    try { renderContainers((cs && cs.list) || []); } catch (e) {
      document.getElementById('containers').innerHTML = '<div class="empty" style="color:var(--err)">渲染失败: ' + esc(e.message) + '</div>';
    }
    try { renderIcons((ic && ic.list) || []); } catch (e) {
      document.getElementById('icons').innerHTML = '<div class="empty" style="color:var(--err)">渲染失败: ' + esc(e.message) + '</div>';
    }
    try { renderBackups((bk && bk.list) || []); } catch (e) {
      document.getElementById('backups').innerHTML = '<div class="empty" style="color:var(--err)">渲染失败: ' + esc(e.message) + '</div>';
    }
  } catch (e) {
    // 全局兜底：refreshAll 任何致命异常都替换「加载中」提示
    console.error('refreshAll fatal:', e);
    const boxes = ['containers', 'icons', 'backups'];
    boxes.forEach(id => {
      const el = document.getElementById(id);
      if (el && el.querySelector('.empty') && el.querySelector('.empty').textContent.indexOf('加载中') !== -1) {
        el.innerHTML = '<div class="empty" style="color:var(--err)">加载失败: ' + esc(e.message) + '<br>请查看 /var/log/fn-docker-desk.log</div>';
      }
    });
  }
}

// 事件委托：data-add（添加到桌面）/ data-rm（移除图标），避免内联 onclick 转义问题
document.addEventListener('click', function (e) {
  var addEl = e.target.closest ? e.target.closest('[data-add]') : null;
  if (addEl) { openModal(addEl.getAttribute('data-add')); return; }
  var rmEl = e.target.closest ? e.target.closest('[data-rm]') : null;
  if (rmEl) { removeIcon(rmEl.getAttribute('data-rm')); return; }
});

refreshAll();
</script>
</body>
</html>
"""

PAGE = PAGE_TEMPLATE.replace("__APP_VERSION__", APP_VERSION)


GATEWAY_PAGE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>飞牛桌面图标 - 入口检测</title>
<style>
:root{--bg:#070a10;--panel:#0c131f;--line:#1c2a40;--txt:#dbe7f6;--dim:#7187a8;--acc:#2dd4a7;--mono:ui-monospace,"Cascadia Code",Consolas,monospace}
*{box-sizing:border-box;margin:0;padding:0}
body{background:radial-gradient(700px 400px at 50% -10%,rgba(45,212,167,.12),transparent 60%),linear-gradient(var(--bg),#0a0f17);color:var(--txt);font-family:var(--mono);min-height:100vh;display:flex;align-items:center;justify-content:center}
.box{width:min(640px,92vw);background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:30px;box-shadow:0 30px 90px rgba(0,0,0,.5)}
.bar{display:flex;gap:7px;margin-bottom:22px}
.bar i{width:11px;height:11px;border-radius:50%}
.bar i:nth-child(1){background:#ff5f57}.bar i:nth-child(2){background:#febc2e}.bar i:nth-child(3){background:#28c840}
h1{font-size:17px;margin-bottom:14px}
h1 b{color:var(--acc)}
p{color:var(--dim);line-height:1.8;font-size:13px}
code{color:var(--acc);background:rgba(45,212,167,.08);padding:1px 6px;border-radius:6px;font-size:12px}
.status{margin-top:18px;padding:12px 14px;border-radius:10px;background:#0b1320;border-left:3px solid var(--acc);color:#8fd8b8;font-size:13px}
</style>
<script>
function go(){
  var host = location.hostname || location.host.split(':')[0];
  var target = location.protocol + '//' + host + ':5558/';
  document.getElementById('status').textContent = '正在跳转：' + target;
  if (location.pathname === '/' || location.pathname === '/index.html') return;
  location.replace(target);
}
window.onload = go;
</script>
</head>
<body>
<div class="box">
  <div class="bar"><i></i><i></i><i></i></div>
  <h1><b>fn-docker-desk</b> · 入口检测</h1>
  <p>正在进入管理面板。若没有自动跳转，请外部访问 <code>http://NAS_IP:5558/</code>。</p>
  <div id="status" class="status">准备跳转...</div>
</div>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "fn-docker-desk/" + APP_VERSION

    def _send_error_json(self, code, message):
        """任何未捕获异常都返回 JSON，避免前端 r.json() 崩溃"""
        try:
            body = json.dumps({"ok": False, "output": message}, ensure_ascii=False)
            self._send(code, body)
        except Exception:  # noqa: BLE001
            # 最后兜底：即使 headers 已发送等极端情况，也尝试写日志
            try:
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write("[web] 致命错误，无法发送响应: %s\n" % message)
            except Exception:
                pass

    def handle_error(self, request, client_address):
        """重写 BaseHTTPRequestHandler.handle_error：返回 JSON 500 而非默认 HTML 错误页

        BaseHTTPRequestHandler 在 do_GET/do_POST 抛异常时会调用本方法，
        默认实现是输出一堆 HTML 堆栈，导致前端 r.json() 抛 SyntaxError，
        整个 refreshAll() 被异常吞噬后界面永远卡在「加载中」。
        这里改为：写日志 + 发送 JSON 格式的 500 响应。
        """
        import traceback
        tb = traceback.format_exc()
        # 记录到本地日志文件（便于排查）
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write("[web] HTTP 处理异常 @%s:\n%s\n" % (client_address, tb[-2000:]))
        except Exception:  # noqa: BLE001
            pass
        try:
            # 截取对用户友好的最后一行异常描述
            lines = [l for l in tb.splitlines() if l.strip()][-2:]
            friendly = " | ".join(lines) if lines else "未知异常"
            self._send_error_json(500, "服务器内部错误: " + friendly[:300])
        except Exception:  # noqa: BLE001
            # headers 可能已发送或连接已断，静默失败
            pass

    def _send(self, code, body, ctype="application/json; charset=utf-8", cors=False):
        if isinstance(body, str):
            data = body.encode("utf-8")
        else:
            data = body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        # 仅对注入桌面 JS 需跨域的 /api/icons 放行 CORS；写接口同源访问，
        # 避免 CORS * 叠加无鉴权被跨站驱动式调用
        if cors:
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, obj, cors=False):
        self._send(200, json.dumps(obj, ensure_ascii=False), cors=cors)

    def send_html(self, html):
        self._send(200, html, "text/html; charset=utf-8")

    def _check_origin(self):
        """CSRF 防护：非 GET 请求必须同源（Host 与 Origin/Referer 主机名一致即可）

        - 放宽端口比较：飞牛桌面主站点运行在 :80/:443，而本管理面板运行在 manifest 的
          service_port（默认 5558），从桌面端以 iframe/新窗口打开面板后发起的 XHR
          Origin 与 Host 端口必然不同；严格匹配 netloc 会误杀合法调用。
        - 因此改为：仅比较主机名（hostname 部分，不含端口/用户/密码）。
        - Origin/Referer 缺失时放行（兼容非浏览器或老版本客户端；现代浏览器跨站
          POST 会携带 Origin，无法绕过）。
        - manifest 已声明 disable_authorization_path=true（内网工具无鉴权），
          因此同源校验是阻止跨站驱动式调用的关键防线。
        """
        headers = getattr(self, "headers", None)
        if not headers:
            return True
        host_header = headers.get("Host", "")
        if not host_header:
            return True
        src = headers.get("Origin") or headers.get("Referer") or ""
        if not src:
            return True
        try:
            host_h = urlparse("http://" + host_header).hostname or ""
            host_s = urlparse(src).hostname or ""
        except Exception:  # noqa: BLE001
            return False
        # 主机名一致即放行（忽略端口差异与 IPv4/IPv6 格式差异：urlparse hostname 统一小写）
        return host_h and host_s and host_h.lower() == host_s.lower()

    def do_GET(self):
        """GET 统一入口：外层全局 try-except 兜底，任何异常都返回 JSON 500。

        相比重写 handle_error，在方法内部捕获有两个优势：
        1) 保证 headers 尚未发送时构造完整响应，避免半写导致客户端 RST；
        2) 异常发生时无需依赖 BaseHTTPRequestHandler 的 handle_error 调用时机，
           不同 Python 版本该时机略有差异。
        """
        import traceback
        try:
            self._do_GET_inner()
        except Exception as e:  # noqa: BLE001
            tb = traceback.format_exc()
            try:
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write("[web] do_GET 异常 %s: %s\n%s\n" % (self.path, e, tb[-1500:]))
            except Exception:  # noqa: BLE001
                pass
            try:
                lines = [l for l in tb.splitlines() if l.strip()][-2:]
                friendly = " | ".join(lines) if lines else str(e)
                self._send_error_json(500, "GET 失败: " + friendly[:300])
            except Exception:  # noqa: BLE001
                pass

    def _do_GET_inner(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            self.send_html(PAGE)
        elif u.path == "/index.cgi":
            self.send_html(GATEWAY_PAGE)
        elif u.path == "/api/containers":
            self.send_json({"ok": True, "list": get_containers()})
        elif u.path == "/api/icons":
            self.send_json({"ok": True, "list": get_icons()}, cors=True)
        elif u.path == "/api/backups":
            self.send_json({"ok": True, "list": get_backups()})
        elif u.path == "/api/ip":
            self.send_json({"ok": True, "ip": get_nas_ip()})
        elif u.path == "/api/logs":
            self.send_json({"ok": True, "logs": get_logs()})
        elif u.path.startswith("/icons/"):
            self.serve_icon(u.path)
        else:
            self.send_json({"ok": False, "output": "404"})

    def serve_icon(self, path):
        """提供图标静态文件（仅允许 ICON_DIR 下的单个文件，防路径穿越）"""
        try:
            name = os.path.basename(path)
            if not name or "/" in name.replace("\\", "/"):
                self.send_json({"ok": False, "output": "bad name"})
                return
            fp = os.path.join(ICON_DIR, name)
            if not os.path.isfile(fp):
                self.send_json({"ok": False, "output": "404 icon"})
                return
            ext = os.path.splitext(name)[1].lower()
            ctype = {
                ".svg": "image/svg+xml; charset=utf-8",
                ".png": "image/png",
                ".jpg": "image/jpeg",
                ".jpeg": "image/jpeg",
                ".gif": "image/gif",
                ".webp": "image/webp",
                ".ico": "image/x-icon",
                ".bmp": "image/bmp",
            }.get(ext, "application/octet-stream")
            with open(fp, "rb") as f:
                data = f.read()
            self._send(200, data.decode("utf-8", "replace") if ctype.startswith("image/svg") else data, ctype)
        except Exception as e:  # noqa: BLE001
            self.send_json({"ok": False, "output": str(e)})

    def handle_upload(self):
        """接收 base64 PNG，保存到 TRIM_PKGVAR/icons/（文件名白名单防穿越）"""
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > 3 * 1024 * 1024:
                self._send(400, json.dumps({"ok": False, "output": "请求体为空或超过 3MB"}, ensure_ascii=False))
                return
            body = self.rfile.read(length).decode("utf-8", "replace")
            data = json.loads(body)
            name = str(data.get("name") or "icon")
            if not re.match(r"^[a-zA-Z0-9_-]{1,64}$", name):
                self._send(400, json.dumps({"ok": False, "output": "文件名不合法"}, ensure_ascii=False))
                return
            b64 = str(data.get("data") or "")
            raw = base64.b64decode(b64)
            if not raw:
                self.send_json({"ok": False, "output": "图片数据为空"})
                return
            if not _is_image(raw):
                self.send_json({"ok": False, "output": "非支持的图片格式"})
                return
            os.makedirs(ICON_DIR, exist_ok=True)
            fp = os.path.join(ICON_DIR, name + ".png")
            with open(fp, "wb") as f:
                f.write(raw)
            os.chmod(fp, 0o644)
            rel = "icons/" + name + ".png"
            try:
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write("[web] 图标上传: %s (%d bytes)\n" % (rel, len(raw)))
            except Exception:  # noqa: BLE001
                pass
            self.send_json({"ok": True, "rel": rel})
        except Exception as e:  # noqa: BLE001
            self.send_json({"ok": False, "output": "上传失败: %s" % e})

    def do_POST(self):
        """POST 统一入口：外层全局 try-except 兜底，任何异常都返回 JSON 500。"""
        import traceback
        try:
            self._do_POST_inner()
        except Exception as e:  # noqa: BLE001
            tb = traceback.format_exc()
            try:
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write("[web] do_POST 异常 %s: %s\n%s\n" % (self.path, e, tb[-1500:]))
            except Exception:  # noqa: BLE001
                pass
            try:
                lines = [l for l in tb.splitlines() if l.strip()][-2:]
                friendly = " | ".join(lines) if lines else str(e)
                self._send_error_json(500, "POST 失败: " + friendly[:300])
            except Exception:  # noqa: BLE001
                pass

    def _do_POST_inner(self):
        # CSRF 防护：写接口必须同源（manifest disable_authorization_path=true，
        # 内网工具无鉴权，同源校验是阻止跨站 POST 调用 add/remove/restore 等的关键）
        if not self._check_origin():
            self._send(403, json.dumps({"ok": False, "output": "跨站请求已拦截"}, ensure_ascii=False))
            return
        # 全局请求体大小限制（10MB），防止恶意大 body 占用资源
        # /api/upload 内部另有 3MB 更严格限制
        headers = getattr(self, "headers", None)
        if headers:
            try:
                length = int(headers.get("Content-Length") or 0)
            except (TypeError, ValueError):
                length = 0
            if length > 10 * 1024 * 1024:
                self._send(400, json.dumps({"ok": False, "output": "请求体超过 10MB 限制"}, ensure_ascii=False))
                return
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        if u.path == "/api/upload":
            self.handle_upload()
        elif u.path == "/api/add-custom":
            title = (qs.get("title") or [""])[0].strip()
            url = (qs.get("url") or [""])[0].strip()
            icon = (qs.get("icon") or [""])[0].strip()
            if not title or not url:
                self.send_json({"ok": False, "output": "缺少标题或链接"})
                return
            if not re.match(r"^https?://", url):
                self.send_json({"ok": False, "output": "链接必须以 http:// 或 https:// 开头"})
                return
            if icon and not valid_icon(icon):
                self.send_json({"ok": False, "output": "图标地址仅支持 http/https 或本地 icons/ 路径"})
                return
            args = ["add-custom", "--title", title, "--url", url]
            if icon:
                args += ["--icon", icon]
            with WRITE_LOCK:
                code, out = run_script(*args, timeout=180)
            self.send_json({"ok": code == 0, "output": out[-4000:]})
        elif u.path == "/api/add":
            container = (qs.get("container") or [""])[0].strip()
            if not container:
                self.send_json({"ok": False, "output": "缺少容器名"})
                return
            args = ["add", container]
            name = (qs.get("name") or [""])[0].strip()
            port = (qs.get("port") or [""])[0].strip()
            icon = (qs.get("icon") or [""])[0].strip()
            if icon and not valid_icon(icon):
                self.send_json({"ok": False, "output": "图标地址仅支持 http/https 或本地 icons/ 路径"})
                return
            if name:
                args += ["--name", name]
            if port:
                if not re.match(r"^\d+$", port):
                    self.send_json({"ok": False, "output": "端口号格式无效"})
                    return
                args += ["--port", port]
            if icon:
                args += ["--icon", icon]
            with WRITE_LOCK:
                code, out = run_script(*args, timeout=180)
            self.send_json({"ok": code == 0, "output": out[-4000:]})
        elif u.path == "/api/remove":
            key = (qs.get("id") or [""])[0].strip()
            if not key:
                self.send_json({"ok": False, "output": "缺少序号"})
                return
            with WRITE_LOCK:
                code, out = run_script("remove", key)
            self.send_json({"ok": code == 0, "output": out[-4000:]})
        elif u.path == "/api/apply":
            with WRITE_LOCK:
                code, out = run_script("apply", timeout=180)
            self.send_json({"ok": code == 0, "output": out[-4000:]})
        elif u.path == "/api/restore":
            with WRITE_LOCK:
                code, out = run_script("restore")
            self.send_json({"ok": code == 0, "output": out[-4000:]})
        else:
            self.send_json({"ok": False, "output": "404"})

    def log_message(self, fmt, *args):
        """记录请求日志到 web 日志（nohup 重定向到 /var/log/fn-docker-desk-web.log）"""
        try:
            msg = fmt % args
            if "/api/" in msg and "/api/logs" not in msg:
                print(msg, flush=True)
        except Exception:  # noqa: BLE001
            pass


def main():
    parser = argparse.ArgumentParser(description="飞牛桌面图标 Web 管理面板")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="监听端口")
    parser.add_argument("--host", default="0.0.0.0", help="监听地址")
    args = parser.parse_args()

    try:
        server = ThreadingHTTPServer((args.host, args.port), Handler)
    except OSError as e:
        print("端口 %d 启动失败: %s" % (args.port, e), file=sys.stderr)
        sys.exit(1)

    print("飞牛桌面图标管理面板已启动: http://0.0.0.0:%d/" % args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()

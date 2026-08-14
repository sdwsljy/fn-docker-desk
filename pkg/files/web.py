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
APP_VERSION = "2.0.1"

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
<title>fn-docker-desk · 桌面图标控制台 v__APP_VERSION__</title>
<style>
:root{
  --bg:#05080f; --bg2:#0a1120; --panel:#0e1728; --panel2:#121e33; --panel3:#17243c;
  --line:rgba(90,130,180,.18); --line2:rgba(90,130,180,.34);
  --txt:#e5eefc; --dim:#7f94b3; --faint:#4e6488;
  --cy:#22d3ee; --em:#5ad1ff; --ok:#34d399; --warn:#fbbf24; --err:#f87171; --acc:#7c5cff;
  --ok-bg:rgba(52,211,153,.10); --ok-bd:rgba(52,211,153,.30);
  --warn-bg:rgba(251,191,36,.10); --warn-bd:rgba(251,191,36,.30);
  --err-bg:rgba(248,113,113,.10); --err-bd:rgba(248,113,113,.30);
  --cy-bg:rgba(34,211,238,.08); --cy-bd:rgba(34,211,238,.26);
  --acc-bg:rgba(124,92,255,.10); --acc-bd:rgba(124,92,255,.32);
  --mono:ui-monospace,"Cascadia Code","JetBrains Mono",Consolas,"Courier New",monospace;
  --sans:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei","Noto Sans CJK SC",sans-serif;
  --radius:14px; --radius-lg:18px; --radius-xs:9px;
  --shadow:0 18px 60px rgba(0,0,0,.55), 0 1px 0 rgba(255,255,255,.03) inset;
}
*{box-sizing:border-box;margin:0;padding:0}
html,body{min-height:100%}
body{
  font-family:var(--sans);color:var(--txt);
  background:
    radial-gradient(1100px 520px at -10% -10%, rgba(124,92,255,.18), transparent 55%),
    radial-gradient(980px 520px at 110% 0%, rgba(34,211,238,.16), transparent 55%),
    radial-gradient(720px 720px at 50% 110%, rgba(52,211,153,.08), transparent 60%),
    linear-gradient(180deg, var(--bg), var(--bg2));
  background-attachment:fixed;
  -webkit-font-smoothing:antialiased; text-rendering:optimizeLegibility;
}
body::before{
  content:"";position:fixed;inset:0;pointer-events:none;z-index:0;opacity:.6;
  background-image:
    linear-gradient(rgba(120,160,220,.05) 1px, transparent 1px),
    linear-gradient(90deg, rgba(120,160,220,.05) 1px, transparent 1px);
  background-size:36px 36px;
  -webkit-mask-image:radial-gradient(ellipse at 50% 0%, #000 20%, transparent 85%);
          mask-image:radial-gradient(ellipse at 50% 0%, #000 20%, transparent 85%);
}
.app{position:relative;z-index:1;max-width:1280px;margin:0 auto;padding:18px 18px 42px;min-height:100vh}
.layout{display:grid;grid-template-columns:260px 1fr;gap:18px;align-items:start}
@media (max-width: 900px){ .layout{grid-template-columns:1fr} }

/* ======== SIDEBAR ======== */
.side{
  position:sticky; top:18px;
  background:linear-gradient(180deg, rgba(20,30,52,.78), rgba(14,23,40,.78));
  backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
  border:1px solid var(--line); border-radius:var(--radius-lg);
  padding:16px 14px; box-shadow:var(--shadow);
}
.brand{display:flex;align-items:center;gap:11px;padding:6px 8px 16px;border-bottom:1px solid var(--line)}
.brand-logo{
  width:40px;height:40px;border-radius:12px;flex-shrink:0;
  background:
    radial-gradient(circle at 30% 30%, #6ee7f9 0%, #22d3ee 40%, #7c5cff 100%);
  box-shadow:0 8px 24px rgba(34,211,238,.35), 0 0 0 1px rgba(255,255,255,.12) inset;
  display:flex;align-items:center;justify-content:center;font-family:var(--mono);font-weight:800;color:#021018;font-size:13px;letter-spacing:.5px;
}
.brand-t .t1{font-weight:700;font-size:14px;letter-spacing:.02em}
.brand-t .t2{font-family:var(--mono);font-size:11px;color:var(--dim);margin-top:2px}
.brand-t .t2 b{color:var(--cy);background:var(--cy-bg);border:1px solid var(--cy-bd);padding:1px 7px;border-radius:999px;font-weight:600;margin-left:4px}

.nav{margin-top:12px;display:flex;flex-direction:column;gap:3px}
.nav a{
  display:flex;align-items:center;gap:10px;padding:10px 12px;border-radius:11px;color:var(--dim);cursor:pointer;
  font-size:13.5px;font-weight:500;text-decoration:none;user-select:none;transition:all .18s ease;border:1px solid transparent;
}
.nav a:hover{background:var(--panel2);color:var(--txt);border-color:var(--line)}
.nav a.active{
  color:var(--txt);
  background:linear-gradient(135deg, var(--acc-bg), var(--cy-bg));
  border-color:var(--acc-bd);
  box-shadow:0 0 0 1px rgba(124,92,255,.12) inset;
}
.nav a .ico{width:18px;height:18px;display:inline-flex;align-items:center;justify-content:center;color:inherit;opacity:.9;flex-shrink:0;font-size:15px}
.nav a .num{margin-left:auto;font-family:var(--mono);font-size:11px;background:var(--panel3);padding:1px 8px;border-radius:999px;color:var(--dim);border:1px solid var(--line)}
.nav a.active .num{background:var(--acc-bg);border-color:var(--acc-bd);color:var(--txt)}

.side-actions{margin-top:14px;padding-top:14px;border-top:1px solid var(--line);display:flex;flex-direction:column;gap:8px}
.ver-bar{font-family:var(--mono);font-size:11px;color:var(--faint);padding:10px 8px 2px}
.ver-bar b{color:var(--em);font-weight:600}

/* ======== MAIN ======== */
.main{display:flex;flex-direction:column;gap:18px}

.topbar{
  display:flex;align-items:center;gap:12px;flex-wrap:wrap;
  background:linear-gradient(180deg, rgba(20,30,52,.72), rgba(14,23,40,.72));
  backdrop-filter:blur(12px); -webkit-backdrop-filter:blur(12px);
  border:1px solid var(--line);border-radius:var(--radius-lg);padding:14px 16px;box-shadow:var(--shadow);
}
.hb-icon{
  width:44px;height:44px;border-radius:12px;flex-shrink:0;
  background:
    radial-gradient(circle at 30% 30%, #6ee7f9 0%, #22d3ee 35%, #7c5cff 100%);
  box-shadow:0 8px 24px rgba(34,211,238,.32);
  display:flex;align-items:center;justify-content:center;font-family:var(--mono);font-weight:800;color:#021018;font-size:13px
}
.hb-text{flex:1;min-width:0}
.hb-text .t{font-size:15.5px;font-weight:700}
.hb-text .s{font-family:var(--mono);font-size:11.5px;color:var(--dim);margin-top:2px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.hb-text .s b{color:var(--ok);font-weight:600}
.hb-ops{display:flex;gap:8px;flex-wrap:wrap;flex-shrink:0}

.btn{border:1px solid transparent;border-radius:10px;padding:9px 15px;font-size:13px;cursor:pointer;transition:all .18s;font-weight:600;font-family:var(--sans);display:inline-flex;align-items:center;gap:7px}
.btn:disabled{opacity:.5;cursor:not-allowed}
.btn-pri{
  background:linear-gradient(135deg, #22d3ee 0%, #7c5cff 100%);
  color:#030814;
  box-shadow:0 8px 28px rgba(124,92,255,.35), 0 0 0 1px rgba(255,255,255,.12) inset;
}
.btn-pri:hover:not(:disabled){filter:brightness(1.08);transform:translateY(-1px)}
.btn-ghost{background:var(--panel2);color:var(--txt);border-color:var(--line)}
.btn-ghost:hover:not(:disabled){border-color:var(--cy);color:var(--cy);background:var(--cy-bg)}
.btn-ok{background:var(--ok-bg);color:var(--ok);border-color:var(--ok-bd)}
.btn-ok:hover:not(:disabled){filter:brightness(1.12)}
.btn-warn{background:var(--warn-bg);color:var(--warn);border-color:var(--warn-bd)}
.btn-warn:hover:not(:disabled){filter:brightness(1.1)}
.btn-danger{background:var(--err-bg);color:var(--err);border-color:var(--err-bd)}
.btn-danger:hover:not(:disabled){background:rgba(248,113,113,.16)}
.btn-sm{padding:6px 11px;font-size:12px;border-radius:8px;font-weight:600}
.btn .sp{display:inline-block;width:12px;height:12px;border:2px solid rgba(255,255,255,.35);border-top-color:#fff;border-radius:50%;animation:r .7s linear infinite;vertical-align:-1px}

.stats{display:grid;grid-template-columns:repeat(4, 1fr);gap:14px}
@media (max-width: 900px){ .stats{grid-template-columns:repeat(2,1fr)} }
.stat{
  position:relative;overflow:hidden;
  background:linear-gradient(180deg, rgba(23,36,60,.82), rgba(18,30,51,.82));
  border:1px solid var(--line);border-radius:var(--radius);padding:16px;box-shadow:var(--shadow);
  transition:border-color .2s, transform .2s;
}
.stat:hover{border-color:var(--line2);transform:translateY(-2px)}
.stat::before{content:"";position:absolute;inset:auto auto 0 0;width:100%;height:3px;background:linear-gradient(90deg, var(--tc,var(--cy)), transparent)}
.stat .lbl{font-family:var(--mono);font-size:10.5px;color:var(--dim);letter-spacing:.14em;text-transform:uppercase}
.stat .n{font-family:var(--mono);font-size:26px;font-weight:800;margin-top:7px;color:var(--txt)}
.stat .n small{font-size:12px;color:var(--faint);font-weight:500;margin-left:4px}
.stat .s{margin-top:9px;display:flex;align-items:center;gap:7px;font-size:11.5px;color:var(--dim)}
.stat .s .dot{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 8px var(--ok)}

.section{display:none}
.section.active{display:block;animation:fadeUp .35s ease both}

.card{
  background:linear-gradient(180deg, rgba(23,36,60,.82), rgba(14,23,40,.82));
  border:1px solid var(--line);border-radius:var(--radius-lg);padding:18px;
  box-shadow:var(--shadow);backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);
}
.card-head{display:flex;align-items:center;gap:10px;margin-bottom:16px;flex-wrap:wrap}
.card-t{font-size:15px;font-weight:700;letter-spacing:.01em;display:flex;align-items:center;gap:8px}
.card-t::before{content:"";width:3px;height:14px;border-radius:2px;background:linear-gradient(180deg,var(--cy),var(--acc))}
.badge{font-family:var(--mono);font-size:10.5px;padding:2px 9px;border-radius:999px;border:1px solid var(--cy-bd);background:var(--cy-bg);color:var(--cy);font-weight:600;letter-spacing:.03em}
.badge.ok{border-color:var(--ok-bd);background:var(--ok-bg);color:var(--ok)}
.badge.warn{border-color:var(--warn-bd);background:var(--warn-bg);color:var(--warn)}
.badge.err{border-color:var(--err-bd);background:var(--err-bg);color:var(--err)}
.badge.muted{border-color:var(--line);background:var(--panel2);color:var(--dim)}

/* ======= OVERVIEW tiles ======= */
.tiles{display:grid;grid-template-columns:1fr 1fr;gap:16px}
@media (max-width: 900px){ .tiles{grid-template-columns:1fr} }
.ft{display:flex;gap:12px;align-items:flex-start;padding:14px;background:var(--panel2);border:1px solid var(--line);border-radius:var(--radius);transition:all .18s}
.ft:hover{border-color:var(--line2)}
.ft-ic{width:40px;height:40px;border-radius:11px;display:flex;align-items:center;justify-content:center;flex-shrink:0;font-size:18px}
.ft-ic.cy{background:var(--cy-bg);color:var(--cy)}
.ft-ic.ok{background:var(--ok-bg);color:var(--ok)}
.ft-ic.warn{background:var(--warn-bg);color:var(--warn)}
.ft-ic.err{background:var(--err-bg);color:var(--err)}
.ft .b{font-size:13px;font-weight:600}
.ft .d{font-size:11.5px;color:var(--dim);margin-top:3px;line-height:1.6}

/* ======= LIST ITEMS ======= */
.list{display:flex;flex-direction:column;gap:9px}
.empty{text-align:center;padding:32px 12px;color:var(--dim);font-size:13px;font-family:var(--mono)}
.it{
  display:grid;grid-template-columns:auto 38px 1fr auto;gap:12px;align-items:center;
  padding:12px 14px;background:var(--panel2);border:1px solid var(--line);border-radius:var(--radius);
  transition:all .18s; animation:rise .3s ease both;
}
.it:hover{border-color:var(--line2);background:var(--panel3);transform:translateY(-1px)}
.it .st{width:9px;height:9px;border-radius:50%;flex-shrink:0;background:var(--ok);box-shadow:0 0 10px var(--ok)}
.it .st.off{background:var(--faint);box-shadow:none}
.it .ic{width:38px;height:38px;border-radius:10px;background:#0a1221;border:1px solid var(--line);overflow:hidden;display:flex;align-items:center;justify-content:center;flex-shrink:0}
.it .ic img{width:100%;height:100%;object-fit:cover}
.it .info{min-width:0}
.it .info .n{font-size:13.5px;font-weight:600;font-family:var(--mono);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.it .info .m{font-size:11.5px;color:var(--dim);margin-top:2px;font-family:var(--mono);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.it .ops{display:flex;gap:6px;flex-shrink:0}
.tag{font-family:var(--mono);font-size:10.5px;padding:3px 9px;border-radius:999px;border:1px solid var(--cy-bd);background:var(--cy-bg);color:var(--cy)}
.tag.off{border-color:var(--line);background:transparent;color:var(--faint)}

/* ======= ICONS GRID ======= */
.igrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:14px}
.icard{
  background:var(--panel2);border:1px solid var(--line);border-radius:var(--radius);padding:16px 14px;
  text-align:center;transition:all .2s;cursor:pointer;user-select:none;animation:rise .3s ease both;
}
.icard:hover{border-color:var(--acc-bd);transform:translateY(-3px);box-shadow:0 14px 34px rgba(124,92,255,.22)}
.icard .p{
  width:72px;height:72px;margin:4px auto 12px;border-radius:18px;background:#0a1221;border:1px solid var(--line);
  display:flex;align-items:center;justify-content:center;overflow:hidden;position:relative;
  box-shadow:0 12px 28px rgba(0,0,0,.35);
}
.icard .p img{width:100%;height:100%;object-fit:cover}
.icard .t{font-size:13px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;padding:0 2px}
.icard .u{font-family:var(--mono);font-size:10.5px;color:var(--faint);margin-top:4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.icard .seq{font-family:var(--mono);font-size:10px;color:var(--dim);margin-top:8px}
.icard .row{margin-top:10px;display:flex;justify-content:center;gap:6px}

/* ======= DIAGNOSTICS ======= */
.dlist{display:flex;flex-direction:column;gap:10px}
.drow{display:grid;grid-template-columns:200px 1fr auto;gap:14px;align-items:center;padding:12px 14px;background:var(--panel2);border:1px solid var(--line);border-radius:var(--radius)}
.drow .k{font-family:var(--mono);font-size:12px;color:var(--dim)}
.drow .v{font-family:var(--mono);font-size:12.5px;color:var(--txt);word-break:break-all}
.drow .s{flex-shrink:0}

.tip{
  display:flex;gap:10px;align-items:flex-start;padding:12px 14px;
  background:var(--cy-bg);border:1px solid var(--cy-bd);border-radius:var(--radius);font-size:12.5px;color:var(--txt);line-height:1.75;margin-top:14px
}
.tip .tm{color:var(--cy);font-family:var(--mono);flex-shrink:0;font-weight:700}
.tip b{color:var(--txt)}
.tip code{color:var(--em);font-family:var(--mono);background:rgba(34,211,238,.1);padding:1px 6px;border-radius:6px;font-size:11.5px}

/* ======= LOG ======= */
.tabs{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}
.tab{padding:7px 14px;border-radius:999px;font-size:12px;font-weight:600;cursor:pointer;border:1px solid var(--line);background:var(--panel2);color:var(--dim);transition:all .16s}
.tab.active{background:linear-gradient(135deg,var(--acc-bg),var(--cy-bg));border-color:var(--acc-bd);color:var(--txt)}
.log{
  background:#060b14;border:1px solid var(--line);border-radius:var(--radius);
  padding:14px;min-height:260px;max-height:520px;overflow:auto;font-family:var(--mono);
  font-size:12px;line-height:1.7;color:#8fd8b0;white-space:pre-wrap;word-break:break-all
}
.log::-webkit-scrollbar{width:10px;height:10px}
.log::-webkit-scrollbar-thumb{background:var(--panel3);border-radius:999px}

/* ======= MODAL ======= */
.mask{position:fixed;inset:0;background:rgba(2,6,14,.72);backdrop-filter:blur(6px);-webkit-backdrop-filter:blur(6px);display:none;align-items:center;justify-content:center;z-index:100}
.mask.show{display:flex;animation:fadein .18s ease both}
.mod{
  width:470px;max-width:94vw;background:linear-gradient(180deg, rgba(20,30,52,.98), rgba(14,23,40,.98));
  border:1px solid var(--line2);border-radius:18px;padding:22px 22px 20px;box-shadow:0 36px 100px rgba(0,0,0,.65);
  animation:pop .24s ease both;
}
.mod-h{display:flex;align-items:center;gap:10px;margin-bottom:18px}
.mod-h .b{font-size:15.5px;font-weight:700}
.mod-h .s{font-family:var(--mono);font-size:11px;color:var(--dim);margin-left:auto}
.r{margin-bottom:14px}
.r>label{display:block;font-size:11.5px;color:var(--dim);margin-bottom:6px;letter-spacing:.06em;text-transform:uppercase}
.r input[type="text"]{
  width:100%;background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:10px 13px;color:var(--txt);
  font-size:13px;outline:none;font-family:var(--mono);transition:all .16s
}
.r input[type="text"]:focus{border-color:var(--cy);box-shadow:0 0 0 3px rgba(34,211,238,.12)}
.r input[disabled]{opacity:.55}
.r .h{font-size:11px;color:var(--faint);margin-top:5px;line-height:1.6}
.radio{display:flex;align-items:center;gap:9px;font-size:13px;cursor:pointer;padding:8px 10px;border-radius:9px;transition:background .15s;margin-bottom:3px}
.radio:hover{background:var(--panel3)}
.radio input{accent-color:var(--cy)}
.mops{display:flex;justify-content:flex-end;gap:10px;margin-top:18px;padding-top:14px;border-top:1px solid var(--line)}

/* ======= TOAST ======= */
#toast{
  position:fixed;bottom:30px;left:50%;transform:translate(-50%, 20px);
  background:#0b1322;color:var(--txt);padding:12px 20px;border-radius:12px;font-size:13px;opacity:0;pointer-events:none;z-index:9999;
  max-width:86vw;box-shadow:0 18px 60px rgba(0,0,0,.6);border:1px solid var(--line2);font-family:var(--mono);
  transition:opacity .24s, transform .24s;
}
#toast.show{opacity:1;transform:translate(-50%, 0)}
#toast.ok{border-left:3px solid var(--ok)}
#toast.err{border-left:3px solid var(--err)}
#toast.warn{border-left:3px solid var(--warn)}

@keyframes r{to{transform:rotate(360deg)}}
@keyframes rise{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
@keyframes fadein{from{opacity:0}to{opacity:1}}
@keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
@keyframes pop{from{opacity:0;transform:scale(.96) translateY(8px)}to{opacity:1;transform:none}}
</style>
</head>
<body>
<div class="app">
  <div class="layout">

    <!-- ====== SIDEBAR ====== -->
    <aside class="side">
      <div class="brand">
        <div class="brand-logo">fn<br>dd</div>
        <div class="brand-t">
          <div class="t1">Docker 桌面控制台</div>
          <div class="t2">fn-docker-desk<b>v__APP_VERSION__</b></div>
        </div>
      </div>

      <nav class="nav" id="nav">
        <a data-s="ov" class="active"><span class="ico">◉</span>概览<span class="num" id="navOv">•</span></a>
        <a data-s="ct"><span class="ico">▣</span>运行容器<span class="num" id="navCt">0</span></a>
        <a data-s="ic"><span class="ico">✦</span>桌面图标<span class="num" id="navIc">0</span></a>
        <a data-s="diag"><span class="ico">◎</span>注入诊断<span class="num" id="navDiag">–</span></a>
        <a data-s="lg"><span class="ico">≡</span>操作日志<span class="num" id="navLg">log</span></a>
      </nav>

      <div class="side-actions">
        <button class="btn btn-ghost btn-sm" style="width:100%;justify-content:center" onclick="openCustom()">＋ 自定义图标</button>
        <button class="btn btn-ok btn-sm" style="width:100%;justify-content:center" onclick="doApi('apply','应用配置')">✓ 应用配置</button>
        <button class="btn btn-warn btn-sm" style="width:100%;justify-content:center" onclick="doRestore()">↺ 一键还原</button>
      </div>

      <div class="ver-bar">Built for <b>fnOS</b> · 精准反注入式还原</div>
    </aside>

    <!-- ====== MAIN ====== -->
    <main class="main">

      <div class="topbar">
        <div class="hb-icon">fn</div>
        <div class="hb-text">
          <div class="t">飞牛 Docker 图标管理面板</div>
          <div class="s">NAS&nbsp;<b id="nasIp">检测中…</b> &nbsp;·&nbsp; v2.0 精准反注入式还原，不依赖任何备份</div>
        </div>
        <div class="hb-ops">
          <button class="btn btn-ghost" onclick="showLogs()">≡ 日志</button>
          <button class="btn btn-ghost" onclick="refreshAll()">⟳ 刷新</button>
        </div>
      </div>

      <div class="stats">
        <div class="stat" style="--tc:#22d3ee">
          <div class="lbl">RUNNING 容器</div>
          <div class="n" id="cCount">0</div>
          <div class="s"><span class="dot"></span><span id="cSub">无运行容器</span></div>
        </div>
        <div class="stat" style="--tc:#7c5cff">
          <div class="lbl">桌面图标</div>
          <div class="n" id="iCount">0</div>
          <div class="s"><span class="dot" id="iDot"></span><span id="iSub">还未添加图标</span></div>
        </div>
        <div class="stat" style="--tc:#34d399">
          <div class="lbl">注入状态</div>
          <div class="n" id="injN"><small>检测中…</small></div>
          <div class="s"><span class="dot" id="injDot" style="background:var(--warn);box-shadow:0 0 8px var(--warn)"></span><span id="injSub">等待数据</span></div>
        </div>
        <div class="stat" style="--tc:#fbbf24">
          <div class="lbl">备份条目</div>
          <div class="n" id="bCount">0<small>项</small></div>
          <div class="s"><span class="dot" id="bDot" style="background:var(--faint);box-shadow:none"></span><span id="bSub">v2.0 零备份依赖</span></div>
        </div>
      </div>

      <!-- ===== OVERVIEW ===== -->
      <section class="section active" id="sec-ov">
        <div class="card">
          <div class="card-head">
            <div class="card-t">系统概览</div>
            <span class="badge ok" id="ovBadge">就绪</span>
          </div>
          <div class="tiles" id="ovTiles">
            <div class="ft"><div class="ft-ic cy">✦</div><div>
              <div class="b">精准反注入式还原</div>
              <div class="d">v2.0 彻底移除对 <code style="font-family:var(--mono);color:var(--cy)">runtime.orig / www.zip.fndesk.orig</code> 等备份的依赖。还原仅基于注入 marker 精确剥离，零备份、零误覆盖、不影响应用商城已装应用。</div>
            </div></div>
            <div class="ft"><div class="ft-ic ok">◉</div><div>
              <div class="b">四道防线 · 避免 nginx 重启</div>
              <div class="d">① 版本命中时直接跳过写 /usr/trim/www；② cmp 字节比较；③ /tmp → 原子 mv 落地；④ 仅真变更才 reload。<b>完全避免飞牛桌面断开连接</b>。</div>
            </div></div>
            <div class="ft"><div class="ft-ic warn">▣</div><div>
              <div class="b">运行容器 · 一键添加</div>
              <div class="d">自动识别 Docker 运行中的容器和映射端口；支持自动提取图标、上传自定义图片、或填写 URL，3 步完成桌面图标添加。</div>
            </div></div>
            <div class="ft"><div class="ft-ic err">↺</div><div>
              <div class="b">一键还原 · 无副作用</div>
              <div class="d">仅剥离本工具对 index.html、assets JS、www.zip 注入的条目；保持系统 OTA 完整性；移除持久化开机注入服务；图标数据与持久卷备份一并清理。</div>
            </div></div>
          </div>
          <div class="tip"><span class="tm">TIP</span><span>添加图标后若桌面未显示，请<b>强制刷新飞牛桌面页面</b>（浏览器 <code>Ctrl+Shift+R</code>）。仍不显示请切到「操作日志」Tab 查看 <code>fn-docker-desk</code> 输出，或在飞牛 F12 控制台搜索 <code>fn-docker-desk</code>。</span></div>
        </div>
      </section>

      <!-- ===== CONTAINERS ===== -->
      <section class="section" id="sec-ct">
        <div class="card">
          <div class="card-head">
            <div class="card-t">运行中的容器</div>
            <span class="badge" id="ctBadge">0</span>
          </div>
          <div class="list" id="containers"><div class="empty">加载中...</div></div>
        </div>
      </section>

      <!-- ===== ICONS ===== -->
      <section class="section" id="sec-ic">
        <div class="card">
          <div class="card-head">
            <div class="card-t">桌面图标</div>
            <span class="badge" id="icBadge">0</span>
            <div style="margin-left:auto"><button class="btn btn-pri btn-sm" onclick="openCustom()">＋ 自定义图标</button></div>
          </div>
          <div class="igrid" id="icons"><div class="empty">还没有自定义图标<br>切换到「运行容器」Tab 选择容器「添加到桌面」</div></div>
        </div>
      </section>

      <!-- ===== DIAGNOSTICS ===== -->
      <section class="section" id="sec-diag">
        <div class="card">
          <div class="card-head">
            <div class="card-t">注入诊断</div>
            <span class="badge" id="diagBadge">检测中…</span>
          </div>
          <div class="dlist" id="dlist"></div>
          <div class="tip"><span class="tm">INFO</span><span>v2.0 还原不再依赖任何备份文件。这里显示的是当前运行目录 <code>/usr/trim/www</code> 与源包 <code>/usr/trim/share/.restore/www.zip</code> 内 fn-docker-desk 注入的真实状态。</span></div>
        </div>

        <div class="card" style="margin-top:18px">
          <div class="card-head">
            <div class="card-t">历史备份条目（BACKUP_DIR）</div>
            <span class="badge muted" id="bBadge">0</span>
          </div>
          <div class="list" id="backups"><div class="empty">暂无备份（v2.0 已不再新建备份；旧备份仍在此列出）</div></div>
          <div class="tip"><span class="tm">NOTE</span><span>v2.0 不再创建 <code>index.html.runtime.orig / JS.runtime.orig / www.zip.fndesk.orig / www.zip.fndesk.bak.*</code> 等文件。仅保留旧有备份用于查阅。</span></div>
        </div>
      </section>

      <!-- ===== LOGS ===== -->
      <section class="section" id="sec-lg">
        <div class="card">
          <div class="card-head">
            <div class="card-t">操作日志</div>
            <span class="chip badge muted">tail -100</span>
          </div>
          <div class="log" id="logs"><div class="empty" style="color:var(--dim)">日志加载中...</div></div>
          <div class="tip"><span class="tm">PATH</span><span>NAS 文件路径：<code>/var/log/fn-docker-desk.log</code>（主操作） / <code>/var/log/fn-docker-desk-web.log</code>（Web 面板请求）。</span></div>
        </div>
      </section>

    </main>
  </div>
</div>

<!-- ========== 添加图标 Modal ========== -->
<div class="mask" id="modalAdd" onclick="if(event.target===this)closeModal()"><div class="mod">
  <div class="mod-h"><div class="b" style="display:inline-flex;align-items:center;gap:8px">
    <span style="width:8px;height:8px;border-radius:50%;background:var(--cy);box-shadow:0 0 10px var(--cy)"></span>
    添加到飞牛桌面
  </div><div class="s">from container</div></div>
  <input type="hidden" id="fContainer">
  <div class="r">
    <label>容器名</label>
    <input type="text" id="fContainerShow" disabled>
  </div>
  <div class="r">
    <label>图标名称（桌面显示标题）</label>
    <input type="text" id="fName" placeholder="例如：我的影视">
    <div class="h">留空则使用容器名</div>
  </div>
  <div class="r">
    <label>端口号</label>
    <input type="text" id="fPort" placeholder="例如：8080">
    <div class="h">留空则自动识别容器映射端口</div>
  </div>
  <div class="r">
    <label>图标来源</label>
    <label class="radio"><input type="radio" name="iconMode" value="auto" checked onchange="toggleIconMode()"> 自动提取容器图标</label>
    <label class="radio"><input type="radio" name="iconMode" value="upload" onchange="toggleIconMode()"> 上传本地图片</label>
    <label class="radio"><input type="radio" name="iconMode" value="custom" onchange="toggleIconMode()"> 自定义图标 URL</label>
    <input type="text" id="fIcon" placeholder="https://example.com/icon.png" style="margin-top:8px;display:none;background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:10px 13px;color:var(--txt);font-size:13px;outline:none;font-family:var(--mono);width:100%">
    <div id="uploadRow" style="margin-top:8px;display:none">
      <input type="file" id="fIconFile" accept="image/*" onchange="uploadIconFile()" style="color:var(--dim)">
      <div class="h">自动缩放为 256x256 PNG</div>
    </div>
    <div class="h" id="iconHint">自动提取：容器内 favicon → Web favicon → 内置图标库 → 占位图标</div>
  </div>
  <div class="mops">
    <button class="btn btn-ghost" onclick="closeModal()">取消</button>
    <button class="btn btn-pri" id="fSubmit" onclick="submitAdd()">＋ 添加到桌面</button>
  </div>
</div></div>

<!-- ========== 自定义图标 Modal ========== -->
<div class="mask" id="modalCustom" onclick="if(event.target===this)closeCustom()"><div class="mod">
  <div class="mod-h"><div class="b" style="display:inline-flex;align-items:center;gap:8px">
    <span style="width:8px;height:8px;border-radius:50%;background:var(--acc);box-shadow:0 0 10px var(--acc)"></span>
    自定义桌面图标
  </div><div class="s">standalone</div></div>
  <div class="r">
    <label>图标名称（桌面显示标题）</label>
    <input type="text" id="cName" placeholder="例如：我的网盘">
  </div>
  <div class="r">
    <label>链接地址（点击图标跳转）</label>
    <input type="text" id="cUrl" placeholder="http://192.168.31.200:8080/">
    <div class="h">必须以 http:// 或 https:// 开头</div>
  </div>
  <div class="r">
    <label>图标图片 URL（可选）</label>
    <input type="text" id="cIcon" placeholder="https://example.com/icon.png">
    <div class="h">留空则自动生成首字母占位图标；图片会下载保存到本地</div>
  </div>
  <div class="mops">
    <button class="btn btn-ghost" onclick="closeCustom()">取消</button>
    <button class="btn btn-pri" id="cSubmit" onclick="submitCustom()">＋ 添加到桌面</button>
  </div>
</div></div>

<div id="toast"></div>

<script>
'use strict';

// ========== NAV ==========
function switchSection(id){
  document.querySelectorAll('.section').forEach(s => s.classList.toggle('active', s.id === 'sec-'+id));
  document.querySelectorAll('#nav a').forEach(a => a.classList.toggle('active', a.dataset.s === id));
  if(id === 'lg') showLogsInternal();
  try { localStorage.setItem('fn-dd-sec', id); } catch(e){}
}
document.getElementById('nav').addEventListener('click', (e) => {
  const a = e.target.closest && e.target.closest('a');
  if(a){ switchSection(a.dataset.s); }
});
try {
  const saved = localStorage.getItem('fn-dd-sec');
  if(saved) switchSection(saved);
} catch(e){}

// ========== API ==========
async function api(path, opts) {
  let r;
  try { r = await fetch(path, opts); }
  catch (e) { return { ok: false, output: '网络请求失败: ' + e.message }; }
  let text = '';
  try { text = await r.text(); }
  catch (e) { return { ok: false, output: '读取响应失败: ' + e.message }; }
  try { return JSON.parse(text); }
  catch (e) {
    const snippet = text.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);
    return { ok: false, output: '后端响应异常（HTTP ' + r.status + '）：' + (snippet || '空响应') + '，请查看 /var/log/fn-docker-desk.log' };
  }
}

// ========== TOAST ==========
let toastTimer = null;
function toast(msg, type) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'show ' + (type || 'ok');
  if(toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.className = ''; }, 3400);
}

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

// ========== RENDER: Containers ==========
function renderContainers(list){
  const box = document.getElementById('containers');
  document.getElementById('cCount').textContent = list.length;
  document.getElementById('cChip') && (document.getElementById('cChip').textContent = list.length);
  document.getElementById('ctBadge').textContent = list.length;
  document.getElementById('navCt').textContent = list.length;
  document.getElementById('cSub').textContent = list.length ? ('当前 ' + list.length + ' 个运行中的容器') : '无运行容器';
  if(!list.length){ box.innerHTML = '<div class="empty">没有运行中的容器</div>'; return; }
  box.innerHTML = list.map(c => {
    const name = c.Names || '';
    const img = c.Image || '';
    const port = c.HostPort || '';
    const tag = port ? ('<span class="tag">:' + esc(port) + '</span>') : ('<span class="tag off">无端口</span>');
    return '<div class="it" data-add="'+esc(name)+'"><span class="st"></span><div class="ic" style="background:linear-gradient(135deg,#182438,#0a1221);font-family:var(--mono);font-size:11px;color:var(--acc);font-weight:800">▣</div>'
      +'<div class="info"><div class="n">'+esc(name)+'</div><div class="m">'+esc(img)+'</div></div>'
      +'<div class="ops">'+tag+'<button class="btn btn-pri btn-sm" style="margin-left:6px">＋ 添加</button></div></div>';
  }).join('');
}

// ========== RENDER: Icons ==========
function renderIcons(list){
  const box = document.getElementById('icons');
  document.getElementById('iCount').textContent = list.length;
  document.getElementById('icBadge').textContent = list.length;
  document.getElementById('navIc').textContent = list.length;
  const iDot = document.getElementById('iDot'), iSub = document.getElementById('iSub');
  if(iDot){ iDot.style.background = list.length ? 'var(--acc)' : 'var(--faint)'; iDot.style.boxShadow = list.length ? '0 0 8px var(--acc)' : 'none'; }
  if(iSub){ iSub.textContent = list.length ? ('已设置 ' + list.length + ' 个桌面图标') : '还未添加图标'; }
  if(!list.length){ box.innerHTML = '<div class="empty">还没有自定义图标<br>切换到「运行容器」Tab 选择容器「添加到桌面」</div>'; return; }
  box.innerHTML = list.map(it => {
    const seq = it['序号'], title = it['标题'], url = it['跳转URL'], img = it['图片URL'] || '';
    return '<div class="icard" data-rm="'+seq+'" title="'+esc(url)+'">'
      +'<div class="p"><img src="'+esc(img)+'" onerror="this.style.display=\'none\'"></div>'
      +'<div class="t">'+esc(title)+'</div><div class="u">'+esc(url)+'</div>'
      +'<div class="seq"># '+seq+'</div>'
      +'<div class="row"><button class="btn btn-danger btn-sm">移除</button></div>'
      +'</div>';
  }).join('');
}

// ========== RENDER: Backups (diagnostics) ==========
function renderBackups(list){
  const box = document.getElementById('backups');
  document.getElementById('bCount').textContent = list.length;
  document.getElementById('bBadge').textContent = list.length;
  const bDot = document.getElementById('bDot'), bSub = document.getElementById('bSub');
  if(list.length){
    if(bDot){ bDot.style.background='var(--warn)'; bDot.style.boxShadow='0 0 8px var(--warn)'; }
    if(bSub){ bSub.textContent = '旧备份 '+list.length+' 项（不再新建）'; }
  }else{
    if(bDot){ bDot.style.background='var(--faint)'; bDot.style.boxShadow='none'; }
    if(bSub){ bSub.textContent = 'v2.0 零备份依赖'; }
  }
  if(!list.length){ box.innerHTML = '<div class="empty">暂无备份（v2.0 已不再新建备份；旧备份仍在此列出）</div>'; return; }
  box.innerHTML = list.map(b => {
    let sz;
    if(b.size > 1048576) sz = (b.size / 1048576).toFixed(2) + ' MB';
    else if(b.size > 1024) sz = (b.size / 1024).toFixed(1) + ' KB';
    else sz = b.size + ' B';
    return '<div class="it"><span class="st off"></span><div class="ic" style="background:linear-gradient(135deg,#182438,#0a1221);font-family:var(--mono);font-size:10px;color:var(--warn);font-weight:700">BAK</div>'
      +'<div class="info"><div class="n" style="font-size:12.5px">'+esc(b.name)+'</div><div class="m">'+sz+'</div></div>'
      +'<div class="ops"><span class="tag off">legacy</span></div></div>';
  }).join('');
}

// ========== DIAGNOSTICS (synthesized from logs + backups + IP) ==========
function renderDiagnostics(state){
  // state: { ip, backupsCount, iconsCount, containersCount, lastLog }
  const d = document.getElementById('dlist');
  const nasIp = state.ip || '';
  const items = [];
  // 1  NAS 地址
  items.push({k:'NAS 管理地址', v: nasIp ? ('http://'+esc(nasIp)+':5558/') : '(请从飞牛桌面图标打开)', s:'ok'});
  // 2. 注入版本标记（通过 icons 是否存在 + 有无备份 —— 只能粗估）
  const injVerGuess = (state.iconsCount > 0) ? '疑似已注入 (含 '+state.iconsCount+' 个图标)' : '无图标注入数据';
  items.push({k:'图标数据 (icons.json)', v: esc(injVerGuess), s: state.iconsCount>0?'ok':'warn'});
  // 3. 备份存在性
  if (state.backupsCount > 0) {
    items.push({k:'BACKUP_DIR 备份条目', v: '存在 '+state.backupsCount+' 个遗留备份文件 (v1.x 遗留)', s:'warn'});
  } else {
    items.push({k:'BACKUP_DIR 备份条目', v: '无 (v2.0 零备份依赖)', s:'ok'});
  }
  // 4. 容器健康
  items.push({k:'Docker 运行容器', v: state.containersCount+' 个', s: state.containersCount>0?'ok':'muted'});
  // 5. 最后日志
  const lastLog = (state.lastLog || '').trim();
  const lastSnippet = lastLog ? lastLog.split(/\r?\n/).filter(Boolean).slice(-1)[0].slice(0, 200) : '(暂无日志)';
  const cls = /\[(ERR|ERROR|FATAL)\]|error|失败|exception/i.test(lastSnippet) ? 'err' : 'ok';
  items.push({k:'最后操作线索', v: esc(lastSnippet) || '(暂无日志)', s: cls});

  d.innerHTML = items.map(it => {
    const cls = it.s === 'ok' ? 'ok' : it.s === 'warn' ? 'warn' : it.s === 'err' ? 'err' : 'muted';
    const clsMap = {ok:'✓ OK', warn:'! WARN', err:'✕ ERR', muted:'– ·'};
    return '<div class="drow"><div class="k">'+it.k+'</div><div class="v">'+it.v+'</div><div class="s"><span class="badge '+cls+'">'+clsMap[cls]+'</span></div></div>';
  }).join('');

  // summary badge
  const hasErr = items.some(x => x.s === 'err');
  const hasWarn = items.some(x => x.s === 'warn');
  const b = document.getElementById('diagBadge');
  const injN = document.getElementById('injN');
  const injDot = document.getElementById('injDot');
  const injSub = document.getElementById('injSub');
  if(hasErr){
    b.textContent = '异常'; b.className = 'badge err';
    if(injN){ injN.innerHTML = '异常'; }
    if(injDot){ injDot.style.background = 'var(--err)'; injDot.style.boxShadow = '0 0 8px var(--err)'; }
    if(injSub){ injSub.textContent = '存在错误线索，切换到日志 Tab 排查'; }
  } else if(hasWarn){
    b.textContent = '待确认'; b.className = 'badge warn';
    if(injN){ injN.innerHTML = '待确认<small style="color:var(--faint);font-weight:500">含遗留备份</small>'; }
    if(injDot){ injDot.style.background = 'var(--warn)'; injDot.style.boxShadow = '0 0 8px var(--warn)'; }
    if(injSub){ injSub.textContent = state.iconsCount ? ('已注入 '+state.iconsCount+' 个图标') : '未发现注入数据'; }
  } else {
    b.textContent = '正常'; b.className = 'badge ok';
    if(injN){ injN.innerHTML = '正常'; }
    if(injDot){ injDot.style.background = 'var(--ok)'; injDot.style.boxShadow = '0 0 8px var(--ok)'; }
    if(injSub){ injSub.textContent = state.iconsCount ? ('已注入 '+state.iconsCount+' 个图标') : '未发现注入数据'; }
  }
}

// ========== MODAL: Add Icon ==========
let editingContainer = null;
let uploadedIcon = '';
function openModal(name){
  editingContainer = name;
  uploadedIcon = '';
  document.getElementById('fContainerShow').value = name;
  document.getElementById('fName').value = '';
  document.getElementById('fPort').value = '';
  document.getElementById('fIcon').value = '';
  const f = document.getElementById('fIconFile'); if(f) f.value = '';
  const auto = document.querySelector('input[name="iconMode"][value="auto"]');
  if(auto) auto.checked = true;
  toggleIconMode();
  document.getElementById('modalAdd').classList.add('show');
}
function closeModal(){ document.getElementById('modalAdd').classList.remove('show'); }

function toggleIconMode(){
  const mode = document.querySelector('input[name="iconMode"]:checked');
  const v = mode && mode.value;
  document.getElementById('fIcon').style.display = v === 'custom' ? 'block' : 'none';
  document.getElementById('uploadRow').style.display = v === 'upload' ? 'block' : 'none';
  document.getElementById('iconHint').textContent =
    v === 'custom' ? '使用指定的图标 URL'
    : v === 'upload' ? '选择本地图片，自动缩放为 256x256 PNG 后上传'
    : '自动提取：容器内 favicon → Web favicon → 内置图标库 → 占位图标';
}

function convertBlobToPng(file, maxSize){
  maxSize = maxSize || 256;
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        let w = img.width, h = img.height;
        if(w > maxSize || h > maxSize){ const r = maxSize / Math.max(w, h); w = Math.round(w*r); h = Math.round(h*r); }
        const canvas = document.createElement('canvas');
        canvas.width = w; canvas.height = h;
        const ctx = canvas.getContext('2d');
        ctx.clearRect(0, 0, w, h);
        ctx.drawImage(img, 0, 0, w, h);
        const tryQ = (q) => {
          canvas.toBlob(blob => {
            if(!blob) return reject(new Error('PNG 转换失败'));
            if(blob.size > 1048576 && q > 0.1) return tryQ(q - 0.1);
            resolve(blob);
          }, 'image/png', q);
        };
        tryQ(1);
      };
      img.onerror = () => reject(new Error('图片加载失败'));
      img.src = reader.result;
    };
    reader.onerror = () => reject(new Error('文件读取失败'));
    reader.readAsDataURL(file);
  });
}

async function uploadIconFile(){
  const file = document.getElementById('fIconFile').files[0];
  if(!file) return;
  try{
    const blob = await convertBlobToPng(file);
    const b64 = await new Promise((res, rej) => {
      const r = new FileReader();
      r.onload = () => res(String(r.result).split(',')[1]);
      r.onerror = () => rej(new Error('编码失败'));
      r.readAsDataURL(blob);
    });
    const name = (editingContainer || 'icon').replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 60);
    const rr = await api('/api/upload', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ name: name, data: b64 })
    });
    if(rr.ok){ uploadedIcon = rr.rel; toast('图标已上传：'+rr.rel, 'ok'); }
    else { toast('上传失败：'+failReason(rr.output), 'err'); uploadedIcon = ''; }
  } catch(e){ toast('上传失败：'+e.message, 'err'); uploadedIcon = ''; }
}

async function submitAdd(){
  const name = document.getElementById('fName').value.trim();
  const port = document.getElementById('fPort').value.trim();
  const mode = document.querySelector('input[name="iconMode"]:checked');
  const v = mode && mode.value;
  const icon = v === 'custom' ? document.getElementById('fIcon').value.trim()
             : v === 'upload' ? uploadedIcon : '';
  if(port && !/^\d+$/.test(port)){ toast('端口号格式无效', 'err'); return; }
  const btn = document.getElementById('fSubmit');
  btn.disabled = true; btn.innerHTML = '<span class="sp"></span>处理中';
  const q = new URLSearchParams({ container: editingContainer });
  if(name) q.set('name', name);
  if(port) q.set('port', port);
  if(icon) q.set('icon', icon);
  const r = await api('/api/add?'+q.toString(), { method:'POST' });
  btn.disabled = false; btn.innerHTML = '＋ 添加到桌面';
  closeModal();
  toast(r.ok ? ('已添加「'+(name||editingContainer)+'」，刷新浏览器查看桌面') : ('添加失败：'+failReason(r.output)), r.ok ? 'ok' : 'err');
  refreshAll();
}

// ========== MODAL: Custom Icon ==========
function openCustom(){
  document.getElementById('cName').value = '';
  document.getElementById('cUrl').value = '';
  document.getElementById('cIcon').value = '';
  document.getElementById('modalCustom').classList.add('show');
}
function closeCustom(){ document.getElementById('modalCustom').classList.remove('show'); }

async function submitCustom(){
  const name = document.getElementById('cName').value.trim();
  const url = document.getElementById('cUrl').value.trim();
  const icon = document.getElementById('cIcon').value.trim();
  if(!name){ toast('请输入图标名称', 'err'); return; }
  if(!/^https?:\/\//.test(url)){ toast('链接必须以 http:// 或 https:// 开头', 'err'); return; }
  const btn = document.getElementById('cSubmit');
  btn.disabled = true; btn.innerHTML = '<span class="sp"></span>处理中';
  const q = new URLSearchParams({ title: name, url: url });
  if(icon) q.set('icon', icon);
  const r = await api('/api/add-custom?'+q.toString(), { method:'POST' });
  btn.disabled = false; btn.innerHTML = '＋ 添加到桌面';
  closeCustom();
  toast(r.ok ? ('已添加「'+name+'」，刷新浏览器查看桌面') : ('添加失败：'+failReason(r.output)), r.ok ? 'ok' : 'err');
  refreshAll();
}

// ========== ACTIONS ==========
async function removeIcon(seq){
  if(!confirm('确认移除图标 #'+seq+' ？')) return;
  const r = await api('/api/remove?id='+seq, { method:'POST' });
  toast(r.ok ? '已移除' : ('移除失败：'+failReason(r.output)), r.ok ? 'ok' : 'err');
  refreshAll();
}

async function doApi(act, label){
  const r = await api('/api/'+act, { method:'POST' });
  toast(r.ok ? (label+'完成') : (label+'失败：'+failReason(r.output)), r.ok ? 'ok' : 'err');
  refreshAll();
}

async function doRestore(){
  if(!confirm('【v2.0 精准反注入式还原】将执行以下操作：\n\n• 精准剥离 index.html 内 fn-docker-desk 注入的缓存参数\n• 精准剥离 assets JS 文件尾的 fn-docker-desk 注入代码块\n• 剥离 /usr/trim/share/.restore/www.zip 内对应注入条目\n• 移除开机自启重放服务 (systemd / cron)\n• 清除本工具的图标配置、上传图标、BACKUP_DIR 遗留备份\n\n应用商城已装应用图标不受影响；重新启动本应用不会恢复图标，需重新添加。\n\n确认继续？')) return;
  const r = await api('/api/restore', { method:'POST' });
  toast(r.ok ? '已还原到原始飞牛桌面（零备份依赖）' : ('还原失败：'+failReason(r.output)), r.ok ? 'ok' : 'err');
  refreshAll();
}

function showLogs(){ switchSection('lg'); }

let lastLoadedLogs = null;
async function showLogsInternal(){
  const box = document.getElementById('logs');
  if(lastLoadedLogs !== null){ box.textContent = lastLoadedLogs; return; }
  box.innerHTML = '<div class="empty">日志加载中...</div>';
  try{
    const r = await api('/api/logs');
    const arr = (r.logs || []);
    const txt = arr.length ? arr.join('') : '(暂无日志，执行一次「添加」或「应用配置」后重试)';
    lastLoadedLogs = txt;
    box.textContent = txt;
    box.scrollTop = box.scrollHeight;
  } catch(e){ box.textContent = '日志读取失败：'+e; }
}

// ========== REFRESH ALL ==========
async function refreshAll(){
  lastLoadedLogs = null;
  try{
    let cs = {}, ic = {}, bk = {}, ip = {}, lg = {};
    try { cs = await api('/api/containers'); } catch(e){ console.error('containers:', e); }
    try { ic = await api('/api/icons'); } catch(e){ console.error('icons:', e); }
    try { bk = await api('/api/backups'); } catch(e){ console.error('backups:', e); }
    try { ip = await api('/api/ip'); } catch(e){ console.error('ip:', e); }
    try { lg = await api('/api/logs'); } catch(e){ console.error('logs:', e); }
    const nasIp = (ip && ip.ip) || '';
    document.getElementById('nasIp').textContent = nasIp ? ('http://'+nasIp+':5558/') : '请从飞牛桌面图标打开';
    try { renderContainers((cs && cs.list) || []); } catch(e){
      document.getElementById('containers').innerHTML = '<div class="empty" style="color:var(--err)">渲染失败: '+esc(e.message)+'</div>';
    }
    try { renderIcons((ic && ic.list) || []); } catch(e){
      document.getElementById('icons').innerHTML = '<div class="empty" style="color:var(--err)">渲染失败: '+esc(e.message)+'</div>';
    }
    try { renderBackups((bk && bk.list) || []); } catch(e){
      document.getElementById('backups').innerHTML = '<div class="empty" style="color:var(--err)">渲染失败: '+esc(e.message)+'</div>';
    }
    try{
      renderDiagnostics({
        ip: nasIp,
        backupsCount: ((bk && bk.list) || []).length,
        iconsCount: ((ic && ic.list) || []).length,
        containersCount: ((cs && cs.list) || []).length,
        lastLog: ((lg && lg.logs) || []).join(''),
      });
    } catch(e){
      document.getElementById('dlist').innerHTML = '<div class="empty" style="color:var(--err)">诊断渲染失败: '+esc(e.message)+'</div>';
    }
  } catch(e){
    console.error('refreshAll fatal:', e);
    const boxes = ['containers','icons','backups'];
    boxes.forEach(id => {
      const el = document.getElementById(id);
      if(el){
        const em = el.querySelector('.empty');
        if(em && em.textContent.indexOf('加载中') !== -1){
          el.innerHTML = '<div class="empty" style="color:var(--err)">加载失败: '+esc(e.message)+'<br>请查看 /var/log/fn-docker-desk.log</div>';
        }
      }
    });
  }
}

// ========== EVENT DELEGATION ==========
document.addEventListener('click', (e) => {
  const addEl = e.target.closest && e.target.closest('[data-add]');
  if(addEl){ openModal(addEl.getAttribute('data-add')); return; }
  const rmEl = e.target.closest && e.target.closest('[data-rm]');
  if(rmEl){ removeIcon(rmEl.getAttribute('data-rm')); return; }
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

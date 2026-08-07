"""
Pytest 共享 fixtures —— fn-docker-desk 测试基础设施

为 web.py / build_fpk.py 提供隔离的临时路径和模块加载机制，
避免测试依赖真实的 /usr/fn-docker-desk 等系统路径。
"""
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
PKG_FILES = ROOT / "pkg" / "files"


@pytest.fixture
def web_module(tmp_path, monkeypatch):
    """加载 web.py 并将其路径常量重定向到临时目录，实现测试隔离"""
    conf_dir = tmp_path / "fn-docker-desk"
    conf_dir.mkdir()
    (conf_dir / "icons").mkdir()
    (conf_dir / "backup").mkdir()
    icons_json = conf_dir / "icons.json"
    icons_json.write_text("[]", encoding="utf-8")

    # 临时加入 sys.path 以便 import
    monkeypatch.syspath_prepend(str(PKG_FILES))

    # 移除可能已加载的缓存
    if "web" in sys.modules:
        del sys.modules["web"]

    import web

    # 重定向路径常量到临时目录
    monkeypatch.setattr(web, "CONF", str(icons_json))
    monkeypatch.setattr(web, "ICON_DIR", str(conf_dir / "icons"))
    monkeypatch.setattr(web, "BACKUP_DIR", str(conf_dir / "backup"))
    monkeypatch.setattr(web, "LOG_FILE", str(tmp_path / "test.log"))
    monkeypatch.setattr(web, "SCRIPT", str(conf_dir / "fn-docker-desk.sh"))

    yield web

    # 清理
    if "web" in sys.modules:
        del sys.modules["web"]


@pytest.fixture
def build_module(tmp_path, monkeypatch):
    """加载 build_fpk.py 用于测试"""
    scripts_dir = ROOT / "scripts"
    monkeypatch.syspath_prepend(str(scripts_dir))

    if "build_fpk" in sys.modules:
        del sys.modules["build_fpk"]

    import build_fpk

    yield build_fpk

    if "build_fpk" in sys.modules:
        del sys.modules["build_fpk"]


@pytest.fixture
def sample_icons_json(tmp_path):
    """创建包含示例图标的 icons.json"""
    import json

    data = [
        {"序号": 1, "标题": "Jellyfin", "跳转URL": "http://192.168.1.1:8096/", "图片URL": "icons/jellyfin.svg", "容器名": "jellyfin", "类型": "docker"},
        {"序号": 2, "标题": "Alist", "跳转URL": "http://192.168.1.1:5244/", "图片URL": "icons/alist.svg", "容器名": "alist", "类型": "docker"},
        {"序号": 3, "标题": "飞牛桌面图标", "跳转URL": "http://192.168.1.1:5558/", "图片URL": "icons/manager.svg", "容器名": "", "类型": "manager"},
    ]
    json_file = tmp_path / "icons.json"
    json_file.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return json_file


@pytest.fixture
def mock_docker_ps_output():
    """模拟 docker ps --format '{{json .}}' 的输出"""
    return (
        '{"Names":"jellyfin","Image":"jellyfin/jellyfin:latest","Ports":"0.0.0.0:8096->8096/tcp"}\n'
        '{"Names":"alist","Image":"xhofe/alist:latest","Ports":"0.0.0.0:5244->5244/tcp"}\n'
        '{"Names":"redis","Image":"redis:7","Ports":"6379/tcp"}\n'
    )

"""
web.py 单元测试 —— 飞牛桌面图标管理面板后端

覆盖核心函数：clean_output / get_containers / get_icons / get_backups /
get_nas_ip / get_logs / run_script，以及 HTTP Handler 的关键路由。
"""
import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

ROOT = Path(__file__).resolve().parents[1]


# ==================== clean_output ====================

class TestCleanOutput:
    """ANSI 颜色码清理"""

    def test_strips_ansi_color_codes(self, web_module):
        s = "\033[1;32m[INFO]\033[0m hello"
        assert web_module.clean_output(s) == "[INFO] hello"

    def test_empty_string(self, web_module):
        assert web_module.clean_output("") == ""

    def test_none_input(self, web_module):
        assert web_module.clean_output(None) == ""

    def test_no_ansi_codes(self, web_module):
        assert web_module.clean_output("plain text") == "plain text"

    def test_multiple_ansi_codes(self, web_module):
        s = "\033[1;31m[ERROR]\033[0m \033[1;33m[WARN]\033[0m done"
        assert web_module.clean_output(s) == "[ERROR] [WARN] done"

    def test_strips_complex_ansi(self, web_module):
        s = "\033[38;5;46mgreen\033[0m"
        assert web_module.clean_output(s) == "green"


# ==================== get_icons ====================

class TestGetIcons:
    """图标配置读取与过滤"""

    def test_reads_valid_json(self, web_module, sample_icons_json, monkeypatch):
        monkeypatch.setattr(web_module, "CONF", str(sample_icons_json))
        icons = web_module.get_icons()
        # manager 类型应被过滤
        assert len(icons) == 2
        assert all(i.get("类型") != "manager" for i in icons)

    def test_empty_json_array(self, web_module, tmp_path, monkeypatch):
        f = tmp_path / "empty.json"
        f.write_text("[]", encoding="utf-8")
        monkeypatch.setattr(web_module, "CONF", str(f))
        assert web_module.get_icons() == []

    def test_missing_file_returns_empty(self, web_module, monkeypatch):
        monkeypatch.setattr(web_module, "CONF", "/nonexistent/path/icons.json")
        assert web_module.get_icons() == []

    def test_invalid_json_returns_empty(self, web_module, tmp_path, monkeypatch):
        f = tmp_path / "bad.json"
        f.write_text("{invalid json", encoding="utf-8")
        monkeypatch.setattr(web_module, "CONF", str(f))
        assert web_module.get_icons() == []

    def test_non_list_json_returns_empty(self, web_module, tmp_path, monkeypatch):
        f = tmp_path / "dict.json"
        f.write_text('{"key": "value"}', encoding="utf-8")
        monkeypatch.setattr(web_module, "CONF", str(f))
        assert web_module.get_icons() == []

    def test_filters_manager_type(self, web_module, tmp_path, monkeypatch):
        import json as json_mod
        data = [
            {"序号": 1, "标题": "App1", "类型": "docker"},
            {"序号": 2, "标题": "Manager", "类型": "manager"},
            {"序号": 3, "标题": "App2", "类型": "custom"},
        ]
        f = tmp_path / "icons.json"
        f.write_text(json_mod.dumps(data, ensure_ascii=False), encoding="utf-8")
        monkeypatch.setattr(web_module, "CONF", str(f))
        icons = web_module.get_icons()
        assert len(icons) == 2
        titles = [i["标题"] for i in icons]
        assert "Manager" not in titles


# ==================== get_backups ====================

class TestGetBackups:
    """备份目录列表"""

    def test_empty_dir(self, web_module, tmp_path, monkeypatch):
        d = tmp_path / "backup"
        d.mkdir()
        monkeypatch.setattr(web_module, "BACKUP_DIR", str(d))
        assert web_module.get_backups() == []

    def test_lists_files_with_size(self, web_module, tmp_path, monkeypatch):
        d = tmp_path / "backup"
        d.mkdir()
        (d / "backup1.tar").write_bytes(b"x" * 100)
        (d / "backup2.tar").write_bytes(b"y" * 200)
        monkeypatch.setattr(web_module, "BACKUP_DIR", str(d))
        result = web_module.get_backups()
        assert len(result) == 2
        names = [r["name"] for r in result]
        assert "backup1.tar" in names
        assert "backup2.tar" in names
        for r in result:
            assert "size" in r
            assert isinstance(r["size"], int)

    def test_missing_dir_returns_empty(self, web_module, monkeypatch):
        monkeypatch.setattr(web_module, "BACKUP_DIR", "/nonexistent/backup")
        assert web_module.get_backups() == []


# ==================== get_containers ====================

class TestGetContainers:
    """Docker 容器列表解析"""

    def test_parses_containers_with_ports(self, web_module, mock_docker_ps_output):
        mock_result = MagicMock()
        mock_result.stdout = mock_docker_ps_output
        with patch("subprocess.run", return_value=mock_result):
            containers = web_module.get_containers()
        assert len(containers) == 3
        # jellyfin: 0.0.0.0:8096->8096/tcp
        assert containers[0]["Names"] == "jellyfin"
        assert containers[0]["HostPort"] == "8096"
        assert "8096" in containers[0]["GuessURL"]
        # alist
        assert containers[1]["Names"] == "alist"
        assert containers[1]["HostPort"] == "5244"
        # redis: 6379/tcp (no host port mapping)
        assert containers[2]["Names"] == "redis"
        assert containers[2]["HostPort"] == ""
        assert containers[2]["GuessURL"] == ""

    def test_empty_docker_output(self, web_module):
        mock_result = MagicMock()
        mock_result.stdout = ""
        with patch("subprocess.run", return_value=mock_result):
            assert web_module.get_containers() == []

    def test_docker_command_fails(self, web_module):
        with patch("subprocess.run", side_effect=Exception("docker not found")):
            assert web_module.get_containers() == []

    def test_malformed_json_skipped(self, web_module):
        mock_result = MagicMock()
        mock_result.stdout = '{"Names":"ok"}\n{bad json}\n{"Names":"ok2","Ports":"0.0.0.0:80->80/tcp"}\n'
        with patch("subprocess.run", return_value=mock_result):
            containers = web_module.get_containers()
        # 跳过坏行，保留两条有效记录
        assert len(containers) == 2

    def test_ipv6_port_mapping(self, web_module):
        mock_result = MagicMock()
        mock_result.stdout = '{"Names":"app","Image":"test","Ports":"[::]:3000->3000/tcp"}\n'
        with patch("subprocess.run", return_value=mock_result):
            containers = web_module.get_containers()
        assert len(containers) == 1
        # [::]:3000-> 格式也应能提取端口
        assert containers[0]["HostPort"] == "3000"


# ==================== get_nas_ip ====================

class TestGetNasIp:
    """NAS IP 地址检测"""

    def test_parses_ip_from_route(self, web_module):
        mock_result = MagicMock()
        mock_result.stdout = "1 via 192.168.1.1 dev eth0 src 192.168.1.100 uid 0\n"
        with patch("subprocess.run", return_value=mock_result):
            ip = web_module.get_nas_ip()
        assert ip == "192.168.1.100"

    def test_fallback_to_hostname(self, web_module):
        # ip route 失败，hostname -I 成功
        def side_effect(cmd, **kwargs):
            if "route" in cmd:
                raise Exception("route not available")
            mock = MagicMock()
            mock.stdout = "192.168.1.200 172.17.0.1\n"
            return mock

        with patch("subprocess.run", side_effect=side_effect):
            ip = web_module.get_nas_ip()
        assert ip == "192.168.1.200"

    def test_returns_empty_on_failure(self, web_module):
        with patch("subprocess.run", side_effect=Exception("all failed")):
            assert web_module.get_nas_ip() == ""

    def test_skips_loopback(self, web_module):
        def side_effect(cmd, **kwargs):
            if "route" in cmd:
                raise Exception("no route")
            mock = MagicMock()
            mock.stdout = "127.0.0.1 192.168.1.50\n"
            return mock

        with patch("subprocess.run", side_effect=side_effect):
            ip = web_module.get_nas_ip()
        assert ip == "192.168.1.50"


# ==================== get_logs ====================

class TestGetLogs:
    """日志文件读取"""

    def test_reads_existing_log(self, web_module, tmp_path, monkeypatch):
        log = tmp_path / "test.log"
        log.write_text("line1\nline2\nline3\n", encoding="utf-8")
        monkeypatch.setattr(web_module, "LOG_FILE", str(log))
        logs = web_module.get_logs()
        assert len(logs) == 3
        assert "line1" in logs[0]

    def test_missing_log_returns_empty(self, web_module, monkeypatch):
        monkeypatch.setattr(web_module, "LOG_FILE", "/nonexistent/log")
        assert web_module.get_logs() == []

    def test_tail_100_lines(self, web_module, tmp_path, monkeypatch):
        log = tmp_path / "big.log"
        lines = ["line%d\n" % i for i in range(200)]
        log.write_text("".join(lines), encoding="utf-8")
        monkeypatch.setattr(web_module, "LOG_FILE", str(log))
        logs = web_module.get_logs()
        assert len(logs) == 100
        assert "line199" in logs[-1]


# ==================== run_script ====================

class TestRunScript:
    """主脚本调用封装"""

    def test_successful_execution(self, web_module):
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "[INFO] success"
        mock_result.stderr = ""
        with patch("subprocess.run", return_value=mock_result):
            code, out = web_module.run_script("list")
        assert code == 0
        assert "success" in out

    def test_script_failure(self, web_module):
        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stdout = ""
        mock_result.stderr = "[ERROR] failed"
        with patch("subprocess.run", return_value=mock_result):
            code, out = web_module.run_script("bad-cmd")
        assert code == 1
        assert "failed" in out

    def test_timeout(self, web_module):
        import subprocess
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="bash", timeout=5)):
            code, out = web_module.run_script("slow-cmd", timeout=5)
        assert code == -1
        assert "超时" in out

    def test_strips_ansi_from_output(self, web_module):
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "\033[1;32m[INFO]\033[0m done"
        mock_result.stderr = ""
        with patch("subprocess.run", return_value=mock_result):
            code, out = web_module.run_script("test")
        assert "\033" not in out
        assert "[INFO] done" in out


# ==================== HTTP Handler ====================

class TestHandlerRouting:
    """HTTP 请求路由测试"""

    def test_get_api_icons(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/api/icons"
        handler._send = MagicMock()
        with patch.object(web_module, "get_icons", return_value=[{"标题": "test"}]):
            handler.do_GET()
        handler._send.assert_called_once()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert args[0][0] == 200
        assert body["ok"] is True
        assert len(body["list"]) == 1

    def test_get_api_ip(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/api/ip"
        handler._send = MagicMock()
        with patch.object(web_module, "get_nas_ip", return_value="192.168.1.100"):
            handler.do_GET()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is True
        assert body["ip"] == "192.168.1.100"

    def test_get_root_returns_html(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/"
        handler._send = MagicMock()
        handler.do_GET()
        args = handler._send.call_args
        assert args[0][0] == 200
        assert "text/html" in args[0][2]

    def test_get_unknown_path_returns_404_json(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/unknown"
        handler._send = MagicMock()
        handler.do_GET()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False
        assert body["output"] == "404"

    def test_post_add_missing_container(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/api/add"
        handler._send = MagicMock()
        handler.do_POST()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False
        assert "容器名" in body["output"]

    def test_post_add_custom_missing_title(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/api/add-custom"
        handler._send = MagicMock()
        handler.do_POST()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False

    def test_post_add_custom_invalid_url(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/api/add-custom?title=Test&url=javascript:alert(1)"
        handler._send = MagicMock()
        handler.do_POST()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False
        assert "http" in body["output"]

    def test_post_add_invalid_port(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/api/add?container=test&port=abc"
        handler._send = MagicMock()
        handler.do_POST()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False
        assert "端口" in body["output"]


# ==================== serve_icon 安全 ====================

class TestServeIconSecurity:
    """图标静态文件服务路径穿越防护"""

    def test_rejects_path_traversal(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/icons/../../../etc/passwd"
        handler._send = MagicMock()
        handler.serve_icon("/icons/../../../etc/passwd")
        # 路径穿越应被 basename 截断
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False

    def test_missing_icon_returns_404(self, web_module, tmp_path, monkeypatch):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/icons/nonexistent.png"
        handler._send = MagicMock()
        monkeypatch.setattr(web_module, "ICON_DIR", str(tmp_path))
        handler.serve_icon("/icons/nonexistent.png")
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False
        assert "404" in body["output"]

    def test_serves_valid_icon(self, web_module, tmp_path, monkeypatch):
        icon_path = tmp_path / "test.svg"
        icon_path.write_text("<svg></svg>", encoding="utf-8")
        monkeypatch.setattr(web_module, "ICON_DIR", str(tmp_path))

        handler = web_module.Handler.__new__(web_module.Handler)
        handler.path = "/icons/test.svg"
        handler._send = MagicMock()
        handler.wfile = MagicMock()
        handler.serve_icon("/icons/test.svg")
        args = handler._send.call_args
        assert args[0][0] == 200
        assert "image/svg" in args[0][2]


# ==================== handle_upload 安全 ====================

class TestHandleUploadSecurity:
    """图标上传安全校验"""

    def test_rejects_oversized_body(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.headers = {"Content-Length": str(4 * 1024 * 1024)}
        handler._send = MagicMock()
        handler.handle_upload()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False
        assert "3MB" in body["output"]

    def test_rejects_empty_body(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.headers = {"Content-Length": "0"}
        handler._send = MagicMock()
        handler.handle_upload()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False

    def test_rejects_bad_filename(self, web_module):
        handler = web_module.Handler.__new__(web_module.Handler)
        handler.headers = {"Content-Length": "100"}
        handler.rfile = MagicMock()
        handler._send = MagicMock()
        import base64
        payload = json.dumps({"name": "../../../etc/passwd", "data": base64.b64encode(b"x").decode()})
        handler.rfile.read = MagicMock(return_value=payload.encode())
        handler.handle_upload()
        args = handler._send.call_args
        body = json.loads(args[0][1])
        assert body["ok"] is False
        assert "文件名" in body["output"]


# ==================== 版本一致性 ====================

class TestVersionConsistency:
    """版本号一致性检查"""

    def test_web_py_version_matches_manifest(self, web_module):
        manifest = ROOT / "pkg" / "fnos" / "manifest"
        for line in manifest.read_text(encoding="utf-8").splitlines():
            if line.strip().startswith("version"):
                manifest_version = line.split("=", 1)[1].strip()
                assert web_module.APP_VERSION == manifest_version
                return
        pytest.fail("version not found in manifest")

    def test_server_version_string(self, web_module):
        assert "1.0" in web_module.Handler.server_version

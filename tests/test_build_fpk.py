"""
build_fpk.py 单元测试 —— fnpack 打包脚本

覆盖 manifest 版本读取、app.tgz 构建、fpk 完整打包流程。
"""
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FNOS = ROOT / "pkg" / "fnos"


# ==================== read_manifest_version ====================

class TestReadManifestVersion:
    """manifest 文件版本号解析"""

    def test_reads_version_from_manifest(self, build_module):
        version = build_module.read_manifest_version()
        assert version
        # 版本号格式：x.y.z
        parts = version.split(".")
        assert len(parts) >= 2
        for p in parts:
            assert p.isdigit(), f"版本号部分 '{p}' 不是数字"

    def test_version_matches_expected(self, build_module):
        """校验三处版本号一致：manifest == web.py APP_VERSION == fn-docker-desk.sh APP_VERSION。"""
        manifest_version = build_module.read_manifest_version()
        assert manifest_version

        web_py = (ROOT / "pkg" / "files" / "web.py").read_text(encoding="utf-8")
        sh = (ROOT / "pkg" / "files" / "fn-docker-desk.sh").read_text(encoding="utf-8")

        import re
        web_m = re.search(r'^APP_VERSION\s*=\s*"([^"]+)"', web_py, re.M)
        sh_m = re.search(r'^readonly APP_VERSION="([^"]+)"', sh, re.M)

        assert web_m, "web.py 未找到 APP_VERSION 定义"
        assert sh_m, "fn-docker-desk.sh 未找到 readonly APP_VERSION 定义"
        web_version = web_m.group(1)
        sh_version = sh_m.group(1)

        assert manifest_version == web_version, (
            f"manifest.version ({manifest_version}) != web.py APP_VERSION ({web_version})"
        )
        assert manifest_version == sh_version, (
            f"manifest.version ({manifest_version}) != fn-docker-desk.sh APP_VERSION ({sh_version})"
        )


# ==================== build_app_tgz ====================

class TestBuildAppTgz:
    """app.tgz 打包内容校验"""

    def test_app_tgz_contains_required_files(self, build_module, tmp_path):
        output = tmp_path / "app.tgz"
        build_module.build_app_tgz(output)
        assert output.exists()

        with tarfile.open(output, "r:gz") as tar:
            names = tar.getnames()
            # 必须包含核心文件（usr-local-linker 规范：CLI 入口放 bin/fn-docker-desk，无 .sh 后缀）
            assert "bin/fn-docker-desk" in names
            assert "web.py" in names
            assert "desktop-inject.js" in names
            # ui 目录
            ui_files = [n for n in names if n.startswith("ui/")]
            assert len(ui_files) > 0

    def test_app_tgz_scripts_are_executable(self, build_module, tmp_path):
        output = tmp_path / "app.tgz"
        build_module.build_app_tgz(output)

        with tarfile.open(output, "r:gz") as tar:
            for member in tar.getmembers():
                if member.name == "bin/fn-docker-desk":
                    # 0o755 = 493
                    assert member.mode == 0o755, f"bin/fn-docker-desk 权限应为 755, 实际为 {oct(member.mode)}"


# ==================== build_fpk ====================

class TestBuildFpk:
    """完整 .fpk 打包流程"""

    def test_build_fpk_creates_valid_package(self, build_module, tmp_path, monkeypatch):
        # 重定向 DIST 到临时目录
        monkeypatch.setattr(build_module, "DIST", tmp_path)
        package = build_module.build_fpk("1.1.6")
        assert package.exists()
        assert package.name == "fn-docker-desk_1.1.6_all.fpk"

    def test_fpk_contains_manifest_and_icons(self, build_module, tmp_path, monkeypatch):
        monkeypatch.setattr(build_module, "DIST", tmp_path)
        package = build_module.build_fpk("1.1.6")

        with tarfile.open(package, "r:gz") as tar:
            names = tar.getnames()
            assert "manifest" in names
            assert "ICON.PNG" in names
            assert "ICON_256.PNG" in names
            assert "app.tgz" in names
            # cmd 目录
            cmd_files = [n for n in names if n.startswith("cmd/")]
            assert len(cmd_files) > 0
            # config 目录
            config_files = [n for n in names if n.startswith("config/")]
            assert len(config_files) > 0

    def test_fpk_cmd_scripts_are_executable(self, build_module, tmp_path, monkeypatch):
        monkeypatch.setattr(build_module, "DIST", tmp_path)
        package = build_module.build_fpk("1.1.6")

        executable_names = {
            "main",
            "install_callback",
            "upgrade_callback",
            "uninstall_callback",
        }

        with tarfile.open(package, "r:gz") as tar:
            for member in tar.getmembers():
                if member.name.startswith("cmd/") and member.name.split("/")[-1] in executable_names:
                    assert member.mode == 0o755, f"{member.name} 权限应为 755, 实际为 {oct(member.mode)}"

    def test_fpk_uses_manifest_version_by_default(self, build_module, tmp_path, monkeypatch):
        monkeypatch.setattr(build_module, "DIST", tmp_path)
        # 不传 version 参数时，应从 manifest 读取
        package = build_module.build_fpk(build_module.read_manifest_version())
        assert build_module.read_manifest_version() in package.name


# ==================== 打包一致性 ====================

class TestPackageConsistency:
    """打包内容一致性校验"""

    def test_manifest_in_fpk_matches_source(self, build_module, tmp_path, monkeypatch):
        monkeypatch.setattr(build_module, "DIST", tmp_path)
        package = build_module.build_fpk("1.1.6")

        source_manifest = (FNOS / "manifest").read_text(encoding="utf-8")
        with tarfile.open(package, "r:gz") as tar:
            packaged_manifest = tar.extractfile("manifest").read().decode("utf-8")
        assert source_manifest == packaged_manifest

    def test_no_pycache_in_package(self, build_module, tmp_path, monkeypatch):
        monkeypatch.setattr(build_module, "DIST", tmp_path)
        package = build_module.build_fpk("1.1.6")

        with tarfile.open(package, "r:gz") as tar:
            for name in tar.getnames():
                assert "__pycache__" not in name, f"打包中不应包含 __pycache__: {name}"

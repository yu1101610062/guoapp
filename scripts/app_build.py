import json
import os
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLED_DIRECTORY = ROOT / 'native' / 'core' / 'bundled'
MODULE_FILES = ('manifest.json', 'main.js')
ENVIRONMENT_DEFINES = ['PROJECT_URL', 'TELEGRAM_GROUP_URL', 'TELEGRAM_CHANNEL_URL']


class AppBuild:
    slug = 'zhenguojian'
    display_name = '真果鉴'
    sync_test = False

    @property
    def bundle_identifier(self):
        return os.environ.get('PACKAGE_NAME', '').strip() or 'com.duanju.duanju_app'

    @property
    def arguments(self):
        return ['--sync-test'] if self.sync_test else []

    @property
    def flutter_arguments(self):
        arguments = ['--dart-define=SYNC_TEST_BUILD=' + str(self.sync_test).lower()]
        for name in ENVIRONMENT_DEFINES:
            value = os.environ.get(name, '').strip()
            if value:
                arguments.append(f'--dart-define={name}={value}')
        return arguments

    @property
    def go_arguments(self):
        return ['-ldflags=' + self.linker_flags]

    @property
    def linker_flags(self):
        flags = '-s -w'
        update_server = os.environ.get('UPDATE_SERVER_URL', '').strip()
        if update_server:
            flags += ' -X duanjuapp/native/core.nativeUpdateServer=' + update_server
        project = os.environ.get('PROJECT_URL', '').strip()
        if project:
            flags += ' -X duanjuapp/native/core.nativeProjectURL=' + project
        return flags


app = AppBuild()


def add_variant_argument(parser):
    parser.add_argument('--all-sources', action='store_true',
                        help='兼容旧构建命令；2.x 站源统一由运行时模块提供')
    parser.add_argument('--sync-test', action='store_true',
                        help='使用独立同步测试数据目录与 Android 应用 ID')


def configure_app(options):
    app.sync_test = options.sync_test


def prepare_bundled_modules(extra=()):
    BUNDLED_DIRECTORY.mkdir(parents=True, exist_ok=True)
    destination = BUNDLED_DIRECTORY.resolve()
    if not destination.is_relative_to(ROOT.resolve()):
        raise SystemExit('内置模块目录不在当前项目中')
    for child in BUNDLED_DIRECTORY.iterdir():
        if child.name != '.gitkeep':
            if not child.resolve().is_relative_to(destination):
                raise SystemExit('内置模块路径超出构建目录')
            if child.is_dir():
                shutil.rmtree(child)
            else:
                child.unlink()
    for item in [*os.environ.get('BUNDLED_MODULES', '').split(','), *extra]:
        if not item.strip():
            continue
        source = Path(item.strip())
        if not source.is_absolute():
            source = ROOT / source
        missing = [name for name in MODULE_FILES if not (source / name).is_file()]
        if missing:
            raise SystemExit(f'内置模块 {source} 缺少 {"、".join(missing)}')
        manifest = json.loads((source / 'manifest.json').read_text(encoding='utf-8'))
        if not re.fullmatch(r'[a-z0-9_-]{1,64}', manifest.get('id', '')):
            raise SystemExit(f'内置模块 {source} 的 ID 无效')
        target = BUNDLED_DIRECTORY / manifest['id']
        target.mkdir()
        for name in MODULE_FILES:
            shutil.copy2(source / name, target / name)
        print(f'内置模块：{manifest["id"]} {manifest.get("version", "")}', flush=True)

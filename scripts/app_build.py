import os
from dataclasses import dataclass


@dataclass(frozen=True)
class BuildVariant:
    all_sources: bool = False
    sync_test: bool = False

    @property
    def slug(self):
        return 'zhenguojian' if self.all_sources else 'hongguojian'

    @property
    def arguments(self):
        return (['--all-sources'] if self.all_sources else []) + (['--sync-test'] if self.sync_test else [])

    @property
    def flutter_arguments(self):
        return ['--dart-define=ALL_SOURCES=' + str(self.all_sources).lower(),
                '--dart-define=SYNC_TEST_BUILD=' + str(self.sync_test).lower()]

    @property
    def linker_flags(self):
        flags = '-s -w -X duanjuapp/native/core.buildAllSources=' + str(self.all_sources).lower()
        update_server = os.environ.get('UPDATE_SERVER_URL', '').strip()
        if update_server:
            flags += ' -X duanjuapp/native/core.nativeUpdateServer=' + update_server
        return flags


def add_variant_argument(parser):
    parser.add_argument('--sync-test', action='store_true',
                        help='使用独立的同步测试数据目录与 Android 应用 ID，不覆盖正式应用')
    parser.add_argument('--all-sources', action='store_true',
                        help='构建包含全部站源的真果鉴；默认构建仅红果的红果鉴')

import json
import os
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUNDLED_DIRECTORY = ROOT / 'native' / 'core' / 'bundled'
MODULE_FILES = ('manifest.json', 'main.js')
ENVIRONMENT_DEFINES = ['PROJECT_URL', 'TELEGRAM_GROUP_URL', 'TELEGRAM_CHANNEL_URL']


class AppBuild:
    slug = 'guoapp'
    display_name = '小果影视'

    @property
    def bundle_identifier(self):
        return os.environ.get('PACKAGE_NAME', '').strip() or 'com.yingshib.xg'

    @property
    def flutter_arguments(self):
        arguments = []
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


def _module_sources(source):
    if all((source / name).is_file() for name in MODULE_FILES):
        return [source]
    if source.is_dir():
        return [
            child
            for child in sorted(source.iterdir())
            if child.is_dir()
            and all((child / name).is_file() for name in MODULE_FILES)
        ]
    return []


def prepare_bundled_modules(extra=()):
    BUNDLED_DIRECTORY.mkdir(parents=True, exist_ok=True)
    for child in BUNDLED_DIRECTORY.iterdir():
        if child.name != '.gitkeep':
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
        sources = _module_sources(source)
        if not sources:
            raise SystemExit(f'内置模块 {source} 缺少 {"、".join(MODULE_FILES)}')
        for module_source in sources:
            manifest = json.loads(
                (module_source / 'manifest.json').read_text(encoding='utf-8')
            )
            target = BUNDLED_DIRECTORY / manifest['id']
            if target.exists():
                raise SystemExit(f'内置模块 id 重复：{manifest["id"]}')
            target.mkdir()
            for name in MODULE_FILES:
                shutil.copy2(module_source / name, target / name)
            print(
                f'内置模块：{manifest["id"]} {manifest.get("version", "")}',
                flush=True,
            )

"""Фикстуры: герметичный прогон generate.uc на временном UCI."""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATE_UC = (
    REPO_ROOT
    / 'luci-app-rukiki/root/etc/rukiki/ucode/generate.uc'
)
DUMP_UC = Path(__file__).resolve().parent / 'dump.uc'
FIXTURES = Path(__file__).resolve().parent / 'fixtures'

_HAS_UCODE = shutil.which('ucode') is not None
requires_ucode = pytest.mark.skipif(
    not _HAS_UCODE,
    reason='ucode не установлен (brew install ucode / apt install ucode)',
)


def _run_ucode(script: Path, uci_dir: Path, mixin: Path) -> str:
    env = {
        **os.environ,
        'RUKIKI_UCI_DIR': str(uci_dir),
        'RUKIKI_MIXIN_FILE': str(mixin),
    }
    result = subprocess.run(
        ['ucode', str(script)],
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout


@pytest.fixture
def projection(tmp_path: Path) -> dict:
    """Прогоняет генератор и возвращает {nikki, mixin}."""
    uci_dir = tmp_path / 'config'
    uci_dir.mkdir()
    shutil.copy(FIXTURES / 'rukiki', uci_dir / 'rukiki')
    shutil.copy(FIXTURES / 'nikki', uci_dir / 'nikki')
    mixin = tmp_path / 'mixin.yaml'

    _run_ucode(GENERATE_UC, uci_dir, mixin)
    dump = _run_ucode(DUMP_UC, uci_dir, mixin)

    return {
        'nikki': json.loads(dump),
        'mixin': json.loads(mixin.read_text()),
        'mixin_text': mixin.read_text(),
    }

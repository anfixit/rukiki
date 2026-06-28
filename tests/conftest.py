"""Фикстуры для герметичного прогона generate.uc на временном UCI."""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
GENERATE_UC = (
    REPO_ROOT
    / "luci-app-rukiki/root/etc/rukiki/ucode/generate.uc"
)
DUMP_UC = Path(__file__).resolve().parent / "dump.uc"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
UCODE_TIMEOUT_SECONDS = 10

_HAS_UCODE = shutil.which("ucode") is not None
requires_ucode = pytest.mark.skipif(
    not _HAS_UCODE,
    reason="ucode не установлен",
)


def _run_ucode(
    script: Path,
    uci_dir: Path,
    uci_savedir: Path,
    mixin: Path,
) -> str:
    """Запускает ucode с тайм-аутом и понятной диагностикой."""
    env = {
        **os.environ,
        "RUKIKI_UCI_DIR": str(uci_dir),
        "RUKIKI_UCI_SAVEDIR": str(uci_savedir),
        "RUKIKI_MIXIN_FILE": str(mixin),
    }
    command = ["ucode", str(script)]

    print(f"[rukiki-tests] run: {' '.join(command)}", flush=True)

    try:
        result = subprocess.run(
            command,
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=UCODE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ""
        stderr = error.stderr or ""
        pytest.fail(
            "ucode завис и был остановлен по тайм-ауту\n"
            f"script: {script}\n"
            f"timeout: {UCODE_TIMEOUT_SECONDS} s\n"
            f"stdout:\n{stdout}\n"
            f"stderr:\n{stderr}",
            pytrace=False,
        )

    if result.returncode != 0:
        pytest.fail(
            "ucode завершился с ошибкой\n"
            f"script: {script}\n"
            f"exit code: {result.returncode}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}",
            pytrace=False,
        )

    if result.stderr:
        print(
            f"[rukiki-tests] stderr from {script.name}:\n{result.stderr}",
            flush=True,
        )

    print(f"[rukiki-tests] completed: {script.name}", flush=True)
    return result.stdout


@pytest.fixture
def projection(tmp_path: Path) -> dict[str, object]:
    """Прогоняет генератор и возвращает UCI-проекцию и mixin."""
    uci_dir = tmp_path / "config"
    uci_savedir = tmp_path / "saved"
    uci_dir.mkdir()
    uci_savedir.mkdir()

    shutil.copy(FIXTURES / "rukiki", uci_dir / "rukiki")
    shutil.copy(FIXTURES / "nikki", uci_dir / "nikki")

    mixin = tmp_path / "mixin.yaml"

    _run_ucode(
        GENERATE_UC,
        uci_dir,
        uci_savedir,
        mixin,
    )
    dump = _run_ucode(
        DUMP_UC,
        uci_dir,
        uci_savedir,
        mixin,
    )

    mixin_text = mixin.read_text(encoding="utf-8")

    return {
        "nikki": json.loads(dump),
        "mixin": json.loads(mixin_text),
        "mixin_text": mixin_text,
    }

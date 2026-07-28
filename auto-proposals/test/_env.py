"""Shared test bootstrap: every test module in this package must build its
own throwaway archive under tempfile.mkdtemp() and must NEVER point at the
real Dropbox. This guard runs at import time so a mistake here fails loudly
instead of quietly writing into someone's actual proposals archive.
"""

import os
import tempfile
from pathlib import Path

_real_dropbox = Path("~/Dropbox").expanduser()


def make_test_root() -> Path:
    root = Path(tempfile.mkdtemp(prefix="auto-proposals-test-"))
    try:
        real_dropbox = _real_dropbox.resolve()
    except OSError:
        real_dropbox = _real_dropbox
    try:
        root.resolve().relative_to(real_dropbox)
    except ValueError:
        return root
    raise RuntimeError(
        f"refusing to run tests against a root under the real Dropbox: {root}"
    )


def configure_env(root: Path, *, host_ok: bool = True) -> None:
    os.environ["AUTO_PROPOSALS_ROOT"] = str(root)
    os.environ["AUTO_PROPOSALS_ALLOW_UNSYNCED"] = "1"
    os.environ["AUTO_PROPOSALS_ALLOW_ANY_HOST"] = "1"
    if host_ok:
        import socket

        os.environ["AUTO_PROPOSALS_PUBLISH_HOST"] = socket.gethostname()
    else:
        os.environ["AUTO_PROPOSALS_PUBLISH_HOST"] = "not-this-host-xyz"

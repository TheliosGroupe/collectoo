"""reportlab with the library's own defaults only (receipts, review M2b-5 #4).

reportlab reads its global configuration (`reportlab.rl_config`) once, at import, from its defaults
overridden by `RL_<name>` environment variables, a `reportlab_settings.py` anywhere on `sys.path` or
`~/.reportlab_settings`, and runs `reportlab_mods` / `~/.reportlab_mods` hooks. Several of those
settings change the bytes of a PDF (`ttfAsciiReadable`, `canvas_basefontname`, `documentLang`,
`pdfMultiLine`, `pdfComments`, `paraFontSizeHeightOffset`…), and some are copied into other
modules at import. A receipt's PDF must be a function of the receipt only, so this module imports
reportlab first with none of them (the variables hidden, the settings and hook modules replaced by
empty ones for the duration of the import), and `pin()` sets every global setting back to its
default before each render. If another module imported reportlab first, its configuration is
compared with the defaults: any difference makes `pin()` refuse, rather than render other bytes.

`receipt_pdf` imports this module before reportlab.
"""

from __future__ import annotations

import copy
import os
import sys
import types
from typing import Any, cast

HOOKS = (
    "reportlab.local_rl_mods",
    "reportlab_mods",
    "reportlab.local_rl_settings",
    "reportlab_settings",
)


def _import_with_its_defaults() -> bool:
    """Import reportlab with no setting or hook from the environment; False if it was imported
    already (by another module, possibly under other settings)."""
    if "reportlab" in sys.modules:
        return False
    hidden = {k: os.environ.pop(k) for k in [k for k in os.environ if k.startswith("RL_")]}
    stubs = [name for name in HOOKS if name not in sys.modules]
    for name in stubs:
        sys.modules[name] = types.ModuleType(name)
    try:
        import reportlab.rl_config  # noqa: F401, PLC0415 - must run with the stubs in place
    finally:
        for name in stubs:
            sys.modules.pop(name, None)
        os.environ.update(hidden)
    return True


IMPORTED_HERE = _import_with_its_defaults()

from reportlab import rl_config, rl_settings  # noqa: E402 - after the import above, on purpose
from reportlab.lib import pagesizes  # noqa: E402


def _defaults() -> dict[str, Any]:
    """reportlab's own default of every global setting, as `rl_config` holds it (font search paths
    aside: fonts are loaded from this package by path)."""
    out: dict[str, Any] = {}
    for name in cast(tuple[str, ...], getattr(rl_settings, "__all__")):  # noqa: B009
        if name.endswith("SearchPath"):
            continue
        value = getattr(rl_settings, name)
        if name == "defaultPageSize":
            value = getattr(pagesizes, value)
        elif name.endswith("Glob"):
            value = value.split() if value else []
        out[name] = value
    return out


DEFAULTS = _defaults()
# Settings that differed from the defaults when this module found reportlab imported already.
EARLIER_DRIFT = (
    ()
    if IMPORTED_HERE
    else tuple(sorted(k for k, v in DEFAULTS.items() if getattr(rl_config, k, None) != v))
)


def pin() -> None:
    """Every global setting back to reportlab's default, invariant mode on (design §10); refuses if
    reportlab was imported earlier under other settings (its import-time copies may differ)."""
    if EARLIER_DRIFT:
        raise RuntimeError(
            "reportlab was configured outside the receipt renderer (RL_* variables, settings "
            f"files or code that imported it first): {', '.join(EARLIER_DRIFT)}; receipts are "
            "rendered only with reportlab's own defaults"
        )
    for name, value in DEFAULTS.items():
        setattr(rl_config, name, copy.copy(value))
    rl_config.invariant = 1

"""Build-time patch: defensive acp_command guard in delegate_tool.py.

Validates that override_acp_command is on PATH before letting it force
the subagent onto the copilot-acp transport. Without this, a model
hallucinating acp_command="copilot" on a host without the binary crashes
the subagent and can take the gateway down.

Upstream fix tracked at https://github.com/NousResearch/hermes-agent/pull/27426
— delete this file and the Dockerfile COPY/RUN step once that PR merges
and HERMES_REF is bumped past it.

Idempotent: re-running on an already-patched file is a no-op.
"""

from __future__ import annotations

import sys
from pathlib import Path

TARGET = Path("/opt/hermes-agent/tools/delegate_tool.py")

NEEDLE = (
    '    effective_acp_command = override_acp_command or getattr(\n'
    '        parent_agent, "acp_command", None\n'
    '    )'
)

PATCH = '''    # DEFENSIVE: validate override_acp_command actually exists on PATH
    # before honoring it. Models occasionally hallucinate
    # acp_command="copilot" / "claude" / etc. in delegate_task tool calls
    # despite the schema saying not to, which forces the subagent onto
    # the copilot-acp transport below and crashes when the binary is
    # missing (e.g. headless container deploys).
    if override_acp_command:
        import shutil as _sh
        if not _sh.which(override_acp_command):
            import logging as _logging
            _logging.getLogger(__name__).warning(
                "Ignoring acp_command=%r: binary not found on PATH; "
                "falling back to default transport.",
                override_acp_command,
            )
            override_acp_command = None
            override_acp_args = None
    effective_acp_command = override_acp_command or getattr(
        parent_agent, "acp_command", None
    )'''


def main() -> int:
    if not TARGET.exists():
        print(f"ERROR: {TARGET} not found — upstream layout may have changed", file=sys.stderr)
        return 1
    src = TARGET.read_text()
    if "DEFENSIVE: validate override_acp_command" in src:
        print("already patched, skipping")
        return 0
    if NEEDLE not in src:
        print(f"ERROR: patch needle not found in {TARGET} — upstream code drift", file=sys.stderr)
        return 1
    TARGET.write_text(src.replace(NEEDLE, PATCH, 1))
    print("patched OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

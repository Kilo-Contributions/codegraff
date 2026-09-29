"""Harbor installed agent for graff (github.com/justrach/codegraff).

Installs the static Linux graff binary in the task container, either from a
GitHub release (`version`, checked against that release's SHA256SUMS; the
latest release when omitted) or from a local binary (`binary`), then solves
the task as one headless `graff -p` run with every tool approved. Headless runs wait for their own background work before they end
(ADR 0215), so a build or test suite the agent starts in the background is
collected rather than dropped.

graff keeps its session, traces and scratch worktrees in `.graff/` under the
working directory. After the run that directory moves into the agent logs, so
the verifier sees only the agent's changes to the task.
"""

from __future__ import annotations

import shlex
from pathlib import Path, PurePosixPath
from typing import Annotated, Any, override

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.agents.model_connection import ModelConnectionSpec
from harbor.agents.options import Cli, InstalledAgentOptions
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from pydantic import Field

from graff_harbor.usage import parse_footer

RELEASES = "https://github.com/justrach/codegraff/releases"
REMOTE = PurePosixPath("/installed-agent/graff")
LOGS = PurePosixPath("/logs/agent")


class GraffOptions(InstalledAgentOptions):
    binary: str | None = Field(
        default=None,
        description="Local static Linux graff binary to upload instead of a release.",
    )
    max_model_calls: Annotated[int | None, Cli("--max-model-calls")] = Field(
        default=None, description="Stop the run after this many model calls."
    )


def release_tag(version: str | None) -> str:
    """`latest`, or a release tag with its leading `v`."""
    if not version or version == "latest":
        return "latest"
    return version if version.startswith("v") else f"v{version}"


def release_base(release: str) -> str:
    """Download base for `latest` or a tag such as `v0.0.302.10`."""
    if release == "latest":
        return f"{RELEASES}/latest/download"
    return f"{RELEASES}/download/{release}"


def install_script(release: str) -> str:
    """Fetch the release tarball for this machine and verify it."""
    base = shlex.quote(release_base(release))
    return "\n".join(
        [
            "set -eu",
            'case "$(uname -m)" in',
            "  x86_64|amd64) arch=x86_64 ;;",
            "  aarch64|arm64) arch=aarch64 ;;",
            '  *) echo "graff: unsupported architecture $(uname -m)" >&2; exit 1 ;;',
            "esac",
            'tmp="$(mktemp -d)"',
            'cd "$tmp"',
            f'curl -fsSL -o graff.tar.gz {base}/graff-"$arch"-linux.tar.gz',
            f"curl -fsSL -o SHA256SUMS {base}/SHA256SUMS",
            'want="$(grep " graff-$arch-linux.tar.gz$" SHA256SUMS | head -n 1 | cut -d " " -f 1)"',
            'got="$(sha256sum graff.tar.gz | cut -d " " -f 1)"',
            'if [ -z "$want" ] || [ "$want" != "$got" ]; then',
            '  echo "graff: release checksum mismatch" >&2',
            "  exit 1",
            "fi",
            "tar -xzf graff.tar.gz",
            f'cp "graff-$arch-linux/graff" {REMOTE}/graff',
            'rm -rf "$tmp"',
        ]
    )


def run_command(model: str, flags: str) -> str:
    """One headless graff run, then `.graff/` moves out of the task tree."""
    graff = shlex.join(
        [
            str(REMOTE / "graff"),
            "--yolo",
            "--no-telemetry",
            "--model",
            model,
        ]
    )
    extra = f" {flags}" if flags else ""
    return "\n".join(
        [
            'had_state=""',
            'if [ -e .graff ]; then had_state=1; fi',
            f'{graff}{extra} -p "$(cat {LOGS}/instruction.md)" '
            f">{LOGS}/graff.stdout 2>{LOGS}/graff.stderr",
            "rc=$?",
            'if [ -z "$had_state" ] && [ -d .graff ]; then',
            f"  mkdir -p {LOGS}/graff-state",
            f"  cp -R .graff/. {LOGS}/graff-state/ && rm -rf .graff",
            "  git worktree prune >/dev/null 2>&1 || true",
            "fi",
            'exit "$rc"',
        ]
    )


class Graff(BaseInstalledAgent):
    """graff, installed from a release or a local static Linux binary."""

    MODEL_CONNECTION = ModelConnectionSpec(passthrough=True)
    options_model = GraffOptions

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        if not self.model_name or "/" not in self.model_name:
            raise ValueError(
                "Use a provider/model name, e.g. anthropic/claude-sonnet-5-5"
            )
        self._release = release_tag(self._version)
        binary = self.options.binary if isinstance(self.options, GraffOptions) else None
        self._binary = Path(binary).expanduser().resolve() if binary else None
        if self._binary is not None and not self._binary.is_file():
            raise ValueError(f"graff binary not found: {self._binary}")

    @staticmethod
    @override
    def name() -> str:
        return "graff"

    @override
    def get_version_command(self) -> str | None:
        return f"{REMOTE}/graff --version"

    @override
    def parse_version(self, stdout: str) -> str:
        lines = stdout.strip().splitlines()
        return lines[0].removeprefix("graff").strip() if lines else ""

    @override
    async def install(self, environment: BaseEnvironment) -> None:
        # The release download needs curl, and Terminal-Bench verifiers
        # bootstrap their test runners with it. An uploaded binary does not,
        # so there a missing package mirror is only a warning.
        await self.exec_as_root(environment, command=f"mkdir -p {REMOTE}")
        if self._binary is not None:
            try:
                await self.ensure_system_dependencies(environment, ("curl",))
            except Exception as error:  # noqa: BLE001 - best effort off the release path
                self.logger.warning("curl install failed (%s); continuing with the uploaded binary", error)
            await environment.upload_file(self._binary, str(REMOTE / "graff"))
        else:
            await self.ensure_system_dependencies(environment, ("curl",))
            await self.exec_as_root(environment, command=install_script(self._release))
        await self.exec_as_root(
            environment,
            command=f"chmod 755 {REMOTE}/graff && {REMOTE}/graff --version",
        )

    @override
    @with_prompt_template
    async def run(
        self, instruction: str, environment: BaseEnvironment, context: AgentContext
    ) -> None:
        await self.exec_as_agent(environment, command=f"mkdir -p {LOGS}")
        await self._upload_config_text(
            environment,
            content=instruction,
            filename="instruction.md",
            remote_path=str(LOGS / "instruction.md"),
        )
        env = {
            **self.model_connection.env,
            "GRAFF_NO_TELEMETRY": "1",
            "GRAFF_BEHAVIOR_UPLOAD": "off",
            "NO_COLOR": "1",
        }
        await self.exec_as_agent(
            environment,
            command=run_command(self.model_name or "", self.build_cli_flags()),
            env=env,
        )

    @override
    def populate_context_post_run(self, context: AgentContext) -> None:
        stderr = self.logs_dir / "graff.stderr"
        usage = parse_footer(stderr.read_text(errors="replace")) if stderr.exists() else None
        metadata = {**(context.metadata or {}), "graff_release": self._release}
        if self._binary is not None:
            metadata["graff_binary"] = self._binary.name
        if usage is None:
            metadata["graff_usage_missing"] = True
        else:
            context.n_input_tokens = usage.input_tokens
            context.n_cache_tokens = usage.cached_tokens
            context.n_output_tokens = usage.output_tokens
            context.cost_usd = usage.cost_usd
            metadata["graff_api_calls"] = usage.calls
        context.metadata = metadata

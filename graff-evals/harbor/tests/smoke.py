"""Run one real Harbor trial of graff against a scripted in-container model.

The task container serves graff's scripted test model on graff's `lmstudio`
port, so the trial needs no API key and makes no network calls beyond the
release download. Needs a Harbor environment on this machine: `docker`, or
`apple-container` on Apple silicon.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def smoke(environment: str, release: str, binary: str | None) -> None:
    # Under $HOME: Apple container's builder cannot read a build context in the
    # system temp directory (/private/var/folders), and Docker does not mind.
    scratch = Path.home() / ".cache" / "graff-harbor-smoke"
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="run-", dir=scratch) as directory:
        root = Path(directory)
        task = root / "task"
        shutil.copytree(HERE / "task", task)
        shutil.copy(REPO / "scripts/eval/mock_model.py", task / "environment/mock_model.py")
        source = ["--ak", f"binary={Path(binary).resolve()}"] if binary else ["--ak", f"version={release}"]
        subprocess.run(
            [
                "harbor", "run",
                "-p", str(task),
                "-a", "graff_harbor.agent:Graff",
                "-m", "lmstudio/smoke",
                *source,
                "--ae", "LMSTUDIO_API_KEY=local",
                "-e", environment,
                "-n", "1", "-k", "1",
                "-o", str(root / "jobs"),
                "--job-name", "smoke",
            ],
            check=True,
            timeout=1200,
        )
        results = list((root / "jobs").glob("smoke/*/result.json"))
        assert len(results) == 1, results
        trial = results[0].parent
        result = json.loads(results[0].read_text())
        agent_dir = trial / "agent"
        if result.get("exception_info"):
            stderr = agent_dir / "graff.stderr"
            detail = stderr.read_text() if stderr.exists() else "no graff stderr"
            raise AssertionError(f"{result['exception_info']['exception_message']}\n{detail}")
        assert result["verifier_result"]["rewards"]["reward"] == 1, result["verifier_result"]
        assert "Wrote done" in (agent_dir / "graff.stdout").read_text()
        assert (agent_dir / "graff-state").is_dir(), "graff's .graff state was not moved into the logs"
        metrics = result["agent_result"]
        assert metrics["n_input_tokens"] and metrics["n_input_tokens"] > 0, metrics
        assert metrics["n_output_tokens"] is not None, metrics
        print(f"Harbor {environment} smoke passed: reward 1, tokens reported, task tree left clean.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", default="docker")
    parser.add_argument("--release", default="latest")
    parser.add_argument("--binary", help="local static Linux graff binary instead of a release")
    args = parser.parse_args()
    smoke(args.environment, args.release, args.binary)

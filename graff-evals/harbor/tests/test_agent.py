import tempfile
import unittest
from pathlib import Path

from harbor.models.agent.context import AgentContext

from graff_harbor.agent import Graff, install_script, release_base, release_tag, run_command


class AgentTest(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.logs = Path(self._dir.name)

    def tearDown(self):
        self._dir.cleanup()

    def test_model_must_name_its_provider(self):
        with self.assertRaises(ValueError):
            Graff(logs_dir=self.logs, model_name="claude-sonnet-5-5")

    def test_a_missing_local_binary_is_refused(self):
        with self.assertRaises(ValueError):
            Graff(logs_dir=self.logs, model_name="openai/gpt-5.4", binary=str(self.logs / "nope"))

    def test_version_option_picks_the_release_tag(self):
        self.assertEqual(release_tag(None), "latest")
        self.assertEqual(release_tag("0.0.302.10"), "v0.0.302.10")
        self.assertEqual(release_tag("v0.0.302.10"), "v0.0.302.10")
        agent = Graff(logs_dir=self.logs, model_name="openai/gpt-5.4", version="0.0.302.10")
        self.assertEqual(agent._release, "v0.0.302.10")

    def test_release_download_is_checksum_verified_for_either_arch(self):
        self.assertTrue(release_base("latest").endswith("/releases/latest/download"))
        self.assertTrue(release_base("v0.0.302.10").endswith("/releases/download/v0.0.302.10"))
        script = install_script("v0.0.302.10")
        self.assertIn("aarch64|arm64) arch=aarch64", script)
        self.assertIn('graff-"$arch"-linux.tar.gz', script)
        self.assertIn("SHA256SUMS", script)
        self.assertIn("checksum mismatch", script)

    def test_run_is_one_headless_approved_run_that_moves_its_state_out(self):
        command = run_command("openai/gpt-5.4", "--max-model-calls 30")
        self.assertIn("--yolo --no-telemetry --model openai/gpt-5.4 --max-model-calls 30 -p", command)
        self.assertIn("/logs/agent/instruction.md", command)
        self.assertIn("rm -rf .graff", command)
        self.assertIn('exit "$rc"', command)

    def test_options_compile_to_graff_flags(self):
        agent = Graff(logs_dir=self.logs, model_name="openai/gpt-5.4", max_model_calls=30)
        self.assertEqual(agent.build_cli_flags(), "--max-model-calls 30")
        self.assertEqual(Graff(logs_dir=self.logs, model_name="openai/gpt-5.4").build_cli_flags(), "")

    def test_version_line_parses(self):
        agent = Graff(logs_dir=self.logs, model_name="openai/gpt-5.4")
        self.assertEqual(agent.parse_version("graff v0.0.302.10\n\nWhat's new\n"), "v0.0.302.10")

    def test_usage_footer_reaches_the_context(self):
        agent = Graff(logs_dir=self.logs, model_name="openai/gpt-5.4", version="v0.0.302.10")
        (self.logs / "graff.stderr").write_text(
            "[usage] 4 api call(s) · 900 in (300 cached, 0 cache writes) + 80 out tokens · $0.00500000\n"
        )
        context = AgentContext()
        agent.populate_context_post_run(context)
        self.assertEqual((context.n_input_tokens, context.n_cache_tokens, context.n_output_tokens), (900, 300, 80))
        self.assertAlmostEqual(context.cost_usd, 0.005)
        self.assertEqual(context.metadata["graff_api_calls"], 4)
        self.assertEqual(context.metadata["graff_release"], "v0.0.302.10")

    def test_missing_usage_is_recorded_not_raised(self):
        agent = Graff(logs_dir=self.logs, model_name="openai/gpt-5.4")
        context = AgentContext()
        agent.populate_context_post_run(context)
        self.assertTrue(context.metadata["graff_usage_missing"])


if __name__ == "__main__":
    unittest.main()

import unittest

from graff_harbor.usage import parse_footer


class FooterTest(unittest.TestCase):
    def test_metered_run_reports_tokens_and_cost(self):
        usage = parse_footer(
            "calling claude\n"
            "[usage] 3 api call(s) · 7538 in (4096 cached, 12 cache writes) + 512 out tokens · $0.01234567\n"
        )
        assert usage is not None
        self.assertEqual((usage.calls, usage.input_tokens, usage.cached_tokens), (3, 7538, 4096))
        self.assertEqual((usage.cache_write_tokens, usage.output_tokens), (12, 512))
        self.assertAlmostEqual(usage.cost_usd, 0.01234567)

    def test_last_footer_wins_and_ansi_is_ignored(self):
        usage = parse_footer(
            "[usage] 1 api call(s) · 10 in (0 cached, 0 cache writes) + 1 out tokens · $0.00000100\n"
            "\x1b[2m[usage] 2 api call(s) · 20 in (5 cached, 0 cache writes) + 2 out tokens · $0.00000200\x1b[0m\n"
        )
        assert usage is not None
        self.assertEqual(usage.calls, 2)
        self.assertEqual(usage.cached_tokens, 5)

    def test_cost_is_unknown_when_the_line_leaves_calls_out(self):
        for line in (
            "[usage] 1 api call(s) · 7538 in (0 cached, 0 cache writes) + 5 out tokens · $0.00000000 · 1 subscription call(s), flat-rate (not in $)",
            "[usage] known subtotal: 2 api call(s) · 90 in (0 cached, 0 cache writes) + 9 out tokens · $0.00100000 · 1 call(s) with unknown cost",
        ):
            usage = parse_footer(line)
            assert usage is not None
            self.assertIsNone(usage.cost_usd, line)
            self.assertGreater(usage.input_tokens, 0)

    def test_no_footer_is_none(self):
        self.assertIsNone(parse_footer("calling model\nsomething went wrong\n"))


if __name__ == "__main__":
    unittest.main()

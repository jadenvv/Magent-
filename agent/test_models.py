"""Tests for the parts of models.py that don't need the model: python3 -m unittest -v (in agent/)."""

import json
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import sys

import models


class BuildSpec(unittest.TestCase):
    def test_valid_output(self):
        out = '{"goal": "g", "steps_hint": ["a", "", 3], "success_check": "c", "risky_actions": ["send", "bogus"]}'
        spec = models.build_spec("open notes", out)
        self.assertEqual(spec["source"], "model")
        self.assertEqual(spec["steps_hint"], ["a"])
        self.assertEqual(spec["risky_actions"], ["send"])
        self.assertTrue(spec["needs_confirmation"])
        self.assertEqual(spec["prompt"], "open notes")

    def test_prose_and_think_block_around_json(self):
        out = '<think>{"goal": "wrong"}</think>Sure! {"goal": "g {x}", "success_check": "c"} done'
        self.assertEqual(models.build_spec("p", out)["goal"], "g {x}")

    def test_garbage_falls_back_to_prompt(self):
        for out in ["", "no json here", '{"goal": ', '["list"]', '{"goal": "g"}']:
            spec = models.build_spec("  open   Safari ", out)
            self.assertEqual(spec["source"], "fallback", out)
            self.assertEqual(spec["goal"], "open Safari")

    def test_model_cannot_clear_keyword_risks(self):
        spec = models.build_spec("delete my old screenshots", '{"goal": "g", "success_check": "c", "risky_actions": []}')
        self.assertIn("delete", spec["risky_actions"])
        self.assertTrue(spec["needs_confirmation"])

    def test_no_risk(self):
        spec = models.build_spec("open Safari", '{"goal": "g", "success_check": "c", "risky_actions": []}')
        self.assertEqual(spec["risky_actions"], [])
        self.assertFalse(spec["needs_confirmation"])

    def test_json_is_byte_stable(self):
        a = models.spec_to_json(models.build_spec("open Safari", '{"goal": "é", "success_check": "c"}'))
        b = models.spec_to_json(models.build_spec("open  Safari", '{"success_check": "c", "goal": "é"}'))
        self.assertNotEqual(json.loads(a)["request_hash"], json.loads(b)["request_hash"])
        self.assertEqual(list(json.loads(a)), list(models.build_spec("x", "")))
        self.assertIn("é", a)


class SpeedPaths(unittest.TestCase):
    def test_bypass_does_not_load_model_and_preserves_prompt(self):
        s = models.PromptStructurer()
        with patch.object(s, "_load_locked", side_effect=AssertionError("model loaded")):
            spec = s.structure("  open Safari! ")
        self.assertEqual(spec["prompt"], "  open Safari! ")
        self.assertEqual(spec["source"], "deterministic")
        self.assertEqual(s.last_metrics["route"], "simple_bypass")
        self.assertEqual(s.structure("open  Safari")["prompt"], "open  Safari")
        s.structure("open  Safari")
        self.assertEqual(s.last_metrics["route"], "result_cache")

    def test_bypass_rejects_extra_instructions(self):
        for prompt in ["open Safari and send an email", "open Safari https://example.com",
                       "open Terminal", "open Notes; delete files"]:
            self.assertIsNone(models.simple_request(prompt))

    def test_stream_stops_at_valid_json_and_closes(self):
        s = models.PromptStructurer()
        s._model, s._tokenizer, s._cache, s._prefix = object(), object(), [], [1]
        closed = []
        consumed = []
        chunks = ['"a {brace} and \\"quote\\"",',
                  '"success_check":"done"}', ' unwanted trailing text']
        def stream(*args, **kwargs):
            try:
                for n, chunk in enumerate(chunks, 1):
                    consumed.append(chunk)
                    yield SimpleNamespace(text=chunk, generation_tokens=n, finish_reason="stop")
            finally:
                closed.append(True)
        modules = {"mlx_lm": SimpleNamespace(stream_generate=stream),
                   "mlx_lm.models.cache": SimpleNamespace(make_prompt_cache=lambda m: [])}
        with patch.dict(sys.modules, modules), patch.object(s, "_encode", return_value=[1, 2]):
            out = s._generate("task")
            self.assertEqual(len(consumed), 2)
            self.assertEqual(json.loads(out)["success_check"], "done")
            self.assertTrue(s.last_metrics["prefix_cache_hit"])
            self.assertEqual(s.last_metrics["stop_reason"], "complete_json")
        self.assertEqual(closed, [True])

    def test_disabled_early_stop_consumes_full_stream_and_prefix_miss(self):
        s = models.PromptStructurer(early_stop=False)
        s._model, s._tokenizer, s._cache, s._prefix = object(), object(), [], [1]
        chunks = ['"g","success_check":"c"}', ' trailing']
        def stream(*args, **kwargs):
            for n, chunk in enumerate(chunks, 1):
                yield SimpleNamespace(text=chunk, generation_tokens=n, finish_reason="stop")
        modules = {"mlx_lm": SimpleNamespace(stream_generate=stream),
                   "mlx_lm.models.cache": SimpleNamespace(make_prompt_cache=lambda m: [])}
        with patch.dict(sys.modules, modules), patch.object(s, "_encode", return_value=[3, 2]):
            self.assertTrue(s._generate("task").endswith(" trailing"))
        self.assertFalse(s.last_metrics["prefix_cache_hit"])
        self.assertEqual(s.last_metrics["input_tokens"], 2)

    def test_fallback_is_not_cached(self):
        s = models.PromptStructurer(simple_bypass=False)
        with patch.object(s, "_load_locked"), patch.object(s, "_generate", return_value="invalid") as generate:
            self.assertEqual(s.structure("task")["source"], "fallback")
            s.structure("task")
        self.assertEqual(generate.call_count, 2)

    def test_encode_seeds_json_after_closing_thinking(self):
        s = models.PromptStructurer()
        s._tokenizer = SimpleNamespace(
            apply_chat_template=lambda *a, **kw: "assistant\n<think>",
            encode=lambda text, **kw: text,
        )
        self.assertEqual(s._encode([], True), 'assistant\n<think></think>\n{"goal":')


if __name__ == "__main__":
    unittest.main()

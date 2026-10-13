"""Tests for planner.py with fake API clients (no network): python3 -m unittest -v (in agent/)."""

import json
import struct
import unittest
import zlib
from types import SimpleNamespace
from unittest.mock import patch

import models
import planner


def png(width, height):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = b"".join(b"\x00" + b"\x00" * 3 * width for _ in range(height))
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


SPEC = models.build_spec("open notes", '{"goal": "Notes is open.", "success_check": "Notes has a window."}')
GOOD = {
    "summary": "Open Notes.",
    "steps": [{"action": "open_app", "args": {"app": "Notes"}, "description": "Open Notes", "expect": "Notes window", "observe": "ax", "risky_actions": []}],
    "final": True,
    "next_observation": "none",
    "success_check": {"kind": "applescript", "check": 'tell application "System Events" to exists process "Notes"'},
}


def step(action, args, risks=(), observe="none"):
    return {"action": action, "args": args, "description": "d", "expect": "e", "observe": observe, "risky_actions": list(risks)}


class BuildPlan(unittest.TestCase):
    def build(self, **overrides):
        return planner.build_plan(SPEC, dict(GOOD, **overrides), 100, 50, "claude", "m")

    def test_valid(self):
        plan = self.build()
        self.assertEqual(plan["steps"][0]["id"], 1)
        self.assertEqual(plan["steps"][0]["action"], "open_app")
        self.assertTrue(plan["final"])
        self.assertFalse(plan["needs_confirmation"])
        self.assertEqual(plan["request_hash"], SPEC["request_hash"])
        self.assertEqual(plan["steps"][0]["observe"], "ax")
        self.assertEqual(plan["next_observation"], "none")

    def test_rejects_bad_steps(self):
        bad = [
            [],
            [step("teleport", {})],
            [step("click", {"x": 1})],
            [step("click", {"x": "1", "y": 2})],
            [step("click", {"x": True, "y": 2})],
            [step("click", {"x": 100, "y": 10})],  # outside 100x50
            [step("wait", {"seconds": 1})] * (planner.MAX_STEPS + 1),
        ]
        for steps in bad:
            with self.assertRaises(planner.PlanError, msg=steps):
                self.build(steps=steps)

    def test_rejects_bad_observation(self):
        for steps in ([step("wait", {"seconds": 1}, observe="vibes")],
                      [step("wait", {"seconds": 1}, observe=None)],
                      [step("open_app", {"app": "Notes"}, observe="output")]):  # output: shell/applescript only
            with self.assertRaises(planner.PlanError, msg=steps):
                self.build(steps=steps)
        self.build(steps=[step("shell", {"command": "ls"}, observe="output")])
        for overrides in ({"next_observation": "vibes"}, {"next_observation": None},
                          {"final": False, "next_observation": "none"}):
            with self.assertRaises(planner.PlanError, msg=overrides):
                self.build(**overrides)
        self.assertEqual(self.build(final=False, next_observation="window")["next_observation"], "window")

    def test_rejects_bad_success_check(self):
        for check in [None, {"kind": "vibes", "check": "x"}, {"kind": "screen", "check": " "}]:
            with self.assertRaises(planner.PlanError):
                self.build(success_check=check)

    def test_risks_added_from_commands_never_cleared(self):
        plan = self.build(steps=[step("shell", {"command": "rm -rf ~/tmp/x"}, ["bogus"])])
        self.assertEqual(plan["steps"][0]["risky_actions"], ["delete"])
        self.assertTrue(plan["needs_confirmation"])

    def test_spec_risks_carry_over(self):
        spec = models.build_spec("send an email to bob", "")
        plan = planner.build_plan(spec, GOOD, 100, 50, "claude", "m")
        self.assertIn("send", plan["risky_actions"])
        self.assertTrue(plan["needs_confirmation"])

    def test_risky_success_check_flagged(self):
        plan = self.build(success_check={"kind": "shell", "check": "sudo ls"})
        self.assertIn("sudo", plan["risky_actions"])


class LoadImage(unittest.TestCase):
    def test_png(self):
        self.assertEqual(planner.load_image(png(7, 3))[1:], ("image/png", 7, 3))

    def test_jpeg(self):
        sof = b"\xff\xc0" + struct.pack(">HBHH", 11, 8, 3, 7) + b"\x00" * 6
        self.assertEqual(planner.load_image(b"\xff\xd8" + sof)[1:], ("image/jpeg", 7, 3))

    def test_rejects_other(self):
        with self.assertRaises(ValueError):
            planner.load_image(b"GIF89a....")


class FakeClaude:
    def __init__(self, tool_input):
        self.calls = []
        usage = SimpleNamespace(input_tokens=10, output_tokens=5, cache_read_input_tokens=3, cache_creation_input_tokens=0)
        block = SimpleNamespace(type="tool_use", name="submit_plan", input=tool_input)
        self.messages = SimpleNamespace(create=lambda **kw: self.calls.append(kw) or SimpleNamespace(
            content=[block], stop_reason="tool_use", usage=usage))


class FakeOpenAI:
    def __init__(self, text):
        self.calls = []
        usage = SimpleNamespace(input_tokens=10, output_tokens=5, input_tokens_details=SimpleNamespace(cached_tokens=4))
        self.responses = SimpleNamespace(create=lambda **kw: self.calls.append(kw) or SimpleNamespace(
            output_text=text, status="completed", usage=usage))


class Providers(unittest.TestCase):
    def test_claude(self):
        client = FakeClaude(GOOD)
        p = planner.Planner("claude", client=client)
        out = json.loads(p.plan_json(models.spec_to_json(SPEC), png(100, 50)))
        self.assertEqual(out["provider"], "claude")
        self.assertEqual(out["steps"][0]["args"], {"app": "Notes"})
        call = client.calls[0]
        self.assertEqual(call["tool_choice"], {"type": "tool", "name": "submit_plan"})
        self.assertEqual(call["system"][0]["text"], planner.SYSTEM_PROMPT)  # stable prefix
        self.assertEqual(call["messages"][0]["content"][0]["type"], "image")
        self.assertEqual(p.last_metrics["cache_read_tokens"], 3)

    def test_codex_alias_and_openai(self):
        client = FakeOpenAI(json.dumps(GOOD))
        p = planner.Planner("codex", client=client)
        self.assertEqual(p.plan(SPEC, png(100, 50))["provider"], "openai")
        self.assertEqual(client.calls[0]["text"]["format"]["type"], "json_schema")
        self.assertEqual(p.last_metrics["cache_read_tokens"], 4)

    def test_openai_non_json_raises(self):
        with self.assertRaises(planner.PlanError):
            planner.Planner("openai", client=FakeOpenAI("sorry")).plan(SPEC, png(100, 50))

    def test_models_plan_request(self):
        client = FakeClaude(GOOD)
        shared = planner.Planner("claude", client=client)
        with patch.object(models, "structure_prompt", return_value=models.spec_to_json(SPEC)), \
             patch.object(planner, "_shared", return_value=shared):
            out = json.loads(models.plan_request("open notes", png(100, 50)))
            with self.assertRaises(TypeError):
                models.plan_request("open notes", "shot.png")
        self.assertEqual(out["steps"][0]["action"], "open_app")
        self.assertIn('"prompt": "open notes"', client.calls[0]["messages"][0]["content"][1]["text"])

    def test_unknown_provider(self):
        with self.assertRaises(ValueError):
            planner.Planner("gemini")


if __name__ == "__main__":
    unittest.main()

"""Tests for the omelette script. Run: python3 -m unittest discover -s tests"""
import importlib.machinery
import importlib.util
import json
import os
import random
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parent.parent / "omelette"
loader = importlib.machinery.SourceFileLoader("omelette_mod", str(SCRIPT))
spec = importlib.util.spec_from_loader("omelette_mod", loader)
om = importlib.util.module_from_spec(spec)
loader.exec_module(om)


def win(addr, ws, cls="com.mitchellh.ghostty", mru=0, **extra):
    c = {"address": addr, "workspace": {"id": ws, "name": str(ws)}, "class": cls, "title": addr,
         "at": [0, 0], "size": [800, 600], "focusHistoryID": mru, "mapped": True}
    c.update(extra)
    return c


MONITORS = [{"activeWorkspace": {"id": 1}, "specialWorkspace": {"id": 0}}]


class Names(unittest.TestCase):
    def test_friendly_names(self):
        self.assertEqual(om.app_name({"class": "com.mitchellh.ghostty"}), "Ghostty")
        self.assertEqual(om.app_name({"class": "org.omarchy.agent.restore-2fb9833f-ae25"}), "Agent")
        self.assertEqual(om.app_name({"class": "chrome-github.com__-Default"}), "Web app")
        self.assertEqual(om.app_name({"class": "org.kde.dolphin"}), "Dolphin")
        self.assertEqual(om.app_name({"class": ""}), "Window")

    def test_restored_windows_count_as_the_same_app(self):
        self.assertEqual(om.base_class({"class": "org.omarchy.agent.restore-abc-123"}), "org.omarchy.agent")


class Eligibility(unittest.TestCase):
    def test_skips_floating_fullscreen_grouped_pinned_special(self):
        self.assertTrue(om.eligible(win("a", 1)))
        for extra in ({"floating": True}, {"fullscreen": 2}, {"grouped": ["x"]}, {"pinned": True}, {"hidden": True}):
            self.assertFalse(om.eligible(win("a", 1, **extra)), extra)
        self.assertFalse(om.eligible(win("a", -98)))


class Ordering(unittest.TestCase):
    def ring(self, clients, tile, same_app=False, flagged=()):
        pool = {c["address"]: c for c in clients}
        with mock.patch.object(om, "attention_addresses", return_value={om.norm(a) for a in flagged}):
            ring, homes, flags = om.build_ring(pool[tile], pool, MONITORS, same_app)
        return ring, flags

    def test_attention_then_off_screen_then_on_screen(self):
        clients = [
            win("0x1", 1, mru=0),                 # the tile
            win("0x2", 1, mru=1),                 # on screen, most recent
            win("0x3", 2, mru=3),                 # off screen
            win("0x4", 3, mru=2),                 # off screen, more recent
            win("0x5", 1, mru=5),                 # on screen but wants attention
        ]
        ring, flags = self.ring(clients, "0x1", flagged=["0x5"])
        self.assertEqual(ring, ["0x1", "0x5", "0x4", "0x3", "0x2"])
        self.assertEqual(flags, ["0x5"])

    def test_same_app_filters_by_app(self):
        clients = [win("0x1", 1, cls="org.omarchy.agent"), win("0x2", 2, cls="org.omarchy.agent.restore-ab12"),
                   win("0x3", 2, cls="google-chrome")]
        ring, _ = self.ring(clients, "0x1", same_app=True)
        self.assertEqual(ring, ["0x1", "0x2"])


class FakeCompositor:
    """Applies the Lua swaps omelette emits to a map of window -> slot."""

    SWAP = re.compile(r'swap\(\{ window = "address:(\w+)", target = "address:(\w+)" \}\)')

    def __init__(self, slots):
        self.slot = dict(slots)
        self.focused = None

    def eval(self, lua):
        for line in lua:
            m = self.SWAP.search(line)
            if m:
                a, b = m.groups()
                self.slot[a], self.slot[b] = self.slot[b], self.slot[a]
            f = re.search(r'focus\(\{ window = "address:(\w+)" \}\)', line)
            if f:
                self.focused = f.group(1)


class OneSwapRule(unittest.TestCase):
    def test_random_flips_only_ever_displace_two_windows(self):
        rng = random.Random(7)
        addrs = [f"0x{i}" for i in range(1, 9)]
        homes = {a: f"slot{i}" for i, a in enumerate(addrs)}
        for trial in range(200):
            comp = FakeCompositor(homes)
            session = {"ring": list(addrs), "origin": addrs[0], "index": 0}
            with mock.patch.object(om, "hypr_eval", comp.eval), mock.patch.object(om, "start_fade"), \
                    mock.patch.object(om, "window_opacity", return_value=1.0):
                for _ in range(rng.randint(1, 25)):
                    step = rng.choice([1, -1, rng.randrange(len(addrs))])
                    j = (session["index"] + step) % len(addrs) if step in (1, -1) else step
                    om.move_to(session, j, 10, 10, on_screen=rng.random() < 0.5)
                    shown = session["ring"][session["index"]]
                    self.assertEqual(comp.slot[shown], homes[addrs[0]], "shown window sits in the tile")
                    for a in addrs:
                        if a in (shown, addrs[0]):
                            continue
                        self.assertEqual(comp.slot[a], homes[a], f"{a} never leaves home")
                    if shown != addrs[0]:
                        self.assertEqual(comp.slot[addrs[0]], homes[shown], "original holds the shown window's spot")
                # Flipping back to the start restores the layout exactly.
                om.move_to(session, 0, 10, 10, on_screen=False)
                self.assertEqual(comp.slot, homes)

    def test_fade_starts_translucent_and_restores_own_opacity(self):
        comp = FakeCompositor({"0x1": "t", "0x2": "h"})
        session = {"ring": ["0x1", "0x2"], "origin": "0x1", "index": 0}
        seen = []
        with mock.patch.object(om, "hypr_eval", lambda lua: (seen.extend(lua), comp.eval(lua))), \
                mock.patch.object(om, "window_opacity", return_value=0.9), \
                mock.patch.object(om, "start_fade") as fade:
            om.move_to(session, 1, 0, 0, on_screen=True)
        self.assertIn('value = "0.36"', seen[0])   # FADE_START * own opacity
        fade.assert_called_once_with("0x2", 0.9)
        self.assertEqual(session["alpha"], {"0x2": 0.9})


class Setup(unittest.TestCase):
    def run_setup(self, home, args=(), taken=()):
        binds = [{"modmask": m, "key": k, "description": "Something else"} for m, k in taken]

        def fake_run(cmd, **kw):
            out = json.dumps(binds) if cmd[:2] == ["hyprctl", "binds"] else ""
            return mock.Mock(stdout=out, returncode=0)

        with mock.patch.dict(os.environ, {"HOME": home}), mock.patch.object(om.subprocess, "run", fake_run):
            return om.setup(list(args))

    def test_installs_once_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as home:
            path = Path(home, ".config/hypr/bindings.lua")
            path.parent.mkdir(parents=True)
            path.write_text("-- mine\n")
            self.assertEqual(self.run_setup(home), 0)
            first = path.read_text()
            self.assertIn(om.BEGIN, first)
            self.assertTrue(first.startswith("-- mine\n"))
            self.assertEqual(self.run_setup(home), 0)
            self.assertEqual(path.read_text(), first)

    def test_skips_combos_already_in_use(self):
        with tempfile.TemporaryDirectory() as home:
            path = Path(home, ".config/hypr/bindings.lua")
            path.parent.mkdir(parents=True)
            path.write_text("")
            self.run_setup(home, taken=[(68, "slash")])
            text = path.read_text()
            self.assertIn('-- o.bind("SUPER + CTRL + SLASH"', text)
            self.assertIn('o.bind("SUPER + CTRL + ESCAPE"', text)


if __name__ == "__main__":
    unittest.main()

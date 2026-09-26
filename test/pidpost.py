#!/usr/bin/env python3
"""Pid-targeted synthetic input for processes this script launched itself. Never posts to a HID or session tap.

Every post re-checks that the target is alive, is the child we spawned, and has the expected executable name.
"""
import os, subprocess, time
import Quartz
from AppKit import NSRunningApplication

KEYCODES = {'a': 0, 's': 1, 'd': 2, 'f': 3, 'h': 4, 'g': 5, 'z': 6, 'x': 7, 'c': 8, 'v': 9, 'b': 11, 'q': 12, 'w': 13,
            'e': 14, 'r': 15, 'y': 16, 't': 17, 'o': 31, 'u': 32, 'i': 34, 'p': 35, 'l': 37, 'j': 38, 'k': 40, 'n': 45,
            'm': 46, ' ': 49, '\r': 36, '\b': 51, '\x1b': 53}


class Target:
    def __init__(self, popen, name):
        self.popen, self.name = popen, name

    @property
    def pid(self):
        return self.popen.pid

    def check(self):
        if self.popen.poll() is not None:
            raise SystemExit(f'ABORT: {self.name} pid {self.pid} exited')
        app = NSRunningApplication.runningApplicationWithProcessIdentifier_(self.pid)
        exe = app.executableURL().lastPathComponent() if app and app.executableURL() else None
        if exe is None:
            exe = os.path.basename(subprocess.run(['ps', '-p', str(self.pid), '-o', 'comm='], capture_output=True, text=True).stdout.strip())
        if exe != self.name:
            raise SystemExit(f'ABORT: pid {self.pid} is {exe!r}, expected {self.name!r}')

    def post(self, ev):
        self.check()
        Quartz.CGEventPostToPid(self.pid, ev)

    @staticmethod
    def _event(ch, down, flags=0):
        # Characters without a key code here (digits, punctuation, non-ASCII, emoji) ride on the 'a' key with their own text.
        e = Quartz.CGEventCreateKeyboardEvent(None, KEYCODES.get(ch.lower(), 0) if len(ch) == 1 else 0, down)
        if ch.isprintable():
            Quartz.CGEventKeyboardSetUnicodeString(e, len(ch.encode('utf-16-le')) // 2, ch)
        if flags:
            Quartz.CGEventSetFlags(e, flags)
        return e

    def burst(self, s):
        """Back-to-back keys after a single target check (the whole burst takes well under a millisecond)."""
        self.check()
        for ch in s:
            for down in (True, False):
                Quartz.CGEventPostToPid(self.pid, self._event(ch, down))

    def special(self, code, flags=0):
        """A key by virtual key code (arrows 123-126, Return 36, Delete 51, Escape 53), optionally with modifier flags."""
        for down in (True, False):
            e = Quartz.CGEventCreateKeyboardEvent(None, code, down)
            if flags: Quartz.CGEventSetFlags(e, flags)
            self.post(e)
            time.sleep(0.02)
        time.sleep(0.04)

    def key(self, ch, flags=0):
        for down in (True, False):
            self.post(self._event(ch, down, flags))
            time.sleep(0.03)
        time.sleep(0.05)

    def type(self, s):
        for ch in s:
            self.key(ch)

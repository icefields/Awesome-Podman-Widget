#!/usr/bin/env python3
"""Run the Lua widget tests without requiring a system Lua installation."""

from pathlib import Path

from lupa import LuaRuntime


PROJECT_DIR = Path(__file__).resolve().parent.parent


def main():
    luaRuntime = LuaRuntime(unpack_returned_tuples=True)
    luaRuntime.globals().WIDGET_PATH = str(PROJECT_DIR / "docker.lua")
    testFile = PROJECT_DIR / "tests" / "widget_spec.lua"
    luaRuntime.execute(testFile.read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()

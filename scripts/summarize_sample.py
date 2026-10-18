#!/usr/bin/env python3
"""Condenses the main-thread call graph from a macOS `sample` report.

  summarize_sample.py sample.txt          print the hot main-thread stack
  summarize_sample.py --busy sample.txt   exit 0 if the main thread is NOT idle in its run loop
"""
import re
import sys

IDLE_MARKERS = ("mach_msg", "__CFRunLoopServiceMachPort", "ReceiveNextEventCommon", "_BlockUntilNextEventMatchingListInMode")


def main_thread_lines(text):
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if "com.apple.main-thread" in line:
            start = i
            break
    if start is None:
        return []
    out = [lines[start]]
    for line in lines[start + 1:]:
        if re.match(r"^\s{4}\d+\s+Thread_", line) or line.startswith("Total number in stack") or not line.strip():
            break
        out.append(line)
    return out


def count_of(line):
    m = re.search(r"(\d+)\s+\S", line.lstrip(" +!:|"))
    return int(m.group(1)) if m else 0


def clean(line):
    line = re.sub(r"\s+\[0x[0-9a-f,]+\]", "", line)
    line = re.sub(r"\s+0x[0-9a-f]+", "", line)
    line = re.sub(r"\(in ([^)]+)\) \+ \d+", r"(\1)", line)
    return line.rstrip()


def main():
    args = sys.argv[1:]
    busy_mode = args and args[0] == "--busy"
    path = args[-1]
    text = open(path, encoding="utf-8", errors="replace").read()
    lines = main_thread_lines(text)
    if not lines:
        if busy_mode:
            sys.exit(1)
        print("main thread not found")
        return
    total = count_of(lines[0]) or 1
    hot = [l for l in lines[1:] if count_of(l) >= total * 0.25]

    # The deepest hot frames tell where the main thread spends its time.
    deepest = hot[-40:] if len(hot) > 40 else hot
    if busy_mode:
        tail = " ".join(deepest[-6:])
        idle = any(m in tail for m in IDLE_MARKERS)
        sys.exit(1 if idle else 0)

    print(f"main thread samples: {total}")
    # keep the first frames (app entry) and the deepest frames
    shown = hot[:12] + (["  ..."] if len(hot) > 52 else []) + (hot[-40:] if len(hot) > 52 else hot[12:])
    for l in shown:
        print(clean(l)[:220])


if __name__ == "__main__":
    main()

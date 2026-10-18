#!/usr/bin/env python3
"""Lists the localizable string keys used in the Swift sources (for Localizable.strings)."""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources")

CALLS = r'(?:Text|Button|Label|Toggle|Picker|TableColumn|Section|Menu|TextField|SecureField|LabeledContent|Stepper|DatePicker|help|String\(localized:|ToolButton\(title:|InfoRow\(label:|row|Link)'
LIT = r'"((?:[^"\\]|\\.)*)"'
pattern = re.compile(CALLS + r'\(\s*(?:localized:\s*)?' + LIT)
pattern2 = re.compile(r'(?:String\(localized:|NSLocalizedString\(|title:|label:)\s*' + LIT)
ternary = re.compile(r'\?\s*' + LIT + r'\s*:\s*' + LIT)

keys = []
for dirpath, _, files in os.walk(SRC):
    for f in sorted(files):
        if not f.endswith(".swift"):
            continue
        text = open(os.path.join(dirpath, f), encoding="utf-8").read()
        for m in pattern.finditer(text):
            keys.append(m.group(1))
        for m in pattern2.finditer(text):
            keys.append(m.group(1))
        for line in text.splitlines():
            if any(w in line for w in ("Label(", "Text(", ".help(", "Toggle(")):
                for m in ternary.finditer(line):
                    keys.extend([m.group(1), m.group(2)])

extra = ["General", "Compressed", "Documents", "Music", "Programs", "Video", "Main Download Queue"]
seen = []
for k in keys + extra:
    if "\\(" in k or k.strip() == "" or k not in seen:
        if "\\(" in k or k.strip() == "":
            continue
        seen.append(k)
for k in seen:
    print(k)

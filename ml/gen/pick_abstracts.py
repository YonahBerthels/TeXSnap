"""Reads arXiv abstracts (JSON lines) on stdin; keeps ones with inline math. Usage: ... | python pick_abstracts.py out.txt"""
import json
import re
import sys

out = open(sys.argv[1], "w")
n = 0
for line in sys.stdin:
    try:
        r = json.loads(line)
    except Exception:
        continue
    a = " ".join(r.get("abstract", "").split())
    if len(re.findall(r"\$[^$]+\$", a)) >= 2 and 200 < len(a) < 1500:
        out.write(json.dumps(a) + "\n")
        n += 1
        if n >= 120000:
            break
print(n)

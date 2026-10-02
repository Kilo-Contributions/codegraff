"""Held-out check for sa-census: recompute the census from logs/ and compare."""
import collections
import gzip
import json
import os


def census():
    services = {}
    for service in sorted(os.listdir("logs")):
        d = os.path.join("logs", service)
        if not os.path.isdir(d) or service.startswith("."):
            continue
        lines = 0
        codes = collections.Counter()
        for name in sorted(os.listdir(d)):
            path = os.path.join(d, name)
            if name.endswith(".gz"):
                text = gzip.open(path, "rt").read()
            elif name.endswith(".log"):
                text = open(path).read()
            else:
                continue
            for line in text.splitlines():
                if not line.strip():
                    continue
                lines += 1
                fields = line.split()
                if len(fields) > 3 and fields[2] == "ERROR":
                    codes[fields[3]] += 1
        top = min(codes, key=lambda c: (-codes[c], c))
        services[service] = {"lines": lines, "errors": sum(codes.values()), "top_error": top}
    return {"services": services, "total_errors": sum(s["errors"] for s in services.values())}


want = census()
got = json.load(open("summary.json"))
assert got == want, f"summary.json differs:\n got  {json.dumps(got, sort_keys=True)}\n want {json.dumps(want, sort_keys=True)}"
print("sa-census hidden OK")

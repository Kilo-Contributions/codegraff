"""Setup for sa-census: writes logs/<service>/ (plain + gzipped) into the cwd.

Deterministic: fixed seed, fixed error-code counts per service, gzip mtime 0.
WARN/INFO lines that merely mention an error code are noise; the level is the
third whitespace-separated field.
"""
import gzip
import os
import random

ERRORS = {
    "auth": {"E401": 31, "E403": 18, "E500": 9, "E503": 7},
    "billing": {"E402": 22, "E409": 22, "E500": 10},
    "search": {"E504": 27, "E500": 26, "E429": 12},
    "mailer": {"E550": 14, "E421": 19, "E451": 19},
}
NOISE = {"auth": "E503", "billing": "E500", "search": "E500", "mailer": "E550"}
MESSAGES = {
    "INFO": ["request ok id={id} latency_ms={ms}", "cache hit key=k{id}", "session refreshed id={id}"],
    "DEBUG": ["pool size={ms} idle={id}", "tick seq={id}"],
    "WARN": ["slow request id={id} latency_ms={ms}", "retrying id={id} attempt=2"],
}


def lines_for(service, rng):
    out = []
    for code, n in ERRORS[service].items():
        out += [("ERROR", f"{code} request failed id={{id}}")] * n
    out += [("WARN", f"recovered after ERROR {NOISE[service]} id={{id}}")] * 15
    out += [("INFO", f"retry budget reset after ERROR {NOISE[service]} id={{id}}")] * 6
    filler = 900 - len(out)
    for _ in range(filler):
        level = rng.choices(["INFO", "DEBUG", "WARN"], weights=[80, 8, 12])[0]
        out.append((level, rng.choice(MESSAGES[level])))
    rng.shuffle(out)
    rendered = []
    for i, (level, msg) in enumerate(out):
        ts = f"2026-09-14T{8 + i // 3600:02d}:{(i // 60) % 60:02d}:{i % 60:02d}Z"
        rendered.append(f"{ts} {service} {level} " + msg.format(id=1000 + i, ms=rng.randint(2, 900)))
    return rendered


def main():
    rng = random.Random(1445)
    for service in ERRORS:
        d = os.path.join("logs", service)
        os.makedirs(d, exist_ok=True)
        lines = lines_for(service, rng)
        cut1, cut2 = 280 + rng.randint(0, 60), 600 + rng.randint(0, 60)
        parts = [lines[:cut1], lines[cut1:cut2], lines[cut2:]]
        with open(os.path.join(d, f"{service}.log"), "w") as f:
            f.write("\n".join(parts[2]) + "\n")
        with open(os.path.join(d, f"{service}.1.log"), "w") as f:
            f.write("\n".join(parts[1]) + "\n")
        with gzip.GzipFile(os.path.join(d, f"{service}.2.log.gz"), "wb", mtime=0) as f:
            f.write(("\n".join(parts[0]) + "\n").encode())


if __name__ == "__main__":
    main()

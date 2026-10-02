import json, sys
got = json.load(open("stale.json"))
want = ["ENG-104", "ENG-105"]
sys.exit(0 if got == want else f"stale.json {got} != {want}")

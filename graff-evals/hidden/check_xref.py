import json, sys
expected = {"ENG-101": 3, "ENG-102": 0, "ENG-103": 2, "ENG-104": 6, "ENG-105": 1, "ENG-106": 0, "ENG-107": 3, "ENG-108": 2}
got = json.load(open('xref.json'))
got = {k: int(v) for k, v in got.items()}
sys.exit(0 if got == expected else f'xref.json {got} != {expected}')

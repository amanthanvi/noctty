"""MEASUREMENT ONLY: compact per-run table + side summary from analyze_load.py JSON.

usage: python -I table_load.py <analyze_load json>
"""
import json
import sys


def main():
    d = json.loads(open(sys.argv[1], encoding="utf-8").read())
    for r in d["runs"]:
        if "error" in r:
            print(f"{r['run']} {r['side']} {r['error']}")
            continue
        x = r["display"]
        pb = ",".join(f"{b['max_ms']:.0f}{'c' if b['cdb_overlap'] else ''}" for b in r["per_burst"])
        st = [e for e in r["wd_events"] if e["kind"] == "stall"]
        sts = ",".join(f"{e['unanswered_ms']:.0f}{'C' if e['cdb_caused'] else ''}{'' if e['phase'] == 'during_keys' else ('<' if e['phase'] == 'before_first_key' else '>')}" for e in st)
        print(f"{r['batch'][-4:]} {r['run']:5s} {r['side'][:4]} med={x['median']:.1f} p95={x['p95']:.1f} max={x['max']:.0f} spk={r['swaps_per_key']} busy={r['cpu_busy_pct']} "
              f"in/out={r['keys_in_burst']}/{r['keys_outside_burst']} slow={len(r['slow_keys'])}" + (f" pb=[{pb}]" if pb else "") + (f" wd=[{sts}]" if sts else ""))
    print()
    for k, o in d["sides"].items():
        print(k, json.dumps(o))


if __name__ == "__main__":
    main()

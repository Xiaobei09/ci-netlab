#!/usr/bin/env python3
"""Rank proxyip entries for freshness: high reputation + rare exit country.

Input lines look like:
  95.130.84.36:8443#BY-V4-RES-100-U100      (simplified)
  216.40.87.123:443#US<-US-25ms-116.95MB/s-RES-fast-V6-CN-CNH-100-U100-CMOK

Fields after '#':
  first ISO code = exit country (what the target sees)
  tokens         = latency, speed, RES/DC/MOB/PROXY, V4/V6/DS,
                   reputation 0-100, U<uptime 0-100>

Score = reputation
      + rare-country bonus
      + residential/mobile bonus
      + IPv4 bonus
      + 0.1 * uptime
then dedupe by entry ip:port and cap entries per exit country.

Usage: rank.py <list-file> <count> [--max-per-country N] [--min-rep N]
"""
import collections
import re
import sys

HOT = set(
    "US CA DE FR GB NL JP KR SG HK TW AU RU CN IN BR IT PL SE ES CH AT FI NO "
    "IE BE DK CZ UA TR IL AE ZA MX AR CL RO HU GR PT BG VN TH ID PH MY".split()
)

RARE_BONUS = 30.0
RES_BONUS = 8.0
V4_BONUS = 5.0


def parse(line):
    line = line.strip()
    if not line or "#" not in line:
        return None
    entry, meta = line.split("#", 1)
    # ISO code is exactly two uppercase letters; "#ALL" must not parse as "AL".
    m = re.match(r"[^A-Za-z]*([A-Z]{2})(?![A-Z])", meta)
    if not m:
        return None
    cc = m.group(1)
    rep = fam = typ = uptime = None
    for tok in meta.split("-"):
        if re.fullmatch(r"\d{1,3}", tok):
            rep = int(tok)
        elif tok in ("V4", "V6", "DS"):
            fam = tok
        elif tok in ("RES", "DC", "MOB", "PROXY"):
            typ = tok
        elif re.fullmatch(r"U\d{1,3}", tok):
            uptime = int(tok[1:])
    if rep is None or not (0 <= rep <= 100):
        return None
    score = float(rep)
    if cc not in HOT:
        score += RARE_BONUS
    if typ in ("RES", "MOB"):
        score += RES_BONUS
    if fam == "V4":
        score += V4_BONUS
    if uptime is not None:
        score += min(uptime, 100) * 0.1
    return {
        "score": score,
        "rep": rep,
        "cc": cc,
        "fam": fam or "-",
        "typ": typ or "-",
        "up": uptime if uptime is not None else 0,
        "entry": entry,
        "line": line,
    }


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, count = sys.argv[1], int(sys.argv[2])
    max_per_cc = 2
    min_rep = 0
    args = sys.argv[3:]
    i = 0
    while i < len(args):
        if args[i] == "--max-per-country":
            max_per_cc = int(args[i + 1])
            i += 2
        elif args[i] == "--min-rep":
            min_rep = int(args[i + 1])
            i += 2
        else:
            i += 1

    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            r = parse(line)
            if r and r["rep"] >= min_rep:
                rows.append(r)

    rows.sort(key=lambda r: -r["score"])
    seen_entry = set()
    cc_count = collections.Counter()
    out = []
    for r in rows:
        if r["entry"] in seen_entry:
            continue
        if cc_count[r["cc"]] >= max_per_cc:
            continue
        seen_entry.add(r["entry"])
        cc_count[r["cc"]] += 1
        out.append(r)
        if len(out) >= count:
            break

    print(
        f"rank: {len(rows)} parsed, picked {len(out)} "
        f"({sum(1 for r in out if r['cc'] not in HOT)} rare-country, "
        f"max {max_per_cc}/country, min-rep {min_rep})",
        file=sys.stderr,
    )
    for r in out[:10]:
        print(
            f"rank:   {r['score']:6.1f} rep={r['rep']:3d} cc={r['cc']} "
            f"{r['fam']:2s} {r['typ']:4s} U{r['up']:<3d} {r['entry']}",
            file=sys.stderr,
        )
    for r in out:
        print(r["line"])


if __name__ == "__main__":
    main()

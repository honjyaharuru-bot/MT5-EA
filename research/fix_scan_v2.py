#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# fix_scan_v2.py  --  B02: London 4pm WM/Reuters Fix reversion scan
#
# Hypothesis: benchmark order flow around the 16:00 London fix dislocates spot;
# the pre-fix move partially reverts afterwards. Trade = fade the pre-fix move.
#
# Fix-time handling (the critical correctness point for B02):
#   MT5 bar 'time' is the broker SERVER wall-clock (as an epoch). Standard MT5
#   FX brokers run on EET (UTC+2 winter / UTC+3 summer, EU DST). EET and
#   Europe/London switch DST on the SAME dates, so EET is ALWAYS exactly 2h
#   ahead of London. Therefore the M15 bar that opens at SERVER 17:45 closes at
#   server 18:00 = London 16:00 = the fix. No per-bar DST branching, no tick
#   offset detection (v1's tick method broke on weekends: the last tick was ~42h
#   stale, giving a nonsense offset).
#   If your broker is NOT EET, change SERVER_FIX_HOUR only.
#
# Evaluation matches the project framework: gross first (THRESH=0 = every fix,
# high N), then subtract real spread; PnL in bp (log-return*1e4); true OOS split
# (OOS=2015-2021, IS=2022-2024); corrected-t threshold REQ_T; output structure
# mirrors pairs_scan_v1.py (meta / per_pair / pooled) so the same judgment works.
#
# Fast sanity pass FIRST:  python fix_scan_v2.py --check
# Full sweep:              python fix_scan_v2.py --out fix.json

import argparse
import json
import math
import sys
from datetime import datetime, timedelta

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

# ----------------------------- configuration -----------------------------
# USDCAD excluded on purpose (bars=0 / not in MarketWatch in the B04 run).
PAIRS = ["EURUSD", "GBPUSD", "USDJPY", "USDCHF", "AUDUSD"]

TF = mt5.TIMEFRAME_M15
YEAR_START = 2015
YEAR_END = 2024                       # inclusive
OOS_YEARS = set(range(2015, 2022))    # 2015-2021 (true OOS)
IS_YEARS = set(range(2022, 2025))     # 2022-2024 (recent)

# Broker EET assumption: server 17:45 open == London 15:45 open (fix bar).
SERVER_FIX_HOUR = 17
SERVER_FIX_MIN = 45
SERVER_MINUS_LONDON_H = 2             # display only (London = server - 2h)

# sweep axes -> 3 * 3 * 3 = 27 configs
PRE_BARS = [1, 2, 4]                  # pre-fix window (15/30/60 min)
HOLD_BARS = [1, 2, 4]                 # post-fix holding (15/30/60 min)
THRESHES = [0.0, 1.0, 2.0]           # min |pre-move| in rolling-sigma units; 0 = take all

REQ_T = 3.11
SIGMA_WIN = 250


# ----------------------------- MT5 helpers -------------------------------
def mt5_init():
    if not mt5.initialize():
        print("[fatal] mt5.initialize failed:", mt5.last_error(), file=sys.stderr)
        sys.exit(2)


def load_pair(symbol):
    """DataFrame indexed by SERVER wall-clock with close, spread_pts, point."""
    mt5.symbol_select(symbol, True)
    info = mt5.symbol_info(symbol)
    if info is None:
        return None, {"bars": 0, "digits": None}
    dt_from = datetime(YEAR_START, 1, 1) - timedelta(days=3)
    dt_to = datetime(YEAR_END, 12, 31) + timedelta(days=3)
    rates = mt5.copy_rates_range(symbol, TF, dt_from, dt_to)
    if rates is None or len(rates) == 0:
        return None, {"bars": 0, "digits": int(info.digits)}
    df = pd.DataFrame(rates)
    df["srv"] = pd.to_datetime(df["time"], unit="s")   # server wall-clock (naive)
    df = df.set_index("srv").sort_index()
    df["point"] = info.point
    df["spread_pts"] = df["spread"].astype(float)
    keep = df[["close", "spread_pts", "point"]].copy()
    return keep, {"bars": int(len(keep)), "digits": int(info.digits)}


# ----------------------------- signal core -------------------------------
def build_events(close):
    """One row per fixing day (server 17:45 bar): pre-move up to the fix and the
    forward returns needed for each HOLD. Integer bar positions -> a missing
    fix bar (holiday/gap) is simply skipped."""
    c = close["close"].astype(float)
    logc = np.log(c.values)
    n = len(c)
    idx = c.index                                        # DatetimeIndex (server)

    mask = (idx.hour == SERVER_FIX_HOUR) & (idx.minute == SERVER_FIX_MIN)  # ndarray
    fix_pos = np.where(mask)[0]

    max_pre = max(PRE_BARS)
    max_hold = max(HOLD_BARS)
    spread_bp_all = (close["spread_pts"].values * close["point"].values) / c.values * 1e4

    rows = []
    for p in fix_pos:
        if p - max_pre < 0 or p + max_hold >= n:
            continue
        row = {"t": idx[p], "spread_bp": float(spread_bp_all[p])}
        for k in PRE_BARS:
            row[f"pre_{k}"] = logc[p] - logc[p - k]
        for h in HOLD_BARS:
            row[f"fwd_{h}"] = logc[p + h] - logc[p]
        rows.append(row)
    if not rows:
        return pd.DataFrame()
    ev = pd.DataFrame(rows).set_index("t").sort_index()
    ev["year"] = ev.index.year
    return ev


def eval_config(ev, pre, hold, thresh):
    pre_col = ev[f"pre_{pre}"]
    fwd_col = ev[f"fwd_{hold}"]
    side = -np.sign(pre_col.values)                      # fade the pre-move

    if thresh > 0:
        sigma = pre_col.abs().rolling(SIGMA_WIN, min_periods=30).std().shift(1)
        take = pre_col.abs().values > (thresh * sigma.values)
    else:
        take = np.ones(len(ev), dtype=bool)
    take = take & (side != 0) & ~np.isnan(fwd_col.values)
    if take.sum() == 0:
        return None

    gross_bp = (side[take] * fwd_col.values[take]) * 1e4
    cost_bp = ev["spread_bp"].values[take]
    net_bp = gross_bp - cost_bp
    years = ev["year"].values[take]
    return gross_bp, net_bp, years


def tstat(x):
    x = np.asarray(x, dtype=float)
    if x.size < 2:
        return 0.0
    sd = x.std(ddof=1)
    if sd == 0:
        return 0.0
    return float(x.mean() / (sd / math.sqrt(x.size)))


# ----------------------------- runner ------------------------------------
def run(out_path, check=False):
    mt5_init()
    print(f"broker server TZ assumed EET: server {SERVER_FIX_HOUR}:{SERVER_FIX_MIN:02d} "
          f"open == London {SERVER_FIX_HOUR - SERVER_MINUS_LONDON_H}:{SERVER_FIX_MIN:02d} (fix)")

    per_pair_events = {}
    meta_pairs = {}
    for s in PAIRS:
        close, m = load_pair(s)
        meta_pairs[s] = m
        if close is None or m["bars"] == 0:
            print(f"[warn] {s}: bars=0 (skipped)")
            continue
        ev = build_events(close)
        per_pair_events[s] = ev
        if len(ev):
            srv = ev.index[:3]
            lon = srv - pd.Timedelta(hours=SERVER_MINUS_LONDON_H)
            print(f"{s}: bars={m['bars']} fix_events={len(ev)} "
                  f"server={[str(x) for x in srv]} London={[str(x) for x in lon]}")
        else:
            print(f"{s}: bars={m['bars']} fix_events=0  (timing wrong -> check SERVER_FIX_HOUR)")

    total = sum(len(e) for e in per_pair_events.values())
    print(f"fix_events_total={total} pairs_loaded={len(per_pair_events)}")

    if check:
        for s, ev in per_pair_events.items():
            if len(ev):
                print(f"  {s} fixes/year={ev.groupby('year').size().to_dict()}")
        print("CHECK DONE (no sweep). Expect server times = 17:45:00, London = 15:45:00, "
              "fixes/year ~250. If so, rerun without --check.")
        mt5.shutdown()
        return

    per_pair_out, pooled_out = [], []
    n_configs = len(PRE_BARS) * len(HOLD_BARS) * len(THRESHES)

    for pre in PRE_BARS:
        for hold in HOLD_BARS:
            for th in THRESHES:
                pg, pn, py = [], [], []
                for s, ev in per_pair_events.items():
                    if not len(ev):
                        continue
                    r = eval_config(ev, pre, hold, th)
                    if r is None:
                        continue
                    g, nt, yr = r
                    per_pair_out.append({
                        "pair": s, "pre": pre, "hold": hold, "thresh": th,
                        "N": int(g.size),
                        "EV_gross_bp": round(float(g.mean()), 4),
                        "EV_net_bp": round(float(nt.mean()), 4),
                        "t_gross": round(tstat(g), 3),
                        "t_net": round(tstat(nt), 3),
                        "OOS_t": None,
                    })
                    pg.append(g); pn.append(nt); py.append(yr)
                if not pn:
                    continue
                G = np.concatenate(pg); NT = np.concatenate(pn); YR = np.concatenate(py)
                oos = np.isin(YR, list(OOS_YEARS)); ins = np.isin(YR, list(IS_YEARS))
                by_year = {int(y): round(float(NT[YR == y].mean()), 3)
                           for y in sorted(set(YR.tolist()))}
                years_pos = sum(1 for v in by_year.values() if v > 0)
                oos_t = tstat(NT[oos]) if oos.sum() > 1 else 0.0
                is_t = tstat(NT[ins]) if ins.sum() > 1 else 0.0
                survives = (tstat(NT) > REQ_T) and (oos_t > 2.0) and (NT.mean() > 0)
                pooled_out.append({
                    "pre": pre, "hold": hold, "thresh": th,
                    "n_pairs": len(pn), "N": int(NT.size),
                    "EV_gross_bp": round(float(G.mean()), 4),
                    "EV_net_bp": round(float(NT.mean()), 4),
                    "t_gross": round(tstat(G), 3),
                    "t_net": round(tstat(NT), 3),
                    "OOS_t": round(oos_t, 3),
                    "OOS_EV_bp": round(float(NT[oos].mean()) if oos.sum() else 0.0, 3),
                    "IS_t": round(is_t, 3),
                    "years_pos": f"{years_pos}/{len(by_year)}",
                    "EV_by_year": by_year,
                    "SURVIVES": bool(survives),
                })

    survivors = sum(1 for r in pooled_out if r["SURVIVES"])
    payload = {
        "meta": {
            "pairs": meta_pairs,
            "server_fix_hour": SERVER_FIX_HOUR,
            "fix_events_total": int(total),
            "n_configs": int(n_configs),
            "req_t": REQ_T,
            "oos_years": sorted(OOS_YEARS),
            "is_years": sorted(IS_YEARS),
        },
        "per_pair": per_pair_out,
        "pooled": pooled_out,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(f"wrote {out_path} tests={len(pooled_out)} survivors={survivors} req_t={REQ_T}")
    mt5.shutdown()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fix.json")
    ap.add_argument("--check", action="store_true", help="fast timing sanity pass")
    a = ap.parse_args()
    run(a.out, check=a.check)

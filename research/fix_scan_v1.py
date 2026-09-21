#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# fix_scan_v1.py  --  B02: London 4pm WM/Reuters Fix reversion scan
#
# Hypothesis: benchmark-driven order flow around the 16:00 London fix
# dislocates spot; the pre-fix move partially reverts afterwards.
# Trade = fade the pre-fix move (enter at the fix, exit after HOLD bars).
#
# Evaluation matches the project framework:
#   - gross first (THRESH=0 takes every fix at high N), then subtract real spread
#   - PnL in bp (log-return * 1e4); log returns normalise JPY vs non-JPY digits
#   - true OOS split: OOS = 2015-2021, IS = 2022-2024
#   - multiple-testing corrected t threshold (REQ_T), cluster judged downstream
#   - output structure mirrors pairs_scan_v1.py (meta / per_pair / pooled)
#
# CRITICAL correctness point (B02): the fix is a wall-clock event at 16:00
# Europe/London. MT5 bar 'time' is broker SERVER wall-clock expressed as an
# epoch. We auto-detect the broker's UTC offset at runtime, convert each bar
# to true UTC, then to Europe/London (zoneinfo handles BST/GMT DST), and pick
# the M15 bar that OPENS at London 15:45 (i.e. closes at 16:00 = the fix).
#
# Run a fast sanity pass FIRST:   python fix_scan_v1.py --check
# Then the full sweep:            python fix_scan_v1.py --out fix.json

import argparse
import json
import math
import sys
import time
from datetime import datetime, timedelta, timezone

import numpy as np
import pandas as pd

try:
    from zoneinfo import ZoneInfo
except Exception:
    ZoneInfo = None

import MetaTrader5 as mt5

# ----------------------------- configuration -----------------------------
# USDCAD is excluded on purpose: it returned bars=0 (not in MarketWatch) in
# the B04 run, so we only use symbols confirmed loadable there.
PAIRS = ["EURUSD", "GBPUSD", "USDJPY", "USDCHF", "AUDUSD"]

TF = mt5.TIMEFRAME_M15
BARS_PER_HOUR = 4                     # M15

YEAR_START = 2015
YEAR_END = 2024                       # inclusive
OOS_YEARS = set(range(2015, 2022))    # 2015-2021  (true out-of-sample)
IS_YEARS = set(range(2022, 2025))     # 2022-2024  (in-sample / recent)

FIX_TZ = "Europe/London"
FIX_OPEN_HOUR = 15                    # M15 bar OPENING 15:45 London closes at 16:00
FIX_OPEN_MIN = 45

# sweep axes -> 3 * 3 * 3 = 27 configs (same count as pairs_scan)
PRE_BARS = [1, 2, 4]                  # pre-fix measurement window (15/30/60 min)
HOLD_BARS = [1, 2, 4]                 # post-fix holding (15/30/60 min)
THRESHES = [0.0, 1.0, 2.0]           # min |pre-move| in rolling-sigma units; 0 = take every fix

REQ_T = 3.11                          # corrected threshold (kept identical to pairs_scan)
SIGMA_WIN = 250                       # rolling window (in fix-events) for the threshold sigma

UTC = timezone.utc


# ----------------------------- MT5 helpers -------------------------------
def mt5_init():
    if not mt5.initialize():
        print("[fatal] mt5.initialize failed:", mt5.last_error(), file=sys.stderr)
        sys.exit(2)


def detect_server_offset_hours():
    """Broker server wall-clock minus true UTC, rounded to the nearest hour.

    MT5 tick/bar 'time' is the server wall-clock as an epoch (i.e. it already
    reads as server-local time when passed through utcfromtimestamp). Comparing
    a fresh tick's time to real UTC gives the server offset."""
    best = None
    for s in PAIRS:
        mt5.symbol_select(s, True)
        tick = mt5.symbol_info_tick(s)
        if tick and tick.time:
            best = tick.time
            break
    if best is None:
        return None
    off = (best - time.time()) / 3600.0
    return int(round(off))


def load_pair(symbol, offset_hours):
    """Return a DataFrame indexed by TRUE UTC with close, spread_pts, point,
    and a London-localised timestamp; plus digits and raw bar count."""
    mt5.symbol_select(symbol, True)
    info = mt5.symbol_info(symbol)
    if info is None:
        return None, {"bars": 0, "digits": None}
    point = info.point
    digits = info.digits

    dt_from = datetime(YEAR_START, 1, 1) - timedelta(days=3)
    dt_to = datetime(YEAR_END, 12, 31) + timedelta(days=3)
    rates = mt5.copy_rates_range(symbol, TF, dt_from, dt_to)
    if rates is None or len(rates) == 0:
        return None, {"bars": 0, "digits": digits}

    df = pd.DataFrame(rates)
    # server wall-clock -> true UTC
    srv = pd.to_datetime(df["time"], unit="s")           # naive = server wall-clock
    true_utc = srv - pd.Timedelta(hours=offset_hours)
    df = df.assign(utc=true_utc)
    df = df.set_index("utc").sort_index()
    df["point"] = point
    df["spread_pts"] = df["spread"].astype(float)
    keep = df[["close", "spread_pts", "point"]].copy()
    return keep, {"bars": int(len(keep)), "digits": int(digits)}


def london_open_mask(idx_utc):
    """Boolean mask: bars whose OPEN maps to 15:45 Europe/London (fix bar)."""
    if ZoneInfo is None:
        # fallback: assume London == UTC+0/+1 handled by fixed guess (not ideal)
        raise RuntimeError("zoneinfo unavailable; cannot DST-correct the fix time")
    lon = idx_utc.tz_localize(UTC).tz_convert(ZoneInfo(FIX_TZ))
    return (lon.hour == FIX_OPEN_HOUR) & (lon.minute == FIX_OPEN_MIN)


# ----------------------------- signal core -------------------------------
def build_events(close):
    """One row per fixing day: pre-move (up to fix) and the sequence of forward
    log-returns needed for the HOLD variants. Uses integer bar positions so a
    missing 15:45 bar (holiday/gap) is simply skipped.

    Returns a DataFrame indexed by fix time with columns:
      logc (log close at fix), spread_bp (round-trip cost estimate at fix),
      pre_<k> for k in PRE_BARS, fwd_<h> for h in HOLD_BARS.
    """
    c = close["close"].astype(float)
    logc = np.log(c.values)
    n = len(c)
    idx = c.index

    fixmask = london_open_mask(idx)
    fix_pos = np.where(fixmask.values)[0]

    max_pre = max(PRE_BARS)
    max_hold = max(HOLD_BARS)
    # spread in bp at the fix bar (round-trip ~ full spread)
    spread_bp_all = (close["spread_pts"].values * close["point"].values) / c.values * 1e4

    rows = []
    for p in fix_pos:
        if p - max_pre < 0 or p + max_hold >= n:
            continue
        row = {"t": idx[p], "logc": logc[p], "spread_bp": float(spread_bp_all[p])}
        for k in PRE_BARS:
            row[f"pre_{k}"] = logc[p] - logc[p - k]         # move ending at fix
        for h in HOLD_BARS:
            row[f"fwd_{h}"] = logc[p + h] - logc[p]          # post-fix forward move
        rows.append(row)
    if not rows:
        return pd.DataFrame()
    ev = pd.DataFrame(rows).set_index("t").sort_index()
    ev["year"] = ev.index.year
    return ev


def eval_config(ev, pre, hold, thresh):
    """Fade the pre-move. Return per-trade net/gross bp arrays with year labels.
    thresh in rolling-sigma units (shift(1) so no lookahead). thresh=0 -> all."""
    pre_col = ev[f"pre_{pre}"]
    fwd_col = ev[f"fwd_{hold}"]
    side = -np.sign(pre_col.values)                          # fade

    if thresh > 0:
        sigma = pre_col.abs().rolling(SIGMA_WIN, min_periods=30).std().shift(1)
        take = (pre_col.abs().values > (thresh * sigma.values))
    else:
        take = np.ones(len(ev), dtype=bool)
    take = take & (side != 0)
    take = take & ~np.isnan(fwd_col.values)

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
    offset = detect_server_offset_hours()
    if offset is None:
        print("[fatal] could not detect server offset", file=sys.stderr)
        sys.exit(3)
    print(f"detected server offset = UTC+{offset}h")

    per_pair_events = {}
    meta_pairs = {}
    for s in PAIRS:
        close, m = load_pair(s, offset)
        meta_pairs[s] = m
        if close is None or m["bars"] == 0:
            print(f"[warn] {s}: bars=0 (skipped)")
            continue
        ev = build_events(close)
        per_pair_events[s] = ev
        # verification: show that fix bars land at London 16:00 close
        if len(ev):
            sample = ev.index[:3]
            lon = sample.tz_localize(UTC).tz_convert(ZoneInfo(FIX_TZ))
            print(f"{s}: bars={m['bars']} fix_events={len(ev)} "
                  f"sample_fix_open_London={[str(x) for x in lon]}")
        else:
            print(f"{s}: bars={m['bars']} fix_events=0 (check timing!)")

    total_fixes = sum(len(e) for e in per_pair_events.values())
    print(f"fix_events_total={total_fixes} pairs_loaded={len(per_pair_events)}")

    if check:
        # fast sanity mode: do NOT sweep, just confirm timing & counts, then stop
        for s, ev in per_pair_events.items():
            if len(ev):
                yc = ev.groupby("year").size().to_dict()
                print(f"  {s} fixes/year={yc}")
        print("CHECK DONE (no sweep). If London fix opens read 15:45 and "
              "fixes/year ~250, timing is correct; rerun without --check.")
        mt5.shutdown()
        return

    per_pair_out = []
    pooled_out = []
    n_configs = len(PRE_BARS) * len(HOLD_BARS) * len(THRESHES)

    for pre in PRE_BARS:
        for hold in HOLD_BARS:
            for th in THRESHES:
                pooled_g, pooled_n, pooled_y = [], [], []
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
                        "OOS_t": None,   # OOS computed at pooled level (see below)
                    })
                    pooled_g.append(g)
                    pooled_n.append(nt)
                    pooled_y.append(yr)

                if not pooled_n:
                    continue
                G = np.concatenate(pooled_g)
                NT = np.concatenate(pooled_n)
                YR = np.concatenate(pooled_y)

                oos_mask = np.isin(YR, list(OOS_YEARS))
                is_mask = np.isin(YR, list(IS_YEARS))
                by_year = {int(y): round(float(NT[YR == y].mean()), 3)
                           for y in sorted(set(YR.tolist()))}
                years_pos = sum(1 for v in by_year.values() if v > 0)

                oos_t = tstat(NT[oos_mask]) if oos_mask.sum() > 1 else 0.0
                is_t = tstat(NT[is_mask]) if is_mask.sum() > 1 else 0.0
                t_net = tstat(NT)
                t_gross = tstat(G)
                ev_net = float(NT.mean())
                ev_gross = float(G.mean())
                oos_ev = float(NT[oos_mask].mean()) if oos_mask.sum() else 0.0

                survives = (t_net > REQ_T) and (oos_t > 2.0) and (ev_net > 0)

                pooled_out.append({
                    "pre": pre, "hold": hold, "thresh": th,
                    "n_pairs": len(pooled_n), "N": int(NT.size),
                    "EV_gross_bp": round(ev_gross, 4),
                    "EV_net_bp": round(ev_net, 4),
                    "t_gross": round(t_gross, 3),
                    "t_net": round(t_net, 3),
                    "OOS_t": round(oos_t, 3),
                    "OOS_EV_bp": round(oos_ev, 3),
                    "IS_t": round(is_t, 3),
                    "years_pos": f"{years_pos}/{len(by_year)}",
                    "EV_by_year": by_year,
                    "SURVIVES": bool(survives),
                })

    survivors = sum(1 for r in pooled_out if r["SURVIVES"])
    payload = {
        "meta": {
            "pairs": meta_pairs,
            "server_offset_hours": offset,
            "fix_events_total": int(total_fixes),
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
    ap.add_argument("--check", action="store_true",
                    help="fast timing sanity pass, no sweep")
    a = ap.parse_args()
    run(a.out, check=a.check)

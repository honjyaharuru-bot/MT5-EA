#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# fix_scan_v3.py  --  B02 London Fix reversion + COST STRESS TEST
#
# Same signal / sweep / fix-time handling as fix_scan_v2.py (server 17:45 EET
# == London 15:45 fix; fade the pre-fix move; PnL in bp; OOS=2015-2021).
#
# What v3 adds (the decisive test): the modeled cost in v2 was the M15 recorded
# spread, which came out to ~0.2 bp -- far below realistic major round-trip cost
# (~1-1.5 bp normally, MORE at the fix when liquidity thins). v3
#   (a) prints the MEAN modeled cost so we can see how thin it is, and
#   (b) re-scores the whole sweep while adding an EXTRA flat round-trip cost of
#       {0, 0.5, 1.0, 1.5, 2.0, 3.0} bp, reporting how many configs still SURVIVE
#       (t_net>REQ_T & OOS_t>2 & EV_net>0) at each haircut.
# This shows the edge's cost headroom in one run.
#
#   python fix_scan_v3.py --out fix_v3.json

import argparse
import json
import math
import sys
from datetime import datetime, timedelta

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

PAIRS = ["EURUSD", "GBPUSD", "USDJPY", "USDCHF", "AUDUSD"]
TF = mt5.TIMEFRAME_M15
YEAR_START, YEAR_END = 2015, 2024
OOS_YEARS = set(range(2015, 2022))
IS_YEARS = set(range(2022, 2025))

SERVER_FIX_HOUR = 17
SERVER_FIX_MIN = 45
SERVER_MINUS_LONDON_H = 2

PRE_BARS = [1, 2, 4]
HOLD_BARS = [1, 2, 4]
THRESHES = [0.0, 1.0, 2.0]

REQ_T = 3.11
SIGMA_WIN = 250

EXTRA_COSTS = [0.0, 0.5, 1.0, 1.5, 2.0, 3.0]   # extra round-trip cost in bp


def mt5_init():
    if not mt5.initialize():
        print("[fatal] mt5.initialize failed:", mt5.last_error(), file=sys.stderr)
        sys.exit(2)


def load_pair(symbol):
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
    df["srv"] = pd.to_datetime(df["time"], unit="s")
    df = df.set_index("srv").sort_index()
    df["point"] = info.point
    df["spread_pts"] = df["spread"].astype(float)
    return df[["close", "spread_pts", "point"]].copy(), {"bars": int(len(df)), "digits": int(info.digits)}


def build_events(close):
    c = close["close"].astype(float)
    logc = np.log(c.values)
    n = len(c)
    idx = c.index
    mask = (idx.hour == SERVER_FIX_HOUR) & (idx.minute == SERVER_FIX_MIN)
    fix_pos = np.where(mask)[0]
    max_pre, max_hold = max(PRE_BARS), max(HOLD_BARS)
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
    side = -np.sign(pre_col.values)
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
    years = ev["year"].values[take]
    return gross_bp, cost_bp, years


def tstat(x):
    x = np.asarray(x, dtype=float)
    if x.size < 2:
        return 0.0
    sd = x.std(ddof=1)
    return float(x.mean() / (sd / math.sqrt(x.size))) if sd else 0.0


def run(out_path):
    mt5_init()
    print(f"server 17:45==London 15:45 fix; EXTRA_COSTS={EXTRA_COSTS}")
    events, meta_pairs = {}, {}
    for s in PAIRS:
        close, m = load_pair(s)
        meta_pairs[s] = m
        if close is None or m["bars"] == 0:
            print(f"[warn] {s}: bars=0"); continue
        events[s] = build_events(close)
        print(f"{s}: bars={m['bars']} fix_events={len(events[s])}")

    # collect per-config pooled arrays once
    configs = []
    all_cost = []
    for pre in PRE_BARS:
        for hold in HOLD_BARS:
            for th in THRESHES:
                g_list, c_list, y_list = [], [], []
                for s, ev in events.items():
                    if not len(ev):
                        continue
                    r = eval_config(ev, pre, hold, th)
                    if r is None:
                        continue
                    g, c, y = r
                    g_list.append(g); c_list.append(c); y_list.append(y)
                if not g_list:
                    continue
                G = np.concatenate(g_list)
                C = np.concatenate(c_list)
                Y = np.concatenate(y_list)
                configs.append({"pre": pre, "hold": hold, "thresh": th,
                                "G": G, "C": C, "Y": Y})
                all_cost.append(C)

    mean_cost = float(np.concatenate(all_cost).mean()) if all_cost else 0.0
    print(f"MEAN modeled cost (M15 spread) = {mean_cost:.3f} bp  "
          f"(realistic major round-trip ~1.0-1.5 bp normal, more at the fix)")

    # cost stress curve
    print("HAIRCUT_CURVE  extra_bp -> survivors / best_OOS_t / best_net_bp")
    curve = []
    for hc in EXTRA_COSTS:
        surv, best_oos_t, best_net = 0, -99.0, -99.0
        for cf in configs:
            net = cf["G"] - cf["C"] - hc
            oos = np.isin(cf["Y"], list(OOS_YEARS))
            t_all = tstat(net)
            oos_t = tstat(net[oos]) if oos.sum() > 1 else 0.0
            if (t_all > REQ_T) and (oos_t > 2.0) and (net.mean() > 0):
                surv += 1
                best_oos_t = max(best_oos_t, oos_t)
                best_net = max(best_net, float(net.mean()))
        curve.append({"extra_bp": hc, "survivors": surv,
                      "best_oos_t": round(best_oos_t, 2), "best_net_bp": round(best_net, 3)})
        print(f"  +{hc:>3} bp -> survivors={surv:2d}  best_OOS_t={best_oos_t:6.2f}  best_net={best_net:6.3f}")

    payload = {"meta": {"pairs": meta_pairs, "mean_modeled_cost_bp": round(mean_cost, 4),
                        "req_t": REQ_T, "extra_costs": EXTRA_COSTS},
               "haircut_curve": curve}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(f"wrote {out_path} configs={len(configs)} mean_cost={mean_cost:.3f}")
    mt5.shutdown()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="fix_v3.json")
    a = ap.parse_args()
    run(a.out)

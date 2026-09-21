#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# er_ic_v1.py  --  trend-efficiency-filtered momentum, TRUE OOS test
#
# regime_ic (in-sample 2022-2024) flagged ER (Kaufman efficiency ratio) as the
# one axis with a consistent, economically sensible IC: clean/efficient trends
# tend to continue. This tests that as a tradeable rule on TRUE OOS (2015-2021):
#
#   ER_K(t) = |c[t]-c[t-K]| / sum_{i}|c[i]-c[i-1]|   over the last K bars (0..1)
#   rule: when ER_K > theta, follow the K-bar momentum; exit after hfx bars.
#
# theta=0 is included as the BASELINE (plain momentum, no efficiency filter) so
# we can see whether the ER filter actually improves plain momentum -- that is
# the real question, not whether momentum alone works.
#
# Framework parity: log-bp PnL (pair-normalised), non-overlapping sampling (no
# inflated t), true OOS split, Bonferroni-corrected t over the config count,
# real spread cost + built-in haircut curve {0,0.5,1,1.5,2,3} bp.
#
#   python er_ic_v1.py --out er.json

import argparse
import json
import math
import sys
from datetime import datetime, timedelta
from statistics import NormalDist

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

PAIRS = ["EURUSD", "GBPUSD", "USDJPY", "USDCHF", "AUDUSD"]  # last two ~ pseudo-OOS pairs
TF = mt5.TIMEFRAME_M15
YEAR_START, YEAR_END = 2015, 2024
OOS_YEARS = set(range(2015, 2022))
IS_YEARS = set(range(2022, 2025))

KS = [16, 32]                 # ER lookback / momentum window (from regime_ic meta)
THETAS = [0.0, 0.35, 0.5]     # 0 = plain-momentum baseline; 0.35 = regime_ic's theta
HFXS = [8, 16, 32]            # forward holding (bars)
MIN_N = 50

REQ_T = NormalDist().inv_cdf(1 - (0.05 / (len(KS) * len(THETAS) * len(HFXS))) / 2)
EXTRA_COSTS = [0.0, 0.5, 1.0, 1.5, 2.0, 3.0]


def mt5_init():
    if not mt5.initialize():
        print("[fatal] mt5.initialize failed:", mt5.last_error(), file=sys.stderr)
        sys.exit(2)


def load_pair(symbol):
    mt5.symbol_select(symbol, True)
    info = mt5.symbol_info(symbol)
    if info is None:
        return None, {"bars": 0}
    dt_from = datetime(YEAR_START, 1, 1) - timedelta(days=3)
    dt_to = datetime(YEAR_END, 12, 31) + timedelta(days=3)
    rates = mt5.copy_rates_range(symbol, TF, dt_from, dt_to)
    if rates is None or len(rates) == 0:
        return None, {"bars": 0}
    df = pd.DataFrame(rates)
    df["srv"] = pd.to_datetime(df["time"], unit="s")
    df = df.set_index("srv").sort_index()
    df["point"] = info.point
    df["spread_pts"] = df["spread"].astype(float)
    return df[["close", "spread_pts", "point"]].copy(), {"bars": int(len(df))}


def er_series(c, K):
    """Kaufman efficiency ratio over K bars (vectorised)."""
    diff1 = np.abs(np.diff(c, prepend=c[0]))
    path = pd.Series(diff1).rolling(K).sum().values
    net = np.abs(c - pd.Series(c).shift(K).values)
    with np.errstate(divide="ignore", invalid="ignore"):
        er = np.where(path > 0, net / path, np.nan)
    return er


def config_trades(close, K, theta, hfx):
    c = close["close"].astype(float).values
    logc = np.log(c)
    n = len(c)
    er = er_series(c, K)
    mom = np.sign(c - pd.Series(c).shift(K).values)
    spread_bp = (close["spread_pts"].values * close["point"].values) / c * 1e4
    years = close.index.year.values

    qual = np.where((er > theta) & (mom != 0) & ~np.isnan(er))[0]
    qual = qual[(qual >= K) & (qual < n - hfx)]
    # greedy non-overlapping selection (spacing >= hfx)
    picks = []
    last = -10**9
    for i in qual:
        if i - last >= hfx:
            picks.append(i)
            last = i
    if len(picks) < MIN_N:
        return None
    picks = np.array(picks)
    gross = mom[picks] * (logc[picks + hfx] - logc[picks]) * 1e4
    cost = spread_bp[picks]
    yrs = years[picks]
    return gross, cost, yrs


def tstat(x):
    x = np.asarray(x, dtype=float)
    if x.size < 2:
        return 0.0
    sd = x.std(ddof=1)
    return float(x.mean() / (sd / math.sqrt(x.size))) if sd else 0.0


def run(out_path):
    mt5_init()
    print(f"ER-momentum OOS | KS={KS} THETAS={THETAS} HFXS={HFXS} "
          f"req_t={REQ_T:.3f} (Bonferroni, {len(KS)*len(THETAS)*len(HFXS)} configs)")
    data, meta = {}, {}
    for s in PAIRS:
        cl, m = load_pair(s)
        meta[s] = m
        if cl is None or m["bars"] == 0:
            print(f"[warn] {s}: bars=0"); continue
        data[s] = cl
        print(f"{s}: bars={m['bars']}")

    configs, per_pair = [], []
    for K in KS:
        for th in THETAS:
            for hfx in HFXS:
                gl, cl_, yl = [], [], []
                for s, cl in data.items():
                    r = config_trades(cl, K, th, hfx)
                    if r is None:
                        continue
                    g, c, y = r
                    per_pair.append({"pair": s, "K": K, "theta": th, "hfx": hfx,
                                     "N": int(g.size),
                                     "EV_gross_bp": round(float(g.mean()), 4),
                                     "EV_net_bp": round(float((g - c).mean()), 4),
                                     "t_net": round(tstat(g - c), 3)})
                    gl.append(g); cl_.append(c); yl.append(y)
                if not gl:
                    continue
                G = np.concatenate(gl); C = np.concatenate(cl_); Y = np.concatenate(yl)
                configs.append({"K": K, "theta": th, "hfx": hfx, "G": G, "C": C, "Y": Y})

    pooled = []
    for cf in configs:
        net = cf["G"] - cf["C"]
        oos = np.isin(cf["Y"], list(OOS_YEARS)); ins = np.isin(cf["Y"], list(IS_YEARS))
        by_year = {int(y): round(float(net[cf["Y"] == y].mean()), 3) for y in sorted(set(cf["Y"].tolist()))}
        yp = sum(1 for v in by_year.values() if v > 0)
        oos_t = tstat(net[oos]) if oos.sum() > 1 else 0.0
        is_t = tstat(net[ins]) if ins.sum() > 1 else 0.0
        surv = (tstat(net) > REQ_T) and (oos_t > 2.0) and (net.mean() > 0)
        pooled.append({"K": cf["K"], "theta": cf["theta"], "hfx": cf["hfx"], "N": int(net.size),
                       "EV_gross_bp": round(float(cf["G"].mean()), 4),
                       "EV_net_bp": round(float(net.mean()), 4),
                       "t_net": round(tstat(net), 3), "OOS_t": round(oos_t, 3),
                       "IS_t": round(is_t, 3), "OOS_EV_bp": round(float(net[oos].mean()) if oos.sum() else 0.0, 3),
                       "years_pos": f"{yp}/{len(by_year)}", "SURVIVES": bool(surv)})

    surv0 = sum(1 for r in pooled if r["SURVIVES"])
    print(f"survivors@modeled = {surv0}/{len(pooled)}")
    # baseline vs filtered: show all, grouped by (K,hfx), so theta effect is visible
    for r in sorted(pooled, key=lambda z: (z["K"], z["hfx"], z["theta"])):
        flag = " <==SV" if r["SURVIVES"] else ""
        print(f"  K{r['K']:>2} th{r['theta']:.2f} hf{r['hfx']:>2} N{r['N']:>6} "
              f"gross{r['EV_gross_bp']:+7.3f} net{r['EV_net_bp']:+7.3f} tnet{r['t_net']:+6.2f} "
              f"OOSt{r['OOS_t']:+6.2f} ISt{r['IS_t']:+6.2f} yr{r['years_pos']}{flag}")

    print("HAIRCUT_CURVE  extra_bp -> survivors / best_OOS_t / best_net")
    curve = []
    for hc in EXTRA_COSTS:
        sv, bo, bn = 0, -99.0, -99.0
        for cf in configs:
            net = cf["G"] - cf["C"] - hc
            oos = np.isin(cf["Y"], list(OOS_YEARS))
            ot = tstat(net[oos]) if oos.sum() > 1 else 0.0
            if (tstat(net) > REQ_T) and (ot > 2.0) and (net.mean() > 0):
                sv += 1; bo = max(bo, ot); bn = max(bn, float(net.mean()))
        curve.append({"extra_bp": hc, "survivors": sv, "best_oos_t": round(bo, 2), "best_net_bp": round(bn, 3)})
        print(f"  +{hc:>3} bp -> survivors={sv:2d}  best_OOS_t={bo:6.2f}  best_net={bn:6.3f}")

    payload = {"meta": {"pairs": meta, "KS": KS, "THETAS": THETAS, "HFXS": HFXS,
                        "req_t": round(REQ_T, 4), "oos_years": sorted(OOS_YEARS)},
               "per_pair": per_pair, "pooled": pooled, "haircut_curve": curve}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(f"wrote {out_path} tests={len(pooled)} survivors={surv0} req_t={REQ_T:.3f}")
    mt5.shutdown()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="er.json")
    a = ap.parse_args()
    run(a.out)

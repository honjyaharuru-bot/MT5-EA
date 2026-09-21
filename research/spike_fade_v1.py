#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# spike_fade_v1.py  --  C04: outlier-bar (post-news overshoot) reversion
#
# Rule (calendar-free, endogenous): a bar whose log body |log(close)-log(open)|
# exceeds K * rolling-average body is an overshoot; fade it (enter opposite at
# the bar close), exit after HOLD bars. This is the catalog's "1st bar body =
# 2x average -> fade" rule, generalised so no economic-calendar API is needed.
#
# Two sessions are swept: "all" (any outlier bar, high N) and "us0830ET" (only
# the bar opening 08:30 America/New_York, i.e. the NFP/CPI release bar) to see
# whether the edge concentrates at scheduled US data. Server time (EET) is
# converted via zoneinfo so the US/EU DST mismatch weeks are handled correctly.
#
# Framework parity: PnL in bp (log*1e4, pair-normalised); OOS=2015-2021;
# Bonferroni-corrected t over the config count; real spread cost PLUS a built-in
# haircut curve {0,0.5,1,1.5,2,3} bp (the B02 lesson applied up front, since
# outlier bars are exactly when spreads blow out). Output mirrors the prior
# scripts (meta / per_pair / pooled) and adds haircut_curve.
#
# Sanity first:  python spike_fade_v1.py --check
# Full run:      python spike_fade_v1.py --out spike.json

import argparse
import json
import math
import sys
from datetime import datetime, timedelta
from statistics import NormalDist

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

PAIRS = ["EURUSD", "GBPUSD", "USDJPY", "USDCHF", "AUDUSD"]
TF = mt5.TIMEFRAME_M15
YEAR_START, YEAR_END = 2015, 2024
OOS_YEARS = set(range(2015, 2022))
IS_YEARS = set(range(2022, 2025))

KS = [2.0, 3.0, 4.0]              # outlier threshold (x rolling avg body)
HOLD_BARS = [1, 2, 4]            # reversion horizon (15/30/60 min)
SESSIONS = ["all", "us0830ET"]   # all bars vs the US 08:30 ET release bar
AVG_WIN = 96                     # rolling window (~1 M15 day) for avg body
MIN_N = 30                       # skip configs with too few trades

SERVER_TZ = "Europe/Bucharest"   # EET/EEST broker time (matches MT5 default)
US_TZ = "America/New_York"

EXTRA_COSTS = [0.0, 0.5, 1.0, 1.5, 2.0, 3.0]

FAMILY_ALPHA = 0.05
N_CONFIGS = len(KS) * len(HOLD_BARS) * len(SESSIONS)
REQ_T = NormalDist().inv_cdf(1 - (FAMILY_ALPHA / N_CONFIGS) / 2)  # Bonferroni, 2-sided


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
    return df[["open", "close", "spread_pts", "point"]].copy(), {"bars": int(len(df)), "digits": int(info.digits)}


def prep_pair(df):
    """Return a frame with logc, log-body, rolling avg body (shift1), spread_bp,
    forward returns per HOLD, year, and a us0830ET session flag."""
    o = df["open"].astype(float).values
    c = df["close"].astype(float).values
    logc = np.log(c)
    logo = np.log(o)
    lbody = logc - logo                              # bar log return (signed)
    absb = np.abs(lbody)
    out = pd.DataFrame(index=df.index)
    out["logc"] = logc
    out["lbody"] = lbody
    out["absb"] = absb
    out["avgb"] = pd.Series(absb, index=df.index).rolling(AVG_WIN, min_periods=30).mean().shift(1).values
    out["spread_bp"] = (df["spread_pts"].values * df["point"].values) / c * 1e4
    out["year"] = df.index.year
    for h in HOLD_BARS:
        out[f"fwd_{h}"] = pd.Series(logc, index=df.index).shift(-h).values - logc
    # US 08:30 ET release bar
    et = df.index.tz_localize(SERVER_TZ, ambiguous="NaT", nonexistent="shift_forward").tz_convert(US_TZ)
    out["us0830"] = (et.hour == 8) & (et.minute == 30)
    return out


def tstat(x):
    x = np.asarray(x, dtype=float)
    if x.size < 2:
        return 0.0
    sd = x.std(ddof=1)
    return float(x.mean() / (sd / math.sqrt(x.size))) if sd else 0.0


def config_trades(prep, k, hold, session):
    """Return gross_bp, cost_bp, years for one (K, HOLD, SESSION) on one pair."""
    absb = prep["absb"].values
    avgb = prep["avgb"].values
    outlier = absb > (k * avgb)
    sess = np.ones(len(prep), dtype=bool) if session == "all" else prep["us0830"].values.astype(bool)
    fwd = prep[f"fwd_{hold}"].values
    take = outlier & sess & ~np.isnan(fwd) & ~np.isnan(avgb)
    if take.sum() == 0:
        return None
    side = -np.sign(prep["lbody"].values[take])      # fade the bar direction
    gross_bp = side * fwd[take] * 1e4
    cost_bp = prep["spread_bp"].values[take]
    years = prep["year"].values[take]
    ok = side != 0
    return gross_bp[ok], cost_bp[ok], years[ok]


def run(out_path, check=False):
    mt5_init()
    print(f"C04 spike-fade | configs={N_CONFIGS} req_t={REQ_T:.3f} (Bonferroni) "
          f"KS={KS} HOLD={HOLD_BARS} SESS={SESSIONS}")
    preps, meta_pairs = {}, {}
    for s in PAIRS:
        df, m = load_pair(s)
        meta_pairs[s] = m
        if df is None or m["bars"] == 0:
            print(f"[warn] {s}: bars=0"); continue
        p = prep_pair(df)
        preps[s] = p
        n_out = int((p["absb"].values > 2.0 * p["avgb"].values).sum())
        n_us = int(p["us0830"].sum())
        if check:
            et_sample = df.index[p["us0830"].values][:3]
            et_sample = et_sample.tz_localize(SERVER_TZ, ambiguous="NaT", nonexistent="shift_forward").tz_convert(US_TZ)
            print(f"{s}: bars={m['bars']} outliers(K2)={n_out} us0830_bars={n_us} "
                  f"ET_sample={[str(x) for x in et_sample]}")
        else:
            print(f"{s}: bars={m['bars']} outliers(K2)={n_out} us0830_bars={n_us}")

    if check:
        print("CHECK DONE. Expect ET_sample times = 08:30:00, us0830_bars ~2000-2500, "
              "outliers(K2) a few % of bars. If so, rerun without --check.")
        mt5.shutdown()
        return

    # collect per-config pooled arrays
    configs, per_pair_out = [], []
    for k in KS:
        for hold in HOLD_BARS:
            for session in SESSIONS:
                gl, cl, yl = [], [], []
                for s, p in preps.items():
                    r = config_trades(p, k, hold, session)
                    if r is None:
                        continue
                    g, c, y = r
                    if g.size >= MIN_N:
                        per_pair_out.append({
                            "pair": s, "K": k, "hold": hold, "session": session,
                            "N": int(g.size),
                            "EV_gross_bp": round(float(g.mean()), 4),
                            "EV_net_bp": round(float((g - c).mean()), 4),
                            "t_gross": round(tstat(g), 3),
                        })
                    gl.append(g); cl.append(c); yl.append(y)
                if not gl:
                    continue
                G = np.concatenate(gl); C = np.concatenate(cl); Y = np.concatenate(yl)
                if G.size < MIN_N:
                    continue
                configs.append({"K": k, "hold": hold, "session": session,
                                "G": G, "C": C, "Y": Y})

    # survivors at modeled cost (haircut 0) with detail
    pooled_out = []
    for cf in configs:
        net = cf["G"] - cf["C"]
        oos = np.isin(cf["Y"], list(OOS_YEARS))
        by_year = {int(y): round(float(net[cf["Y"] == y].mean()), 3) for y in sorted(set(cf["Y"].tolist()))}
        years_pos = sum(1 for v in by_year.values() if v > 0)
        oos_t = tstat(net[oos]) if oos.sum() > 1 else 0.0
        survives = (tstat(net) > REQ_T) and (oos_t > 2.0) and (net.mean() > 0)
        pooled_out.append({
            "K": cf["K"], "hold": cf["hold"], "session": cf["session"],
            "N": int(net.size),
            "EV_gross_bp": round(float(cf["G"].mean()), 4),
            "EV_net_bp": round(float(net.mean()), 4),
            "t_net": round(tstat(net), 3),
            "OOS_t": round(oos_t, 3),
            "OOS_EV_bp": round(float(net[oos].mean()) if oos.sum() else 0.0, 3),
            "years_pos": f"{years_pos}/{len(by_year)}",
            "SURVIVES": bool(survives),
        })

    mean_cost_all = float(np.concatenate([cf["C"] for cf in configs]).mean()) if configs else 0.0
    surv0 = sum(1 for r in pooled_out if r["SURVIVES"])
    print(f"MEAN modeled cost = {mean_cost_all:.3f} bp   survivors@modeled={surv0}/{len(configs)}")
    for r in sorted([r for r in pooled_out if r["SURVIVES"]], key=lambda z: -z["t_net"]):
        print(f"  SV K{r['K']} h{r['hold']} {r['session']:9s} gross{r['EV_gross_bp']:7.3f} "
              f"net{r['EV_net_bp']:7.3f} tnet{r['t_net']:6.2f} OOSt{r['OOS_t']:6.2f} yr{r['years_pos']}")

    # haircut curve
    print("HAIRCUT_CURVE  extra_bp -> survivors / best_OOS_t / best_net_bp")
    curve = []
    for hc in EXTRA_COSTS:
        surv, best_oos, best_net = 0, -99.0, -99.0
        for cf in configs:
            net = cf["G"] - cf["C"] - hc
            oos = np.isin(cf["Y"], list(OOS_YEARS))
            oos_t = tstat(net[oos]) if oos.sum() > 1 else 0.0
            if (tstat(net) > REQ_T) and (oos_t > 2.0) and (net.mean() > 0):
                surv += 1; best_oos = max(best_oos, oos_t); best_net = max(best_net, float(net.mean()))
        curve.append({"extra_bp": hc, "survivors": surv,
                      "best_oos_t": round(best_oos, 2), "best_net_bp": round(best_net, 3)})
        print(f"  +{hc:>3} bp -> survivors={surv:2d}  best_OOS_t={best_oos:6.2f}  best_net={best_net:6.3f}")

    payload = {
        "meta": {"pairs": meta_pairs, "req_t": round(REQ_T, 4), "n_configs": N_CONFIGS,
                 "mean_modeled_cost_bp": round(mean_cost_all, 4),
                 "ks": KS, "hold": HOLD_BARS, "sessions": SESSIONS,
                 "oos_years": sorted(OOS_YEARS)},
        "per_pair": per_pair_out,
        "pooled": pooled_out,
        "haircut_curve": curve,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(f"wrote {out_path} tests={len(pooled_out)} survivors={surv0} req_t={REQ_T:.3f}")
    mt5.shutdown()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="spike.json")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    run(a.out, check=a.check)

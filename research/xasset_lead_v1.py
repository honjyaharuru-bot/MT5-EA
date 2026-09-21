#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# xasset_lead_v1.py  --  cross-asset PREDICTIVE lead-lag probe (gross first)
#
# Question: does a LAGGED move in an exogenous asset (S&P/oil/gold CFD) predict
# the FUTURE return of an FX major? Only a genuine LEAD is tradeable; simultaneous
# correlation (both move on the same news) is not. So this is built to be strictly
# predictive:
#   signal  = log(exo[t]) - log(exo[t-Hsig])     # exo move ending AT t (past)
#   outcome = log(fx[t+hfx]) - log(fx[t])        # FX move AFTER t (future)
#   decision at close[t]: signal known, outcome unknown, enter FX at close[t].
# Forward windows are sampled NON-OVERLAPPING (step = hfx) so overlapping-return
# pseudo-replication does not inflate the t-stats.
#
# We do not pre-commit to follow vs fade: we measure the sign-following rule's
# gross EV (bp) and its signed t. Positive => follow the exo move; negative =>
# fade it. Framework parity: log returns (pair/scale-normalised), true OOS
# (2015-2021), Bonferroni-corrected t. Gross first; cost/regime come next only
# if a predictive lead survives OOS.
#
# Broker CFD names vary, so run discovery first:
#   python xasset_lead_v1.py --symbols        # list index/commodity symbols + bars
#   python xasset_lead_v1.py --out xa.json    # full probe (auto-resolves exo)

import argparse
import json
import math
import sys
from datetime import datetime, timedelta
from statistics import NormalDist

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

FX = ["AUDUSD", "USDJPY", "EURUSD", "GBPUSD", "USDCHF"]   # confirmed loadable
TF = mt5.TIMEFRAME_M15
YEAR_START, YEAR_END = 2015, 2024
OOS_YEARS = set(range(2015, 2022))

HSIGS = [4, 16]     # exo signal lookback (bars): 1h, 4h
HFXS = [4, 16]      # FX forward horizon (bars): 1h, 4h
MIN_N = 100

# candidate broker symbol names per exogenous asset (first with data wins)
EXO_CANDIDATES = {
    "SPX": ["US500", "SPX500", "SP500", "SPX", "US500.cash", "SPX500.cash",
            "SP500m", "US500m", "SPXUSD", "US_500", "USA500"],
    "OIL": ["USOIL", "XTIUSD", "WTI", "USOIL.cash", "OILUSD", "XTIUSD.",
            "USOILm", "WTIUSD", "CRUDOIL", "CL", "OIL", "USCrude"],
    "GOLD": ["XAUUSD", "GOLD", "XAUUSDm", "GOLD.cash", "XAUUSD.", "GOLDUSD"],
}
DISCOVERY_KEYS = ["SPX", "US500", "SP500", "OIL", "WTI", "XTI", "BRENT", "XBR",
                  "XAU", "GOLD", "NAS", "US100", "USTEC", "GER", "DAX", "US30",
                  "DJ", "VIX", "CRUD"]


def mt5_init():
    if not mt5.initialize():
        print("[fatal] mt5.initialize failed:", mt5.last_error(), file=sys.stderr)
        sys.exit(2)


def load_close(symbol):
    mt5.symbol_select(symbol, True)
    dt_from = datetime(YEAR_START, 1, 1) - timedelta(days=3)
    dt_to = datetime(YEAR_END, 12, 31) + timedelta(days=3)
    rates = mt5.copy_rates_range(symbol, TF, dt_from, dt_to)
    if rates is None or len(rates) == 0:
        return None
    df = pd.DataFrame(rates)
    df["srv"] = pd.to_datetime(df["time"], unit="s")
    s = df.set_index("srv")["close"].astype(float).sort_index()
    s = s[~s.index.duplicated(keep="last")]
    return s


def discover():
    mt5_init()
    syms = mt5.symbols_get()
    print(f"total symbols visible: {len(syms)}")
    hits = []
    for s in syms:
        up = s.name.upper()
        if any(k in up for k in DISCOVERY_KEYS):
            hits.append(s.name)
    print(f"index/commodity candidates ({len(hits)}):")
    for name in sorted(hits):
        c = load_close(name)
        n = 0 if c is None else len(c)
        print(f"  {name:16s} bars={n}")
    print("Pick the real SPX / OIL / GOLD names from the list above; the full run "
          "auto-resolves from EXO_CANDIDATES (edit it if your names differ).")
    mt5.shutdown()


def resolve_exo():
    resolved = {}
    for label, cands in EXO_CANDIDATES.items():
        for name in cands:
            c = load_close(name)
            if c is not None and len(c) > 1000:
                resolved[label] = (name, c)
                print(f"resolved {label} -> {name} (bars={len(c)})")
                break
        if label not in resolved:
            print(f"[warn] {label}: no candidate resolved (edit EXO_CANDIDATES)")
    return resolved


def tstat(x):
    x = np.asarray(x, dtype=float)
    if x.size < 2:
        return 0.0
    sd = x.std(ddof=1)
    return float(x.mean() / (sd / math.sqrt(x.size))) if sd else 0.0


def eval_pair(exo_close, fx_close, hsig, hfx):
    """Predictive, non-overlapping. Return trade_bp array, years array, corr."""
    j = pd.concat({"e": exo_close, "f": fx_close}, axis=1, join="inner").dropna()
    if len(j) < (hsig + hfx + MIN_N):
        return None
    le = np.log(j["e"].values)
    lf = np.log(j["f"].values)
    yrs = j.index.year.values
    n = len(j)
    # non-overlapping entry points spaced by hfx, needing hsig history and hfx future
    starts = np.arange(hsig, n - hfx, hfx)
    if starts.size < MIN_N:
        return None
    signal = le[starts] - le[starts - hsig]            # exo past move
    fx_fwd = (lf[starts + hfx] - lf[starts]) * 1e4      # FX future move (bp)
    years = yrs[starts]
    side = np.sign(signal)
    take = side != 0
    trade_bp = side[take] * fx_fwd[take]               # follow rule
    years = years[take]
    if trade_bp.size < MIN_N:
        return None
    if np.std(signal[take]) == 0 or np.std(fx_fwd[take]) == 0:
        corr = 0.0
    else:
        corr = float(np.corrcoef(signal[take], fx_fwd[take])[0, 1])
    return trade_bp, years, corr


def run(out_path):
    mt5_init()
    resolved = resolve_exo()
    if not resolved:
        print("[fatal] no exo symbols; run --symbols to find names", file=sys.stderr)
        mt5.shutdown(); sys.exit(3)

    fx_close = {}
    for s in FX:
        c = load_close(s)
        if c is None:
            print(f"[warn] {s}: no data"); continue
        fx_close[s] = c
        print(f"FX {s}: bars={len(c)}")

    n_configs = len(resolved) * len(fx_close) * len(HSIGS) * len(HFXS)
    req_t = NormalDist().inv_cdf(1 - (0.05 / n_configs) / 2)
    print(f"n_configs={n_configs} req_t={req_t:.3f} (Bonferroni)")

    rows, survivors = [], 0
    for elabel, (ename, eclose) in resolved.items():
        for fs, fc in fx_close.items():
            for hsig in HSIGS:
                for hfx in HFXS:
                    r = eval_pair(eclose, fc, hsig, hfx)
                    if r is None:
                        continue
                    trade_bp, years, corr = r
                    oos = np.isin(years, list(OOS_YEARS))
                    t_all = tstat(trade_bp)
                    oos_t = tstat(trade_bp[oos]) if oos.sum() > 1 else 0.0
                    ev = float(trade_bp.mean())
                    surv = (abs(t_all) > req_t) and (abs(oos_t) > 2.0) and \
                           (np.sign(t_all) == np.sign(oos_t))
                    if surv:
                        survivors += 1
                    rows.append({
                        "exo": elabel, "sym": ename, "fx": fs,
                        "hsig": hsig, "hfx": hfx, "N": int(trade_bp.size),
                        "corr": round(corr, 4),
                        "gross_bp": round(ev, 4),
                        "t_gross": round(t_all, 3),
                        "OOS_t": round(oos_t, 3),
                        "SURVIVES": bool(surv),
                    })

    # report: significant configs first
    rows.sort(key=lambda z: -abs(z["t_gross"]))
    print(f"--- configs with |t_gross|>2 (of {len(rows)}) ---")
    shown = 0
    for r in rows:
        if abs(r["t_gross"]) > 2.0:
            flag = "  <== SURVIVES" if r["SURVIVES"] else ""
            print(f"{r['exo']:4s}->{r['fx']} Hs{r['hsig']:>2} hf{r['hfx']:>2} "
                  f"N{r['N']:>6} corr{r['corr']:+.3f} gross{r['gross_bp']:+7.3f}bp "
                  f"t{r['t_gross']:+6.2f} OOSt{r['OOS_t']:+6.2f}{flag}")
            shown += 1
    if shown == 0:
        print("  (none reached |t|>2 -- no predictive lead)")
    print(f"SURVIVORS (|t|>req_t & |OOS_t|>2 & sign-consistent) = {survivors}/{len(rows)} req_t={req_t:.3f}")

    payload = {"meta": {"resolved_exo": {k: v[0] for k, v in resolved.items()},
                        "fx": list(fx_close.keys()), "n_configs": n_configs,
                        "req_t": round(req_t, 4), "oos_years": sorted(OOS_YEARS),
                        "hsigs": HSIGS, "hfxs": HFXS},
               "results": rows}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(f"wrote {out_path} configs={len(rows)} survivors={survivors}")
    mt5.shutdown()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="xa.json")
    ap.add_argument("--symbols", action="store_true", help="discover exo symbol names")
    a = ap.parse_args()
    if a.symbols:
        discover()
    else:
        run(a.out)

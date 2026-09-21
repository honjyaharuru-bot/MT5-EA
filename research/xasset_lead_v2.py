#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# xasset_lead_v2.py  --  cross-asset PREDICTIVE lead-lag probe (gross first)
# Same probe as v1; ONLY the --symbols discovery is fixed to be fast + tight.
# (v1 matched 3298 stock symbols via the loose key 'NAS' and loaded full history
#  for each = very slow. v2 uses tight index/commodity tokens, excludes stock
#  exchange suffixes, and loads history only for a small filtered set.)

import argparse
import json
import math
import re
import sys
from datetime import datetime, timedelta
from statistics import NormalDist

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

FX = ["AUDUSD", "USDJPY", "EURUSD", "GBPUSD", "USDCHF"]
TF = mt5.TIMEFRAME_M15
YEAR_START, YEAR_END = 2015, 2024
OOS_YEARS = set(range(2015, 2022))

HSIGS = [4, 16]
HFXS = [4, 16]
MIN_N = 100

EXO_CANDIDATES = {
    "SPX": ["US500", "SPX500", "SP500", "SPX", "US500.cash", "SPX500.cash",
            "US500.spot", "SP500.cash", "SPXUSD", "USA500", "US500_SB", "#US500"],
    "OIL": ["USOIL", "XTIUSD", "WTI", "USOIL.cash", "OILUSD", "XTIUSD.",
            "WTIUSD", "CRUDOIL", "USOIL.spot", "UKOIL", "XBRUSD", "#USOIL"],
    "GOLD": ["XAUUSD", "GOLD", "XAUUSD.", "GOLD.cash", "GOLDUSD", "#XAUUSD"],
}

# tight tokens for discovery (whole/prefix-ish, index & commodity only)
DISC_TOKENS = ["US500", "SPX500", "SP500", "US30", "US100", "USTEC", "NAS100",
               "GER40", "GER30", "DE40", "DE30", "UK100", "FRA40", "EU50", "STOXX",
               "JP225", "JPN225", "AUS200", "HK50", "CHINA", "VIX", "DXY", "USDX",
               "XAUUSD", "XAGUSD", "GOLD", "SILVER", "USOIL", "UKOIL", "XTIUSD",
               "XBRUSD", "WTI", "BRENT", "NGAS", "NATGAS", "XPTUSD", "COPPER"]
STOCK_SFX = [".NAS", ".NYSE", ".NMS", ".ARCA", ".BATS", ".OTC", ".LSE", ".ASX",
             ".HK", ".TSE", ".SW", ".PA", ".MI", ".AS", ".BR"]


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
    return s[~s.index.duplicated(keep="last")]


def discover():
    mt5_init()
    syms = mt5.symbols_get()
    names = [s.name for s in syms]
    print(f"total symbols visible: {len(names)}")

    def is_stock(nm):
        up = nm.upper()
        return any(sfx in up for sfx in STOCK_SFX)

    cand = []
    for nm in names:
        up = nm.upper()
        if is_stock(nm):
            continue
        if any(tok in up for tok in DISC_TOKENS):
            cand.append(nm)
    cand = sorted(set(cand))
    print(f"tight index/commodity candidates: {len(cand)}")
    # load history only for a bounded set
    LIMIT = 80
    for nm in cand[:LIMIT]:
        # quick recent-bar existence check, then full count
        recent = mt5.copy_rates_from_pos(nm, TF, 0, 5)
        if recent is None or len(recent) == 0:
            print(f"  {nm:16s} (no data)")
            continue
        c = load_close(nm)
        print(f"  {nm:16s} bars={0 if c is None else len(c)}")
    if len(cand) > LIMIT:
        print(f"  ...and {len(cand)-LIMIT} more (names only):")
        print("   " + ", ".join(cand[LIMIT:]))
    print("Pick real SPX / OIL / GOLD names; full run auto-resolves from "
          "EXO_CANDIDATES (edit if needed).")
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
    j = pd.concat({"e": exo_close, "f": fx_close}, axis=1, join="inner").dropna()
    if len(j) < (hsig + hfx + MIN_N):
        return None
    le = np.log(j["e"].values)
    lf = np.log(j["f"].values)
    yrs = j.index.year.values
    n = len(j)
    starts = np.arange(hsig, n - hfx, hfx)
    if starts.size < MIN_N:
        return None
    signal = le[starts] - le[starts - hsig]
    fx_fwd = (lf[starts + hfx] - lf[starts]) * 1e4
    years = yrs[starts]
    side = np.sign(signal)
    take = side != 0
    trade_bp = side[take] * fx_fwd[take]
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
        print("[fatal] no exo symbols; run --symbols", file=sys.stderr)
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
                    survivors += int(surv)
                    rows.append({"exo": elabel, "sym": ename, "fx": fs,
                                 "hsig": hsig, "hfx": hfx, "N": int(trade_bp.size),
                                 "corr": round(corr, 4), "gross_bp": round(ev, 4),
                                 "t_gross": round(t_all, 3), "OOS_t": round(oos_t, 3),
                                 "SURVIVES": bool(surv)})

    rows.sort(key=lambda z: -abs(z["t_gross"]))
    print(f"--- |t_gross|>2 (of {len(rows)}) ---")
    shown = 0
    for r in rows:
        if abs(r["t_gross"]) > 2.0:
            flag = "  <== SURVIVES" if r["SURVIVES"] else ""
            print(f"{r['exo']:4s}->{r['fx']} Hs{r['hsig']:>2} hf{r['hfx']:>2} "
                  f"N{r['N']:>6} corr{r['corr']:+.3f} gross{r['gross_bp']:+7.3f} "
                  f"t{r['t_gross']:+6.2f} OOSt{r['OOS_t']:+6.2f}{flag}")
            shown += 1
    if shown == 0:
        print("  (none reached |t|>2 -- no predictive lead)")
    print(f"SURVIVORS = {survivors}/{len(rows)} req_t={req_t:.3f}")

    payload = {"meta": {"resolved_exo": {k: v[0] for k, v in resolved.items()},
                        "fx": list(fx_close.keys()), "n_configs": n_configs,
                        "req_t": round(req_t, 4)},
               "results": rows}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(f"wrote {out_path} configs={len(rows)} survivors={survivors}")
    mt5.shutdown()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="xa.json")
    ap.add_argument("--symbols", action="store_true")
    a = ap.parse_args()
    discover() if a.symbols else run(a.out)

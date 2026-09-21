#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
spread_probe_v2.py

v1 の結論: B03 のエントリー地点(週明け +15m)は週で最悪のスプレッド帯にあり、
           実コストを入れると優位性が消える。

v2 の問い: エントリーを遅らせればコストは落ちる。値幅はどこまで残るか。

  遅延 d  = 0, 2, 4, 8, 12 本 (週明け +15m, +45m, +1h15, +2h15, +3h15)
  保有 h  = 8, 16 本 (2h, 4h)
  窓幅    = 0.2, 0.4, 0.7, 1.0 ATR

主指標は「保守コスト + スリッページ」。楽観値は参考として併記する。

コスト:
  MT5 の rates は bid。
    買い -> 入口で ask を踏む   -> コスト = 入口スプレッド
    売り -> 出口で ask を踏む   -> コスト = 出口スプレッド
  保守版は約定バーとその1本前の大きい方を採用し、さらに SLIP を加える。

Usage:
  python spread_probe_v2.py --out sp2.json
  python spread_probe_v2.py --slip 0.5 --out sp2.json
"""
import argparse
import json
import math
from datetime import datetime, timezone, timedelta

import numpy as np
import pandas as pd

VERSION = "spread_probe_v2"

SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "NZDUSD",
           "USDCHF", "EURJPY", "GBPJPY"]

DATE_FROM = datetime(2015, 1, 1, tzinfo=timezone.utc)
DATE_TO   = datetime(2025, 1, 1, tzinfo=timezone.utc)
IS_START  = 2022
ATR_BARS  = 96

GAP_THRS = [0.2, 0.4, 0.7, 1.0]
DELAYS   = [0, 2, 4, 8, 12]
HOLDS    = [8, 16]


# ---------------------------------------------------------------- tz / utils
def _last_sunday(year, month):
    d = datetime(year, month, 31)
    while d.weekday() != 6:
        d -= timedelta(days=1)
    return d


def broker_offset_series(local_times):
    lt = pd.DatetimeIndex(local_times)
    off = np.full(len(lt), 2, dtype=np.int8)
    for y in np.unique(lt.year):
        s = _last_sunday(int(y), 3) + timedelta(hours=3)
        e = _last_sunday(int(y), 10) + timedelta(hours=4)
        off[(lt >= s) & (lt < e)] = 3
    return off


def pip_size(sym):
    return 0.01 if sym.endswith("JPY") else 0.0001


def points_per_pip(digits):
    return 10.0 if digits in (3, 5) else 1.0


def tstat(x):
    n = len(x)
    if n < 2:
        return 0.0
    sd = float(np.std(x, ddof=1))
    return float(np.mean(x) / (sd / math.sqrt(n))) if sd > 0 else 0.0


def req_t(n_tests, alpha=0.05):
    from math import erfc, sqrt
    p = alpha / max(1, n_tests) / 2.0
    lo, hi = 0.0, 10.0
    for _ in range(200):
        mid = (lo + hi) / 2
        if 0.5 * erfc(mid / sqrt(2.0)) > p:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


# ---------------------------------------------------------------- load
def load(symbol):
    import MetaTrader5 as mt5
    if not mt5.initialize():
        raise RuntimeError("mt5.initialize failed: %s" % (mt5.last_error(),))
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError("symbol_select failed")
    info = mt5.symbol_info(symbol)
    digits = int(info.digits) if info else 5
    rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M15, DATE_FROM, DATE_TO)
    if rates is None or len(rates) == 0:
        raise RuntimeError("no rates: %s" % (mt5.last_error(),))
    df = pd.DataFrame(rates)
    if "spread" not in df.columns:
        raise RuntimeError("no spread column")
    df["local"] = pd.to_datetime(df["time"], unit="s")
    df = df[["local", "open", "high", "low", "close", "spread"]].dropna()
    df = df.sort_values("local").reset_index(drop=True)
    if len(df) == 0:
        raise RuntimeError("empty")

    off = broker_offset_series(df["local"])
    df["utc"] = df["local"] - pd.to_timedelta(off, unit="h")
    df["jst"] = df["utc"] + pd.Timedelta(hours=9)
    df = df[(df["utc"] >= DATE_FROM.replace(tzinfo=None)) &
            (df["utc"] <  DATE_TO.replace(tzinfo=None))].reset_index(drop=True)
    if len(df) == 0:
        raise RuntimeError("empty after filter")

    df["spread_pips"] = df["spread"] / points_per_pip(digits)
    ps = pip_size(symbol)
    df["atr"]   = ((df["high"] - df["low"]) / ps).rolling(ATR_BARS).mean()
    df["jdow"]  = df["jst"].dt.dayofweek
    df["jdate"] = df["jst"].dt.date
    df["year"]  = df["jst"].dt.year
    df.attrs.update({"ps": ps, "digits": digits, "symbol": symbol})
    return df


# ---------------------------------------------------------------- signal
def monday_gaps(df, gap_thr):
    """週明け1本目のうち、窓幅が ATR 比でしきい値超のものを返す。"""
    newday = pd.Series(df["jdate"] != df["jdate"].shift(1)).values
    first_mon = newday & (df["jdow"] == 0).values
    ps = df.attrs["ps"]
    close_prev = np.roll(df["close"].values, 1)
    gap = (df["open"].values - close_prev) / ps
    gap[0] = 0.0
    with np.errstate(invalid="ignore", divide="ignore"):
        g = gap / df["atr"].values
    long_  = first_mon & (g < -gap_thr)     # 下窓 -> 買い戻し
    short_ = first_mon & (g >  gap_thr)     # 上窓 -> 売り戻し
    idx  = np.concatenate([np.flatnonzero(long_), np.flatnonzero(short_)])
    side = np.concatenate([np.ones(long_.sum()), -np.ones(short_.sum())])
    o = np.argsort(idx)
    return idx[o], side[o]


def evaluate(df, idx0, side0, delay, hold, slip, side_filter='both'):
    n = len(df)
    if side_filter == 'long':
        keep = side0 > 0
    elif side_filter == 'short':
        keep = side0 < 0
    else:
        keep = np.ones(len(side0), dtype=bool)
    idx0, side0 = idx0[keep], side0[keep]
    if len(idx0) == 0:
        return None
    entry_i = idx0 + 1 + delay
    exit_i  = entry_i + hold
    ok = exit_i < n
    entry_i, exit_i, side = entry_i[ok], exit_i[ok], side0[ok]
    base_i = idx0[ok]
    if len(entry_i) == 0:
        return None

    o, c = df["open"].values, df["close"].values
    sp, atr = df["spread_pips"].values, df["atr"].values
    ps = df.attrs["ps"]

    gross = (c[exit_i] - o[entry_i]) * side / ps

    sp_in_opt  = sp[entry_i]
    sp_in_cons = np.maximum(sp[entry_i - 1], sp[entry_i])
    sp_out_opt = sp[exit_i]
    sp_out_cons = np.maximum(sp[exit_i - 1], sp[exit_i])

    cost_opt  = np.where(side > 0, sp_in_opt,  sp_out_opt)
    cost_cons = np.where(side > 0, sp_in_cons, sp_out_cons) + slip

    a = atr[base_i]
    good = np.isfinite(a) & (a > 0) & np.isfinite(cost_opt) & np.isfinite(cost_cons)
    if good.sum() < 20:
        return None
    gross, cost_opt, cost_cons, a = gross[good], cost_opt[good], cost_cons[good], a[good]
    yr = df["year"].values[base_i][good]

    net_opt  = gross - cost_opt
    net_cons = gross - cost_cons
    R_opt, R_cons = net_opt / a, net_cons / a

    by_year = {}
    for y in sorted(set(yr.tolist())):
        s = R_cons[yr == y]
        by_year[str(int(y))] = round(float(np.mean(s)), 4) if len(s) > 3 else None
    signs = [v for v in by_year.values() if v is not None]

    return {
        "N": int(len(R_cons)),
        "gross_pips": round(float(np.mean(gross)), 3),
        "cost_cons_mean": round(float(np.mean(cost_cons)), 2),
        "cost_cons_med": round(float(np.median(cost_cons)), 2),
        "net_opt_pips": round(float(np.mean(net_opt)), 3),
        "net_cons_pips": round(float(np.mean(net_cons)), 3),
        "EV_R_cons": round(float(np.mean(R_cons)), 4),
        "t_opt": round(tstat(R_opt), 2),
        "t_cons": round(tstat(R_cons), 2),
        "win_gross": round(float((gross > 0).mean()), 3),
        "years_pos": "%d/%d" % (sum(1 for v in signs if v > 0), len(signs)),
        "_R": R_cons, "_yr": yr,
    }


def combine(rows):
    rows = [r for r in rows if r]
    if not rows:
        return None
    R  = np.concatenate([r["_R"] for r in rows])
    yr = np.concatenate([r["_yr"] for r in rows])
    if len(R) < 50:
        return None
    oos, ins = R[yr < IS_START], R[yr >= IS_START]
    by_year = {}
    for y in sorted(set(yr.tolist())):
        s = R[yr == y]
        by_year[str(int(y))] = round(float(np.mean(s)), 4) if len(s) > 5 else None
    signs = [v for v in by_year.values() if v is not None]
    return {
        "n_pairs": len(rows),
        "N": int(len(R)),
        "gross_pips_avg": round(float(np.mean([r["gross_pips"] for r in rows])), 3),
        "cost_cons_mean_avg": round(float(np.mean([r["cost_cons_mean"] for r in rows])), 3),
        "net_cons_pips_avg": round(float(np.mean([r["net_cons_pips"] for r in rows])), 3),
        "EV_R_cons": round(float(np.mean(R)), 4),
        "t_cons": round(tstat(R), 2),
        "OOS_t_cons": round(tstat(oos), 2) if len(oos) >= 20 else None,
        "OOS_EV_R": round(float(np.mean(oos)), 4) if len(oos) >= 20 else None,
        "IS_t_cons": round(tstat(ins), 2) if len(ins) >= 20 else None,
        "years_pos": "%d/%d" % (sum(1 for v in signs if v > 0), len(signs)),
        "EV_by_year": by_year,
    }


# ---------------------------------------------------------------- main
def run(out, slip):
    meta, dfs = {}, {}
    for sym in SYMBOLS:
        try:
            dfs[sym] = load(sym)
            meta[sym] = {"bars": int(len(dfs[sym]))}
        except Exception as e:
            meta[sym] = {"error": str(e)[:160]}

    # 事前にシグナルをしきい値ごとに1回だけ計算
    sigs = {}
    for sym, df in dfs.items():
        for g in GAP_THRS:
            sigs[(sym, g)] = monday_gaps(df, g)

    grid, decay = [], []
    for g in GAP_THRS:
        for d in DELAYS:
            for h in HOLDS:
                for sf in ("both", "long", "short"):
                    rows = []
                    for sym, df in dfs.items():
                        i0, s0 = sigs[(sym, g)]
                        try:
                            r = evaluate(df, i0, s0, d, h, slip, sf)
                            if r:
                                rows.append(r)
                        except Exception:
                            pass
                    p = combine(rows)
                    if p:
                        p.update({"gap_thr_atr": g, "delay_bars": d,
                                  "delay_label": "+%dm" % (15 * (1 + d)),
                                  "hold_bars": h, "side": sf})
                        grid.append(p)

    n_tests = len(grid)
    rt = req_t(n_tests)
    for p in grid:
        p["SURVIVES"] = bool(p["t_cons"] > rt and p["EV_R_cons"] > 0
                             and p["OOS_t_cons"] is not None
                             and p["OOS_t_cons"] > 2.0)

    # 遅延によるグロス/コストの推移 (窓幅1.0, 保有8本を代表として)
    for p in grid:
        if p["gap_thr_atr"] == 1.0 and p["hold_bars"] == 8:
            decay.append({"delay": p["delay_label"], "side": p["side"],
                          "N": p["N"],
                          "gross_pips": p["gross_pips_avg"],
                          "cost_pips": p["cost_cons_mean_avg"],
                          "net_pips": p["net_cons_pips_avg"],
                          "t_cons": p["t_cons"], "OOS_t": p["OOS_t_cons"]})
    decay.sort(key=lambda x: (x["side"], int(x["delay"].strip("+m"))))

    best = sorted(grid, key=lambda p: -p["t_cons"])[:10]
    survivors = [p for p in grid if p["SURVIVES"]]

    payload = {
        "version": VERSION,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "params": {"slip_pips": slip, "gap_thresholds": GAP_THRS,
                   "delays_bars": DELAYS, "holds_bars": HOLDS,
                   "period": "2015-01-01..2024-12-31", "atr_bars": ATR_BARS},
        "note": ("主指標は保守コスト(約定バーと直前バーのスプレッドの大きい方 + slip)。"
                 "SURVIVES = t_cons > 多重検定補正後の閾値 かつ OOS t > 2 かつ EV > 0。"),
        "n_tests": n_tests,
        "required_t": round(rt, 2),
        "n_survivors": len(survivors),
        "delay_decay_gap1.0_hold8": decay,
        "top10_by_t_cons": [{k: p[k] for k in
                             ("gap_thr_atr", "delay_label", "hold_bars", "N",
                              "gross_pips_avg", "cost_cons_mean_avg",
                              "net_cons_pips_avg", "EV_R_cons", "t_cons",
                              "OOS_t_cons", "IS_t_cons", "years_pos", "SURVIVES")}
                            for p in best],
        "survivors": [{k: p[k] for k in
                       ("gap_thr_atr", "delay_label", "hold_bars", "N",
                        "gross_pips_avg", "cost_cons_mean_avg",
                        "net_cons_pips_avg", "EV_R_cons", "t_cons",
                        "OOS_t_cons", "years_pos", "EV_by_year")}
                      for p in survivors],
        "meta": meta,
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    print("wrote %s tests=%d survivors=%d req_t=%.2f"
          % (out, n_tests, len(survivors), rt))
    return payload


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="sp2.json")
    ap.add_argument("--slip", type=float, default=0.3)
    a = ap.parse_args()
    run(a.out, a.slip)

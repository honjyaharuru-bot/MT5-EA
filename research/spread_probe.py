#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
spread_probe.py

目的: B03(月曜窓埋め)が「実際のスプレッドを払っても」残るかを決着させる。

やること
  1. MT5 の rates に含まれる spread フィールド(points)を使い、
     週明けオープン近辺のスプレッド分布を平日ベースラインと比較する
  2. B03 の各トレードに「そのバーの実測スプレッド」を当てて
     コスト控除後の EV / t / OOS を再計算する
  3. 直近のティックデータがあれば bid/ask から実測して rates.spread を検証する

コスト計算の考え方:
  MT5 の rates は bid。買いは ask(=bid+spread) で入り bid で出る -> コスト = 入口スプレッド
  売りは bid で入り ask で出る                                  -> コスト = 出口スプレッド
  つまり往復で「1回分のスプレッド」を、方向に応じた地点で払う。

Usage:
  python spread_probe.py --out spread.json
  python spread_probe.py --ticks 1 --out spread.json     # ティック検証も行う
"""
import argparse
import json
import math
from datetime import datetime, timezone, timedelta

import numpy as np
import pandas as pd

VERSION = "spread_probe_v1"

SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "NZDUSD",
           "USDCHF", "EURJPY", "GBPJPY"]

DATE_FROM = datetime(2015, 1, 1, tzinfo=timezone.utc)
DATE_TO   = datetime(2025, 1, 1, tzinfo=timezone.utc)
IS_START  = 2022
ATR_BARS  = 96
HOLD      = 8                      # 2 時間
GAP_THRS  = [0.2, 0.4, 0.7, 1.0]   # ATR 比


# ---------------------------------------------------------------- helpers
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


def pip_size(symbol):
    return 0.01 if symbol.endswith("JPY") else 0.0001


def points_per_pip(digits):
    """5桁/3桁業者は 1pip = 10point、4桁/2桁は 1pip = 1point。"""
    return 10.0 if digits in (3, 5) else 1.0


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
        raise RuntimeError("rates have no spread column")
    df["local"] = pd.to_datetime(df["time"], unit="s")
    df = df[["local", "open", "high", "low", "close", "spread"]].dropna()
    df = df.sort_values("local").reset_index(drop=True)
    if len(df) == 0:
        raise RuntimeError("empty after cleaning")

    off = broker_offset_series(df["local"])
    df["utc"] = df["local"] - pd.to_timedelta(off, unit="h")
    df["jst"] = df["utc"] + pd.Timedelta(hours=9)
    df = df[(df["utc"] >= DATE_FROM.replace(tzinfo=None)) &
            (df["utc"] <  DATE_TO.replace(tzinfo=None))].reset_index(drop=True)
    if len(df) == 0:
        raise RuntimeError("empty after date filter")

    ppp = points_per_pip(digits)
    df["spread_pips"] = df["spread"] / ppp
    ps = pip_size(symbol)
    df["atr"] = ((df["high"] - df["low"]) / ps).rolling(ATR_BARS).mean()
    df["jdow"]  = df["jst"].dt.dayofweek
    df["jdate"] = df["jst"].dt.date
    df["year"]  = df["jst"].dt.year
    df.attrs.update({"ps": ps, "digits": digits, "ppp": ppp, "symbol": symbol})
    return df


# ---------------------------------------------------------------- spread profile
def q(a, p):
    return round(float(np.percentile(a, p)), 2) if len(a) else None


def spread_profile(df):
    """週明けオープンからの経過バー別にスプレッドを集計。"""
    newday = pd.Series(df["jdate"] != df["jdate"].shift(1)).values
    first_mon = newday & (df["jdow"] == 0).values
    starts = np.flatnonzero(first_mon)
    sp = df["spread_pips"].values

    prof = {}
    for k, name in [(0, "open_+0m"), (1, "+15m"), (2, "+30m"),
                    (4, "+1h"), (8, "+2h"), (16, "+4h")]:
        ii = starts + k
        ii = ii[ii < len(sp)]
        a = sp[ii]
        a = a[np.isfinite(a)]
        prof[name] = {"n": int(len(a)), "median": q(a, 50),
                      "p75": q(a, 75), "p90": q(a, 90), "p99": q(a, 99)}

    # 平日ベースライン (月曜オープン後 4h を除いた全バー)
    mask = np.ones(len(sp), dtype=bool)
    for s in starts:
        mask[s:min(s + 17, len(sp))] = False
    base = sp[mask]
    base = base[np.isfinite(base)]
    prof["baseline_all"] = {"n": int(len(base)), "median": q(base, 50),
                            "p75": q(base, 75), "p90": q(base, 90),
                            "p99": q(base, 99)}
    return prof


# ---------------------------------------------------------------- B03 with real cost
def b03_trades(df, gap_thr):
    newday = pd.Series(df["jdate"] != df["jdate"].shift(1)).values
    first_mon = newday & (df["jdow"] == 0).values
    ps = df.attrs["ps"]
    gap = (df["open"].values - np.roll(df["close"].values, 1)) / ps
    gap[0] = 0.0
    atr = df["atr"].values
    with np.errstate(invalid="ignore", divide="ignore"):
        gap_atr = gap / atr

    long_  = first_mon & (gap_atr < -gap_thr)
    short_ = first_mon & (gap_atr >  gap_thr)
    idx  = np.concatenate([np.flatnonzero(long_), np.flatnonzero(short_)])
    side = np.concatenate([np.ones(long_.sum()), -np.ones(short_.sum())])
    o = np.argsort(idx)
    return idx[o], side[o]


def eval_b03(df, gap_thr, symbol):
    idx, side = b03_trades(df, gap_thr)
    n_bar = len(df)
    ok = (idx + HOLD + 1) < n_bar
    idx, side = idx[ok], side[ok]
    if len(idx) == 0:
        return None

    o = df["open"].values
    c = df["close"].values
    sp = df["spread_pips"].values
    atr = df["atr"].values
    ps = df.attrs["ps"]

    entry_i = idx + 1
    exit_i  = idx + 1 + HOLD
    entry = o[entry_i]
    exit_ = c[exit_i]
    gross = (exit_ - entry) * side / ps

    # 買いは入口、売りは出口でスプレッドを払う。
    # 約定は bar idx+1 の始値 = bar idx の終値直後なので、
    #   楽観 = bar idx+1 の spread
    #   保守 = max(bar idx, bar idx+1) の spread  <- 週明け直後の拡大を拾う
    sp_in_opt  = sp[entry_i]
    sp_in_cons = np.maximum(sp[idx], sp[entry_i])
    sp_out     = sp[exit_i]
    cost      = np.where(side > 0, sp_in_opt,  sp_out)
    cost_cons = np.where(side > 0, sp_in_cons, sp_out)

    a = atr[idx]
    good = np.isfinite(a) & (a > 0) & np.isfinite(cost) & np.isfinite(cost_cons)
    if good.sum() == 0:
        return None
    gross, cost, cost_cons, a = gross[good], cost[good], cost_cons[good], a[good]
    sp_in_opt, sp_in_cons, sp_out = sp_in_opt[good], sp_in_cons[good], sp_out[good]
    yr = df["year"].values[idx][good]

    net = gross - cost
    net_cons = gross - cost_cons
    netR = net / a
    netR_cons = net_cons / a
    n = len(netR)
    sd = float(np.std(netR, ddof=1)) if n > 1 else 0.0
    ev = float(np.mean(netR))
    t = ev / (sd / math.sqrt(n)) if sd > 0 and n > 1 else 0.0

    def sub(mask):
        s = netR[mask]
        if len(s) < 20:
            return {"N": int(len(s)), "EV_R": None, "t": None}
        m = float(np.mean(s)); v = float(np.std(s, ddof=1))
        return {"N": int(len(s)), "EV_R": round(m, 4),
                "t": round(m / (v / math.sqrt(len(s))), 2) if v > 0 else 0.0}

    by_year = {}
    for y in sorted(set(yr.tolist())):
        s = netR[yr == y]
        by_year[str(int(y))] = round(float(np.mean(s)), 4) if len(s) > 3 else None
    signs = [v for v in by_year.values() if v is not None]

    n2 = len(netR_cons)
    sd2 = float(np.std(netR_cons, ddof=1)) if n2 > 1 else 0.0
    ev2 = float(np.mean(netR_cons))
    t2 = ev2 / (sd2 / math.sqrt(n2)) if sd2 > 0 and n2 > 1 else 0.0

    return {
        "symbol": symbol,
        "gap_thr_atr": gap_thr,
        "N": int(n),
        "EV_gross_pips": round(float(np.mean(gross)), 3),
        "cost_median_pips": round(float(np.median(cost)), 3),
        "cost_p90_pips": round(float(np.percentile(cost, 90)), 3),
        "cost_cons_median_pips": round(float(np.median(cost_cons)), 3),
        "EV_net_pips_cons": round(float(np.mean(net_cons)), 3),
        "EV_net_R_cons": round(ev2, 4),
        "t_stat_cons": round(float(t2), 2),
        "EV_net_pips": round(float(np.mean(net)), 3),
        "EV_net_R": round(ev, 4),
        "t_stat": round(float(t), 2),
        "win_rate_gross": round(float((gross > 0).mean()), 3),
        "win_rate_net": round(float((net > 0).mean()), 3),
        "years_pos": "%d/%d" % (sum(1 for v in signs if v > 0), len(signs)),
        "EV_by_year": by_year,
        "OOS_2015_2021": sub(yr < IS_START),
        "IS_2022_2024": sub(yr >= IS_START),
        "_netR": netR, "_netR_cons": netR_cons, "_year": yr,
        "spread_entry_median": round(float(np.median(sp_in_opt)), 2),
        "spread_entry_cons_median": round(float(np.median(sp_in_cons)), 2),
        "spread_exit_median": round(float(np.median(sp_out)), 2),
    }


def pool(rows, gap_thr):
    rows = [r for r in rows if r]
    if not rows:
        return None
    allR = np.concatenate([r["_netR"] for r in rows])
    allC = np.concatenate([r["_netR_cons"] for r in rows])
    yr   = np.concatenate([r["_year"] for r in rows])
    n = len(allR)
    if n < 30:
        return None
    sd = float(np.std(allR, ddof=1)); ev = float(np.mean(allR))
    t = ev / (sd / math.sqrt(n)) if sd > 0 else 0.0

    def sub(s):
        if len(s) < 20:
            return {"N": int(len(s)), "EV_R": None, "t": None}
        m = float(np.mean(s)); v = float(np.std(s, ddof=1))
        return {"N": int(len(s)), "EV_R": round(m, 4),
                "t": round(m / (v / math.sqrt(len(s))), 2) if v > 0 else 0.0}

    by_year = {}
    for y in sorted(set(yr.tolist())):
        s = allR[yr == y]
        by_year[str(int(y))] = round(float(np.mean(s)), 4) if len(s) > 5 else None
    signs = [v for v in by_year.values() if v is not None]

    return {
        "gap_thr_atr": gap_thr,
        "symbol": "POOLED",
        "n_pairs": len(rows),
        "N": int(n),
        "EV_net_R": round(ev, 4),
        "EV_net_R_cons": round(float(np.mean(allC)), 4),
        "t_stat_cons": round(float(np.mean(allC) / (np.std(allC, ddof=1) / math.sqrt(len(allC)))), 2) if np.std(allC, ddof=1) > 0 else 0.0,
        "EV_net_pips_avg": round(float(np.mean([r["EV_net_pips"] for r in rows])), 3),
        "cost_median_pips_avg": round(float(np.mean([r["cost_median_pips"] for r in rows])), 3),
        "t_stat": round(float(t), 2),
        "years_pos": "%d/%d" % (sum(1 for v in signs if v > 0), len(signs)),
        "EV_by_year": by_year,
        "OOS_2015_2021": sub(allR[yr < IS_START]),
        "IS_2022_2024": sub(allR[yr >= IS_START]),
    }


# ---------------------------------------------------------------- tick check
def tick_check(symbol, months=6):
    """直近の実ティックで bid/ask スプレッドを確認し rates.spread を検証する。"""
    import MetaTrader5 as mt5
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=30 * months)
    ticks = mt5.copy_ticks_range(symbol, start, end, mt5.COPY_TICKS_INFO)
    if ticks is None or len(ticks) == 0:
        return {"available": False, "reason": str(mt5.last_error())}
    t = pd.DataFrame(ticks)
    t = t[(t["ask"] > 0) & (t["bid"] > 0)]
    if len(t) == 0:
        return {"available": False, "reason": "no valid bid/ask"}
    ps = pip_size(symbol)
    t["sp"] = (t["ask"] - t["bid"]) / ps
    t["local"] = pd.to_datetime(t["time"], unit="s")
    off = broker_offset_series(t["local"])
    t["jst"] = t["local"] - pd.to_timedelta(off, unit="h") + pd.Timedelta(hours=9)
    t["jdow"] = t["jst"].dt.dayofweek
    t["jdate"] = t["jst"].dt.date

    firsts = t.groupby("jdate")["jst"].transform("min")
    is_open = (t["jdow"] == 0) & (t["jst"] < firsts + pd.Timedelta(minutes=45)) \
              & (t["jst"] >= firsts + pd.Timedelta(minutes=15))
    a = t.loc[is_open, "sp"].values
    b = t.loc[~is_open, "sp"].values
    return {
        "available": True,
        "n_ticks": int(len(t)),
        "monday_open_15_45m": {"n": int(len(a)), "median": q(a, 50),
                               "p90": q(a, 90), "p99": q(a, 99)},
        "baseline": {"n": int(len(b)), "median": q(b, 50),
                     "p90": q(b, 90), "p99": q(b, 99)},
    }


# ---------------------------------------------------------------- main
def run(out, do_ticks):
    meta, profiles, per_pair, pooled_rows, ticks = {}, {}, [], [], {}
    dfs = {}

    for sym in SYMBOLS:
        try:
            df = load(sym)
            dfs[sym] = df
            meta[sym] = {"bars": int(len(df)), "digits": df.attrs["digits"],
                         "first": str(df["utc"].iloc[0]),
                         "last": str(df["utc"].iloc[-1])}
            profiles[sym] = spread_profile(df)
        except Exception as e:
            meta[sym] = {"error": str(e)[:180]}

    for thr in GAP_THRS:
        rows = []
        for sym, df in dfs.items():
            try:
                r = eval_b03(df, thr, sym)
                if r:
                    rows.append(r)
            except Exception as e:
                per_pair.append({"symbol": sym, "gap_thr_atr": thr,
                                 "error": str(e)[:150]})
        p = pool(rows, thr)
        if p:
            pooled_rows.append(p)
        for r in rows:
            r.pop("_netR", None); r.pop("_netR_cons", None); r.pop("_year", None)
            per_pair.append(r)

    if do_ticks:
        for sym in list(dfs.keys())[:3]:
            try:
                ticks[sym] = tick_check(sym)
            except Exception as e:
                ticks[sym] = {"available": False, "reason": str(e)[:150]}

    verdict = []
    for p in pooled_rows:
        oos = p["OOS_2015_2021"]
        ok = (p["t_stat"] > 3.56 and oos.get("t") is not None and oos["t"] > 2.0
              and p["EV_net_R"] > 0)
        verdict.append({"gap_thr_atr": p["gap_thr_atr"], "N": p["N"],
                        "EV_net_pips_avg": p["EV_net_pips_avg"],
                        "cost_med": p["cost_median_pips_avg"],
                        "t": p["t_stat"], "t_cons": p["t_stat_cons"],
                        "EV_net_R_cons": p["EV_net_R_cons"],
                        "OOS_t": oos.get("t"),
                        "years_pos": p["years_pos"], "SURVIVES": bool(ok)})

    payload = {
        "version": VERSION,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "note": ("rates.spread(points) を pips 換算し、各トレードの実測スプレッドで "
                 "コストを計算した。買いは入口、売りは出口でスプレッドを負担する前提。"
                 "SURVIVES = プール t>3.56 かつ OOS t>2 かつ純EV>0。"),
        "params": {"hold_bars": HOLD, "atr_bars": ATR_BARS,
                   "gap_thresholds_atr": GAP_THRS,
                   "period": "2015-01-01..2024-12-31"},
        "verdict": verdict,
        "pooled": pooled_rows,
        "spread_profile": profiles,
        "tick_validation": ticks,
        "per_pair": sorted([r for r in per_pair if "t_stat" in r],
                           key=lambda r: -r.get("t_stat", 0))[:24],
        "errors": [r for r in per_pair if "error" in r][:10],
        "meta": meta,
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    print("wrote %s  pooled=%d pairs=%d" % (out, len(pooled_rows), len(dfs)))
    return payload


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="spread.json")
    ap.add_argument("--ticks", type=int, default=0)
    a = ap.parse_args()
    run(a.out, bool(a.ticks))

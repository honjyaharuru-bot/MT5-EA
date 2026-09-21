#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
edge_scan_v2.py

v1 からの変更点:
  1. 通貨ペアを 9 本に拡張
  2. 期間を 2015-2024 に拡張 -> 2015-2021 は v1 の発見に対する真の OOS
  3. DST 補正 (EU 夏時間で UTC+3 / 冬 UTC+2 を自動判定)
  4. ATR 正規化 (R 単位) によりペア間・年代間で単位を揃えてプール可能に
  5. B03 は窓幅しきい値と保有期間を掃引
  6. プール t 値と OOS/IS 分離を出力

出力は小さな JSON のみ。

Usage:
  python edge_scan_v2.py --out result_edgescan_v2.json
  python edge_scan_v2.py --tzmode fixed --offset 3 --out x.json
"""
import argparse
import json
import math
import os
from datetime import datetime, timezone, timedelta

import numpy as np
import pandas as pd

VERSION = "edge_scan_v2"

SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "NZDUSD",
           "USDCAD", "USDCHF", "EURJPY", "GBPJPY"]

DATE_FROM = datetime(2015, 1, 1, tzinfo=timezone.utc)
DATE_TO   = datetime(2025, 1, 1, tzinfo=timezone.utc)

IS_START  = 2022          # v1 で発見に使った期間 (in-sample)
HOLD_BARS = 8             # 既定の保有本数 (M15 x 8 = 2h)
COST_PIPS = 1.0           # 往復コスト想定
ATR_BARS  = 96            # 1 日 (M15 x 96)


# ---------------------------------------------------------------- time zone
def _last_sunday(year, month):
    d = datetime(year, month, 31) if month == 3 else datetime(year, month, 31)
    while d.weekday() != 6:
        d -= timedelta(days=1)
    return d


def broker_offset_series(local_times):
    """
    ブローカーのローカル時刻 (tz-naive) から UTC オフセット(時間) を返す。
    EU 夏時間: 3月最終日曜 01:00 UTC 〜 10月最終日曜 01:00 UTC を +3、それ以外 +2。
    """
    lt = pd.DatetimeIndex(local_times)
    off = np.full(len(lt), 2, dtype=np.int8)
    for y in np.unique(lt.year):
        s = _last_sunday(int(y), 3) + timedelta(hours=3)    # local +3 の開始点
        e = _last_sunday(int(y), 10) + timedelta(hours=4)   # local 側の終了点
        m = (lt >= s) & (lt < e)
        off[m] = 3
    return off


def pip_size(symbol):
    return 0.01 if symbol.endswith("JPY") else 0.0001


# ---------------------------------------------------------------- data load
def load_from_mt5(symbol):
    import MetaTrader5 as mt5
    if not mt5.initialize():
        raise RuntimeError("mt5.initialize failed: %s" % (mt5.last_error(),))
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError("symbol_select failed: %s" % symbol)
    rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M15, DATE_FROM, DATE_TO)
    if rates is None or len(rates) == 0:
        raise RuntimeError("no rates: %s err=%s" % (symbol, mt5.last_error()))
    df = pd.DataFrame(rates)
    # MT5 の time はサーバローカル時刻を epoch 扱いしたもの
    df["local"] = pd.to_datetime(df["time"], unit="s")
    return df[["local", "open", "high", "low", "close"]]


def load_from_csv(symbol, csvdir):
    cands = [os.path.join(csvdir, "m15_%s.csv" % symbol),
             os.path.join(csvdir, "%s_M15.csv" % symbol),
             os.path.join(csvdir, "%s.csv" % symbol)]
    path = next((p for p in cands if os.path.exists(p)), None)
    if path is None:
        raise FileNotFoundError("csv not found: %s" % symbol)
    df = pd.read_csv(path, sep=None, engine="python")
    df.columns = [str(c).strip().lower().lstrip("<").rstrip(">") for c in df.columns]
    ren = {}
    for c in df.columns:
        for k in ("open", "high", "low", "close"):
            if c.startswith(k):
                ren[c] = k
    df = df.rename(columns=ren)
    if "datetime" in df.columns:
        t = pd.to_datetime(df["datetime"])
    elif "date" in df.columns and "time" in df.columns:
        t = pd.to_datetime(df["date"].astype(str) + " " + df["time"].astype(str))
    else:
        t = pd.to_datetime(df["time"])
    t = pd.DatetimeIndex(t).tz_localize(None)
    return pd.DataFrame({"local": t, "open": df["open"], "high": df["high"],
                         "low": df["low"], "close": df["close"]})


def prepare(symbol, csvdir, tzmode, fixed_offset):
    err = None
    try:
        df = load_from_mt5(symbol); src = "mt5"
    except Exception as e:
        err = str(e)
        df = load_from_csv(symbol, csvdir); src = "csv"

    df = df.dropna().sort_values("local").reset_index(drop=True)

    if tzmode == "auto":
        off = broker_offset_series(df["local"])
    else:
        off = np.full(len(df), int(fixed_offset), dtype=np.int8)
    df["off"] = off
    df["utc"] = df["local"] - pd.to_timedelta(df["off"], unit="h")
    df["jst"] = df["utc"] + pd.Timedelta(hours=9)

    df = df[(df["utc"] >= DATE_FROM.replace(tzinfo=None)) &
            (df["utc"] <  DATE_TO.replace(tzinfo=None))].reset_index(drop=True)

    df["jh"]    = df["jst"].dt.hour
    df["jdow"]  = df["jst"].dt.dayofweek
    df["jdate"] = df["jst"].dt.date
    df["year"]  = df["jst"].dt.year

    ps = pip_size(symbol)
    df["atr"] = ((df["high"] - df["low"]) / ps).rolling(ATR_BARS).mean()
    df.attrs["ps"] = ps
    df.attrs["symbol"] = symbol
    return df, src, err


# ---------------------------------------------------------------- evaluation
def make_trades(df, idx, side, symbol, hold=HOLD_BARS):
    """エントリー idx の次足始値で約定、hold 本後の終値で決済。R 単位も返す。"""
    ps = pip_size(symbol)
    n  = len(df)
    idx = np.asarray(idx, dtype=int)
    side = np.asarray(side, dtype=float)
    ok = (idx + hold + 1) < n
    idx, side = idx[ok], side[ok]
    if len(idx) == 0:
        return None

    o = df["open"].values; c = df["close"].values
    atr = df["atr"].values
    entry = o[idx + 1]
    exit_ = c[idx + 1 + hold]
    pnl = (exit_ - entry) * side / ps

    a = atr[idx]
    good = np.isfinite(a) & (a > 0)
    idx, side, pnl, a = idx[good], side[good], pnl[good], a[good]
    if len(pnl) == 0:
        return None

    return {
        "pnl_pips": pnl,
        "pnl_R": pnl / a,
        "cost_R": COST_PIPS / a,
        "year": df["year"].values[idx],
        "atr": a,
    }


def stat_block(tr, label, symbol, extra=None):
    if tr is None:
        return None
    pnl  = tr["pnl_pips"]
    R    = tr["pnl_R"] - tr["cost_R"]      # コスト控除後の R
    n    = len(R)
    months = max(1.0, (DATE_TO - DATE_FROM).days / 30.44)
    sd   = float(np.std(R, ddof=1)) if n > 1 else 0.0
    ev   = float(np.mean(R))
    t    = ev / (sd / math.sqrt(n)) if sd > 0 and n > 1 else 0.0

    yr = tr["year"]
    is_m  = yr >= IS_START
    oos_m = ~is_m

    def sub(mask):
        s = R[mask]
        if len(s) < 20:
            return {"N": int(len(s)), "EV_R": None, "t": None}
        m = float(np.mean(s)); v = float(np.std(s, ddof=1))
        tt = m / (v / math.sqrt(len(s))) if v > 0 else 0.0
        return {"N": int(len(s)), "EV_R": round(m, 4), "t": round(tt, 2)}

    by_year = {}
    for y in sorted(set(yr.tolist())):
        s = R[yr == y]
        by_year[str(int(y))] = round(float(np.mean(s)), 4) if len(s) > 5 else None
    signs = [v for v in by_year.values() if v is not None]
    pos = sum(1 for v in signs if v > 0)

    out = {
        "label": label,
        "symbol": symbol,
        "N": int(n),
        "EV_net_R": round(ev, 4),
        "EV_gross_pips": round(float(np.mean(pnl)), 3),
        "EV_net_pips": round(float(np.mean(pnl)) - COST_PIPS, 3),
        "sd_R": round(sd, 3),
        "t_stat": round(float(t), 2),
        "trades_per_month": round(n / months, 1),
        "win_rate_ref": round(float((pnl > 0).mean()), 3),
        "years_pos": "%d/%d" % (pos, len(signs)),
        "EV_by_year": by_year,
        "OOS_2015_2021": sub(oos_m),
        "IS_2022_2024": sub(is_m),
    }
    if extra:
        out.update(extra)
    return out


def pooled(blocks_R, label):
    """複数ペアの R を連結してプール統計を出す。"""
    if not blocks_R:
        return None
    allR = np.concatenate([b["R"] for b in blocks_R])
    allG = np.concatenate([b["G"] for b in blocks_R])
    yr   = np.concatenate([b["year"] for b in blocks_R])
    npair = len(blocks_R)
    n = len(allR)
    if n < 30:
        return None
    sd = float(np.std(allR, ddof=1)); ev = float(np.mean(allR))
    t  = ev / (sd / math.sqrt(n)) if sd > 0 else 0.0
    oos = allR[yr < IS_START]; ins = allR[yr >= IS_START]

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
    pos = sum(1 for v in signs if v > 0)

    o_, i_ = sub(oos), sub(ins)
    oos_ok = (o_["t"] is not None) and (o_["t"] > 2.0)
    return {
        "label": label + " [POOLED]",
        "symbol": "ALL",
        "n_pairs": npair,
        "N": int(n),
        "EV_gross_R": round(float(np.mean(allG)), 4),
        "EV_net_R": round(ev, 4),
        "sd_R": round(sd, 3),
        "t_stat": round(float(t), 2),
        "years_pos": "%d/%d" % (pos, len(signs)),
        "EV_by_year": by_year,
        "OOS_2015_2021": o_,
        "IS_2022_2024": i_,
        "oos_confirms": bool(oos_ok),
    }


# ---------------------------------------------------------------- conditions
def rsi(close, n=14):
    d = close.diff()
    up = d.clip(lower=0).ewm(alpha=1.0 / n, adjust=False).mean()
    dn = (-d.clip(upper=0)).ewm(alpha=1.0 / n, adjust=False).mean()
    rs = up / dn.replace(0, np.nan)
    return (100 - 100 / (1 + rs)).fillna(50)


def _pack(long_mask, short_mask):
    lm = np.asarray(long_mask.fillna(False).values, dtype=bool)
    sm = np.asarray(short_mask.fillna(False).values, dtype=bool)
    idx = np.concatenate([np.flatnonzero(lm), np.flatnonzero(sm)])
    side = np.concatenate([np.ones(lm.sum()), -np.ones(sm.sum())])
    o = np.argsort(idx)
    return idx[o], side[o]


def cond_B03(df, min_gap_atr):
    """月曜窓埋め。窓幅を ATR 比でしきい値化。"""
    newday = pd.Series(df["jdate"] != df["jdate"].shift(1))
    first_mon = newday & (df["jdow"] == 0)
    ps = df.attrs["ps"]
    gap = (df["open"] - df["close"].shift(1)) / ps          # pips
    gap_atr = gap / df["atr"]
    long_  = first_mon & (gap_atr < -min_gap_atr)
    short  = first_mon & (gap_atr >  min_gap_atr)
    return _pack(long_, short)


def cond_B01(df):
    r = rsi(df["close"])
    m = df["close"].rolling(20).mean()
    s = df["close"].rolling(20).std(ddof=0)
    tw = df["jh"].between(9, 15)
    long_ = tw & (df["close"] < m - 2 * s) & (r < 30)
    short = tw & (df["close"] > m + 2 * s) & (r > 70)
    return _pack(long_, short)


def cond_D02(df):
    h2 = df["high"].shift(2); l2 = df["low"].shift(2)
    bull = df["low"] > h2
    bear = df["high"] < l2
    lo = h2.where(bull); hi = l2.where(bear)
    long_ = pd.Series(False, index=df.index)
    short = pd.Series(False, index=df.index)
    lows, highs = df["low"].values, df["high"].values
    for i in np.flatnonzero(np.asarray(bull.fillna(False).values, dtype=bool)):
        lvl = lo.values[i]; j = min(i + 13, len(df))
        hit = np.flatnonzero(lows[i + 1:j] <= lvl)
        if hit.size: long_.iloc[i + 1 + hit[0]] = True
    for i in np.flatnonzero(np.asarray(bear.fillna(False).values, dtype=bool)):
        lvl = hi.values[i]; j = min(i + 13, len(df))
        hit = np.flatnonzero(highs[i + 1:j] >= lvl)
        if hit.size: short.iloc[i + 1 + hit[0]] = True
    return _pack(long_, short)


def cond_D01(df):
    tokyo = df["jh"].between(8, 15)
    hi = df.loc[tokyo].groupby(df.loc[tokyo, "jdate"])["high"].max()
    lo = df.loc[tokyo].groupby(df.loc[tokyo, "jdate"])["low"].min()
    rh = df["jdate"].map(hi); rl = df["jdate"].map(lo)
    win = df["jh"].between(16, 17)
    long_ = win & (df["close"] > rh)
    short = win & (df["close"] < rl)
    long_ = long_ & (~long_.groupby(df["jdate"]).cumsum().shift(1).fillna(0).astype(bool))
    short = short & (~short.groupby(df["jdate"]).cumsum().shift(1).fillna(0).astype(bool))
    return _pack(long_, short)


def _req_t(n_tests, alpha=0.05):
    """Bonferroni 補正後に必要な |t| の目安 (正規近似)。"""
    from math import sqrt, log
    p = alpha / max(1, n_tests) / 2.0
    # 正規分布の上側 p 点を近似 (Beasley-Springer-Moro 簡易版)
    import statistics
    lo, hi = 0.0, 10.0
    for _ in range(200):
        mid = (lo + hi) / 2
        # 上側確率
        from math import erfc
        u = 0.5 * erfc(mid / sqrt(2.0))
        if u > p: lo = mid
        else:     hi = mid
    return (lo + hi) / 2


# ---------------------------------------------------------------- main
def run(csvdir, tzmode, fixed_offset, out):
    meta, results = {}, []
    dfs = {}

    for sym in SYMBOLS:
        try:
            df, src, err = prepare(sym, csvdir, tzmode, fixed_offset)
            dfs[sym] = df
            meta[sym] = {"source": src, "bars": int(len(df)),
                         "first": str(df["utc"].iloc[0]),
                         "last": str(df["utc"].iloc[-1]),
                         "note": err}
        except Exception as e:
            meta[sym] = {"source": "FAILED", "error": str(e)[:200]}

    # ---- B03 : 窓幅しきい値 x 保有期間 の掃引 --------------------------
    for gap_thr in [0.2, 0.4, 0.7, 1.0]:
        for hold in [8, 16, 32]:
            lbl = "B03_gap_atr%.1f_hold%d" % (gap_thr, hold)
            pool = []
            for sym, df in dfs.items():
                try:
                    idx, side = cond_B03(df, gap_thr)
                    tr = make_trades(df, idx, side, sym, hold)
                    if tr is None:
                        continue
                    pool.append({"R": tr["pnl_R"] - tr["cost_R"], "G": tr["pnl_R"], "year": tr["year"]})
                    b = stat_block(tr, lbl, sym)
                    if b and b["N"] >= 20:
                        results.append(b)
                except Exception as e:
                    results.append({"label": lbl, "symbol": sym, "error": str(e)[:150]})
            p = pooled(pool, lbl)
            if p:
                results.append(p)

    # ---- 参照条件 (既定パラメータのみ) ---------------------------------
    others = [("B01_asia_range_fade", cond_B01),
              ("D01_london_breakout", cond_D01),
              ("D02_fvg_retrace",     cond_D02)]
    for lbl, fn in others:
        pool = []
        for sym, df in dfs.items():
            try:
                idx, side = fn(df)
                tr = make_trades(df, idx, side, sym, HOLD_BARS)
                if tr is None:
                    continue
                pool.append({"R": tr["pnl_R"] - tr["cost_R"], "G": tr["pnl_R"], "year": tr["year"]})
                b = stat_block(tr, lbl, sym)
                if b and b["N"] >= 20:
                    results.append(b)
            except Exception as e:
                results.append({"label": lbl, "symbol": sym, "error": str(e)[:150]})
        p = pooled(pool, lbl)
        if p:
            results.append(p)

    n_tests = len([r for r in results if "t_stat" in r])
    pooled_rows = [r for r in results if r.get("symbol") == "ALL"]
    best = sorted(pooled_rows, key=lambda r: -abs(r.get("t_stat", 0)))[:5]

    payload = {
        "version": VERSION,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "params": {"period": "2015-01-01..2024-12-31", "tf": "M15",
                   "tzmode": tzmode, "fixed_offset": fixed_offset,
                   "cost_pips": COST_PIPS, "atr_bars": ATR_BARS,
                   "IS_from_year": IS_START},
        "note": ("R = ATR(1day) 正規化後の損益。EV_net_R はコスト控除後。"
                 "OOS_2015_2021 は v1 の発見に対する真の未使用データ。"
                 "多重検定のため単独 t は 3 以上、かつ OOS でも同符号を要求する。"),
        "n_tests": n_tests,
        "required_t_bonferroni": round(float(_req_t(n_tests)), 2),
        "meta": meta,
        "pooled_top5": [{"label": b["label"], "N": b["N"],
                         "EV_net_R": b["EV_net_R"], "t": b["t_stat"],
                         "years_pos": b["years_pos"],
                         "OOS": b["OOS_2015_2021"], "IS": b["IS_2022_2024"]}
                        for b in best],
        "results": (sorted(pooled_rows, key=lambda r: -abs(r.get("t_stat", 0)))
                    + sorted([r for r in results
                              if "t_stat" in r and r.get("symbol") != "ALL"],
                             key=lambda r: -abs(r.get("t_stat", 0)))[:40]),
        "errors": [r for r in results if "error" in r][:20],
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    print("wrote %s  rows=%d tests=%d" % (out, len(payload["results"]), n_tests))
    return payload


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--csvdir", default="data")
    ap.add_argument("--tzmode", default="auto", choices=["auto", "fixed"])
    ap.add_argument("--offset", type=int, default=3)
    ap.add_argument("--out", default="result_edgescan_v2.json")
    a = ap.parse_args()
    run(a.csvdir, a.tzmode, a.offset, a.out)

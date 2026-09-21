#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
edge_scan_v1.py
B/C/D群の生シグナル期待値を、EA化せずにOHLCから直接測る。

出力: 小さなJSON (N / EV_pips / sd / t / 年別EV / 頻度 / MFE / MAE)
決済ルール: 全条件で「HOLD_BARS本後に成行」で統一 (足内経路依存を回避)

Usage:
  python edge_scan_v1.py --out result_edgescan_v1.json
  python edge_scan_v1.py --csvdir C:\\MT5-EA\\data --out out.json
"""
import argparse
import json
import math
import os
import sys
from datetime import datetime, timezone, timedelta

import numpy as np
import pandas as pd

VERSION = "edge_scan_v1"
SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY"]
DATE_FROM = datetime(2022, 1, 1, tzinfo=timezone.utc)
DATE_TO = datetime(2025, 1, 1, tzinfo=timezone.utc)
HOLD_BARS = 8              # M15 x 8 = 2時間
COST_PIPS = 1.0            # 往復コスト想定(pips)。純EV算出用


# ---------------------------------------------------------------- data load
def pip_size(symbol):
    return 0.01 if symbol.endswith("JPY") else 0.0001


def load_from_mt5(symbol, broker_offset):
    import MetaTrader5 as mt5
    if not mt5.initialize():
        raise RuntimeError("mt5.initialize failed: %s" % (mt5.last_error(),))
    tf = mt5.TIMEFRAME_M15
    rates = mt5.copy_rates_range(symbol, tf, DATE_FROM, DATE_TO)
    if rates is None or len(rates) == 0:
        raise RuntimeError("no rates for %s" % symbol)
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    return df[["time", "open", "high", "low", "close"]]


def load_from_csv(symbol, csvdir):
    """MT5のExport Bars等で出したCSVを想定。列名は緩く解釈する。"""
    cands = [
        os.path.join(csvdir, "m15_%s.csv" % symbol),
        os.path.join(csvdir, "%s_M15.csv" % symbol),
        os.path.join(csvdir, "%s.csv" % symbol),
    ]
    path = next((p for p in cands if os.path.exists(p)), None)
    if path is None:
        raise FileNotFoundError("csv not found for %s in %s" % (symbol, csvdir))
    df = pd.read_csv(path, sep=None, engine="python")
    df.columns = [str(c).strip().lower().lstrip("<").rstrip(">") for c in df.columns]
    ren = {}
    for c in df.columns:
        if c in ("date", "time", "datetime", "timestamp"):
            ren[c] = c
        elif c.startswith("open"):
            ren[c] = "open"
        elif c.startswith("high"):
            ren[c] = "high"
        elif c.startswith("low"):
            ren[c] = "low"
        elif c.startswith("close"):
            ren[c] = "close"
    df = df.rename(columns=ren)
    if "datetime" in df.columns:
        t = pd.to_datetime(df["datetime"], utc=True)
    elif "date" in df.columns and "time" in df.columns:
        t = pd.to_datetime(df["date"].astype(str) + " " + df["time"].astype(str), utc=True)
    elif "time" in df.columns:
        t = pd.to_datetime(df["time"], utc=True)
    else:
        raise ValueError("no time column in %s" % path)
    out = pd.DataFrame({"time": t, "open": df["open"], "high": df["high"],
                        "low": df["low"], "close": df["close"]})
    return out


def load(symbol, csvdir, broker_offset):
    """MT5優先、失敗したらCSVへフォールバック。"""
    err = None
    try:
        df = load_from_mt5(symbol, broker_offset)
        src = "mt5"
    except Exception as e:
        err = str(e)
        df = load_from_csv(symbol, csvdir)
        src = "csv"
    df = df.dropna().sort_values("time").reset_index(drop=True)
    df = df[(df["time"] >= DATE_FROM) & (df["time"] < DATE_TO)].reset_index(drop=True)
    # ブローカー時刻がUTCでない場合の補正 -> UTCへ寄せる
    if broker_offset:
        df["time"] = df["time"] - pd.Timedelta(hours=broker_offset)
    df["jst"] = df["time"] + pd.Timedelta(hours=9)
    df["jh"] = df["jst"].dt.hour
    df["jdow"] = df["jst"].dt.dayofweek     # 0=Mon
    df["jdate"] = df["jst"].dt.date
    df["year"] = df["jst"].dt.year
    return df, src, err


# ---------------------------------------------------------------- indicators
def rsi(close, n=14):
    d = close.diff()
    up = d.clip(lower=0).ewm(alpha=1.0 / n, adjust=False).mean()
    dn = (-d.clip(upper=0)).ewm(alpha=1.0 / n, adjust=False).mean()
    rs = up / dn.replace(0, np.nan)
    return (100 - 100 / (1 + rs)).fillna(50)


def bbands(close, n=20, k=2.0):
    m = close.rolling(n).mean()
    s = close.rolling(n).std(ddof=0)
    return m, m + k * s, m - k * s


# ---------------------------------------------------------------- evaluation
def evaluate(df, idx, side, symbol, label):
    """idx: エントリー足のindex配列, side: +1/-1 の配列。HOLD_BARS本後の終値で決済。"""
    ps = pip_size(symbol)
    n_bar = len(df)
    idx = np.asarray(idx, dtype=int)
    side = np.asarray(side, dtype=float)
    ok = (idx + HOLD_BARS) < n_bar
    idx, side = idx[ok], side[ok]
    if len(idx) == 0:
        return None

    o = df["open"].values
    h = df["high"].values
    l = df["low"].values
    c = df["close"].values

    entry = o[idx + 1] if (idx + 1).max() < n_bar else c[idx]   # 次足始値で約定
    exit_ = c[idx + HOLD_BARS]
    pnl = (exit_ - entry) * side / ps

    # 保有期間中のMFE/MAE (部分利確設計用)
    mfe = np.empty(len(idx))
    mae = np.empty(len(idx))
    for k, i in enumerate(idx):
        seg_h = h[i + 1:i + 1 + HOLD_BARS]
        seg_l = l[i + 1:i + 1 + HOLD_BARS]
        if side[k] > 0:
            mfe[k] = (seg_h.max() - entry[k]) / ps
            mae[k] = (seg_l.min() - entry[k]) / ps
        else:
            mfe[k] = (entry[k] - seg_l.min()) / ps
            mae[k] = (entry[k] - seg_h.max()) / ps

    yrs = df["year"].values[idx]
    months = max(1.0, (DATE_TO - DATE_FROM).days / 30.44)
    n = len(pnl)
    sd = float(np.std(pnl, ddof=1)) if n > 1 else 0.0
    ev = float(np.mean(pnl))
    t = ev / (sd / math.sqrt(n)) if sd > 0 and n > 1 else 0.0

    by_year = {}
    for y in (2022, 2023, 2024):
        s = pnl[yrs == y]
        by_year[str(y)] = round(float(np.mean(s)), 3) if len(s) > 2 else None

    signs = [v for v in by_year.values() if v is not None]
    consistent = bool(signs) and (all(v > 0 for v in signs) or all(v < 0 for v in signs))

    return {
        "label": label,
        "symbol": symbol,
        "N": int(n),
        "EV_gross_pips": round(ev, 3),
        "EV_net_pips": round(ev - COST_PIPS, 3),
        "sd_pips": round(sd, 2),
        "t_stat": round(float(t), 2),
        "trades_per_month": round(n / months, 1),
        "win_rate_ref": round(float((pnl > 0).mean()), 3),
        "avg_MFE_pips": round(float(np.mean(mfe)), 2),
        "avg_MAE_pips": round(float(np.mean(mae)), 2),
        "EV_by_year": by_year,
        "sign_consistent": consistent,
        "verdict": verdict(ev - COST_PIPS, t, n, consistent),
    }


def verdict(ev_net, t, n, consistent):
    if n < 100:
        return "N_TOO_SMALL"
    if abs(t) < 3.0:
        return "NOISE"          # 多重検定補正のため t>3 を要求
    if not consistent:
        return "UNSTABLE"       # 年で符号が反転
    if ev_net <= 0:
        return "COST_KILLED"
    return "CANDIDATE"


# ---------------------------------------------------------------- conditions
def cond_B01(df):
    """アジアレンジ逆張り: JST 9-16時, BB2σ外 + RSI極値"""
    _, up, lo = bbands(df["close"])
    r = rsi(df["close"])
    tw = df["jh"].between(9, 15)
    long_ = tw & (df["close"] < lo) & (r < 30)
    short = tw & (df["close"] > up) & (r > 70)
    return _pack(long_, short)


def cond_B02(df):
    """ロンドンフィックス反転: JST 0-1時, 直前1時間の動きをフェード"""
    ret4 = df["close"].diff(4)
    tw = df["jh"].isin([0, 1])
    thr = ret4.abs().rolling(200).median()
    big = ret4.abs() > (thr * 1.5)
    long_ = tw & big & (ret4 < 0)
    short = tw & big & (ret4 > 0)
    return _pack(long_, short)


def cond_B03(df):
    """月曜窓埋め: 週初1本目, 窓幅 > 閾値なら窓と逆方向"""
    newday = df["jdate"] != df["jdate"].shift(1)
    first_mon = newday & (df["jdow"] == 0)
    gap = df["open"] - df["close"].shift(1)
    ps = 0.01 if df.attrs.get("jpy") else 0.0001
    thr = 10 * ps
    long_ = first_mon & (gap < -thr)
    short = first_mon & (gap > thr)
    return _pack(long_, short)


def cond_C01(df, dow):
    """曜日効果: 指定曜日のJST9時にロング(符号はEVが語る)"""
    sel = (df["jdow"] == dow) & (df["jh"] == 9) & (df["jh"].shift(1) != 9)
    return _pack(sel, pd.Series(False, index=df.index))


def cond_C02(df):
    """月末フロー: 月内最終営業日 JST20時にロング"""
    ym = df["jst"].dt.tz_localize(None).dt.to_period("M")
    last_date = df.groupby(ym)["jdate"].transform("max")
    sel = (df["jdate"] == last_date) & (df["jh"] == 20) & (df["jh"].shift(1) != 20)
    return _pack(sel, pd.Series(False, index=df.index))


def cond_D01(df):
    """ロンドンOPブレイク: 東京(JST8-16)レンジをJST16-18にブレイク"""
    tokyo = df["jh"].between(8, 15)
    g = df.groupby("jdate")
    hi = g.apply(lambda x: x.loc[tokyo.loc[x.index], "high"].max())
    lo = g.apply(lambda x: x.loc[tokyo.loc[x.index], "low"].min())
    rh = df["jdate"].map(hi)
    rl = df["jdate"].map(lo)
    win = df["jh"].between(16, 17)
    long_ = win & (df["close"] > rh)
    short = win & (df["close"] < rl)
    # 1日1回に制限
    long_ = long_ & (~long_.groupby(df["jdate"]).cumsum().shift(1).fillna(0).astype(bool))
    short = short & (~short.groupby(df["jdate"]).cumsum().shift(1).fillna(0).astype(bool))
    return _pack(long_, short)


def cond_D02(df):
    """FVG: 3本ギャップ形成後、押し目でギャップ帯に戻ったら順張り"""
    h2 = df["high"].shift(2)
    l2 = df["low"].shift(2)
    bull_gap = df["low"] > h2
    bear_gap = df["high"] < l2
    gap_lo = h2.where(bull_gap)
    gap_hi = l2.where(bear_gap)
    # 形成後12本以内に帯へ戻ったバーをエントリーとする
    long_ = pd.Series(False, index=df.index)
    short = pd.Series(False, index=df.index)
    lows, highs = df["low"].values, df["high"].values
    for i in np.flatnonzero(bull_gap.values):
        lvl = gap_lo.values[i]
        j_end = min(i + 13, len(df))
        hit = np.flatnonzero(lows[i + 1:j_end] <= lvl)
        if hit.size:
            long_.iloc[i + 1 + hit[0]] = True
    for i in np.flatnonzero(bear_gap.values):
        lvl = gap_hi.values[i]
        j_end = min(i + 13, len(df))
        hit = np.flatnonzero(highs[i + 1:j_end] >= lvl)
        if hit.size:
            short.iloc[i + 1 + hit[0]] = True
    return _pack(long_, short)


def cond_D03(df):
    """ドンチャン20本ブレイク"""
    hh = df["high"].rolling(20).max().shift(1)
    ll = df["low"].rolling(20).min().shift(1)
    long_ = df["close"] > hh
    short = df["close"] < ll
    return _pack(long_, short)


def _pack(long_mask, short_mask):
    long_mask = long_mask.fillna(False).values.astype(bool)
    short_mask = short_mask.fillna(False).values.astype(bool)
    idx = np.concatenate([np.flatnonzero(long_mask), np.flatnonzero(short_mask)])
    side = np.concatenate([np.ones(long_mask.sum()), -np.ones(short_mask.sum())])
    o = np.argsort(idx)
    return idx[o], side[o]


def cond_B04(dfs):
    """相関乖離: EURUSD/GBPUSD スプレッドZスコア±2 で両建て相当"""
    a, b = dfs.get("EURUSD"), dfs.get("GBPUSD")
    if a is None or b is None:
        return None
    m = pd.merge(a[["time", "close"]], b[["time", "close"]], on="time",
                 suffixes=("_a", "_b")).dropna()
    if len(m) < 500:
        return None
    la = np.log(m["close_a"]); lb = np.log(m["close_b"])
    spread = (la - la.rolling(500).mean()) - (lb - lb.rolling(500).mean())
    z = (spread - spread.rolling(500).mean()) / spread.rolling(500).std(ddof=0)
    sig = pd.Series(0, index=m.index)
    sig[z > 2] = -1
    sig[z < -2] = 1
    ent = np.flatnonzero((sig != 0).values & (sig.shift(1).fillna(0) == 0).values)
    ent = ent[ent + HOLD_BARS < len(m)]
    if len(ent) < 10:
        return None
    fwd = (spread.values[ent + HOLD_BARS] - spread.values[ent]) * sig.values[ent]
    pnl = fwd * 10000.0   # log差 -> 概算pips
    n = len(pnl)
    sd = float(np.std(pnl, ddof=1))
    ev = float(np.mean(pnl))
    t = ev / (sd / math.sqrt(n)) if sd > 0 else 0.0
    yrs = m["time"].dt.year.values[ent]
    by_year = {}
    for y in (2022, 2023, 2024):
        s = pnl[yrs == y]
        by_year[str(y)] = round(float(np.mean(s)), 3) if len(s) > 2 else None
    signs = [v for v in by_year.values() if v is not None]
    cons = bool(signs) and (all(v > 0 for v in signs) or all(v < 0 for v in signs))
    months = max(1.0, (DATE_TO - DATE_FROM).days / 30.44)
    return {
        "label": "B04_pair_zscore", "symbol": "EURUSD-GBPUSD", "N": int(n),
        "EV_gross_pips": round(ev, 3), "EV_net_pips": round(ev - COST_PIPS * 2, 3),
        "sd_pips": round(sd, 2), "t_stat": round(float(t), 2),
        "trades_per_month": round(n / months, 1),
        "win_rate_ref": round(float((pnl > 0).mean()), 3),
        "avg_MFE_pips": None, "avg_MAE_pips": None,
        "EV_by_year": by_year, "sign_consistent": cons,
        "verdict": verdict(ev - COST_PIPS * 2, t, n, cons),
    }


# ---------------------------------------------------------------- main
def run(csvdir, broker_offset, out):
    results, meta = [], {}
    dfs = {}
    for sym in SYMBOLS:
        try:
            df, src, err = load(sym, csvdir, broker_offset)
            df.attrs["jpy"] = sym.endswith("JPY")
            dfs[sym] = df
            meta[sym] = {"source": src, "bars": int(len(df)),
                         "first": str(df["time"].iloc[0]), "last": str(df["time"].iloc[-1]),
                         "mt5_error": err}
        except Exception as e:
            meta[sym] = {"source": "FAILED", "error": str(e)}
            continue

        conds = [
            ("B01_asia_range_fade", cond_B01),
            ("B02_london_fix_fade", cond_B02),
            ("B03_monday_gap_fill", cond_B03),
            ("C02_month_end", cond_C02),
            ("D01_london_breakout", cond_D01),
            ("D02_fvg_retrace", cond_D02),
            ("D03_donchian20", cond_D03),
        ]
        for label, fn in conds:
            try:
                idx, side = fn(df)
                r = evaluate(df, idx, side, sym, label)
                if r:
                    results.append(r)
            except Exception as e:
                results.append({"label": label, "symbol": sym, "error": str(e)})

        for dow, nm in enumerate(["Mon", "Tue", "Wed", "Thu", "Fri"]):
            try:
                idx, side = cond_C01(df, dow)
                r = evaluate(df, idx, side, sym, "C01_dow_%s_long" % nm)
                if r:
                    results.append(r)
            except Exception as e:
                results.append({"label": "C01_dow_%s" % nm, "symbol": sym, "error": str(e)})

    try:
        r = cond_B04(dfs)
        if r:
            results.append(r)
    except Exception as e:
        results.append({"label": "B04_pair_zscore", "error": str(e)})

    cands = [r for r in results if r.get("verdict") == "CANDIDATE"]
    payload = {
        "version": VERSION,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "params": {"hold_bars": HOLD_BARS, "cost_pips": COST_PIPS,
                   "broker_utc_offset": broker_offset,
                   "period": "2022-01-01..2024-12-31", "tf": "M15"},
        "note": "verdict CANDIDATE = N>=100 かつ |t|>3 かつ 年別符号一致 かつ 純EV>0",
        "meta": meta,
        "summary": {"total": len(results), "candidates": len(cands),
                    "candidate_labels": [c["label"] + "/" + c["symbol"] for c in cands]},
        "results": sorted(results, key=lambda r: -abs(r.get("t_stat", 0) or 0)),
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    print("wrote %s  results=%d candidates=%d" % (out, len(results), len(cands)))
    return payload


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--csvdir", default="data")
    ap.add_argument("--offset", type=int, default=3, help="broker UTC offset (hours)")
    ap.add_argument("--out", default="result_edgescan_v1.json")
    a = ap.parse_args()
    run(a.csvdir, a.offset, a.out)

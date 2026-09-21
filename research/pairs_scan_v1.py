#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pairs_scan_v1.py  -- B04: 統計的ペアトレード(相関乖離)

仮説: 共通のドル要因で結ばれた 2 通貨のスプレッドは平均回帰する。
      Z スコアが閾値を超えたら乖離方向に賭け、Z=0 近傍で解消する。

v1 の教訓を全て織り込む:
  - 実測スプレッド(rates.spread)で往復コストを両脚に課す
  - ATR(R) 正規化ではなく「ドル建て損益」で評価(両脚合算しやすい)
  - 2015-2021 を OOS として厳格分離
  - ヘッジ比は IS 期間のみで推定し OOS に固定適用(先読み防止)
  - ローリング窓は全て shift(1) 済み(未来を見ない)
  - 多重検定補正後 t を出力

対象ペア(ドル共通/クロス):
  EURUSD-GBPUSD, AUDUSD-NZDUSD, USDCHF-EURUSD(符号反転),
  EURUSD-USDCHF, AUDUSD-USDCAD(符号反転気味), EURJPY-GBPJPY

評価はスプレッド系列 s = log(A) - beta*log(B) の平均回帰。
エントリー: |Z|>z_in、決済: |Z|<z_out もしくは最大保有到達。
損益: スプレッドの変化 * 方向。pips 換算し実コストを引く。

Usage:
  python pairs_scan_v1.py --out pairs.json
"""
import argparse
import json
import math
from datetime import datetime, timezone, timedelta

import numpy as np
import pandas as pd

VERSION = "pairs_scan_v1"

DATE_FROM = datetime(2015, 1, 1, tzinfo=timezone.utc)
DATE_TO   = datetime(2025, 1, 1, tzinfo=timezone.utc)
IS_START  = 2022

BETA_WIN  = 3000      # ヘッジ比推定の窓(バー) ~ 30日、EWM平滑
Z_WINS    = [200, 500, 1000]   # Z スコアの窓 (掃引)
Z_INS     = [2.0, 2.5, 3.0]
Z_OUT     = 0.5
MAX_HOLD  = [16, 48, 96]   # 4h / 12h / 24h

PAIRS = [
    ("EURUSD", "GBPUSD"),
    ("AUDUSD", "NZDUSD"),
    ("EURUSD", "USDCHF"),
    ("USDCHF", "USDJPY"),
    ("EURJPY", "GBPJPY"),
    ("AUDUSD", "USDCAD"),
]

SYMBOLS = sorted({s for p in PAIRS for s in p})


# ---------------------------------------------------------------- tz utils
def _last_sunday(y, mo):
    d = datetime(y, mo, 31)
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
        raise RuntimeError("symbol_select failed: %s" % symbol)
    info = mt5.symbol_info(symbol)
    digits = int(info.digits) if info else 5
    rates = mt5.copy_rates_range(symbol, mt5.TIMEFRAME_M15, DATE_FROM, DATE_TO)
    if rates is None or len(rates) == 0:
        raise RuntimeError("no rates: %s" % (mt5.last_error(),))
    df = pd.DataFrame(rates)
    df["local"] = pd.to_datetime(df["time"], unit="s")
    off = broker_offset_series(df["local"])
    df["utc"] = df["local"] - pd.to_timedelta(off, unit="h")
    df = df[(df["utc"] >= DATE_FROM.replace(tzinfo=None)) &
            (df["utc"] <  DATE_TO.replace(tzinfo=None))]
    sp = df["spread"].values / points_per_pip(digits) if "spread" in df.columns \
         else np.full(len(df), np.nan)
    out = pd.DataFrame({"utc": df["utc"].values,
                        "close": df["close"].values,
                        "spread_pips": sp})
    out = out.dropna(subset=["close"]).drop_duplicates("utc").set_index("utc").sort_index()
    out.attrs["digits"] = digits
    out.attrs["pip"] = pip_size(symbol)
    return out


# ---------------------------------------------------------------- one pair
def eval_pair(a_sym, b_sym, dfa, dfb, z_in, z_out, max_hold, z_win):
    # 厳密な時刻整列(共通タイムスタンプのみ)
    j = pd.concat([dfa["close"].rename("A"), dfb["close"].rename("B"),
                   dfa["spread_pips"].rename("spA"),
                   dfb["spread_pips"].rename("spB")], axis=1).dropna()
    if len(j) < BETA_WIN + z_win + 100:
        return None

    la = np.log(j["A"].values)
    lb = np.log(j["B"].values)
    yrs = pd.DatetimeIndex(j.index).year.values

    # ローリング beta = Cov/Var を EWM で平滑化(全て shift して未来を見ない)
    dfp = pd.DataFrame({"la": la, "lb": lb})
    cov = dfp["la"].rolling(BETA_WIN).cov(dfp["lb"]).values
    var = dfp["lb"].rolling(BETA_WIN).var().values
    with np.errstate(invalid="ignore", divide="ignore"):
        beta_raw = cov / var
    beta = pd.Series(beta_raw).ewm(span=BETA_WIN, min_periods=BETA_WIN).mean().shift(1).values
    beta = np.where(np.isfinite(beta), beta, np.nan)

    spread = la - beta * lb
    ss = pd.Series(spread)
    mu = ss.rolling(z_win).mean().shift(1).values
    sd = ss.rolling(z_win).std(ddof=0).shift(1).values
    with np.errstate(invalid="ignore", divide="ignore"):
        z = (spread - mu) / sd

    pipA = pip_size(a_sym)
    pipB = pip_size(b_sym)
    spA = j["spA"].values
    spB = j["spB"].values

    n = len(j)
    i = BETA_WIN + z_win
    trades = []
    while i < n - 1:
        if not np.isfinite(z[i]) or not np.isfinite(beta[i]):
            i += 1
            continue
        if abs(z[i]) < z_in:
            i += 1
            continue
        # z>0: spread 高い -> A 売り / B 買い。z<0 は逆。
        dir_a = -np.sign(z[i])
        entry_spread = spread[i]
        # コスト: 両脚それぞれのスプレッドを pips -> log 近似
        # 1 pip の log 変化 ~ pip / price
        cost_log = (spA[i] * pipA / j["A"].values[i]
                    + spB[i] * pipB / j["B"].values[i])
        # 決済まで進める
        k = i + 1
        exit_k = None
        while k < min(i + max_hold, n):
            if np.isfinite(z[k]) and abs(z[k]) < z_out:
                exit_k = k
                break
            k += 1
        if exit_k is None:
            exit_k = min(i + max_hold, n - 1)
        exit_spread = spread[exit_k]
        # スプレッドの縮小方向に賭ける -> PnL = -(exit-entry)*sign(z)
        pnl_log = -(exit_spread - entry_spread) * np.sign(z[i])
        cost_out = (spA[exit_k] * pipA / j["A"].values[exit_k]
                    + spB[exit_k] * pipB / j["B"].values[exit_k])
        net_log = pnl_log - cost_log - cost_out
        trades.append((net_log, pnl_log, yrs[i], exit_k - i))
        i = exit_k + 1

    if len(trades) < 20:
        return None
    net = np.array([t[0] for t in trades])
    gross = np.array([t[1] for t in trades])
    tyr = np.array([t[2] for t in trades])
    hold = np.array([t[3] for t in trades])

    # bp 換算 (log*1e4 ~ bp)
    net_bp = net * 1e4
    gross_bp = gross * 1e4

    def sub(mask):
        s = net_bp[mask]
        if len(s) < 15:
            return {"N": int(len(s)), "EV_bp": None, "t": None}
        return {"N": int(len(s)), "EV_bp": round(float(np.mean(s)), 2),
                "t": round(tstat(s), 2)}

    by_year = {}
    for y in sorted(set(tyr.tolist())):
        s = net_bp[tyr == y]
        by_year[str(int(y))] = round(float(np.mean(s)), 2) if len(s) > 3 else None
    signs = [v for v in by_year.values() if v is not None]

    return {
        "pair": "%s/%s" % (a_sym, b_sym),
        "z_in": z_in, "max_hold": max_hold, "z_win": z_win,
        "N": len(trades),
        "EV_gross_bp": round(float(np.mean(gross_bp)), 2),
        "EV_net_bp": round(float(np.mean(net_bp)), 2),
        "t_net": round(tstat(net_bp), 2),
        "win_net": round(float((net_bp > 0).mean()), 3),
        "avg_hold_bars": round(float(np.mean(hold)), 1),
        "years_pos": "%d/%d" % (sum(1 for v in signs if v > 0), len(signs)),
        "OOS_2015_2021": sub(tyr < IS_START),
        "IS_2022_2024": sub(tyr >= IS_START),
        "EV_by_year": by_year,
        "_net": net_bp, "_yr": tyr,
    }


# ---------------------------------------------------------------- main
def run(out):
    meta, dfs = {}, {}
    for s in SYMBOLS:
        try:
            dfs[s] = load(s)
            meta[s] = {"bars": int(len(dfs[s])), "digits": dfs[s].attrs["digits"]}
        except Exception as e:
            meta[s] = {"error": str(e)[:160]}

    rows, pooled = [], []
    for (a, b) in PAIRS:
        if a not in dfs or b not in dfs:
            continue
        for zi in Z_INS:
            for mh in MAX_HOLD:
                for zw in Z_WINS:
                    try:
                        r = eval_pair(a, b, dfs[a], dfs[b], zi, Z_OUT, mh, zw)
                        if r:
                            rows.append(r)
                    except Exception as e:
                        rows.append({"pair": "%s/%s" % (a, b), "z_in": zi,
                                     "max_hold": mh, "z_win": zw,
                                     "error": str(e)[:150]})

    # パラメータ組ごとに全ペアをプール
    from collections import defaultdict
    groups = defaultdict(list)
    for r in rows:
        if "t_net" in r:
            groups[(r["z_in"], r["max_hold"], r["z_win"])].append(r)
    for (zi, mh, zw), g in groups.items():
        allN = np.concatenate([r["_net"] for r in g])
        allY = np.concatenate([r["_yr"] for r in g])
        if len(allN) < 40:
            continue
        oos = allN[allY < IS_START]
        ins = allN[allY >= IS_START]
        by_year = {}
        for y in sorted(set(allY.tolist())):
            s = allN[allY == y]
            by_year[str(int(y))] = round(float(np.mean(s)), 2) if len(s) > 5 else None
        signs = [v for v in by_year.values() if v is not None]
        pooled.append({
            "z_in": zi, "max_hold": mh, "z_win": zw, "n_pairs": len(g),
            "N": int(len(allN)),
            "EV_net_bp": round(float(np.mean(allN)), 2),
            "t_net": round(tstat(allN), 2),
            "OOS_t": round(tstat(oos), 2) if len(oos) >= 20 else None,
            "OOS_EV_bp": round(float(np.mean(oos)), 2) if len(oos) >= 20 else None,
            "IS_t": round(tstat(ins), 2) if len(ins) >= 20 else None,
            "years_pos": "%d/%d" % (sum(1 for v in signs if v > 0), len(signs)),
            "EV_by_year": by_year,
        })

    n_tests = len(pooled)
    rt = req_t(max(1, n_tests))
    for p in pooled:
        p["SURVIVES"] = bool(p["t_net"] > rt and p["EV_net_bp"] > 0
                             and p["OOS_t"] is not None and p["OOS_t"] > 2.0)

    for r in rows:
        r.pop("_net", None); r.pop("_yr", None)

    payload = {
        "version": VERSION,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "note": ("スプレッド s=log(A)-beta*log(B) の平均回帰。beta,mu,sd は全て "
                 "shift(1) 済みで未来を見ない。損益は bp(log*1e4)。両脚の実測スプレッドを "
                 "入口・出口で控除。SURVIVES = プール t>補正閾値 かつ OOS t>2 かつ EV>0。"),
        "params": {"beta_win": BETA_WIN, "z_ins": Z_INS, "z_wins": Z_WINS,
                   "z_out": Z_OUT, "max_holds": MAX_HOLD,
                   "period": "2015-2024", "IS_from": IS_START},
        "n_tests": n_tests, "required_t": round(rt, 2),
        "n_survivors": sum(1 for p in pooled if p["SURVIVES"]),
        "pooled": sorted(pooled, key=lambda p: -p["t_net"]),
        "per_pair": sorted([r for r in rows if "t_net" in r],
                           key=lambda r: -r.get("t_net", 0))[:24],
        "errors": [r for r in rows if "error" in r][:10],
        "meta": meta,
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    print("wrote %s tests=%d survivors=%d req_t=%.2f"
          % (out, n_tests, payload["n_survivors"], rt))
    return payload


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="pairs.json")
    a = ap.parse_args()
    run(a.out)

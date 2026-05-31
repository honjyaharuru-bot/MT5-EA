//+------------------------------------------------------------------+
//|                                                        FVG_EA.mq5 |
//|                              FVG EA Ver1.0  (MT5)                 |
//|  Spec: Trend=M10 / BOS=M5 / 3-candle FVG / 50% retrace            |
//|        Buy/Sell Limit, SL outside FVG, TP at structural liquidity |
//+------------------------------------------------------------------+
#property copyright "FVG EA Ver1.0"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// 入力パラメータ
//==================================================================
input group "=== 一般 / General ==="
input long    InpMagic           = 990010;   // マジックナンバー
input double  InpRiskPercent     = 1.0;       // 1トレードのリスク% (0=固定ロット)
input double  InpFixedLot        = 0.10;      // 固定ロット (RiskPercent=0の時)
input int     InpMaxSpreadPoints = 25;        // 最大許容スプレッド(ポイント)
input int     InpSlippagePoints  = 10;        // 許容スリッページ

input group "=== 時間足 / Timeframes ==="
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_M10; // トレンド判定
input ENUM_TIMEFRAMES InpBosTF   = PERIOD_M5;  // BOS / FVG / ATR

input group "=== 構造 / Structure ==="
input int     InpSwingHalfWidth  = 3;         // フラクタル左右本数
input int     InpScanBars        = 300;       // 構造スキャン本数

input group "=== FVG ==="
input int     InpATRPeriod       = 14;        // ATR期間
input double  InpATRMultiplier   = 0.5;       // FVG最小サイズ = ATR x この値
input double  InpSLBufferPoints  = 30;        // FVG外側へのSLバッファ(ポイント)
input double  InpMinRR           = 1.5;       // これ未満のRRは見送り

input group "=== 発注 / Order ==="
input int     InpPendingExpiryMin = 60;       // Limit有効期限(分) 0=無期限

input group "=== セッション(サーバー時間) / Sessions ==="
input bool    InpUseSession      = true;      // セッションフィルタ有効
input int     InpLondonStart     = 8;         // ロンドン開始(時)
input int     InpLondonEnd       = 17;        // ロンドン終了(時)
input int     InpNYStart         = 13;        // NY開始(時)
input int     InpNYEnd           = 22;        // NY終了(時)

input group "=== ニュース / News (live only) ==="
input bool    InpUseNewsFilter   = true;      // 指標フィルタ(テスターでは無効)
input int     InpNewsBeforeMin   = 30;        // 指標 前 停止(分)
input int     InpNewsAfterMin    = 30;        // 指標 後 停止(分)

//==================================================================
// グローバル
//==================================================================
int      g_atrHandle = INVALID_HANDLE;
datetime g_lastBarTime = 0;

//==================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_atrHandle = iATR(_Symbol, InpBosTF, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("ATRハンドル作成失敗");
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

//==================================================================
void OnTick()
{
   // 新しいM5バーでのみ処理
   datetime t = iTime(_Symbol, InpBosTF, 0);
   if(t == g_lastBarTime) return;
   g_lastBarTime = t;

   // 既にポジション/待機注文があれば何もしない（同時1・追撃禁止）
   if(HasPositionOrOrder()) return;

   // フィルタ
   if(InpUseSession && !InSession())     return;
   if(!SpreadOK())                        return;
   if(InpUseNewsFilter && NewsBlock())    return;

   // トレンド判定
   int trend = GetTrend();      // +1=up, -1=down, 0=none
   if(trend == 0) return;

   // BOS判定 + FVG抽出 + 発注
   if(trend > 0) TryLong();
   else          TryShort();
}

//==================================================================
// ポジション/注文の存在確認
//==================================================================
bool HasPositionOrOrder()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

//==================================================================
// セッション(サーバー時間)
//==================================================================
bool InSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   bool london = (h >= InpLondonStart && h < InpLondonEnd);
   bool ny     = (h >= InpNYStart     && h < InpNYEnd);
   return (london || ny);
}

//==================================================================
// スプレッド
//==================================================================
bool SpreadOK()
{
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (sp <= InpMaxSpreadPoints);
}

//==================================================================
// ニュースフィルタ (MT5カレンダー / ライブのみ)
//==================================================================
bool NewsBlock()
{
   // Strategy Testerではカレンダー未対応 -> 常に通す
   if(MQLInfoInteger(MQL_TESTER)) return false;

   datetime now    = TimeCurrent();
   datetime from   = now - InpNewsAfterMin*60;   // 直近に発表されたもの
   datetime to     = now + InpNewsBeforeMin*60;  // これから発表されるもの

   string currencies[2] = {"USD","EUR"};
   for(int c = 0; c < 2; c++)
   {
      MqlCalendarValue values[];
      int n = CalendarValueHistory(values, from, to, NULL, currencies[c]);
      for(int i = 0; i < n; i++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev)) continue;
         if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
            return true; // 重要指標が時間窓内にある
      }
   }
   return false;
}

//==================================================================
// フラクタル判定
//==================================================================
bool IsFractalHigh(ENUM_TIMEFRAMES tf, int i, int w)
{
   double h = iHigh(_Symbol, tf, i);
   for(int k = 1; k <= w; k++)
   {
      if(iHigh(_Symbol, tf, i+k) >= h) return false;
      if(iHigh(_Symbol, tf, i-k) >= h) return false;
   }
   return true;
}

bool IsFractalLow(ENUM_TIMEFRAMES tf, int i, int w)
{
   double l = iLow(_Symbol, tf, i);
   for(int k = 1; k <= w; k++)
   {
      if(iLow(_Symbol, tf, i+k) <= l) return false;
      if(iLow(_Symbol, tf, i-k) <= l) return false;
   }
   return true;
}

//==================================================================
// 直近2つのスイング高値・安値を取得
//==================================================================
void GetSwings(ENUM_TIMEFRAMES tf, int w, int scan,
               double &h1, int &h1b, double &h2, int &h2b,
               double &l1, int &l1b, double &l2, int &l2b)
{
   h1=h2=l1=l2=0; h1b=h2b=l1b=l2b=-1;
   int foundH=0, foundL=0;
   int bars = (int)Bars(_Symbol, tf);
   int maxi = MathMin(scan, bars - w - 1);

   for(int i = w; i <= maxi && (foundH<2 || foundL<2); i++)
   {
      if(foundH < 2 && IsFractalHigh(tf, i, w))
      {
         if(foundH==0){ h1=iHigh(_Symbol,tf,i); h1b=i; }
         else        { h2=iHigh(_Symbol,tf,i); h2b=i; }
         foundH++;
      }
      if(foundL < 2 && IsFractalLow(tf, i, w))
      {
         if(foundL==0){ l1=iLow(_Symbol,tf,i); l1b=i; }
         else        { l2=iLow(_Symbol,tf,i); l2b=i; }
         foundL++;
      }
   }
}

//==================================================================
// トレンド判定 (M10): HH+HL=上昇 / LL+LH=下降 / それ以外=不明
//==================================================================
int GetTrend()
{
   double h1,h2,l1,l2; int h1b,h2b,l1b,l2b;
   GetSwings(InpTrendTF, InpSwingHalfWidth, InpScanBars,
             h1,h1b,h2,h2b,l1,l1b,l2,l2b);
   if(h1b<0 || h2b<0 || l1b<0 || l2b<0) return 0;

   bool hh = (h1 > h2);
   bool hl = (l1 > l2);
   bool ll = (l1 < l2);
   bool lh = (h1 < h2);

   if(hh && hl) return  1;
   if(ll && lh) return -1;
   return 0;
}

//==================================================================
// ATR値
//==================================================================
double GetATR()
{
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) <= 0) return 0;
   return buf[0];
}

//==================================================================
// ロット計算 (リスク%)
//==================================================================
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot/step)*step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

double CalcLot(double slDistancePrice)
{
   if(InpRiskPercent <= 0.0 || slDistancePrice <= 0.0)
      return NormalizeLot(InpFixedLot);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return NormalizeLot(InpFixedLot);

   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0) return NormalizeLot(InpFixedLot);

   return NormalizeLot(riskMoney / lossPerLot);
}

//==================================================================
// 買い: M5強気BOS -> BOS後最初の強気FVG -> 50%へBuy Limit
//==================================================================
void TryLong()
{
   double h1,h2,l1,l2; int h1b,h2b,l1b,l2b;
   GetSwings(InpBosTF, InpSwingHalfWidth, InpScanBars,
             h1,h1b,h2,h2b,l1,l1b,l2,l2b);
   if(h1b < 1) return;

   // 直近スイング高値を上抜く終値（BOS）を探す（最も古いブレイク=最初のBOS）
   int bosBar = -1;
   for(int i = h1b-1; i >= 1; i--)
   {
      if(iClose(_Symbol, InpBosTF, i) > h1)
      { bosBar = i; }
   }
   if(bosBar < 0) return;   // BOSなし

   // BOS後 最初の強気FVG: low[j] > high[j+2]
   double atr = GetATR();
   if(atr <= 0) return;
   double minSize = atr * InpATRMultiplier;

   double fvgTop=0, fvgBottom=0;
   bool found=false;
   for(int j = h1b; j >= 1; j--)   // 古い側から走査 = 最初に形成されたFVG
   {
      double lowJ  = iLow(_Symbol,  InpBosTF, j);
      double highJ2= iHigh(_Symbol, InpBosTF, j+2);
      if(lowJ > highJ2)
      {
         double top = lowJ;       // FVG上端
         double bot = highJ2;     // FVG下端
         if((top - bot) >= minSize)
         {
            fvgTop = top; fvgBottom = bot; found = true;
            break;                // 最初の有効FVGのみ
         }
      }
   }
   if(!found) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double mid   = (fvgTop + fvgBottom) / 2.0;
   double entry = NormalizePrice(mid);
   double sl    = NormalizePrice(fvgBottom - InpSLBufferPoints*point);

   // TP: M10で entry より上の直近スイング高値（流動性）
   double tp = FindLiquidityAbove(entry);
   if(tp <= 0) return;
   tp = NormalizePrice(tp);

   // 現在価格より下にLimitを置けること（回帰前）
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(entry >= ask) return;       // 既に回帰済み/不正 -> 見送り

   if((entry - sl) <= 0) return;
   double rr = (tp - entry) / (entry - sl);
   if(rr < InpMinRR) return;      // 品質優先

   double lot = CalcLot(entry - sl);
   datetime exp = (InpPendingExpiryMin>0) ? TimeCurrent()+InpPendingExpiryMin*60 : 0;
   ENUM_ORDER_TYPE_TIME tt = (exp>0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

   trade.BuyLimit(lot, entry, _Symbol, sl, tp, tt, exp, "FVG_BUY");
}

//==================================================================
// 売り: M5弱気BOS -> BOS後最初の弱気FVG -> 50%へSell Limit
//==================================================================
void TryShort()
{
   double h1,h2,l1,l2; int h1b,h2b,l1b,l2b;
   GetSwings(InpBosTF, InpSwingHalfWidth, InpScanBars,
             h1,h1b,h2,h2b,l1,l1b,l2,l2b);
   if(l1b < 1) return;

   int bosBar = -1;
   for(int i = l1b-1; i >= 1; i--)
   {
      if(iClose(_Symbol, InpBosTF, i) < l1)
      { bosBar = i; }
   }
   if(bosBar < 0) return;

   double atr = GetATR();
   if(atr <= 0) return;
   double minSize = atr * InpATRMultiplier;

   // 弱気FVG: high[j] < low[j+2]
   double fvgTop=0, fvgBottom=0;
   bool found=false;
   for(int j = l1b; j >= 1; j--)
   {
      double highJ = iHigh(_Symbol, InpBosTF, j);
      double lowJ2 = iLow(_Symbol,  InpBosTF, j+2);
      if(highJ < lowJ2)
      {
         double top = lowJ2;      // FVG上端
         double bot = highJ;      // FVG下端
         if((top - bot) >= minSize)
         {
            fvgTop = top; fvgBottom = bot; found = true;
            break;
         }
      }
   }
   if(!found) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double mid   = (fvgTop + fvgBottom) / 2.0;
   double entry = NormalizePrice(mid);
   double sl    = NormalizePrice(fvgTop + InpSLBufferPoints*point);

   double tp = FindLiquidityBelow(entry);
   if(tp <= 0) return;
   tp = NormalizePrice(tp);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(entry <= bid) return;       // SellLimitは現値より上に置く

   if((sl - entry) <= 0) return;
   double rr = (entry - tp) / (sl - entry);
   if(rr < InpMinRR) return;

   double lot = CalcLot(sl - entry);
   datetime exp = (InpPendingExpiryMin>0) ? TimeCurrent()+InpPendingExpiryMin*60 : 0;
   ENUM_ORDER_TYPE_TIME tt = (exp>0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

   trade.SellLimit(lot, entry, _Symbol, sl, tp, tt, exp, "FVG_SELL");
}

//==================================================================
// 流動性ポイント(TP)探索: entryより上/下の直近スイング(M10)
//==================================================================
double FindLiquidityAbove(double entry)
{
   int w = InpSwingHalfWidth;
   int bars = (int)Bars(_Symbol, InpTrendTF);
   int maxi = MathMin(InpScanBars, bars - w - 1);
   for(int i = w; i <= maxi; i++)
   {
      if(IsFractalHigh(InpTrendTF, i, w))
      {
         double h = iHigh(_Symbol, InpTrendTF, i);
         if(h > entry) return h;   // 最も近い上のスイング高値
      }
   }
   return 0;
}

double FindLiquidityBelow(double entry)
{
   int w = InpSwingHalfWidth;
   int bars = (int)Bars(_Symbol, InpTrendTF);
   int maxi = MathMin(InpScanBars, bars - w - 1);
   for(int i = w; i <= maxi; i++)
   {
      if(IsFractalLow(InpTrendTF, i, w))
      {
         double l = iLow(_Symbol, InpTrendTF, i);
         if(l < entry) return l;
      }
   }
   return 0;
}

//==================================================================
double NormalizePrice(double p)
{
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}
//+------------------------------------------------------------------+

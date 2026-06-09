//+------------------------------------------------------------------+
//|                                                        FVG_EA.mq5 |
//|                    FVG EA Ver2.0  (MT5)                           |
//|   Bias = H1 trend, Entry = M15 BOS + FVG (limit-only)            |
//|   Rule: if the FVG is NOT filled (limit not hit) -> NO ENTRY      |
//+------------------------------------------------------------------+
#property copyright "FVG EA Ver2.0"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

input group "=== General ==="
input long    InpMagic           = 990015;
input double  InpRiskPercent     = 1.0;
input double  InpFixedLot        = 0.10;
input int     InpMaxSpreadPoints = 25;
input int     InpSlippagePoints  = 10;

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H1;   // bias / liquidity
input ENUM_TIMEFRAMES InpBosTF   = PERIOD_M15;  // BOS / FVG / entry

input group "=== Structure ==="
input int     InpSwingHalfWidth  = 3;
input int     InpScanBars        = 300;

input group "=== FVG ==="
input int     InpATRPeriod       = 14;
input double  InpATRMultiplier   = 0.5;
input double  InpSLBufferPoints  = 30;
input double  InpMinRR           = 1.5;

input group "=== Entry / Fill rule ==="
input double  InpEntryFillRatio  = 0.5;   // 0=near edge, 0.5=mid, 1.0=full fill
input int     InpFillWindowBars  = 8;     // cancel pending if unfilled within N M15 bars

input group "=== Sessions ==="
input bool    InpUseSession      = true;
input int     InpLondonStart     = 8;
input int     InpLondonEnd       = 17;
input int     InpNYStart         = 13;
input int     InpNYEnd           = 22;

input group "=== News ==="
input bool    InpUseNewsFilter   = true;
input int     InpNewsBeforeMin   = 30;
input int     InpNewsAfterMin    = 30;

int      g_atrHandle = INVALID_HANDLE;
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_atrHandle = iATR(_Symbol, InpBosTF, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("ATR handle creation failed");
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime t = iTime(_Symbol, InpBosTF, 0);
   if(t == g_lastBarTime) return;     // act once per new M15 bar
   g_lastBarTime = t;

   ManagePending();                   // handle waiting limit first

   if(HasPosition()) return;          // already in a trade
   if(HasPending())  return;          // a limit is waiting for the FVG fill

   if(InpUseSession && !InSession()) return;
   if(!SpreadOK()) return;
   if(InpUseNewsFilter && NewsBlock()) return;

   int trend = GetTrend();
   if(trend == 0) return;

   if(trend > 0) TryLong();
   else          TryShort();
}

//+------------------------------------------------------------------+
//| Pending management: enforce "no fill -> no entry"                |
//+------------------------------------------------------------------+
void ManagePending()
{
   int barSec = PeriodSeconds(InpBosTF);
   int trend  = GetTrend();

   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL)   != _Symbol)  continue;
      if(OrderGetInteger(ORDER_MAGIC)   != InpMagic) continue;

      long     type  = OrderGetInteger(ORDER_TYPE);
      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      bool isBuy  = (type == ORDER_TYPE_BUY_LIMIT);
      bool isSell = (type == ORDER_TYPE_SELL_LIMIT);

      // (1) FVG not filled within the window -> cancel, no entry
      if(TimeCurrent() - setup >= (long)InpFillWindowBars * barSec)
      {
         trade.OrderDelete(tk);
         Print("FVG not filled within window -> cancel pending, NO ENTRY");
         continue;
      }
      // (2) trend flipped before fill -> setup stale, cancel
      if(isBuy  && trend <  1) { trade.OrderDelete(tk); Print("Trend no longer up -> cancel buy pending");  continue; }
      if(isSell && trend > -1) { trade.OrderDelete(tk); Print("Trend no longer down -> cancel sell pending"); continue; }
   }
}

bool HasPosition()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

bool HasPending()
{
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong tk = OrderGetTicket(i);
      if(tk == 0) continue;
      if(OrderGetString(ORDER_SYMBOL)  == _Symbol &&
         OrderGetInteger(ORDER_MAGIC)  == InpMagic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool InSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   bool london = (h >= InpLondonStart && h < InpLondonEnd);
   bool ny     = (h >= InpNYStart     && h < InpNYEnd);
   return (london || ny);
}

bool SpreadOK()
{
   long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (sp <= InpMaxSpreadPoints);
}

bool NewsBlock()
{
   if(MQLInfoInteger(MQL_TESTER)) return false;
   datetime now  = TimeCurrent();
   datetime from = now - InpNewsAfterMin*60;
   datetime to   = now + InpNewsBeforeMin*60;
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
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
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
         else         { h2=iHigh(_Symbol,tf,i); h2b=i; }
         foundH++;
      }
      if(foundL < 2 && IsFractalLow(tf, i, w))
      {
         if(foundL==0){ l1=iLow(_Symbol,tf,i); l1b=i; }
         else         { l2=iLow(_Symbol,tf,i); l2b=i; }
         foundL++;
      }
   }
}

int GetTrend()   // H1 bias
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

double GetATR()
{
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) <= 0) return 0;
   return buf[0];
}

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

//+------------------------------------------------------------------+
//| LONG: H1 trend up -> M15 BOS up -> first FVG -> limit @ fill zone |
//+------------------------------------------------------------------+
void TryLong()
{
   double h1,h2,l1,l2; int h1b,h2b,l1b,l2b;
   GetSwings(InpBosTF, InpSwingHalfWidth, InpScanBars,
             h1,h1b,h2,h2b,l1,l1b,l2,l2b);
   if(h1b < 1) return;

   int bosBar = -1;
   for(int i = h1b-1; i >= 1; i--)
      if(iClose(_Symbol, InpBosTF, i) > h1) bosBar = i;
   if(bosBar < 0) return;

   double atr = GetATR();
   if(atr <= 0) return;
   double minSize = atr * InpATRMultiplier;

   double fvgTop=0, fvgBottom=0;
   bool found=false;
   for(int j = h1b; j >= 1; j--)
   {
      double lowJ  = iLow(_Symbol,  InpBosTF, j);
      double highJ2= iHigh(_Symbol, InpBosTF, j+2);
      if(lowJ > highJ2 && (lowJ - highJ2) >= minSize)
      {
         fvgTop = lowJ; fvgBottom = highJ2; found = true;
         break;
      }
   }
   if(!found) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double entry = NormalizePrice(fvgTop - InpEntryFillRatio*(fvgTop - fvgBottom));
   double sl    = NormalizePrice(fvgBottom - InpSLBufferPoints*point);
   double tp    = NormalizePrice(FindLiquidityAbove(entry));
   if(tp <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(entry >= ask) return;
   if((entry - sl) <= 0) return;
   if((tp - entry) / (entry - sl) < InpMinRR) return;

   double lot   = CalcLot(entry - sl);
   int barSec   = PeriodSeconds(InpBosTF);
   datetime exp = TimeCurrent() + (long)(InpFillWindowBars+1) * barSec;

   if(trade.BuyLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, exp, "FVG_BUY"))
      PrintFormat("FVG buy pending @ %.5f (SL %.5f TP %.5f) waiting fill within %d M15 bars",
                  entry, sl, tp, InpFillWindowBars);
}

//+------------------------------------------------------------------+
//| SHORT: mirror of TryLong                                         |
//+------------------------------------------------------------------+
void TryShort()
{
   double h1,h2,l1,l2; int h1b,h2b,l1b,l2b;
   GetSwings(InpBosTF, InpSwingHalfWidth, InpScanBars,
             h1,h1b,h2,h2b,l1,l1b,l2,l2b);
   if(l1b < 1) return;

   int bosBar = -1;
   for(int i = l1b-1; i >= 1; i--)
      if(iClose(_Symbol, InpBosTF, i) < l1) bosBar = i;
   if(bosBar < 0) return;

   double atr = GetATR();
   if(atr <= 0) return;
   double minSize = atr * InpATRMultiplier;

   double fvgTop=0, fvgBottom=0;
   bool found=false;
   for(int j = l1b; j >= 1; j--)
   {
      double highJ = iHigh(_Symbol, InpBosTF, j);
      double lowJ2 = iLow(_Symbol,  InpBosTF, j+2);
      if(highJ < lowJ2 && (lowJ2 - highJ) >= minSize)
      {
         fvgTop = lowJ2; fvgBottom = highJ; found = true;
         break;
      }
   }
   if(!found) return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double entry = NormalizePrice(fvgBottom + InpEntryFillRatio*(fvgTop - fvgBottom));
   double sl    = NormalizePrice(fvgTop + InpSLBufferPoints*point);
   double tp    = NormalizePrice(FindLiquidityBelow(entry));
   if(tp <= 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(entry <= bid) return;
   if((sl - entry) <= 0) return;
   if((entry - tp) / (sl - entry) < InpMinRR) return;

   double lot   = CalcLot(sl - entry);
   int barSec   = PeriodSeconds(InpBosTF);
   datetime exp = TimeCurrent() + (long)(InpFillWindowBars+1) * barSec;

   if(trade.SellLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, exp, "FVG_SELL"))
      PrintFormat("FVG sell pending @ %.5f (SL %.5f TP %.5f) waiting fill within %d M15 bars",
                  entry, sl, tp, InpFillWindowBars);
}

//+------------------------------------------------------------------+
double FindLiquidityAbove(double entry)   // H1 structural liquidity
{
   int w = InpSwingHalfWidth;
   int maxi = MathMin(InpScanBars, (int)Bars(_Symbol, InpTrendTF) - w - 1);
   for(int i = w; i <= maxi; i++)
      if(IsFractalHigh(InpTrendTF, i, w))
      {
         double h = iHigh(_Symbol, InpTrendTF, i);
         if(h > entry) return h;
      }
   return 0;
}

double FindLiquidityBelow(double entry)
{
   int w = InpSwingHalfWidth;
   int maxi = MathMin(InpScanBars, (int)Bars(_Symbol, InpTrendTF) - w - 1);
   for(int i = w; i <= maxi; i++)
      if(IsFractalLow(InpTrendTF, i, w))
      {
         double l = iLow(_Symbol, InpTrendTF, i);
         if(l < entry) return l;
      }
   return 0;
}

double NormalizePrice(double p)
{
   return NormalizeDouble(p, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
//| Backtest summary -> JSON (FILE_COMMON = shared, deterministic)   |
//+------------------------------------------------------------------+
double OnTester()
{
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double payoff = TesterStatistics(STAT_EXPECTED_PAYOFF);
   double net    = TesterStatistics(STAT_PROFIT);
   double trades = TesterStatistics(STAT_TRADES);
   double won    = TesterStatistics(STAT_PROFIT_TRADES);
   double lost   = TesterStatistics(STAT_LOSS_TRADES);
   double grossP = TesterStatistics(STAT_GROSS_PROFIT);
   double grossL = TesterStatistics(STAT_GROSS_LOSS);
   double ddRel  = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double sharpe = TesterStatistics(STAT_SHARPE_RATIO);

   double winrate = (trades > 0) ? won / trades * 100.0 : 0.0;
   double avgWin  = (won  > 0)   ? grossP / won          : 0.0;
   double avgLoss = (lost > 0)   ? MathAbs(grossL) / lost : 0.0;
   double avgRR   = (avgLoss > 0)? avgWin / avgLoss       : 0.0;

   string s = "{\n";
   s += StringFormat("  \"profit_factor\": %.4f,\n",   pf);
   s += StringFormat("  \"expected_payoff\": %.4f,\n", payoff);
   s += StringFormat("  \"net_profit\": %.2f,\n",      net);
   s += StringFormat("  \"trades\": %d,\n",            (int)trades);
   s += StringFormat("  \"win_rate_pct\": %.2f,\n",    winrate);
   s += StringFormat("  \"avg_rr\": %.4f,\n",          avgRR);
   s += StringFormat("  \"max_dd_rel_pct\": %.2f,\n",  ddRel);
   s += StringFormat("  \"sharpe\": %.4f\n",           sharpe);
   s += "}\n";

   int h = FileOpen("fvg_result.json", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) { FileWriteString(h, s); FileClose(h); }

   return pf;
}
//+------------------------------------------------------------------+

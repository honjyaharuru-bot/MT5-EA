//+------------------------------------------------------------------+
//|  FVG_EA_v3.mq5                                                   |
//|  Ver3.0  H1 bias + liquidity sweep + M15 displacement FVG        |
//|  All comments ASCII only (CI / Windows-1252 safe)                |
//|                                                                  |
//|  Design notes (read before tuning):                              |
//|   - Each entry filter has an ON/OFF input so you can test        |
//|     incrementally (raw FVG first, then add filters one by one).  |
//|   - RR is tunable. Partial TP (close at 1R, move SL to BE) is ON  |
//|     by default to lower break-even win rate. Set                 |
//|     InpUsePartialTP=false to reproduce the strict 1:2 spec.      |
//|   - OnTester writes JSON via FILE_COMMON to                       |
//|     Terminal\Common\Files\fvg_result.json (same as v2 pipeline). |
//|   - Long/short outcomes are tallied in OnTradeTransaction.        |
//+------------------------------------------------------------------+
#property copyright "FVG_EA"
#property version   "3.60"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//==================== Risk / exit ====================
input double InpRiskPercent   = 1.0;    // risk per trade (percent of balance)
input double InpTargetRR       = 1.0;   // final reward:risk (runner target)
input bool   InpUsePartialTP   = true;  // close part at partial RR, move SL to BE
input double InpPartialRR       = 0.5;  // partial take profit in R (first leg)
input double InpPartialPct      = 30.0; // pct closed at 0.5R; rest runs to 1R (lean=runner)

//==================== H1 bias ====================
input ENUM_TIMEFRAMES InpBiasTF      = PERIOD_H1;
input int    InpSwingLeftRight       = 3;   // pivot strength (bars each side)
input int    InpSwingScan            = 60;  // bars scanned for swings

//==================== Liquidity sweep (bias TF) ====================
input bool   InpRequireSweep   = false; // require a stop-hunt wick before bias
input double InpSweepPips        = 15.0; // wick pierces prior swing up to this (pips)
input int    InpSweepLookback   = 12;   // bias-TF bars back to look for the sweep

//==================== H1 FVG quality (confluence) ====================
input bool   InpRequireH1FVG   = false; // require a qualifying H1 FVG zone
input double InpH1GapAtrMult   = 1.5;   // H1 FVG gap >= ATR(H1) * this
input int    InpAtrPeriod       = 14;

//==================== M15 execution ====================
input ENUM_TIMEFRAMES InpExecTF      = PERIOD_M15;
input bool   InpRequireDisplacement  = false; // require big displacement candle
input double InpDispBodyMult          = 1.5; // mid body >= avg body * this
input int    InpAvgBodyLen            = 10;  // bars used for average body
input bool   InpUseSplitEntry         = false; // 50% at tip, 50% at 50% retr
input double InpFillRatio              = 0.5; // retracement for 2nd leg
input int    InpFillWindowBars        = 8;   // cancel pending after N exec bars
input double InpSLBufferPips          = 5.0; // SL buffer beyond origin candle

input long   InpMagic = 30300;

//==================== Globals ====================
double   g_pip      = 0.0;
int      g_hAtrH1   = INVALID_HANDLE;
datetime g_lastExecBar = 0;

// pending tracking
datetime g_pendingPlacedBar = 0;
int      g_pendingDir       = 0;   // 1 buy, -1 sell, 0 none

// position management
bool     g_partialDone = false;
double   g_posRiskDist = 0.0;      // SL distance (price) for current position

// outcome tally (for JSON)
int      g_longTrades=0, g_longWins=0;
int      g_shortTrades=0, g_shortWins=0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);

   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = ((d==3 || d==5) ? 10.0 : 1.0) * _Point;

   g_hAtrH1 = iATR(_Symbol, InpBiasTF, InpAtrPeriod);
   if(g_hAtrH1==INVALID_HANDLE)
   {
      Print("ATR handle failed");
      return(INIT_FAILED);
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_hAtrH1!=INVALID_HANDLE) IndicatorRelease(g_hAtrH1);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageOpenPosition();
   ManagePending();

   datetime curExec = iTime(_Symbol, InpExecTF, 0);
   if(curExec==g_lastExecBar) return;   // act once per closed exec bar
   g_lastExecBar = curExec;

   if(HasPositionOrPending()) return;   // 1 setup at a time

   EvaluateSetup();
}

//+------------------------------------------------------------------+
//| State checks                                                     |
//+------------------------------------------------------------------+
bool HasPositionOrPending()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
   }
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)==_Symbol &&
         OrderGetInteger(ORDER_MAGIC)==InpMagic) return true;
   }
   return false;
}

bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| H1 swing detection (simple pivots)                               |
//+------------------------------------------------------------------+
bool IsSwingHigh(ENUM_TIMEFRAMES tf,int idx,int lr)
{
   double h=iHigh(_Symbol,tf,idx);
   for(int k=1;k<=lr;k++)
   {
      if(iHigh(_Symbol,tf,idx+k)>=h) return false;
      if(iHigh(_Symbol,tf,idx-k)>h)  return false;
   }
   return true;
}
bool IsSwingLow(ENUM_TIMEFRAMES tf,int idx,int lr)
{
   double l=iLow(_Symbol,tf,idx);
   for(int k=1;k<=lr;k++)
   {
      if(iLow(_Symbol,tf,idx+k)<=l) return false;
      if(iLow(_Symbol,tf,idx-k)<l)  return false;
   }
   return true;
}

// returns last two swing highs/lows (prices and bar index)
bool LastSwings(ENUM_TIMEFRAMES tf,double &sh1,double &sh2,double &sl1,double &sl2,
                int &shIdx1,int &slIdx1)
{
   int lr=InpSwingLeftRight;
   int got_h=0, got_l=0;
   sh1=sh2=sl1=sl2=0; shIdx1=slIdx1=-1;
   for(int i=lr+1; i<=InpSwingScan && i<Bars(_Symbol,tf)-lr-1; i++)
   {
      if(got_h<2 && IsSwingHigh(tf,i,lr))
      {
         if(got_h==0){ sh1=iHigh(_Symbol,tf,i); shIdx1=i; }
         else        { sh2=iHigh(_Symbol,tf,i); }
         got_h++;
      }
      if(got_l<2 && IsSwingLow(tf,i,lr))
      {
         if(got_l==0){ sl1=iLow(_Symbol,tf,i); slIdx1=i; }
         else        { sl2=iLow(_Symbol,tf,i); }
         got_l++;
      }
      if(got_h>=2 && got_l>=2) break;
   }
   return(got_h>=2 && got_l>=2);
}

// 1 up, -1 down, 0 none
int H1Trend()
{
   double sh1,sh2,sl1,sl2; int shi,sli;
   if(!LastSwings(InpBiasTF,sh1,sh2,sl1,sl2,shi,sli)) return 0;
   if(sh1>sh2 && sl1>sl2) return 1;   // HH + HL
   if(sh1<sh2 && sl1<sl2) return -1;  // LH + LL
   return 0;
}

//+------------------------------------------------------------------+
//| Liquidity sweep: recent wick pierced a prior swing and closed    |
//| back. For up bias we want a sell-side sweep (below a swing low). |
//+------------------------------------------------------------------+
bool SweepConfirmed(int dir)
{
   if(!InpRequireSweep) return true;
   double sh1,sh2,sl1,sl2; int shi,sli;
   if(!LastSwings(InpBiasTF,sh1,sh2,sl1,sl2,shi,sli)) return false;
   double tol=InpSweepPips*g_pip;

   for(int i=1;i<=InpSweepLookback;i++)
   {
      double hi=iHigh(_Symbol,InpBiasTF,i);
      double lo=iLow(_Symbol,InpBiasTF,i);
      double cl=iClose(_Symbol,InpBiasTF,i);
      if(dir>0)
      {
         // wick below prior swing low, within tol, close back above it
         if(lo < sl1 && lo >= sl1-tol && cl > sl1) return true;
      }
      else if(dir<0)
      {
         if(hi > sh1 && hi <= sh1+tol && cl < sh1) return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| H1 FVG quality gate (gap >= ATR*mult, aligned with bias)         |
//+------------------------------------------------------------------+
bool H1FVGOk(int dir)
{
   if(!InpRequireH1FVG) return true;
   double atr[1];
   if(CopyBuffer(g_hAtrH1,0,1,1,atr)!=1) return false;
   double minGap=atr[0]*InpH1GapAtrMult;

   // scan recent H1 3-candle FVGs (A oldest .. C newest)
   for(int i=1;i<=InpSweepLookback;i++)
   {
      double aHigh=iHigh(_Symbol,InpBiasTF,i+2);
      double aLow =iLow (_Symbol,InpBiasTF,i+2);
      double cHigh=iHigh(_Symbol,InpBiasTF,i);
      double cLow =iLow (_Symbol,InpBiasTF,i);
      if(dir>0 && cLow>aHigh && (cLow-aHigh)>=minGap) return true;  // bullish gap
      if(dir<0 && aLow>cHigh && (aLow-cHigh)>=minGap) return true;  // bearish gap
   }
   return false;
}

//+------------------------------------------------------------------+
//| Average body of recent exec-TF candles                           |
//+------------------------------------------------------------------+
double AvgBody(int startIdx,int len)
{
   double s=0; int n=0;
   for(int i=startIdx;i<startIdx+len;i++)
   {
      s+=MathAbs(iClose(_Symbol,InpExecTF,i)-iOpen(_Symbol,InpExecTF,i));
      n++;
   }
   return(n>0 ? s/n : 0);
}

//+------------------------------------------------------------------+
//| Find latest M15 FVG aligned with bias. Fills out levels.         |
//|  A = bar 3 (oldest), B = bar 2 (displacement), C = bar 1 (newest)|
//|  Bullish: C.low > A.high (gap). tip = C.low (near edge on dip),  |
//|           mid = (A.high+C.low)/2, SL ref = B.low.                |
//+------------------------------------------------------------------+
bool FindM15FVG(int dir,double &tip,double &mid,double &slRef)
{
   int a=3, b=2, c=1;
   double aHigh=iHigh(_Symbol,InpExecTF,a);
   double aLow =iLow (_Symbol,InpExecTF,a);
   double bHigh=iHigh(_Symbol,InpExecTF,b);
   double bLow =iLow (_Symbol,InpExecTF,b);
   double cHigh=iHigh(_Symbol,InpExecTF,c);
   double cLow =iLow (_Symbol,InpExecTF,c);

   // displacement check on middle candle
   if(InpRequireDisplacement)
   {
      double body=MathAbs(iClose(_Symbol,InpExecTF,b)-iOpen(_Symbol,InpExecTF,b));
      double avg =AvgBody(b+1,InpAvgBodyLen);
      if(avg<=0 || body < avg*InpDispBodyMult) return false;
   }

   if(dir>0)
   {
      if(!(cLow>aHigh)) return false;          // valid bullish gap
      tip   = cLow;                            // near edge
      mid   = (aHigh+cLow)/2.0;
      slRef = bLow;                            // origin candle opposite end
      return true;
   }
   else if(dir<0)
   {
      if(!(aLow>cHigh)) return false;          // valid bearish gap
      tip   = cHigh;                           // near edge
      mid   = (aLow+cHigh)/2.0;
      slRef = bHigh;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Lot sizing from risk and SL distance                             |
//+------------------------------------------------------------------+
double CalcLot(double riskMoney,double slDistPrice)
{
   double tickVal =SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickVal<=0 || slDistPrice<=0) return 0;

   double lossPerLot=(slDistPrice/tickSize)*tickVal;
   if(lossPerLot<=0) return 0;
   double lot=riskMoney/lossPerLot;

   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lot=MathFloor(lot/step)*step;
   if(lot<vmin) lot=0;        // below min -> skip this leg
   if(lot>vmax) lot=vmax;
   return NormalizeDouble(lot,2);
}

//+------------------------------------------------------------------+
//| Build setup and place pending limit order(s)                     |
//+------------------------------------------------------------------+
void EvaluateSetup()
{
   int dir=H1Trend();
   if(dir==0) return;
   if(!SweepConfirmed(dir)) return;
   if(!H1FVGOk(dir)) return;

   double tip,mid,slRef;
   if(!FindM15FVG(dir,tip,mid,slRef)) return;

   double buf=InpSLBufferPips*g_pip;
   double sl,slDist;
   if(dir>0) sl=slRef-buf; else sl=slRef+buf;

   slDist=MathAbs(tip-sl);
   if(slDist<=0) return;

   double tp;
   if(dir>0) tp=tip+slDist*InpTargetRR; else tp=tip-slDist*InpTargetRR;

   double riskMoney=AccountInfoDouble(ACCOUNT_BALANCE)*InpRiskPercent/100.0;
   double leg1Risk = InpUseSplitEntry ? riskMoney*0.5 : riskMoney;

   tip=NormalizeDouble(tip,_Digits);
   sl =NormalizeDouble(sl ,_Digits);
   tp =NormalizeDouble(tp ,_Digits);

   double lot1=CalcLot(leg1Risk,slDist);
   bool placed=false;
   if(lot1>0)
   {
      if(dir>0) placed = trade.BuyLimit (lot1,tip,_Symbol,sl,tp,ORDER_TIME_GTC,0,"v3-leg1");
      else      placed = trade.SellLimit(lot1,tip,_Symbol,sl,tp,ORDER_TIME_GTC,0,"v3-leg1");
   }

   if(InpUseSplitEntry)
   {
      double entry2=NormalizeDouble(mid,_Digits);
      double slDist2=MathAbs(entry2-sl);
      double tp2 = (dir>0) ? entry2+slDist2*InpTargetRR : entry2-slDist2*InpTargetRR;
      tp2=NormalizeDouble(tp2,_Digits);
      double lot2=CalcLot(riskMoney*0.5,slDist2);
      if(lot2>0)
      {
         if(dir>0) trade.BuyLimit (lot2,entry2,_Symbol,sl,tp2,ORDER_TIME_GTC,0,"v3-leg2");
         else      trade.SellLimit(lot2,entry2,_Symbol,sl,tp2,ORDER_TIME_GTC,0,"v3-leg2");
         placed=true;
      }
   }

   if(placed)
   {
      g_pendingPlacedBar=iTime(_Symbol,InpExecTF,0);
      g_pendingDir=dir;
   }
}

//+------------------------------------------------------------------+
//| Cancel pending if window elapsed or bias flipped                 |
//+------------------------------------------------------------------+
void ManagePending()
{
   if(g_pendingDir==0) return;
   bool anyPending=false;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i);
      if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
      anyPending=true;
   }
   if(!anyPending){ g_pendingDir=0; return; }

   // bars elapsed since placement
   int bars=0;
   datetime now=iTime(_Symbol,InpExecTF,0);
   for(int i=0;i<InpFillWindowBars+5;i++)
   {
      if(iTime(_Symbol,InpExecTF,i)<=g_pendingPlacedBar) break;
      bars++;
   }
   bool flip=(H1Trend()!=g_pendingDir);

   if(bars>=InpFillWindowBars || flip)
   {
      for(int i=OrdersTotal()-1;i>=0;i--)
      {
         ulong t=OrderGetTicket(i);
         if(t==0) continue;
         if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC)!=InpMagic) continue;
         trade.OrderDelete(t);
      }
      g_pendingDir=0;
   }
}

//+------------------------------------------------------------------+
//| Partial TP at InpPartialRR and move SL to break-even             |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(!HasOpenPosition()){ g_partialDone=false; g_posRiskDist=0; return; }
   if(!InpUsePartialTP) return;
   if(g_partialDone) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      long   type =PositionGetInteger(POSITION_TYPE);
      double open =PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   =PositionGetDouble(POSITION_SL);
      double vol  =PositionGetDouble(POSITION_VOLUME);
      double risk =MathAbs(open-sl);
      if(risk<=0) continue;

      double price=(type==POSITION_TYPE_BUY)
                   ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                   : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double rNow=(type==POSITION_TYPE_BUY)?(price-open)/risk:(open-price)/risk;

      if(rNow>=InpPartialRR)
      {
         double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         double closeVol=MathFloor((vol*InpPartialPct/100.0)/step)*step;
         double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         if(closeVol>=vmin && closeVol<vol)
            trade.PositionClosePartial(t,closeVol);
         // move remaining SL to break-even
         double be=NormalizeDouble(open,_Digits);
         double tp=PositionGetDouble(POSITION_TP);
         trade.PositionModify(t,be,tp);
         g_partialDone=true;
      }
   }
}

//+------------------------------------------------------------------+
//| Tally long/short outcomes for JSON                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult &res)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagic) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=_Symbol) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;

   double profit=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)
                +HistoryDealGetDouble(trans.deal,DEAL_SWAP)
                +HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
   long dtype=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   // closing deal type is opposite of position direction
   if(dtype==DEAL_TYPE_SELL) { g_longTrades++;  if(profit>0) g_longWins++; }
   else if(dtype==DEAL_TYPE_BUY){ g_shortTrades++; if(profit>0) g_shortWins++; }
}

//+------------------------------------------------------------------+
//| Write result JSON (FILE_COMMON, same as v2 pipeline)             |
//+------------------------------------------------------------------+
double OnTester()
{
   double trades =TesterStatistics(STAT_TRADES);
   double wins   =TesterStatistics(STAT_PROFIT_TRADES);
   double losses =TesterStatistics(STAT_LOSS_TRADES);
   double pf     =TesterStatistics(STAT_PROFIT_FACTOR);
   double net    =TesterStatistics(STAT_PROFIT);
   double ddpct  =TesterStatistics(STAT_BALANCE_DDREL_PERCENT);
   double grossP =TesterStatistics(STAT_GROSS_PROFIT);
   double grossL =TesterStatistics(STAT_GROSS_LOSS);

   double winRate=(trades>0)?(wins/trades*100.0):0.0;
   double avgWin =(wins>0)?(grossP/wins):0.0;
   double avgLoss=(losses>0)?(MathAbs(grossL)/losses):0.0;
   double avgRR  =(avgLoss>0)?(avgWin/avgLoss):0.0;
   double lWR=(g_longTrades>0)?(100.0*g_longWins/g_longTrades):0.0;
   double sWR=(g_shortTrades>0)?(100.0*g_shortWins/g_shortTrades):0.0;

   string js="{";
   js+="\"version\":\"3.6-split\",";
   js+="\"symbol\":\""+_Symbol+"\",";
   js+="\"trades\":"+IntegerToString((int)trades)+",";
   js+="\"wins\":"+IntegerToString((int)wins)+",";
   js+="\"losses\":"+IntegerToString((int)losses)+",";
   js+="\"win_rate\":"+DoubleToString(winRate,2)+",";
   js+="\"profit_factor\":"+DoubleToString(pf,3)+",";
   js+="\"avg_rr\":"+DoubleToString(avgRR,3)+",";
   js+="\"net_profit\":"+DoubleToString(net,2)+",";
   js+="\"max_dd_pct\":"+DoubleToString(ddpct,2)+",";
   js+="\"long_trades\":"+IntegerToString(g_longTrades)+",";
   js+="\"long_win_rate\":"+DoubleToString(lWR,2)+",";
   js+="\"short_trades\":"+IntegerToString(g_shortTrades)+",";
   js+="\"short_win_rate\":"+DoubleToString(sWR,2);
   js+="}";

   int h=FileOpen("fvg_result.json",FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h!=INVALID_HANDLE)
   {
      FileWriteString(h,js);
      FileClose(h);
   }
   else Print("OnTester: FileOpen failed ",GetLastError());

   return(net);
}
//+------------------------------------------------------------------+

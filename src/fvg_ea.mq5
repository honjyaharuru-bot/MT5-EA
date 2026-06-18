//+------------------------------------------------------------------+
//| range_breakout_retrace_v1.mq5                                     |
//| M10 range breakout, 80pct retrace entry, M30 HH/HL trend gate     |
//| Exit: 50pct profit target + 50pct giveback trailing               |
//| All comments ASCII only. OnTester writes small JSON per symbol.   |
//+------------------------------------------------------------------+
#property copyright "EA dev"
#property version   "1.00"

#include <Trade/Trade.mqh>

#define EA_VERSION "range_breakout_retrace_v1"

//--- risk / sizing
input double InpRiskPct          = 1.0;    // Risk per trade (% of balance)
input ulong  InpMagic            = 100210; // Magic number
input long   InpSlippage         = 20;     // Deviation (points)

//--- range / breakout (M10)
input int    InpRangeLookback    = 24;     // M10 bars defining the range (pre-breakout)
input double InpRetraceEntryPct  = 80.0;   // Retrace % of breakout leg to enter
input int    InpSetupMaxBars     = 12;     // Cancel setup if no entry within N M10 bars
input bool   InpUseFlatness      = false;  // Require tight range (filter, off for raw signal)
input double InpMaxRangeATR      = 2.5;    // If flatness on: range width <= mult * ATR(M10)

//--- trend gate (M30 HH/HL)
input bool   InpUseM30Trend      = true;   // Require M30 HH+HL (long) / LH+LL (short)
input int    InpM30Lookback      = 24;     // M30 bars for trend window (split in two halves)

//--- exits
input double InpExitProfitPct    = 50.0;   // TP = % of (peak - entry) distance
input double InpExitGivebackPct  = 50.0;   // Trail: give back % of (maxfav - entry)
input bool   InpUseGiveback      = true;   // Enable giveback trailing stop
input int    InpStopMode         = 0;      // 0=structural(range bound) 1=ATR
input double InpStopATR          = 1.5;    // SL = mult * ATR(M10) if StopMode=1

//--- pullback re-entry (off for raw v1 signal test)
input bool   InpEnablePullback   = false;  // Enable pullback re-entries (v2)
input int    InpMaxPositions     = 1;      // Max stacked positions
input double InpPullbackMinPct   = 30.0;   // Min pullback % of last leg for re-entry

//--- globals
CTrade   trade;
int      atrM10Handle = INVALID_HANDLE;
datetime lastM10Time  = 0;

enum EPhase { PH_SEARCH=0, PH_BRK_UP=1, PH_BRK_DN=2 };
EPhase   phase = PH_SEARCH;
double   gRH=0, gRL=0;        // range high/low (pre-breakout)
double   gPeak=0, gTrough=0;  // post-breakout extreme
int      gSetupBars=0;        // bars elapsed since breakout

// per-position tracking for giveback trail
ulong    posTickets[];
double   posEntry[];
double   posMaxFav[];

//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints((ulong)InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   atrM10Handle = iATR(_Symbol, PERIOD_M10, 14);
   if(atrM10Handle==INVALID_HANDLE)
      return INIT_FAILED;
   return INIT_SUCCEEDED;
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(atrM10Handle!=INVALID_HANDLE)
      IndicatorRelease(atrM10Handle);
  }
//+------------------------------------------------------------------+
double ATRM10()
  {
   double a[];
   if(CopyBuffer(atrM10Handle,0,1,1,a)<1)
      return 0.0;
   return a[0];
  }
//+------------------------------------------------------------------+
void ComputeRange(int startShift)
  {
   double hh=-DBL_MAX, ll=DBL_MAX;
   for(int i=startShift; i<startShift+InpRangeLookback; i++)
     {
      double h=iHigh(_Symbol,PERIOD_M10,i);
      double l=iLow(_Symbol,PERIOD_M10,i);
      if(h>hh) hh=h;
      if(l<ll) ll=l;
     }
   gRH=hh; gRL=ll;
  }
//+------------------------------------------------------------------+
// returns +1 up (HH&HL), -1 down (LH&LL), 0 none
int M30Trend()
  {
   int L=InpM30Lookback;
   int half=L/2;
   if(half<1) half=1;
   double rHigh=-DBL_MAX,oHigh=-DBL_MAX,rLow=DBL_MAX,oLow=DBL_MAX;
   for(int i=1; i<=half; i++)
     {
      double h=iHigh(_Symbol,PERIOD_M30,i);
      double l=iLow(_Symbol,PERIOD_M30,i);
      if(h>rHigh) rHigh=h;
      if(l<rLow)  rLow=l;
     }
   for(int i=half+1; i<=L; i++)
     {
      double h=iHigh(_Symbol,PERIOD_M30,i);
      double l=iLow(_Symbol,PERIOD_M30,i);
      if(h>oHigh) oHigh=h;
      if(l<oLow)  oLow=l;
     }
   if(rHigh>oHigh && rLow>oLow) return 1;
   if(rHigh<oHigh && rLow<oLow) return -1;
   return 0;
  }
//+------------------------------------------------------------------+
int CountMyPositions()
  {
   int n=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk=PositionGetTicket(i);
      if(PositionSelectByTicket(tk))
        {
         if(PositionGetInteger(POSITION_MAGIC)==(long)InpMagic &&
            PositionGetString(POSITION_SYMBOL)==_Symbol)
            n++;
        }
     }
   return n;
  }
//+------------------------------------------------------------------+
double LotsForRisk(double slDist)
  {
   if(slDist<=0) return 0.0;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double risk=bal*InpRiskPct/100.0;
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0 || ts<=0) return 0.0;
   double lossPerLot=(slDist/ts)*tv;
   if(lossPerLot<=0) return 0.0;
   double lots=risk/lossPerLot;
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0) step=0.01;
   lots=MathFloor(lots/step)*step;
   if(lots<mn) lots=mn;
   if(lots>mx) lots=mx;
   return lots;
  }
//+------------------------------------------------------------------+
void OpenLong()
  {
   if(CountMyPositions()>= (InpEnablePullback?InpMaxPositions:1)) return;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double sl;
   if(InpStopMode==1) sl=ask-InpStopATR*ATRM10();
   else               sl=gRL;
   if(sl>=ask) return;
   double slDist=ask-sl;
   double tp=ask+(InpExitProfitPct/100.0)*(gPeak-ask);
   if(tp<=ask) tp=0.0;
   double lots=LotsForRisk(slDist);
   if(lots<=0) return;
   trade.Buy(lots,_Symbol,ask,NormalizeDouble(sl,_Digits),
             (tp>0?NormalizeDouble(tp,_Digits):0.0),EA_VERSION);
  }
//+------------------------------------------------------------------+
void OpenShort()
  {
   if(CountMyPositions()>= (InpEnablePullback?InpMaxPositions:1)) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double sl;
   if(InpStopMode==1) sl=bid+InpStopATR*ATRM10();
   else               sl=gRH;
   if(sl<=bid) return;
   double slDist=sl-bid;
   double tp=bid-(InpExitProfitPct/100.0)*(bid-gTrough);
   if(tp>=bid) tp=0.0;
   double lots=LotsForRisk(slDist);
   if(lots<=0) return;
   trade.Sell(lots,_Symbol,bid,NormalizeDouble(sl,_Digits),
              (tp>0?NormalizeDouble(tp,_Digits):0.0),EA_VERSION);
  }
//+------------------------------------------------------------------+
int FindSlot(ulong tk)
  {
   for(int i=0;i<ArraySize(posTickets);i++)
      if(posTickets[i]==tk) return i;
   return -1;
  }
int AddSlot(ulong tk,double entry)
  {
   int n=ArraySize(posTickets);
   ArrayResize(posTickets,n+1);
   ArrayResize(posEntry,n+1);
   ArrayResize(posMaxFav,n+1);
   posTickets[n]=tk; posEntry[n]=entry; posMaxFav[n]=entry;
   return n;
  }
void RemoveSlot(int idx)
  {
   int n=ArraySize(posTickets);
   for(int i=idx;i<n-1;i++)
     {
      posTickets[i]=posTickets[i+1];
      posEntry[i]=posEntry[i+1];
      posMaxFav[i]=posMaxFav[i+1];
     }
   ArrayResize(posTickets,n-1);
   ArrayResize(posEntry,n-1);
   ArrayResize(posMaxFav,n-1);
  }
//+------------------------------------------------------------------+
void ManagePositions()
  {
   // mark closed slots
   for(int i=ArraySize(posTickets)-1;i>=0;i--)
     {
      if(!PositionSelectByTicket(posTickets[i]))
         RemoveSlot(i);
     }
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long   type=PositionGetInteger(POSITION_TYPE);
      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      int s=FindSlot(tk);
      if(s<0) s=AddSlot(tk,entry);
      if(!InpUseGiveback) continue;
      if(type==POSITION_TYPE_BUY)
        {
         if(bid>posMaxFav[s]) posMaxFav[s]=bid;
         double newSL=posMaxFav[s]-(InpExitGivebackPct/100.0)*(posMaxFav[s]-entry);
         if(newSL>sl && newSL<bid)
            trade.PositionModify(tk,NormalizeDouble(newSL,_Digits),tp);
        }
      else
        {
         if(bid<posMaxFav[s] || posMaxFav[s]==entry) { if(bid<posMaxFav[s]) posMaxFav[s]=bid; }
         double newSL=posMaxFav[s]+(InpExitGivebackPct/100.0)*(entry-posMaxFav[s]);
         if((sl==0 || newSL<sl) && newSL>ask)
            trade.PositionModify(tk,NormalizeDouble(newSL,_Digits),tp);
        }
     }
  }
//+------------------------------------------------------------------+
void OnNewM10Bar()
  {
   if(phase==PH_SEARCH)
     {
      if(CountMyPositions()>0) return;
      ComputeRange(2);                       // range = bars 2..L+1 (exclude breakout bar 1)
      if(InpUseFlatness)
        {
         double atr=ATRM10();
         if(atr>0 && (gRH-gRL) > InpMaxRangeATR*atr) return; // not a tight range
        }
      double c1=iClose(_Symbol,PERIOD_M10,1);
      if(c1>gRH)
        {
         phase=PH_BRK_UP; gPeak=iHigh(_Symbol,PERIOD_M10,1); gSetupBars=0;
        }
      else if(c1<gRL)
        {
         phase=PH_BRK_DN; gTrough=iLow(_Symbol,PERIOD_M10,1); gSetupBars=0;
        }
     }
   else
     {
      gSetupBars++;
      if(gSetupBars>InpSetupMaxBars) phase=PH_SEARCH; // stale setup, reset
     }
  }
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime t=iTime(_Symbol,PERIOD_M10,0);
   if(t!=lastM10Time)
     {
      lastM10Time=t;
      OnNewM10Bar();
     }

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   if(phase==PH_BRK_UP)
     {
      if(ask>gPeak) gPeak=ask;
      double leg=gPeak-gRH;
      if(leg>0)
        {
         double trig=gPeak-(InpRetraceEntryPct/100.0)*leg; // 80% retrace down from peak
         if(bid<=gRH) { phase=PH_SEARCH; }                 // failed breakout (>100% retrace)
         else if(bid<=trig)
           {
            int tr = InpUseM30Trend ? M30Trend() : 1;
            if(tr==1)
              {
               OpenLong();
               phase=PH_SEARCH;                            // stop new breakout search while in trade
              }
           }
        }
     }
   else if(phase==PH_BRK_DN)
     {
      if(bid<gTrough) gTrough=bid;
      double leg=gRL-gTrough;
      if(leg>0)
        {
         double trig=gTrough+(InpRetraceEntryPct/100.0)*leg; // 80% retrace up from trough
         if(ask>=gRL) { phase=PH_SEARCH; }
         else if(ask>=trig)
           {
            int tr = InpUseM30Trend ? M30Trend() : -1;
            if(tr==-1)
              {
               OpenShort();
               phase=PH_SEARCH;
              }
           }
        }
     }

   ManagePositions();
  }
//+------------------------------------------------------------------+
double OnTester()
  {
   double profit  = TesterStatistics(STAT_PROFIT);
   double pf      = TesterStatistics(STAT_PROFIT_FACTOR);
   double trades  = TesterStatistics(STAT_TRADES);
   double maxdd   = TesterStatistics(STAT_EQUITYDD_PERCENT);
   double grossP  = TesterStatistics(STAT_GROSS_PROFIT);
   double grossL  = TesterStatistics(STAT_GROSS_LOSS);
   double wins    = TesterStatistics(STAT_PROFIT_TRADES);
   double ev      = (trades>0) ? profit/trades : 0.0;
   double winrate = (trades>0) ? wins/trades*100.0 : 0.0;

   string js=StringFormat(
      "{\"version\":\"%s\",\"symbol\":\"%s\",\"trades\":%d,\"net_profit\":%.2f,\"profit_factor\":%.3f,\"ev_per_trade\":%.4f,\"max_dd_pct\":%.2f,\"gross_profit\":%.2f,\"gross_loss\":%.2f,\"win_rate\":%.2f}",
      EA_VERSION,_Symbol,(int)trades,profit,pf,ev,maxdd,grossP,grossL,winrate);

   string fname="result_"+_Symbol+".json";
   int h=FileOpen(fname,FILE_WRITE|FILE_BIN|FILE_COMMON);
   if(h!=INVALID_HANDLE)
     {
      FileWriteString(h,js);
      FileClose(h);
     }
   return pf;
  }
//+------------------------------------------------------------------+

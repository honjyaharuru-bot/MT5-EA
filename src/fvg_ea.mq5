//+------------------------------------------------------------------+
//|  FVG_DATA_EXPORT.mq5                                             |
//|  Dumps M15 OHLC of the tested symbol/period to CSV (FILE_COMMON) |
//|  for offline FVG-reaction analysis. ASCII-only.                  |
//|  Deploy as src/fvg_ea.mq5; runs in the tester per symbol and     |
//|  writes Common\Files\m15_<SYMBOL>.csv .                          |
//+------------------------------------------------------------------+
#property copyright "FVG_EA"
#property version   "1.00"
#property strict

int OnInit(){ return(INIT_SUCCEEDED); }
void OnTick(){ }

double OnTester()
{
   MqlRates r[];
   ArraySetAsSeries(r,false);
   int got = CopyRates(_Symbol, PERIOD_M15, 0, 500000, r);
   if(got<=0)
   {
      Print("CopyRates failed err=", GetLastError());
      return(0.0);
   }

   string fn = "m15_"+_Symbol+".csv";
   int h = FileOpen(fn, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(h==INVALID_HANDLE)
   {
      Print("FileOpen CSV failed err=", GetLastError());
      return(0.0);
   }
   FileWrite(h, "time","open","high","low","close","tickvol");
   for(int i=0;i<got;i++)
   {
      FileWrite(h,
         TimeToString(r[i].time, TIME_DATE|TIME_MINUTES),
         DoubleToString(r[i].open,  _Digits),
         DoubleToString(r[i].high,  _Digits),
         DoubleToString(r[i].low,   _Digits),
         DoubleToString(r[i].close, _Digits),
         (long)r[i].tick_volume);
   }
   FileClose(h);
   Print("Exported ", got, " M15 bars to ", fn);

   // minimal result json so the existing collect/commit/sync steps complete
   int j = FileOpen("fvg_result.json", FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(j!=INVALID_HANDLE)
   {
      FileWriteString(j, "{\"version\":\"export\",\"symbol\":\""+_Symbol+"\",\"m15_bars\":"+IntegerToString(got)+"}");
      FileClose(j);
   }
   return(0.0);
}

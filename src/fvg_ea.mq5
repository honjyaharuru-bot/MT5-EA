//+------------------------------------------------------------------+
//|  FVG_ANALYZER.mq5                                                |
//|  Server-side FVG-reaction study. Scans all M15 bars, detects     |
//|  every 3-bar FVG (mirrors FVG_EA FindM15FVG), checks H1 trend    |
//|  alignment (mirrors H1Trend), simulates the 8-bar limit fill,    |
//|  and measures forward MFE/MAE in R until SL. Emits compact JSON. |
//|  ASCII-only. Deploy as src/fvg_ea.mq5.                           |
//+------------------------------------------------------------------+
#property copyright "FVG_EA"
#property version   "1.00"
#property strict

// mirror FVG_EA defaults
#define SL_BUFFER_PIPS 5.0
#define FILL_WINDOW    8
#define SWING_LR       3
#define SWING_SCAN     60
#define HORIZON        2000   // safety cap on forward scan (bars)

double g_pip=0.0;

//--- swing helpers on chronological H1 array (mirror IsSwingHigh/Low) ---
bool IsSwingHighArr(const MqlRates &a[], int p, int lr, int hc)
{
   double h=a[p].high;
   for(int k=1;k<=lr;k++)
   {
      if(p-k<0 || p+k>hc) return false;
      if(a[p-k].high >= h) return false;   // older side
      if(a[p+k].high >  h) return false;   // newer side
   }
   return true;
}
bool IsSwingLowArr(const MqlRates &a[], int p, int lr, int hc)
{
   double l=a[p].low;
   for(int k=1;k<=lr;k++)
   {
      if(p-k<0 || p+k>hc) return false;
      if(a[p-k].low <= l) return false;
      if(a[p+k].low <  l) return false;
   }
   return true;
}
// 1 up, -1 down, 0 none (mirror H1Trend via last two swings)
int H1TrendAt(const MqlRates &a[], int hc, int lr, int scan)
{
   if(hc<lr+1) return 0;
   double sh1=0,sh2=0,sl1=0,sl2=0; int gh=0,gl=0;
   for(int off=lr+1; off<=scan; off++)
   {
      int p=hc-off;
      if(p-lr<0) break;
      if(gh<2 && IsSwingHighArr(a,p,lr,hc)){ if(gh==0) sh1=a[p].high; else sh2=a[p].high; gh++; }
      if(gl<2 && IsSwingLowArr(a,p,lr,hc)) { if(gl==0) sl1=a[p].low;  else sl2=a[p].low;  gl++; }
      if(gh>=2 && gl>=2) break;
   }
   if(gh>=2 && gl>=2)
   {
      if(sh1>sh2 && sl1>sl2) return 1;
      if(sh1<sh2 && sl1<sl2) return -1;
   }
   return 0;
}

//--- per-population accumulators ---
int    pN[2];                 // 0=aligned, 1=counter (filled)
double pSumMfe[2], pSumMae[2];
int    pReach[2][6];          // >=0.5,1.0,1.5,2.0,2.5,3.0 R
int    pHist[2][17];          // 0..4.0R in 0.25 bins (16) + overflow(16)

void Record(int pop,double mfeR,double maeR)
{
   pN[pop]++;
   pSumMfe[pop]+=mfeR; pSumMae[pop]+=maeR;
   double th[6]={0.5,1.0,1.5,2.0,2.5,3.0};
   for(int k=0;k<6;k++) if(mfeR>=th[k]) pReach[pop][k]++;
   int b=(int)MathFloor(mfeR/0.25);
   if(b<0) b=0; if(b>16) b=16;
   pHist[pop][b]++;
}

string IntArr(const int &a[],int n)
{
   string s="[";
   for(int i=0;i<n;i++){ s+=IntegerToString(a[i]); if(i<n-1) s+=","; }
   return s+"]";
}

int OnInit(){ return(INIT_SUCCEEDED); }
void OnTick(){ }

double OnTester()
{
   int d=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_pip=((d==3||d==5)?10.0:1.0)*_Point;

   MqlRates m15[]; ArraySetAsSeries(m15,false);
   MqlRates h1[];  ArraySetAsSeries(h1,false);
   int n15=CopyRates(_Symbol,PERIOD_M15,0,500000,m15);
   int nh1=CopyRates(_Symbol,PERIOD_H1, 0,200000,h1);
   if(n15<=10 || nh1<=10){ Print("CopyRates failed ",n15," ",nh1); return(0.0); }

   for(int p=0;p<2;p++){ pN[p]=0; pSumMfe[p]=0; pSumMae[p]=0;
      for(int k=0;k<6;k++) pReach[p][k]=0; for(int b=0;b<17;b++) pHist[p][b]=0; }

   int fvgTotal=0,bull=0,bear=0,alignedTot=0,counterTot=0;
   int filledAligned=0,filledCounter=0;
   int hc=0;

   for(int i=0;i+2<n15;i++)
   {
      double aHigh=m15[i].high,   aLow=m15[i].low;
      double bHigh=m15[i+1].high, bLow=m15[i+1].low;
      double cHigh=m15[i+2].high, cLow=m15[i+2].low;
      int dir=0; double tip=0,slRef=0;
      if(cLow>aHigh){ dir=1;  tip=cLow;  slRef=bLow;  }
      else if(aLow>cHigh){ dir=-1; tip=cHigh; slRef=bHigh; }
      else continue;

      fvgTotal++; if(dir>0) bull++; else bear++;

      // advance H1 pointer to latest bar with time <= C.time
      datetime ct=m15[i+2].time;
      while(hc+1<nh1 && h1[hc+1].time<=ct) hc++;
      int tr=H1TrendAt(h1,hc,SWING_LR,SWING_SCAN);
      bool aligned=(tr!=0 && tr==dir);
      bool counter=(tr!=0 && tr==-dir);
      if(aligned) alignedTot++;
      if(counter) counterTot++;

      double buf=SL_BUFFER_PIPS*g_pip;
      double sl=(dir>0)? slRef-buf : slRef+buf;
      double risk=MathAbs(tip-sl);
      if(risk<=0) continue;

      // simulate 8-bar limit fill
      int fillBar=-1;
      for(int j=i+3;j<=i+2+FILL_WINDOW && j<n15;j++)
      {
         if(dir>0){ if(m15[j].low<=tip){ fillBar=j; break; } }
         else     { if(m15[j].high>=tip){ fillBar=j; break; } }
      }
      if(fillBar<0) continue;
      if(aligned) filledAligned++;
      if(counter) filledCounter++;
      if(!aligned && !counter) continue;   // only score trend-classified pops

      // forward MFE/MAE in R until SL or horizon
      double maxFav=0,maxAdv=0;
      for(int j=fillBar;j<n15 && j<fillBar+HORIZON;j++)
      {
         double fav,adv;
         if(dir>0){ fav=m15[j].high-tip; adv=tip-m15[j].low; }
         else     { fav=tip-m15[j].low;  adv=m15[j].high-tip; }
         if(fav>maxFav) maxFav=fav;
         if(adv>maxAdv) maxAdv=adv;
         if(adv>=risk) break;             // SL would be hit
      }
      Record(aligned?0:1, maxFav/risk, maxAdv/risk);
   }

   double aMfe=(pN[0]>0)?pSumMfe[0]/pN[0]:0.0;
   double aMae=(pN[0]>0)?pSumMae[0]/pN[0]:0.0;
   double cMfe=(pN[1]>0)?pSumMfe[1]/pN[1]:0.0;
   double cMae=(pN[1]>0)?pSumMae[1]/pN[1]:0.0;
   double fillRateA=(alignedTot>0)?100.0*filledAligned/alignedTot:0.0;
   double fillRateC=(counterTot>0)?100.0*filledCounter/counterTot:0.0;

   int rA[6],rC[6]; for(int k=0;k<6;k++){ rA[k]=pReach[0][k]; rC[k]=pReach[1][k]; }
   int hA[17],hC[17]; for(int b=0;b<17;b++){ hA[b]=pHist[0][b]; hC[b]=pHist[1][b]; }

   string js="{";
   js+="\"version\":\"analyzer-1.0\",";
   js+="\"symbol\":\""+_Symbol+"\",";
   js+="\"m15_bars\":"+IntegerToString(n15)+",";
   js+="\"fvg_total\":"+IntegerToString(fvgTotal)+",";
   js+="\"fvg_bull\":"+IntegerToString(bull)+",";
   js+="\"fvg_bear\":"+IntegerToString(bear)+",";
   js+="\"aligned_total\":"+IntegerToString(alignedTot)+",";
   js+="\"counter_total\":"+IntegerToString(counterTot)+",";
   js+="\"filled_aligned\":"+IntegerToString(filledAligned)+",";
   js+="\"filled_counter\":"+IntegerToString(filledCounter)+",";
   js+="\"fill_rate_aligned\":"+DoubleToString(fillRateA,2)+",";
   js+="\"fill_rate_counter\":"+DoubleToString(fillRateC,2)+",";
   js+="\"aligned\":{";
   js+="\"n\":"+IntegerToString(pN[0])+",";
   js+="\"avg_mfe_r\":"+DoubleToString(aMfe,3)+",";
   js+="\"avg_mae_r\":"+DoubleToString(aMae,3)+",";
   js+="\"reach_pct\":[";
   for(int k=0;k<6;k++){ double v=(pN[0]>0)?100.0*rA[k]/pN[0]:0.0; js+=DoubleToString(v,1); if(k<5)js+=","; }
   js+="],\"reach_labels\":[0.5,1.0,1.5,2.0,2.5,3.0],";
   js+="\"hist_025\":"+IntArr(hA,17)+"},";
   js+="\"counter\":{";
   js+="\"n\":"+IntegerToString(pN[1])+",";
   js+="\"avg_mfe_r\":"+DoubleToString(cMfe,3)+",";
   js+="\"avg_mae_r\":"+DoubleToString(cMae,3)+",";
   js+="\"reach_pct\":[";
   for(int k=0;k<6;k++){ double v=(pN[1]>0)?100.0*rC[k]/pN[1]:0.0; js+=DoubleToString(v,1); if(k<5)js+=","; }
   js+="],\"hist_025\":"+IntArr(hC,17)+"}";
   js+="}";

   string fn="fvg_analysis_"+_Symbol+".json";
   int h=FileOpen(fn,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h!=INVALID_HANDLE){ FileWriteString(h,js); FileClose(h); }
   // also write the standard result file so collect/commit/sync completes
   int h2=FileOpen("fvg_result.json",FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h2!=INVALID_HANDLE){ FileWriteString(h2,js); FileClose(h2); }
   Print("FVG analysis done: ",_Symbol," fvg=",fvgTotal," filledAligned=",filledAligned);
   return(0.0);
}

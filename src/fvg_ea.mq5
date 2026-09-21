//+------------------------------------------------------------------+
//| AMB_P0_v0_6c_r1.mq5                                              |
//| AMB Phase 0 : 6-state classifier + excursion measurement         |
//| NO TRADING. Output: result_<SYMBOL>.json (Common\Files)          |
//|                     AMB_P0_events_<SYMBOL>_<LABEL>.csv           |
//| Base design : internal design v0.6-b                             |
//| Change v0.6c: REVERSAL predecessor fix (see InpRevPredMode)      |
//|   v0.6b pred_rev requires st_prev in {TREND,EXH}. Those states   |
//|   need slope*trend_dir >= K_SLOPE while REVERSAL needs           |
//|   slope*trend_dir <= 0 on the next bar -> practically unreachable|
//|   v0.6c pred_rev = trend_dir alive (dir_age <= D_MAX), self      |
//|   continuation still capped by R_MAX. No threshold is changed.   |
//|   Both machines run every bar; only the main one is measured.    |
//+------------------------------------------------------------------+
#property copyright "Maehara"
#property version   "0.61"
#property description "AMB Phase0 v0.6c state measurement EA (no trading)"

#define AMB_VERSION "AMB_P0_v0.6c_r1"
#define LOG_SCHEMA  "p0.1"

#define ST_RANGE 0
#define ST_COMP  1
#define ST_BRK   2
#define ST_TREND 3
#define ST_EXH   4
#define ST_REV   5
#define NST      6
#define NH       4

//--- fixed Phase 0 parameters (design v0.6-b section 7). DO NOT OPTIMIZE.
#define K_BRK     1.0
#define K_SLOPE   1.0
#define K_WIDE    3.0
#define K_NARROW  2.5
#define K_MRATIO  0.5
#define K_DEV     0.5
#define EPS_GUARD 0.05
#define R_MAX     5
#define D_MAX     50
#define WARMUP    200
#define BOOT_SEED 20260921
#define NA_VAL    (-1.0e300)

input int    InpRevPredMode = 1;      // main machine: 0=v0.6b pred, 1=v0.6c pred
input string InpPeriodLabel = "IS";   // IS or OOS (OOS must be run once only)
input bool   InpAllowOOS    = false;  // must be true to evaluate bars >= 2025.01.01
input bool   InpWriteCSV    = true;   // write event CSV to Common\Files
input int    InpServerToJST = 7;      // hours added to server time -> JST (verify GMT/DST)
input int    InpBootB       = 2000;   // bootstrap repetitions

string ST_NAME[NST] = {"RANGE","COMPRESSION","BREAKOUT","TREND","EXHAUSTION","REVERSAL"};
string CO_NAME[3]   = {"NEUTRAL","DIRECTIONAL","FADING"};
int    MIN_DUR[NST] = {4,4,1,4,2,2};
int    HZ[NH]       = {4,8,16,32};

int Coarse(int s) { if(s<=ST_COMP) return 0; if(s<=ST_TREND) return 1; return 2; }
int Sgn(double v) { return (v>0.0) ? 1 : ((v<0.0) ? -1 : 0); }

//+------------------------------------------------------------------+
//| primitives (all shift >= base, base >= 1)                        |
//+------------------------------------------------------------------+
struct Prim
  {
   datetime t;
   double   c, cprev, h, l, atr, dh, dl, width, slope, dev, mratio;
   bool     guard, engulf;
   int      spread;
  };

int g_hATR = INVALID_HANDLE;
int g_hEMA = INVALID_HANDLE;

bool GetPrim(int base, Prim &p)
  {
   double ab[]; ArraySetAsSeries(ab,true);
   if(CopyBuffer(g_hATR,0,base,1,ab)!=1) return false;
   double eb[]; ArraySetAsSeries(eb,true);
   if(CopyBuffer(g_hEMA,0,base,11,eb)!=11) return false;
   double cb[]; ArraySetAsSeries(cb,true);
   if(CopyClose(_Symbol,PERIOD_M15,base,21,cb)!=21) return false;
   double hb[]; if(CopyHigh(_Symbol,PERIOD_M15,base+1,20,hb)!=20) return false;
   double lb[]; if(CopyLow (_Symbol,PERIOD_M15,base+1,20,lb)!=20) return false;
   p.atr = ab[0];
   if(p.atr<=0.0) return false;
   p.t      = iTime(_Symbol,PERIOD_M15,base);
   p.h      = iHigh(_Symbol,PERIOD_M15,base);
   p.l      = iLow (_Symbol,PERIOD_M15,base);
   p.spread = (int)iSpread(_Symbol,PERIOD_M15,base);
   p.c      = cb[0];
   p.cprev  = cb[1];
   p.dh     = hb[ArrayMaximum(hb)];       // shift base+1 .. base+20
   p.dl     = lb[ArrayMinimum(lb)];
   p.width  = (p.dh-p.dl)/p.atr;
   p.slope  = (eb[0]-eb[10])/p.atr;        // EMA[t]-EMA[t-10]
   p.dev    = (p.c-eb[0])/p.atr;
   double d5  = MathAbs(cb[0]-cb[5]) /p.atr;
   double d20 = MathAbs(cb[0]-cb[20])/p.atr;
   double den = d20/4.0;
   p.guard  = (den<EPS_GUARD);
   p.mratio = d5/MathMax(den,EPS_GUARD);
   p.engulf = (p.h>p.dh && p.l<p.dl);
   return true;
  }

//+------------------------------------------------------------------+
//| state machine (raw only)                                         |
//+------------------------------------------------------------------+
struct StepOut
  {
   int  st, dir, prev_state, old_since, prev_dir_ref;
   bool changed;
  };

class CSM
  {
public:
   int    mode;
   int    st_prev, raw_since, trend_dir, dir_age;
   double wh[6];
   int    whn;
   long   trans[NST][NST];
   long   evc[NST];
   long   c_rev_core, c_rev_blocked, c_slope_gap, c_exh_after_rev_blocked;
   long   c_guard, c_engulf, bars_eval;
   int    dur_st[];
   int    dur_len[];
   int    ndur;
   long   closed_blocks, chatter;
   bool   blk_eval, have_last;
   int    last_st;

   void Init(int m)
     {
      mode=m; st_prev=ST_RANGE; raw_since=1; trend_dir=0; dir_age=0; whn=0;
      for(int i=0;i<6;i++) wh[i]=0.0;
      for(int a=0;a<NST;a++) { evc[a]=0; for(int b=0;b<NST;b++) trans[a][b]=0; }
      c_rev_core=0; c_rev_blocked=0; c_slope_gap=0; c_exh_after_rev_blocked=0;
      c_guard=0; c_engulf=0; bars_eval=0;
      ndur=0; ArrayResize(dur_st,0,8192); ArrayResize(dur_len,0,8192);
      closed_blocks=0; chatter=0; blk_eval=false; have_last=false; last_st=-1;
     }

   void Step(const Prim &p, bool eval, StepOut &o)
     {
      for(int k=5;k>0;k--) wh[k]=wh[k-1];
      wh[0]=p.width;
      if(whn<6) whn++;

      int s=-1, d=0;
      //--- 1 BREAKOUT
      bool up=(p.c>p.dh), dn=(p.c<p.dl);
      if((up||dn) && MathAbs(p.c-p.cprev)/p.atr>=K_BRK) { s=ST_BRK; d=up?1:-1; }
      //--- 2 REVERSAL
      int  sdev=Sgn(p.dev);
      bool pricerev=(trend_dir!=0 && sdev==-trend_dir && MathAbs(p.dev)>=K_DEV);
      bool revc=(pricerev && p.slope*trend_dir<=0.0);
      bool pred;
      if(mode==0) pred=(st_prev==ST_TREND || st_prev==ST_EXH) || (st_prev==ST_REV && raw_since<=R_MAX);
      else        pred=(st_prev!=ST_REV) || (raw_since<=R_MAX);
      if(eval && s<0 && pricerev && p.slope*trend_dir>0.0 && (st_prev==ST_TREND || st_prev==ST_EXH)) c_slope_gap++;
      if(s<0 && revc)
        {
         if(eval) c_rev_core++;
         if(pred) { s=ST_REV; d=-trend_dir; }
         else if(eval) c_rev_blocked++;
        }
      //--- 3 EXHAUSTION
      bool exhc=(MathAbs(p.slope)>=K_SLOPE && p.mratio<K_MRATIO);
      bool pexh=(st_prev==ST_BRK || st_prev==ST_TREND || st_prev==ST_EXH);
      if(s<0 && exhc)
        {
         if(pexh) { s=ST_EXH; d=Sgn(p.slope); }
         else if(eval && st_prev==ST_REV) c_exh_after_rev_blocked++;
        }
      //--- 4 TREND
      if(s<0 && MathAbs(p.slope)>=K_SLOPE && p.width>=K_WIDE) { s=ST_TREND; d=Sgn(p.slope); }
      //--- 5 COMPRESSION (width 5 bars ago = wh[5])
      if(s<0 && whn>=6 && p.width<=K_NARROW && p.width<wh[5]) { s=ST_COMP; d=0; }
      //--- 6 RANGE
      if(s<0) { s=ST_RANGE; d=0; }

      o.st=s; o.dir=d; o.prev_state=st_prev; o.old_since=raw_since; o.prev_dir_ref=trend_dir;
      o.changed=(s!=st_prev);

      if(o.changed)
        {
         if(eval)
           {
            trans[st_prev][s]++;
            evc[s]++;
            if(blk_eval)
              {
               ArrayResize(dur_st,ndur+1,8192); ArrayResize(dur_len,ndur+1,8192);
               dur_st[ndur]=st_prev; dur_len[ndur]=raw_since; ndur++;
               closed_blocks++;
               if(have_last && last_st==s && raw_since<MIN_DUR[st_prev]) chatter++;
               have_last=true;
              }
            last_st=st_prev;
           }
         if(st_prev==ST_REV) trend_dir=0;                               // exit first
         if(s==ST_BRK || s==ST_TREND || s==ST_EXH) trend_dir=d;         // then entry
         raw_since=1;
         blk_eval=eval;
        }
      else raw_since++;

      if(s==ST_BRK || s==ST_TREND || s==ST_EXH) dir_age=0; else dir_age++;
      if(dir_age>D_MAX) trend_dir=0;
      st_prev=s;

      if(eval) { bars_eval++; if(p.guard) c_guard++; if(p.engulf) c_engulf++; }
     }
  };

//+------------------------------------------------------------------+
//| events and measurement windows                                   |
//+------------------------------------------------------------------+
struct Ev
  {
   datetime t, tconf;
   long     daykey;
   int      day, st, prev, dir, prev_dir_ref, agrees, dur, bsp, bar_idx, spread;
   double   anchor, atr, c_anchor, c_atr;
   bool     conf, engulf, guard;
   double   width, slope, mratio, dev;
   double   up[NH], dn[NH], cup[NH], cdn[NH];
   int      bup[NH], bdn[NH], cbup[NH], cbdn[NH];
   bool     comp[NH], gap[NH], ccomp[NH], cgap[NH];
  };

struct Win
  {
   int      ev, k, bup, bdn;
   bool     conf, gap;
   double   mx, mn;
   datetime last;
  };

CSM      g_sm[2];
int      g_main=1;
Ev       g_ev[];
int      g_nev=0;
Win      g_win[];
int      g_nwin=0;
int      g_cur_ev=-1;
int      g_nday=0;
long     g_last_daykey=-1;
int      g_bar_idx=0;
int      g_prev_ev_bar=-1;
datetime g_last_bar=0;
datetime g_eval_from=0;
datetime g_first_eval=0, g_last_eval=0;
bool     g_warmed=false;
int      g_warm_bars=0;
bool     g_oos_blocked=false;
long     g_prim_fail=0;
ulong    g_rng=BOOT_SEED;

void AddWin(int ev,bool conf,datetime t)
  {
   ArrayResize(g_win,g_nwin+1,256);
   g_win[g_nwin].ev=ev; g_win[g_nwin].conf=conf; g_win[g_nwin].k=0;
   g_win[g_nwin].mx=-DBL_MAX; g_win[g_nwin].mn=DBL_MAX;
   g_win[g_nwin].bup=0; g_win[g_nwin].bdn=0; g_win[g_nwin].gap=false; g_win[g_nwin].last=t;
   g_nwin++;
  }

void UpdateWindows(const Prim &p)
  {
   for(int i=g_nwin-1;i>=0;i--)
     {
      Win w=g_win[i];
      w.k++;
      if(p.t-w.last>6*3600) w.gap=true;
      w.last=p.t;
      if(p.h>w.mx) { w.mx=p.h; w.bup=w.k; }
      if(p.l<w.mn) { w.mn=p.l; w.bdn=w.k; }
      for(int j=0;j<NH;j++)
        {
         if(w.k!=HZ[j]) continue;
         int e=w.ev;
         if(!w.conf)
           {
            g_ev[e].up[j]=(w.mx-g_ev[e].anchor)/g_ev[e].atr;
            g_ev[e].dn[j]=(g_ev[e].anchor-w.mn)/g_ev[e].atr;
            g_ev[e].bup[j]=w.bup; g_ev[e].bdn[j]=w.bdn;
            g_ev[e].comp[j]=true; g_ev[e].gap[j]=w.gap;
           }
         else
           {
            g_ev[e].cup[j]=(w.mx-g_ev[e].c_anchor)/g_ev[e].c_atr;
            g_ev[e].cdn[j]=(g_ev[e].c_anchor-w.mn)/g_ev[e].c_atr;
            g_ev[e].cbup[j]=w.bup; g_ev[e].cbdn[j]=w.bdn;
            g_ev[e].ccomp[j]=true; g_ev[e].cgap[j]=w.gap;
           }
        }
      if(w.k>=HZ[NH-1]) { g_win[i]=g_win[g_nwin-1]; g_nwin--; }
      else g_win[i]=w;
     }
  }

long DayKey(datetime t)
  {
   MqlDateTime m; TimeToStruct(t,m);
   return (long)m.year*10000+m.mon*100+m.day;
  }

void ProcessBar(int base,bool allow_eval)
  {
   Prim p;
   if(!GetPrim(base,p)) { g_prim_fail++; return; }
   if(!InpAllowOOS && p.t>=D'2025.01.01 00:00') { g_oos_blocked=true; return; }
   bool eval=(allow_eval && p.t>=g_eval_from);
   if(!eval) g_warm_bars++;
   if(eval)
     {
      if(g_first_eval==0) g_first_eval=p.t;
      g_last_eval=p.t;
      g_bar_idx++;
      UpdateWindows(p);
     }
   StepOut o,o2;
   g_sm[g_main].Step(p,eval,o);
   g_sm[1-g_main].Step(p,eval,o2);
   if(!eval) return;

   if(o.changed)
     {
      if(g_cur_ev>=0) g_ev[g_cur_ev].dur=o.old_since;
      ArrayResize(g_ev,g_nev+1,8192);
      int e=g_nev;
      ZeroMemory(g_ev[e]);
      g_ev[e].t=p.t; g_ev[e].st=o.st; g_ev[e].prev=o.prev_state; g_ev[e].dir=o.dir;
      g_ev[e].prev_dir_ref=o.prev_dir_ref;
      g_ev[e].agrees=(o.dir!=0 && o.dir==o.prev_dir_ref) ? 1 : 0;
      g_ev[e].dur=-1;
      g_ev[e].anchor=p.c; g_ev[e].atr=p.atr; g_ev[e].spread=p.spread;
      g_ev[e].engulf=p.engulf; g_ev[e].guard=p.guard;
      g_ev[e].width=p.width; g_ev[e].slope=p.slope; g_ev[e].mratio=p.mratio; g_ev[e].dev=p.dev;
      g_ev[e].bar_idx=g_bar_idx;
      g_ev[e].bsp=(g_prev_ev_bar<0) ? -1 : g_bar_idx-g_prev_ev_bar;
      g_prev_ev_bar=g_bar_idx;
      long dk=DayKey(p.t);
      if(dk!=g_last_daykey) { g_last_daykey=dk; g_nday++; }
      g_ev[e].daykey=dk; g_ev[e].day=g_nday-1;
      g_nev++;
      g_cur_ev=e;
      AddWin(e,false,p.t);
     }
   if(g_cur_ev>=0 && !g_ev[g_cur_ev].conf && g_sm[g_main].raw_since==MIN_DUR[o.st])
     {
      g_ev[g_cur_ev].conf=true; g_ev[g_cur_ev].tconf=p.t;
      g_ev[g_cur_ev].c_anchor=p.c; g_ev[g_cur_ev].c_atr=p.atr;
      AddWin(g_cur_ev,true,p.t);
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRevPredMode!=0 && InpRevPredMode!=1) return INIT_PARAMETERS_INCORRECT;
   g_main=InpRevPredMode;
   g_hATR=iATR(_Symbol,PERIOD_M15,14);
   g_hEMA=iMA(_Symbol,PERIOD_M15,20,0,MODE_EMA,PRICE_CLOSE);
   if(g_hATR==INVALID_HANDLE || g_hEMA==INVALID_HANDLE) return INIT_FAILED;
   g_sm[0].Init(0);
   g_sm[1].Init(1);
   ArrayResize(g_ev,0,8192);
   ArrayResize(g_win,0,256);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_hATR!=INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hEMA!=INVALID_HANDLE) IndicatorRelease(g_hEMA);
  }

void OnTick()
  {
   datetime t0=iTime(_Symbol,PERIOD_M15,0);
   if(t0==0 || t0==g_last_bar) return;
   if(!g_warmed)
     {
      int need=WARMUP+30;
      if(Bars(_Symbol,PERIOD_M15)<need+5) return;
      if(BarsCalculated(g_hATR)<need || BarsCalculated(g_hEMA)<need) return;
      datetime now=TimeCurrent();
      g_eval_from=now-(now%86400);
      for(int b=WARMUP+1;b>=2;b--) ProcessBar(b,false);
      g_warmed=true;
     }
   g_last_bar=t0;
   ProcessBar(1,true);
  }

//+------------------------------------------------------------------+
//| statistics helpers                                               |
//+------------------------------------------------------------------+
ulong RngNext()
  {
   g_rng^=(g_rng>>12); g_rng^=(g_rng<<25); g_rng^=(g_rng>>27);
   return g_rng*2685821657736338717;
  }

double Pct(const double &a[],int n,double q)
  {
   if(n<=0) return NA_VAL;
   double pos=q*(n-1);
   int    i=(int)MathFloor(pos);
   double f=pos-i;
   if(i+1<n) return a[i]+(a[i+1]-a[i])*f;
   return a[i];
  }

double Erfc(double x)
  {
   double z=MathAbs(x);
   double t=1.0/(1.0+0.5*z);
   double r=t*MathExp(-z*z-1.26551223+t*(1.00002368+t*(0.37409196+t*(0.09678418+t*(-0.18628806+
            t*(0.27886807+t*(-1.13520398+t*(1.48851587+t*(-0.82215223+t*0.17087277)))))))));
   return (x>=0.0) ? r : 2.0-r;
  }

string Num(double v,int dig=6)
  {
   if(v==NA_VAL || !MathIsValidNumber(v)) return "null";
   return DoubleToString(v,dig);
  }

// weighted Cliff delta over values sorted ascending; sg=1 group A, 0 group B
double WDelta(const double &sv[],const int &sg[],const double &w[],int n)
  {
   double totA=0.0,totB=0.0;
   for(int k=0;k<n;k++) { if(sg[k]==1) totA+=w[k]; else totB+=w[k]; }
   if(totA<=0.0 || totB<=0.0) return NA_VAL;
   double cumB=0.0,num=0.0;
   int i=0;
   while(i<n)
     {
      int j=i; double tA=0.0,tB=0.0;
      while(j<n && sv[j]==sv[i]) { if(sg[j]==1) tA+=w[j]; else tB+=w[j]; j++; }
      num+=tA*cumB-tA*(totB-cumB-tB);
      cumB+=tB;
      i=j;
     }
   return num/(totA*totB);
  }

// value of an event for group statistics (excursion_max_atr at horizon index h)
bool EvExc(int e,bool conf,int h,double &v)
  {
   if(!conf)
     {
      if(!g_ev[e].comp[h]) return false;
      v=MathMax(g_ev[e].up[h],g_ev[e].dn[h]);
     }
   else
     {
      if(!g_ev[e].conf || !g_ev[e].ccomp[h]) return false;
      v=MathMax(g_ev[e].cup[h],g_ev[e].cdn[h]);
     }
   return true;
  }

int Collect(int grp,bool fine,bool conf,int h,double &vals[],int &days[])
  {
   int n=0;
   ArrayResize(vals,0,g_nev); ArrayResize(days,0,g_nev);
   for(int e=0;e<g_nev;e++)
     {
      int g=fine ? g_ev[e].st : Coarse(g_ev[e].st);
      if(g!=grp) continue;
      double v;
      if(!EvExc(e,conf,h,v)) continue;
      ArrayResize(vals,n+1,g_nev); ArrayResize(days,n+1,g_nev);
      vals[n]=v; days[n]=g_ev[e].day; n++;
     }
   return n;
  }

// pair statistics A vs B (coarse groups), N=16 excursion
string PairJson(int ga,int gb,bool conf,bool boot,double &delta_out,double &ci_lo_out,
                double &medA,double &medB,double &p25A,double &p25B,double &p75A,double &p75B,int &nA,int &nB)
  {
   int h=2;  // N=16
   double va[],vb[]; int da[],db[];
   nA=Collect(ga,false,conf,h,va,da);
   nB=Collect(gb,false,conf,h,vb,db);
   delta_out=NA_VAL; ci_lo_out=NA_VAL;
   medA=NA_VAL; medB=NA_VAL; p25A=NA_VAL; p25B=NA_VAL; p75A=NA_VAL; p75B=NA_VAL;
   string js="{\"a\":\""+CO_NAME[ga]+"\",\"b\":\""+CO_NAME[gb]+"\",\"n_a\":"+IntegerToString(nA)+",\"n_b\":"+IntegerToString(nB);
   if(nA<2 || nB<2) return js+",\"delta\":null}";

   double sa[],sb[];
   ArrayCopy(sa,va); ArrayCopy(sb,vb);
   ArraySort(sa); ArraySort(sb);
   p25A=Pct(sa,nA,0.25); medA=Pct(sa,nA,0.5); p75A=Pct(sa,nA,0.75);
   p25B=Pct(sb,nB,0.25); medB=Pct(sb,nB,0.5); p75B=Pct(sb,nB,0.75);

   int n=nA+nB;
   double arr[][2];
   ArrayResize(arr,n);
   int grp[],day[];
   ArrayResize(grp,n); ArrayResize(day,n);
   for(int i=0;i<nA;i++) { arr[i][0]=va[i]; arr[i][1]=i;    grp[i]=1;    day[i]=da[i]; }
   for(int i=0;i<nB;i++) { arr[nA+i][0]=vb[i]; arr[nA+i][1]=nA+i; grp[nA+i]=0; day[nA+i]=db[i]; }
   ArraySort(arr);
   double sv[],w[]; int sg[],sd[],so[];
   ArrayResize(sv,n); ArrayResize(w,n); ArrayResize(sg,n); ArrayResize(sd,n); ArrayResize(so,n);
   for(int k=0;k<n;k++)
     {
      int o=(int)arr[k][1];
      sv[k]=arr[k][0]; sg[k]=grp[o]; sd[k]=day[o]; so[k]=o; w[k]=1.0;
     }
   double delta=WDelta(sv,sg,w,n);
   delta_out=delta;

   //--- Mann-Whitney (normal approx, tie corrected), report only
   double tie=0.0;
   int i0=0;
   while(i0<n) { int j=i0; while(j<n && sv[j]==sv[i0]) j++; double t=j-i0; tie+=t*t*t-t; i0=j; }
   double nn=(double)nA*(double)nB;
   double var=nn/12.0*((n+1.0)-tie/((double)n*(n-1.0)));
   double pmw=NA_VAL;
   if(var>0.0) { double z=(nn*delta/2.0)/MathSqrt(var); pmw=Erfc(MathAbs(z)/MathSqrt(2.0)); }

   js+=",\"delta\":"+Num(delta)
      +",\"p25_a\":"+Num(p25A)+",\"p50_a\":"+Num(medA)+",\"p75_a\":"+Num(p75A)
      +",\"p25_b\":"+Num(p25B)+",\"p50_b\":"+Num(medB)+",\"p75_b\":"+Num(p75B)
      +",\"median_diff\":"+Num(medA-medB)
      +",\"mw_p_two_sided_report_only\":"+(pmw==NA_VAL?"null":DoubleToString(pmw,12));

   if(!boot) return js+"}";

   //--- day-block bootstrap
   int maxd=0; for(int k=0;k<n;k++) if(sd[k]>maxd) maxd=sd[k];
   int map[]; ArrayResize(map,maxd+1); ArrayInitialize(map,-1);
   int nd=0;
   for(int k=0;k<n;k++) if(map[sd[k]]<0) { map[sd[k]]=nd; nd++; }
   int dix[]; ArrayResize(dix,n);
   for(int k=0;k<n;k++) dix[k]=map[sd[k]];
   int B=MathMax(InpBootB,100);
   double db_[]; ArrayResize(db_,B);
   double cnt[]; ArrayResize(cnt,nd);
   int nb=0;
   g_rng=BOOT_SEED;
   for(int b=0;b<B;b++)
     {
      ArrayInitialize(cnt,0.0);
      for(int r=0;r<nd;r++) cnt[(int)(RngNext()%(ulong)nd)]+=1.0;
      for(int k=0;k<n;k++) w[k]=cnt[dix[k]];
      double d=WDelta(sv,sg,w,n);
      if(d!=NA_VAL) { db_[nb]=d; nb++; }
     }
   double lo=NA_VAL,hi=NA_VAL,seb=NA_VAL;
   if(nb>=100)
     {
      ArrayResize(db_,nb); ArraySort(db_);
      lo=Pct(db_,nb,0.005); hi=Pct(db_,nb,0.995);
      double m=0.0; for(int k=0;k<nb;k++) m+=db_[k]; m/=nb;
      double s2=0.0; for(int k=0;k<nb;k++) s2+=(db_[k]-m)*(db_[k]-m);
      seb=MathSqrt(s2/(nb-1));
     }
   ci_lo_out=lo;

   //--- iid (stratified) bootstrap for n_eff reference
   int posA[],posB[]; ArrayResize(posA,nA); ArrayResize(posB,nB);
   int ia=0,ib=0;
   for(int k=0;k<n;k++) { if(sg[k]==1) posA[ia++]=k; else posB[ib++]=k; }
   double di[]; ArrayResize(di,B);
   int ni=0;
   g_rng=BOOT_SEED+1;
   for(int b=0;b<B;b++)
     {
      ArrayInitialize(w,0.0);
      for(int r=0;r<nA;r++) w[posA[(int)(RngNext()%(ulong)nA)]]+=1.0;
      for(int r=0;r<nB;r++) w[posB[(int)(RngNext()%(ulong)nB)]]+=1.0;
      double d=WDelta(sv,sg,w,n);
      if(d!=NA_VAL) { di[ni]=d; ni++; }
     }
   double sei=NA_VAL;
   if(ni>=100)
     {
      double m=0.0; for(int k=0;k<ni;k++) m+=di[k]; m/=ni;
      double s2=0.0; for(int k=0;k<ni;k++) s2+=(di[k]-m)*(di[k]-m);
      sei=MathSqrt(s2/(ni-1));
     }
   double ratio=(seb!=NA_VAL && sei!=NA_VAL && seb>0.0) ? (sei/seb)*(sei/seb) : NA_VAL;

   js+=",\"boot_block\":\"server_day\",\"boot_days\":"+IntegerToString(nd)
      +",\"boot_B_valid\":"+IntegerToString(nb)
      +",\"boot_ci99_lo\":"+Num(lo)+",\"boot_ci99_hi\":"+Num(hi)
      +",\"boot_se_block\":"+Num(seb)+",\"boot_se_iid\":"+Num(sei)
      +",\"n_eff_a\":"+(ratio==NA_VAL?"null":DoubleToString(nA*ratio,1))
      +",\"n_eff_b\":"+(ratio==NA_VAL?"null":DoubleToString(nB*ratio,1))+"}";
   return js;
  }

string FineJson()
  {
   string js="[";
   for(int s=0;s<NST;s++)
     {
      double v[]; int n=0;
      double mf[],ma[]; int nm=0;
      for(int e=0;e<g_nev;e++)
        {
         if(g_ev[e].st!=s || !g_ev[e].comp[2]) continue;
         ArrayResize(v,n+1,g_nev); v[n]=MathMax(g_ev[e].up[2],g_ev[e].dn[2]); n++;
         if(g_ev[e].dir!=0)
           {
            ArrayResize(mf,nm+1,g_nev); ArrayResize(ma,nm+1,g_nev);
            mf[nm]=(g_ev[e].dir>0) ? g_ev[e].up[2] : g_ev[e].dn[2];
            ma[nm]=(g_ev[e].dir>0) ? g_ev[e].dn[2] : g_ev[e].up[2];
            nm++;
           }
        }
      if(n>0) ArraySort(v);
      if(nm>0) { ArraySort(mf); ArraySort(ma); }
      if(s>0) js+=",";
      js+="{\"state\":\""+ST_NAME[s]+"\",\"n16\":"+IntegerToString(n)
         +",\"exc16_p25\":"+Num(Pct(v,n,0.25))+",\"exc16_p50\":"+Num(Pct(v,n,0.5))+",\"exc16_p75\":"+Num(Pct(v,n,0.75))
         +",\"mfe16_p50\":"+Num(Pct(mf,nm,0.5))+",\"mae16_p50\":"+Num(Pct(ma,nm,0.5))
         +",\"hold_n_lt_300\":"+(n<300?"true":"false")+"}";
     }
   return js+"]";
  }

string VariantJson(int idx)
  {
   string js="{\"rev_pred_mode\":"+IntegerToString(g_sm[idx].mode)
            +",\"rev_pred_label\":\""+(g_sm[idx].mode==0?"v0.6b_stprev_TREND_EXH":"v0.6c_trend_dir_alive")+"\""
            +",\"measured\":"+(idx==g_main?"true":"false")
            +",\"bars_eval\":"+IntegerToString(g_sm[idx].bars_eval);
   js+=",\"events\":{";
   for(int s=0;s<NST;s++) { if(s>0) js+=","; js+="\""+ST_NAME[s]+"\":"+IntegerToString(g_sm[idx].evc[s]); }
   js+="},\"transitions_from_to\":[";
   for(int a=0;a<NST;a++)
     {
      if(a>0) js+=",";
      js+="[";
      for(int b=0;b<NST;b++) { if(b>0) js+=","; js+=IntegerToString(g_sm[idx].trans[a][b]); }
      js+="]";
     }
   js+="],\"rev_exh_diag\":{\"rev_core_true\":"+IntegerToString(g_sm[idx].c_rev_core)
      +",\"rev_core_blocked_by_pred\":"+IntegerToString(g_sm[idx].c_rev_blocked)
      +",\"rev_price_ok_but_slope_not_flat_after_TREND_EXH\":"+IntegerToString(g_sm[idx].c_slope_gap)
      +",\"exh_core_blocked_because_prev_REV\":"+IntegerToString(g_sm[idx].c_exh_after_rev_blocked)+"}";
   //--- Gate 0-4
   js+=",\"gate04\":[";
   for(int s=0;s<NST;s++)
     {
      double d[]; int n=0, shortc=0;
      int lim=(MIN_DUR[s]>=4) ? 3 : 2;
      for(int k=0;k<g_sm[idx].ndur;k++)
        {
         if(g_sm[idx].dur_st[k]!=s) continue;
         ArrayResize(d,n+1,g_sm[idx].ndur); d[n]=g_sm[idx].dur_len[k]; n++;
         if(g_sm[idx].dur_len[k]<lim) shortc++;
        }
      if(n>0) ArraySort(d);
      double med=Pct(d,n,0.5);
      double sr=(n>0) ? (double)shortc/n : NA_VAL;
      double mx=(n>0) ? d[n-1] : NA_VAL;
      string pass="null";
      if(s!=ST_BRK && n>=300) pass=(med>=MIN_DUR[s] && sr<0.10) ? "true" : "false";
      if(s>0) js+=",";
      js+="{\"state\":\""+ST_NAME[s]+"\",\"n_blocks\":"+IntegerToString(n)
         +",\"dur_p50\":"+Num(med,1)+",\"dur_max\":"+Num(mx,0)
         +",\"short_rate\":"+Num(sr,4)+",\"short_def_lt\":"+IntegerToString(lim)
         +",\"pass\":"+pass+"}";
     }
   double cr=(g_sm[idx].closed_blocks>0) ? (double)g_sm[idx].chatter/g_sm[idx].closed_blocks : NA_VAL;
   js+="],\"chatter_rate_report_only\":"+Num(cr,4)
      +",\"mratio_guard_hit\":"+IntegerToString(g_sm[idx].c_guard)
      +",\"bar_engulfs_channel\":"+IntegerToString(g_sm[idx].c_engulf)+"}";
   return js;
  }

//+------------------------------------------------------------------+
//| CSV                                                              |
//+------------------------------------------------------------------+
string NumOrEmpty(bool ok,double v) { return ok ? DoubleToString(v,5) : ""; }
string IntOrEmpty(bool ok,int v)    { return ok ? IntegerToString(v) : ""; }

void WriteCSV()
  {
   string fn="AMB_P0_events_"+_Symbol+"_"+InpPeriodLabel+".csv";
   int fh=FileOpen(fn,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh==INVALID_HANDLE) return;
   string hd="log_schema,version,symbol,timeframe,event_id,bar_timestamp,boot_day_key,hour_jst,market_state,market_state_coarse,previous_state,state_direction,"
            +"min_state_duration,was_confirmed,state_confirm_timestamp,bars_to_next_state_change,bars_since_prev_event,"
            +"atr_at_event,anchor_price,atr_at_state_confirm,anchor_price_confirm,spread";
   for(int j=0;j<NH;j++)
     {
      string N=IntegerToString(HZ[j]);
      hd+=",move_up_atr_"+N+",move_down_atr_"+N+",bars_to_up_"+N+",bars_to_down_"+N+",window_complete_"+N+",window_crosses_gap_"+N;
     }
   for(int j=0;j<NH;j++)
     {
      string N=IntegerToString(HZ[j]);
      hd+=",c_move_up_atr_"+N+",c_move_down_atr_"+N+",c_bars_to_up_"+N+",c_bars_to_down_"+N+",c_window_complete_"+N+",c_window_crosses_gap_"+N;
     }
   hd+=",prev_dir_ref,dir_agrees_prev,bar_engulfs_channel,mratio_guard_hit,width,slope,mratio,dev";
   FileWriteString(fh,hd+"\r\n");
   for(int e=0;e<g_nev;e++)
     {
      MqlDateTime m; TimeToStruct(g_ev[e].t,m);
      int hj=(m.hour+InpServerToJST+48)%24;
      bool cf=g_ev[e].conf;
      string ln=LOG_SCHEMA+","+AMB_VERSION+","+_Symbol+",M15,"+IntegerToString(e)+","
               +TimeToString(g_ev[e].t,TIME_DATE|TIME_MINUTES)+","+IntegerToString(g_ev[e].daykey)+","+IntegerToString(hj)+","
               +ST_NAME[g_ev[e].st]+","+CO_NAME[Coarse(g_ev[e].st)]+","+ST_NAME[g_ev[e].prev]+","+IntegerToString(g_ev[e].dir)+","
               +IntegerToString(MIN_DUR[g_ev[e].st])+","+(cf?"1":"0")+","+(cf?TimeToString(g_ev[e].tconf,TIME_DATE|TIME_MINUTES):"")+","
               +(g_ev[e].dur>=0?IntegerToString(g_ev[e].dur):"")+","+(g_ev[e].bsp>=0?IntegerToString(g_ev[e].bsp):"")+","
               +DoubleToString(g_ev[e].atr,8)+","+DoubleToString(g_ev[e].anchor,8)+","
               +(cf?DoubleToString(g_ev[e].c_atr,8):"")+","+(cf?DoubleToString(g_ev[e].c_anchor,8):"")+","
               +IntegerToString(g_ev[e].spread);
      for(int j=0;j<NH;j++)
        {
         bool ok=g_ev[e].comp[j];
         ln+=","+NumOrEmpty(ok,g_ev[e].up[j])+","+NumOrEmpty(ok,g_ev[e].dn[j])+","+IntOrEmpty(ok,g_ev[e].bup[j])+","
             +IntOrEmpty(ok,g_ev[e].bdn[j])+","+(ok?"1":"0")+","+(ok?(g_ev[e].gap[j]?"1":"0"):"");
        }
      for(int j=0;j<NH;j++)
        {
         bool ok=(cf && g_ev[e].ccomp[j]);
         ln+=","+NumOrEmpty(ok,g_ev[e].cup[j])+","+NumOrEmpty(ok,g_ev[e].cdn[j])+","+IntOrEmpty(ok,g_ev[e].cbup[j])+","
             +IntOrEmpty(ok,g_ev[e].cbdn[j])+","+(cf?(ok?"1":"0"):"")+","+(ok?(g_ev[e].cgap[j]?"1":"0"):"");
        }
      ln+=","+IntegerToString(g_ev[e].prev_dir_ref)+","+IntegerToString(g_ev[e].agrees)+","
          +(g_ev[e].engulf?"1":"0")+","+(g_ev[e].guard?"1":"0")+","
          +DoubleToString(g_ev[e].width,5)+","+DoubleToString(g_ev[e].slope,5)+","
          +DoubleToString(g_ev[e].mratio,5)+","+DoubleToString(g_ev[e].dev,5);
      FileWriteString(fh,ln+"\r\n");
     }
   FileClose(fh);
  }

//+------------------------------------------------------------------+
double OnTester()
  {
   double dDN,loDN,mDa,mNa,p25D,p25N,p75D,p75N; int nD,nN;
   string pDN=PairJson(1,0,false,true,dDN,loDN,mDa,mNa,p25D,p25N,p75D,p75N,nD,nN);
   double d1,l1,a1,b1,c1,e1,f1,g1; int n1,n2;
   string pFN=PairJson(2,0,false,true,d1,l1,a1,b1,c1,e1,f1,g1,n1,n2);
   string pFD=PairJson(2,1,false,true,d1,l1,a1,b1,c1,e1,f1,g1,n1,n2);
   string cDN=PairJson(1,0,true,false,d1,l1,a1,b1,c1,e1,f1,g1,n1,n2);

   //--- Gate 0-1 axes (meaningful for IS run)
   bool okE =(dDN!=NA_VAL && dDN>=0.15);
   bool okQ =(p25D!=NA_VAL && p25D>p25N && mDa>mNa && p75D>p75N);
   bool okS =(loDN!=NA_VAL && loDN>0.0);
   bool okP =(mDa!=NA_VAL && mDa-mNa>=0.3);
   bool okN =(nD>=300 && nN>=300);
   string g01="{\"applies_to\":\"IS\",\"effect_delta_ge_0_15\":"+(okE?"true":"false")
             +",\"quantiles_all_dir_gt_neu\":"+(okQ?"true":"false")
             +",\"boot_ci99_lo_gt_0\":"+(okS?"true":"false")
             +",\"median_diff_ge_0_3\":"+(okP?"true":"false")
             +",\"n_ge_300_each\":"+(okN?"true":"false")
             +",\"pass\":"+((okE&&okQ&&okS&&okP&&okN)?"true":"false")+"}";

   int nconf=0,nc16=0,nbrk=0;
   for(int e=0;e<g_nev;e++) { if(g_ev[e].conf) nconf++; if(g_ev[e].comp[2]) nc16++; if(g_ev[e].st==ST_BRK) nbrk++; }

   string js="{";
   js+="\"version\":\""+AMB_VERSION+"\",\"log_schema\":\""+LOG_SCHEMA+"\"";
   js+=",\"symbol\":\""+_Symbol+"\",\"timeframe\":\"M15\",\"period_label\":\""+InpPeriodLabel+"\"";
   js+=",\"notice\":\"Phase0: thresholds fixed. Diagnostic columns width/slope/mratio/dev must not be used for threshold search during Phase 0.\"";
   js+=",\"first_eval_bar\":\""+TimeToString(g_first_eval,TIME_DATE|TIME_MINUTES)+"\"";
   js+=",\"last_eval_bar\":\""+TimeToString(g_last_eval,TIME_DATE|TIME_MINUTES)+"\"";
   js+=",\"oos_blocked\":"+(g_oos_blocked?"true":"false");
   js+=",\"warmup_bars_replayed\":"+IntegerToString(g_warm_bars)+",\"warmup_required\":"+IntegerToString(WARMUP);
   js+=",\"prim_fail\":"+IntegerToString(g_prim_fail);
   js+=",\"params\":{\"K_BRK\":1.0,\"K_SLOPE\":1.0,\"K_WIDE\":3.0,\"K_NARROW\":2.5,\"K_MRATIO\":0.5,\"K_DEV\":0.5,\"EPS\":0.05,\"R_MAX\":5,\"D_MAX\":50,\"WARMUP\":200,"
       +"\"ATR\":14,\"EMA\":20,\"min_state_duration\":{\"RANGE\":4,\"COMPRESSION\":4,\"BREAKOUT\":1,\"TREND\":4,\"EXHAUSTION\":2,\"REVERSAL\":2},"
       +"\"horizon_main\":16,\"metric\":\"excursion_max_atr\",\"boot_B\":"+IntegerToString(InpBootB)+",\"boot_seed\":"+IntegerToString(BOOT_SEED)+",\"boot_ci\":0.99}";
   js+=",\"breakout_confirmed_equals_raw\":true";
   js+=",\"events_main\":"+IntegerToString(g_nev)+",\"events_window16_complete\":"+IntegerToString(nc16)
      +",\"events_confirmed\":"+IntegerToString(nconf)+",\"events_breakout\":"+IntegerToString(nbrk);
   js+=",\"variants\":["+VariantJson(g_main)+","+VariantJson(1-g_main)+"]";
   js+=",\"pair_DIR_vs_NEU\":"+pDN;
   js+=",\"pair_FAD_vs_NEU_report\":"+pFN;
   js+=",\"pair_FAD_vs_DIR_report\":"+pFD;
   js+=",\"confirmed_DIR_vs_NEU_report\":"+cDN;
   js+=",\"gate01\":"+g01;
   js+=",\"fine_states\":"+FineJson();
   js+="}";

   int fh=FileOpen("result_"+_Symbol+".json",FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh!=INVALID_HANDLE) { FileWriteString(fh,js); FileClose(fh); }
   if(InpWriteCSV) WriteCSV();
   return (double)g_nev;
  }
//+------------------------------------------------------------------+

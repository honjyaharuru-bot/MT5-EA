//+------------------------------------------------------------------+
//| AMB_P0_v0_6d_r1.mq5                                              |
//| AMB Phase 0 follow-up : state-change diagnostics (NO TRADING)    |
//| Base : v0.6c_r1 state machine, thresholds UNCHANGED              |
//| Purpose (explore period 2022-2023 only, 2024 reserved):          |
//|  H1 ATR normalization : DIR vs NEU on raw price (spread units)   |
//|     and on seasonal expected range (same time-of-day, 20 days)   |
//|  H2 session confound  : DIR vs NEU stratified by server hour     |
//|  H4 direction edge    : signed return in state direction, spread |
//|     units, day-clustered SE, cost 1 spread                       |
//|  H5 boundary flip     : per transition bounce-back rate          |
//| Output : result_<SYMBOL>.json (Common\Files)                     |
//+------------------------------------------------------------------+
#property copyright "Maehara"
#property version   "0.62"
#property description "AMB Phase0 v0.6d state-change diagnostics (no trading)"

#define AMB_VERSION "AMB_P0_v0.6d_r1"
#define LOG_SCHEMA  "p0.2"

#define ST_RANGE 0
#define ST_COMP  1
#define ST_BRK   2
#define ST_TREND 3
#define ST_EXH   4
#define ST_REV   5
#define NST      6
#define NH       3
#define HMAIN    1
#define NSLOT    96
#define SEAS_DAYS 20
#define SEAS_MIN  10
#define NBK      4
#define NMET     4

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
#define BOOT_SEED 20260922
#define NA_VAL    (-1.0e300)

input string   InpPeriodLabel = "EXPLORE";               // label only
input bool     InpAllowOOS    = false;                   // must stay false
input datetime InpEvalEnd     = D'2024.01.01 00:00';     // events only before this (2024 = confirmation, not viewed)
input int      InpBootB       = 2000;                    // bootstrap repetitions

string ST_NAME[NST] = {"RANGE","COMPRESSION","BREAKOUT","TREND","EXHAUSTION","REVERSAL"};
string CO_NAME[3]   = {"NEUTRAL","DIRECTIONAL","FADING"};
string MET_NAME[NMET]= {"exc_atr","exc_sp","exc_sv","atr_sp"};
string BK_NAME[NBK] = {"srv00_08","srv09_14","srv15_18","srv19_23"};
int    MIN_DUR[NST] = {4,4,1,4,2,2};
int    HZ[NH]       = {4,16,64};

int Coarse(int s) { if(s<=ST_COMP) return 0; if(s<=ST_TREND) return 1; return 2; }
int Sgn(double v) { return (v>0.0) ? 1 : ((v<0.0) ? -1 : 0); }
int Bucket(int hr) { if(hr<=8) return 0; if(hr<=14) return 1; if(hr<=18) return 2; return 3; }
bool IsDirState(int s) { return (s==ST_BRK || s==ST_TREND || s==ST_EXH || s==ST_REV); }

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
   p.dh     = hb[ArrayMaximum(hb)];
   p.dl     = lb[ArrayMinimum(lb)];
   p.width  = (p.dh-p.dl)/p.atr;
   p.slope  = (eb[0]-eb[10])/p.atr;
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
//| state machine v0.6c (unchanged logic)                            |
//+------------------------------------------------------------------+
struct StepOut
  {
   int  st, dir, prev_state, old_since;
   bool changed;
  };

class CSM
  {
public:
   int    st_prev, raw_since, trend_dir, dir_age;
   double wh[6];
   int    whn;
   long   trans[NST][NST];
   long   evc[NST];
   long   bars_eval;

   void Init()
     {
      st_prev=ST_RANGE; raw_since=1; trend_dir=0; dir_age=0; whn=0; bars_eval=0;
      for(int i=0;i<6;i++) wh[i]=0.0;
      for(int a=0;a<NST;a++) { evc[a]=0; for(int b=0;b<NST;b++) trans[a][b]=0; }
     }

   void Step(const Prim &p, bool eval, StepOut &o)
     {
      for(int k=5;k>0;k--) wh[k]=wh[k-1];
      wh[0]=p.width;
      if(whn<6) whn++;

      int s=-1, d=0;
      bool up=(p.c>p.dh), dn=(p.c<p.dl);
      if((up||dn) && MathAbs(p.c-p.cprev)/p.atr>=K_BRK) { s=ST_BRK; d=up?1:-1; }
      int  sdev=Sgn(p.dev);
      bool pricerev=(trend_dir!=0 && sdev==-trend_dir && MathAbs(p.dev)>=K_DEV);
      bool revc=(pricerev && p.slope*trend_dir<=0.0);
      bool pred=(st_prev!=ST_REV) || (raw_since<=R_MAX);
      if(s<0 && revc && pred) { s=ST_REV; d=-trend_dir; }
      bool exhc=(MathAbs(p.slope)>=K_SLOPE && p.mratio<K_MRATIO);
      bool pexh=(st_prev==ST_BRK || st_prev==ST_TREND || st_prev==ST_EXH);
      if(s<0 && exhc && pexh) { s=ST_EXH; d=Sgn(p.slope); }
      if(s<0 && MathAbs(p.slope)>=K_SLOPE && p.width>=K_WIDE) { s=ST_TREND; d=Sgn(p.slope); }
      if(s<0 && whn>=6 && p.width<=K_NARROW && p.width<wh[5]) { s=ST_COMP; d=0; }
      if(s<0) { s=ST_RANGE; d=0; }

      o.st=s; o.dir=d; o.prev_state=st_prev; o.old_since=raw_since;
      o.changed=(s!=st_prev);

      if(o.changed)
        {
         if(eval) { trans[st_prev][s]++; evc[s]++; }
         if(st_prev==ST_REV) trend_dir=0;
         if(s==ST_BRK || s==ST_TREND || s==ST_EXH) trend_dir=d;
         raw_since=1;
        }
      else raw_since++;

      if(s==ST_BRK || s==ST_TREND || s==ST_EXH) dir_age=0; else dir_age++;
      if(dir_age>D_MAX) trend_dir=0;
      st_prev=s;
      if(eval) bars_eval++;
     }
  };

//+------------------------------------------------------------------+
//| events and windows                                               |
//+------------------------------------------------------------------+
struct Ev
  {
   datetime t;
   long     daykey;
   int      day, year, bk, st, prev, dir, dur, spread;
   double   anchor, atr;
   double   up[NH], dn[NH], cl[NH], sdiv[NH];
   bool     comp[NH], gap[NH], sok[NH];
  };

struct Win
  {
   int      ev, k;
   bool     gap;
   double   mx, mn;
   datetime last;
  };

CSM      g_sm;
Ev       g_ev[];
int      g_nev=0;
Win      g_win[];
int      g_nwin=0;
int      g_cur_ev=-1;
int      g_nday=0;
long     g_last_daykey=-1;
datetime g_last_bar=0;
datetime g_eval_from=0;
datetime g_first_eval=0, g_last_eval=0;
bool     g_warmed=false;
int      g_warm_bars=0;
bool     g_oos_blocked=false;
long     g_prim_fail=0;
ulong    g_rng=BOOT_SEED;
int      g_spr[];
int      g_nspr=0;
double   g_spx=0.0;
int      g_spr_med=0;
long     g_sv_invalid=0;

double   g_seas[NSLOT][SEAS_DAYS];
int      g_seas_n[NSLOT];
int      g_seas_pos[NSLOT];

void SeasPush(int s,double r)
  {
   g_seas[s][g_seas_pos[s]]=r;
   g_seas_pos[s]=(g_seas_pos[s]+1)%SEAS_DAYS;
   if(g_seas_n[s]<SEAS_DAYS) g_seas_n[s]++;
  }

double SeasMean(int s)
  {
   int n=g_seas_n[s];
   if(n<SEAS_MIN) return -1.0;
   double sm=0.0;
   for(int i=0;i<n;i++) sm+=g_seas[s][i];
   return sm/n;
  }

void AddWin(int ev,datetime t)
  {
   ArrayResize(g_win,g_nwin+1,256);
   g_win[g_nwin].ev=ev; g_win[g_nwin].k=0; g_win[g_nwin].gap=false;
   g_win[g_nwin].mx=-DBL_MAX; g_win[g_nwin].mn=DBL_MAX; g_win[g_nwin].last=t;
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
      if(p.h>w.mx) w.mx=p.h;
      if(p.l<w.mn) w.mn=p.l;
      for(int j=0;j<NH;j++)
        {
         if(w.k!=HZ[j]) continue;
         int e=w.ev;
         g_ev[e].up[j]=w.mx-g_ev[e].anchor;
         g_ev[e].dn[j]=g_ev[e].anchor-w.mn;
         g_ev[e].cl[j]=p.c;
         g_ev[e].comp[j]=true;
         g_ev[e].gap[j]=w.gap;
        }
      if(w.k>=HZ[NH-1]) { g_win[i]=g_win[g_nwin-1]; g_nwin--; }
      else g_win[i]=w;
     }
  }

void ProcessBar(int base,bool allow_eval)
  {
   Prim p;
   if(!GetPrim(base,p)) { g_prim_fail++; return; }
   if(!InpAllowOOS && p.t>=D'2025.01.01 00:00') { g_oos_blocked=true; return; }
   MqlDateTime m; TimeToStruct(p.t,m);
   int slot=(m.hour*60+m.min)/15;
   if(slot<0 || slot>=NSLOT) slot=0;
   bool active=(allow_eval && p.t>=g_eval_from);
   bool ev_ok=(active && p.t<InpEvalEnd);
   if(!active) g_warm_bars++;
   if(active) UpdateWindows(p);

   StepOut o;
   g_sm.Step(p,ev_ok,o);

   if(ev_ok)
     {
      if(g_first_eval==0) g_first_eval=p.t;
      g_last_eval=p.t;
      ArrayResize(g_spr,g_nspr+1,65536); g_spr[g_nspr]=p.spread; g_nspr++;
      if(o.changed)
        {
         if(g_cur_ev>=0) g_ev[g_cur_ev].dur=o.old_since;
         ArrayResize(g_ev,g_nev+1,8192);
         int e=g_nev;
         ZeroMemory(g_ev[e]);
         g_ev[e].t=p.t; g_ev[e].st=o.st; g_ev[e].prev=o.prev_state; g_ev[e].dir=o.dir;
         g_ev[e].dur=-1; g_ev[e].anchor=p.c; g_ev[e].atr=p.atr; g_ev[e].spread=p.spread;
         g_ev[e].year=m.year; g_ev[e].bk=Bucket(m.hour);
         long dk=(long)m.year*10000+m.mon*100+m.day;
         if(dk!=g_last_daykey) { g_last_daykey=dk; g_nday++; }
         g_ev[e].daykey=dk; g_ev[e].day=g_nday-1;
         //--- seasonal expected range of the next N slots (past days only)
         bool okall=true;
         double cum=0.0;
         int jj=0;
         for(int k=1;k<=HZ[NH-1];k++)
           {
            double sm=SeasMean((slot+k)%NSLOT);
            if(sm<=0.0) okall=false;
            else cum+=sm;
            if(jj<NH && k==HZ[jj])
              {
               g_ev[e].sok[jj]=okall;
               g_ev[e].sdiv[jj]=okall ? cum : 0.0;
               if(!okall) g_sv_invalid++;
               jj++;
              }
           }
         g_nev++;
         g_cur_ev=e;
         AddWin(e,p.t);
        }
     }
   SeasPush(slot,p.h-p.l);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   g_hATR=iATR(_Symbol,PERIOD_M15,14);
   g_hEMA=iMA(_Symbol,PERIOD_M15,20,0,MODE_EMA,PRICE_CLOSE);
   if(g_hATR==INVALID_HANDLE || g_hEMA==INVALID_HANDLE) return INIT_FAILED;
   g_sm.Init();
   for(int s=0;s<NSLOT;s++) { g_seas_n[s]=0; g_seas_pos[s]=0; for(int d=0;d<SEAS_DAYS;d++) g_seas[s][d]=0.0; }
   ArrayResize(g_ev,0,8192);
   ArrayResize(g_win,0,256);
   ArrayResize(g_spr,0,65536);
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

string Num(double v,int dig=6)
  {
   if(v==NA_VAL || !MathIsValidNumber(v)) return "null";
   return DoubleToString(v,dig);
  }

// weighted Cliff delta on a sorted segment; sg=1 group A, 0 group B
double WDeltaSeg(const double &sv[],const int &sg[],const double &w[],int s0,int len,double &wt)
  {
   double totA=0.0,totB=0.0;
   int s1=s0+len;
   for(int k=s0;k<s1;k++) { if(sg[k]==1) totA+=w[k]; else totB+=w[k]; }
   wt=0.0;
   if(totA<=0.0 || totB<=0.0) return NA_VAL;
   double cumB=0.0,num=0.0;
   int i=s0;
   while(i<s1)
     {
      int j=i; double tA=0.0,tB=0.0;
      while(j<s1 && sv[j]==sv[i]) { if(sg[j]==1) tA+=w[j]; else tB+=w[j]; j++; }
      num+=tA*cumB-tA*(totB-cumB-tB);
      cumB+=tB;
      i=j;
     }
   wt=totA*totB;
   return num/(totA*totB);
  }

double CombDelta(const double &sv[],const int &sg[],const double &w[],const int &off[],const int &len[],int nb,double &bd[])
  {
   double num=0.0,den=0.0;
   for(int b=0;b<nb;b++)
     {
      double wt=0.0;
      double d=WDeltaSeg(sv,sg,w,off[b],len[b],wt);
      bd[b]=d;
      if(d!=NA_VAL && wt>0.0) { num+=wt*d; den+=wt; }
     }
   if(den<=0.0) return NA_VAL;
   return num/den;
  }

// metric: 0=exc_atr 1=exc_sp(raw price / median spread) 2=exc_sv(seasonal) 3=atr_sp
bool EvVal(int e,int metric,int h,double &v)
  {
   if(metric==3) { v=g_ev[e].atr/g_spx; return true; }
   if(!g_ev[e].comp[h]) return false;
   double x=MathMax(g_ev[e].up[h],g_ev[e].dn[h]);
   if(metric==0) { v=x/g_ev[e].atr; return true; }
   if(metric==1) { v=x/g_spx; return true; }
   if(!g_ev[e].sok[h] || g_ev[e].sdiv[h]<=0.0) return false;
   v=x/g_ev[e].sdiv[h];
   return true;
  }

bool Pass(int e,int st,int prv,int yr)
  {
   if(st>=0 && g_ev[e].st!=st) return false;
   if(prv>=0 && g_ev[e].prev!=prv) return false;
   if(yr>0 && g_ev[e].year!=yr) return false;
   return true;
  }

double MedVal(int st,int prv,int metric,int h,int yr,int &n)
  {
   double v[]; n=0;
   ArrayResize(v,0,g_nev);
   for(int e=0;e<g_nev;e++)
     {
      if(!Pass(e,st,prv,yr)) continue;
      double x;
      if(!EvVal(e,metric,h,x)) continue;
      ArrayResize(v,n+1,g_nev); v[n]=x; n++;
     }
   if(n==0) return NA_VAL;
   ArraySort(v);
   return Pct(v,n,0.5);
  }

// signed return in state direction, spread units, day-clustered SE
void SRet(int st,int prv,int h,int yr,double &mean,double &se,int &n)
  {
   n=0; mean=NA_VAL; se=NA_VAL;
   double sm=0.0;
   for(int e=0;e<g_nev;e++)
     {
      if(!Pass(e,st,prv,yr) || !g_ev[e].comp[h] || g_ev[e].dir==0) continue;
      sm+=(g_ev[e].cl[h]-g_ev[e].anchor)*g_ev[e].dir/g_spx; n++;
     }
   if(n==0) return;
   mean=sm/n;
   if(n<2 || g_nday<=0) return;
   double ds[]; ArrayResize(ds,g_nday); ArrayInitialize(ds,0.0);
   for(int e=0;e<g_nev;e++)
     {
      if(!Pass(e,st,prv,yr) || !g_ev[e].comp[h] || g_ev[e].dir==0) continue;
      double x=(g_ev[e].cl[h]-g_ev[e].anchor)*g_ev[e].dir/g_spx;
      int d=g_ev[e].day;
      if(d>=0 && d<g_nday) ds[d]+=x-mean;
     }
   double s2=0.0;
   for(int d=0;d<g_nday;d++) s2+=ds[d]*ds[d];
   se=MathSqrt(s2)/n;
  }

//--- group A vs B delta, optional session stratification, optional day-block bootstrap
string StratJson(string name,int ga,int gb,int metric,int h,int yr,bool strat,bool boot)
  {
   int nb=strat ? NBK : 1;
   double sv[]; int sg[]; int sd[];
   ArrayResize(sv,0,g_nev); ArrayResize(sg,0,g_nev); ArrayResize(sd,0,g_nev);
   double va[]; double vb[];
   ArrayResize(va,0,g_nev); ArrayResize(vb,0,g_nev);
   int off[NBK]; int len[NBK]; int bnA[NBK]; int bnB[NBK];
   int nA=0,nB=0,n=0;
   for(int b=0;b<NBK;b++) { off[b]=0; len[b]=0; bnA[b]=0; bnB[b]=0; }
   for(int b=0;b<nb;b++)
     {
      off[b]=n;
      double arr[][3];
      int m=0;
      for(int e=0;e<g_nev;e++)
        {
         if(yr>0 && g_ev[e].year!=yr) continue;
         if(strat && g_ev[e].bk!=b) continue;
         int g=Coarse(g_ev[e].st);
         int s=-1;
         if(g==ga) s=1; else if(g==gb) s=0;
         if(s<0) continue;
         double x;
         if(!EvVal(e,metric,h,x)) continue;
         ArrayResize(arr,m+1,g_nev);
         arr[m][0]=x; arr[m][1]=(double)s; arr[m][2]=(double)g_ev[e].day;
         m++;
         if(s==1) { ArrayResize(va,nA+1,g_nev); va[nA]=x; nA++; bnA[b]++; }
         else     { ArrayResize(vb,nB+1,g_nev); vb[nB]=x; nB++; bnB[b]++; }
        }
      if(m>1) ArraySort(arr);
      ArrayResize(sv,n+m,g_nev); ArrayResize(sg,n+m,g_nev); ArrayResize(sd,n+m,g_nev);
      for(int k=0;k<m;k++) { sv[n+k]=arr[k][0]; sg[n+k]=(int)arr[k][1]; sd[n+k]=(int)arr[k][2]; }
      len[b]=m;
      n+=m;
     }
   string js="{\"name\":\""+name+"\",\"a\":\""+CO_NAME[ga]+"\",\"b\":\""+CO_NAME[gb]+"\",\"metric\":\""+MET_NAME[metric]+"\""
            +",\"N\":"+IntegerToString(HZ[h])+",\"year\":"+IntegerToString(yr)+",\"strat\":"+(strat?"true":"false")
            +",\"n_a\":"+IntegerToString(nA)+",\"n_b\":"+IntegerToString(nB);
   if(nA<2 || nB<2) return js+",\"delta\":null}";
   ArraySort(va); ArraySort(vb);
   js+=",\"p25_a\":"+Num(Pct(va,nA,0.25),4)+",\"p50_a\":"+Num(Pct(va,nA,0.5),4)+",\"p75_a\":"+Num(Pct(va,nA,0.75),4)
      +",\"p25_b\":"+Num(Pct(vb,nB,0.25),4)+",\"p50_b\":"+Num(Pct(vb,nB,0.5),4)+",\"p75_b\":"+Num(Pct(vb,nB,0.75),4);

   double w[]; ArrayResize(w,n); ArrayInitialize(w,1.0);
   double bd[NBK];
   for(int b=0;b<NBK;b++) bd[b]=NA_VAL;
   double d0=CombDelta(sv,sg,w,off,len,nb,bd);
   js+=",\"delta\":"+Num(d0,4);
   if(strat)
     {
      js+=",\"buckets\":[";
      for(int b=0;b<nb;b++)
        {
         if(b>0) js+=",";
         js+="{\"bk\":\""+BK_NAME[b]+"\",\"n_a\":"+IntegerToString(bnA[b])+",\"n_b\":"+IntegerToString(bnB[b])+",\"delta\":"+Num(bd[b],4)+"}";
        }
      js+="]";
     }
   if(!boot) return js+"}";

   //--- day-block bootstrap
   int maxd=0;
   for(int k=0;k<n;k++) if(sd[k]>maxd) maxd=sd[k];
   int map[]; ArrayResize(map,maxd+1); ArrayInitialize(map,-1);
   int nd=0;
   for(int k=0;k<n;k++) if(map[sd[k]]<0) { map[sd[k]]=nd; nd++; }
   int dix[]; ArrayResize(dix,n);
   for(int k=0;k<n;k++) dix[k]=map[sd[k]];
   int B=MathMax(InpBootB,100);
   double dbs[]; ArrayResize(dbs,B);
   double cnt[]; ArrayResize(cnt,nd);
   double bdt[NBK];
   int nbv=0;
   g_rng=BOOT_SEED;
   for(int r=0;r<B;r++)
     {
      ArrayInitialize(cnt,0.0);
      for(int q=0;q<nd;q++) cnt[(int)(RngNext()%(ulong)nd)]+=1.0;
      for(int k=0;k<n;k++) w[k]=cnt[dix[k]];
      double d=CombDelta(sv,sg,w,off,len,nb,bdt);
      if(d!=NA_VAL) { dbs[nbv]=d; nbv++; }
     }
   double lo=NA_VAL,hi=NA_VAL;
   if(nbv>=100)
     {
      ArrayResize(dbs,nbv); ArraySort(dbs);
      lo=Pct(dbs,nbv,0.005); hi=Pct(dbs,nbv,0.995);
     }
   js+=",\"boot_days\":"+IntegerToString(nd)+",\"boot_B_valid\":"+IntegerToString(nbv)
      +",\"ci99_lo\":"+Num(lo,4)+",\"ci99_hi\":"+Num(hi,4)+"}";
   return js;
  }

string SRetBlock(int st,int prv)
  {
   string js="";
   double mn,se; int n;
   for(int h=0;h<NH;h++)
     {
      SRet(st,prv,h,0,mn,se,n);
      string N=IntegerToString(HZ[h]);
      js+=",\"sret"+N+"_mean\":"+Num(mn,3)+",\"sret"+N+"_se\":"+Num(se,3)+",\"sret"+N+"_n\":"+IntegerToString(n);
      if(h==HMAIN)
        {
         js+=",\"net_follow16\":"+(mn==NA_VAL?"null":Num(mn-1.0,3))
            +",\"net_fade16\":"+(mn==NA_VAL?"null":Num(-mn-1.0,3));
        }
     }
   double m22,s22,m23,s23; int n22,n23;
   SRet(st,prv,HMAIN,2022,m22,s22,n22);
   SRet(st,prv,HMAIN,2023,m23,s23,n23);
   js+=",\"sret16_2022\":"+Num(m22,3)+",\"sret16_2023\":"+Num(m23,3);
   return js;
  }

string FineJson()
  {
   string js="[";
   for(int s=0;s<NST;s++)
     {
      int n,nx;
      int cnt=0,c22=0,c23=0;
      for(int e=0;e<g_nev;e++) if(g_ev[e].st==s) { cnt++; if(g_ev[e].year==2022) c22++; if(g_ev[e].year==2023) c23++; }
      if(s>0) js+=",";
      js+="{\"state\":\""+ST_NAME[s]+"\",\"n\":"+IntegerToString(cnt)+",\"n_2022\":"+IntegerToString(c22)+",\"n_2023\":"+IntegerToString(c23);
      js+=",\"exc_atr16_p50\":"+Num(MedVal(s,-1,0,HMAIN,0,n),3);
      js+=",\"exc_sp16_p50\":"+Num(MedVal(s,-1,1,HMAIN,0,nx),2);
      js+=",\"exc_sv16_p50\":"+Num(MedVal(s,-1,2,HMAIN,0,nx),3);
      js+=",\"atr_sp_p50\":"+Num(MedVal(s,-1,3,HMAIN,0,nx),2);
      js+=",\"n16\":"+IntegerToString(n);
      if(IsDirState(s)) js+=SRetBlock(s,-1);
      js+="}";
     }
   return js+"]";
  }

string TransJson()
  {
   string js="[";
   bool first=true;
   for(int a=0;a<NST;a++)
      for(int b=0;b<NST;b++)
        {
         if(a==b) continue;
         int cnt=0,c22=0,c23=0,bbd=0,bb=0;
         for(int e=0;e<g_nev;e++)
           {
            if(g_ev[e].st!=b || g_ev[e].prev!=a) continue;
            cnt++;
            if(g_ev[e].year==2022) c22++;
            if(g_ev[e].year==2023) c23++;
            if(e+1<g_nev && g_ev[e].dur>=0)
              {
               bbd++;
               if(g_ev[e].dur<=2 && g_ev[e+1].st==a) bb++;
              }
           }
         if(cnt<100) continue;
         int n,nx;
         if(!first) js+=",";
         first=false;
         js+="{\"from\":\""+ST_NAME[a]+"\",\"to\":\""+ST_NAME[b]+"\",\"n\":"+IntegerToString(cnt)
            +",\"n_2022\":"+IntegerToString(c22)+",\"n_2023\":"+IntegerToString(c23)
            +",\"bounce_back_le2_rate_lookahead\":"+(bbd>0?Num((double)bb/bbd,4):"null")
            +",\"exc_atr16_p50\":"+Num(MedVal(b,a,0,HMAIN,0,n),3)
            +",\"exc_sv16_p50\":"+Num(MedVal(b,a,2,HMAIN,0,nx),3)
            +",\"atr_sp_p50\":"+Num(MedVal(b,a,3,HMAIN,0,nx),2);
         if(IsDirState(b)) js+=SRetBlock(b,a);
         js+="}";
        }
   return js+"]";
  }

//+------------------------------------------------------------------+
double OnTester()
  {
   //--- median bar spread over evaluated bars -> spread unit
   g_spr_med=0;
   if(g_nspr>0)
     {
      int tmp[]; ArrayCopy(tmp,g_spr,0,0,g_nspr); ArraySort(tmp);
      g_spr_med=tmp[g_nspr/2];
     }
   int spp=MathMax(g_spr_med,1);
   g_spx=spp*_Point;

   string pairs="[";
   int yrs[3]={0,2022,2023};
   bool fp=true;
   for(int y=0;y<3;y++)
     {
      string ys=(yrs[y]==0)?"all":IntegerToString(yrs[y]);
      string items[5];
      items[0]=StratJson("DIR_NEU_atr_"+ys,     1,0,0,HMAIN,yrs[y],false,true);
      items[1]=StratJson("DIR_NEU_sp_"+ys,      1,0,1,HMAIN,yrs[y],false,true);
      items[2]=StratJson("DIR_NEU_sv_"+ys,      1,0,2,HMAIN,yrs[y],false,true);
      items[3]=StratJson("DIR_NEU_atr_strat_"+ys,1,0,0,HMAIN,yrs[y],true,true);
      items[4]=StratJson("DIR_NEU_sv_strat_"+ys, 1,0,2,HMAIN,yrs[y],true,true);
      for(int i=0;i<5;i++) { if(!fp) pairs+=","; pairs+=items[i]; fp=false; }
     }
   pairs+=","+StratJson("FAD_NEU_sp_all",2,0,1,HMAIN,0,false,true);
   pairs+=","+StratJson("FAD_NEU_sv_all",2,0,2,HMAIN,0,false,true);
   pairs+="]";

   string hz="[";
   bool fh=true;
   for(int h=0;h<NH;h++)
     {
      if(h==HMAIN) continue;
      for(int mt=0;mt<3;mt++)
        {
         if(!fh) hz+=",";
         hz+=StratJson("DIR_NEU_"+MET_NAME[mt]+"_N"+IntegerToString(HZ[h]),1,0,mt,h,0,false,false);
         fh=false;
        }
     }
   hz+="]";

   int nc16=0;
   for(int e=0;e<g_nev;e++) if(g_ev[e].comp[HMAIN]) nc16++;

   string js="{";
   js+="\"version\":\""+AMB_VERSION+"\",\"log_schema\":\""+LOG_SCHEMA+"\"";
   js+=",\"symbol\":\""+_Symbol+"\",\"timeframe\":\"M15\",\"period_label\":\""+InpPeriodLabel+"\"";
   js+=",\"notice\":\"Diagnostics only. State thresholds unchanged from v0.6c. Events restricted to before eval_end (2024 reserved). No pass/fail gate.\"";
   js+=",\"eval_end\":\""+TimeToString(InpEvalEnd,TIME_DATE)+"\"";
   js+=",\"first_eval_bar\":\""+TimeToString(g_first_eval,TIME_DATE|TIME_MINUTES)+"\"";
   js+=",\"last_eval_bar\":\""+TimeToString(g_last_eval,TIME_DATE|TIME_MINUTES)+"\"";
   js+=",\"oos_blocked\":"+(g_oos_blocked?"true":"false");
   js+=",\"prim_fail\":"+IntegerToString(g_prim_fail)+",\"warmup_bars\":"+IntegerToString(g_warm_bars);
   js+=",\"bars_eval\":"+IntegerToString(g_sm.bars_eval)+",\"events\":"+IntegerToString(g_nev)+",\"events_N16_complete\":"+IntegerToString(nc16);
   js+=",\"days\":"+IntegerToString(g_nday)+",\"sv_invalid_events\":"+IntegerToString(g_sv_invalid);
   js+=",\"median_spread_points\":"+IntegerToString(g_spr_med)+",\"point\":"+DoubleToString(_Point,_Digits);
   js+=",\"units\":{\"exc_atr\":\"max(up,dn)/ATR14\",\"exc_sp\":\"max(up,dn)/median_spread\",\"exc_sv\":\"max(up,dn)/sum seasonal mean bar range next N slots (20d)\",\"sret\":\"(close[t+N]-close[t])*dir/median_spread\",\"cost\":\"1 spread\"}";
   js+=",\"session_buckets\":\"server hour 00-08/09-14/15-18/19-23 (JST = server+6 summer, +7 winter, unverified)\"";
   js+=",\"boot\":{\"B\":"+IntegerToString(InpBootB)+",\"seed\":"+IntegerToString(BOOT_SEED)+",\"block\":\"server_day\",\"ci\":0.99}";
   js+=",\"state_events\":{";
   for(int s=0;s<NST;s++) { if(s>0) js+=","; js+="\""+ST_NAME[s]+"\":"+IntegerToString(g_sm.evc[s]); }
   js+="},\"transitions_from_to\":[";
   for(int a=0;a<NST;a++)
     {
      if(a>0) js+=",";
      js+="[";
      for(int b=0;b<NST;b++) { if(b>0) js+=","; js+=IntegerToString(g_sm.trans[a][b]); }
      js+="]";
     }
   js+="]";
   js+=",\"pairs\":"+pairs;
   js+=",\"horizon_check\":"+hz;
   js+=",\"fine_states\":"+FineJson();
   js+=",\"transitions\":"+TransJson();
   js+="}";

   int fh2=FileOpen("result_"+_Symbol+".json",FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(fh2!=INVALID_HANDLE) { FileWriteString(fh2,js); FileClose(fh2); }
   return (double)g_nev;
  }
//+------------------------------------------------------------------+

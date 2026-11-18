//+------------------------------------------------------------------+
//|                                            QuantumScalper_M1.mq5 |
//|   M1 scalper EA                                                  |
//|   - Trend filter (EMA + higher-TF EMA + ADX) + pullback entry    |
//|   - Every order always has SL and TP                             |
//|   - TP1 / TP2 / TP3 legs, break-even, lock profit, trend runner  |
//|   - Recovery: grid averaging while in trade + lot step after loss|
//|   - Dashboard with buttons + daily P/L calendar                  |
//+------------------------------------------------------------------+
#property copyright   "QuantumScalper M1"
#property version     "1.00"
#property description "M1 scalper: trend + pullback entry, TP1/TP2/TP3 legs, trend runner,"
#property description "recovery (grid / after-loss), dashboard with buttons and P/L calendar."

#include <Trade\Trade.mqh>

//--- enums ----------------------------------------------------------
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,   // Fixed lot (ล็อตคงที่)
   LOT_RISK_PERCENT = 1    // Risk % of balance (ความเสี่ยง % ของบาลานซ์)
  };

enum ENUM_RECOVERY_MODE
  {
   REC_OFF        = 0,     // Off (ปิดการแก้ไม้)
   REC_GRID       = 1,     // Grid averaging while in trade (แก้ไม้ระหว่างถือออเดอร์)
   REC_AFTER_LOSS = 2,     // Increase lot after a loss (เพิ่มล็อตหลังแพ้)
   REC_BOTH       = 3      // Both (ทั้งสองแบบ)
  };

//--- inputs ---------------------------------------------------------
input group "=== General / ทั่วไป ==="
input long            InpMagic            = 20261118;     // Magic number
input string          InpComment          = "QS-M1";      // Order comment
input bool            InpAutoTrade        = true;         // Auto trading at start
input ENUM_TIMEFRAMES InpSignalTF         = PERIOD_M1;    // Signal timeframe
input int             InpSlippagePts      = 30;           // Max slippage (points)

input group "=== Lot size / ขนาดล็อต ==="
input ENUM_LOT_MODE   InpLotMode          = LOT_RISK_PERCENT; // Lot mode
input double          InpFixedLot         = 0.03;         // Fixed total lot (split into TP1/TP2/TP3)
input double          InpRiskPercent      = 1.0;          // Risk % per basket (worst case incl. grid)
input double          InpMaxLot           = 5.0;          // Max lot per order
input double          InpManualLot        = 0.03;         // Manual BUY/SELL button lot

input group "=== Signal (M1) / สัญญาณ ==="
input int             InpFastEMA          = 9;            // Fast EMA
input int             InpSlowEMA          = 21;           // Slow EMA
input ENUM_TIMEFRAMES InpTrendTF          = PERIOD_M15;   // Higher-TF trend filter
input int             InpTrendEMA         = 50;           // Higher-TF EMA period
input int             InpRSIPeriod        = 7;            // RSI period
input double          InpRSIBuyLevel      = 40.0;         // RSI pullback level for BUY
input double          InpRSISellLevel     = 60.0;         // RSI pullback level for SELL
input int             InpADXPeriod        = 14;           // ADX period
input double          InpADXMin           = 20.0;         // Min ADX to trade
input int             InpATRPeriod        = 14;           // ATR period
input double          InpMaxCandleATR     = 2.5;          // Skip spike candles larger than x ATR

input group "=== SL / TP (x ATR) ==="
input double          InpSL_ATR           = 1.5;          // Stop loss (no grid) x ATR
input double          InpTP1_ATR          = 1.0;          // TP1 x ATR
input double          InpTP2_ATR          = 2.0;          // TP2 x ATR
input double          InpTP3_ATR          = 3.5;          // TP3 x ATR
input double          InpTP1_Pct          = 40.0;         // % of lot closed at TP1
input double          InpTP2_Pct          = 30.0;         // % of lot closed at TP2 (rest = TP3)
input bool            InpMoveBEAfterTP1   = true;         // Move SL to break-even after TP1
input int             InpBEOffsetPts      = 20;           // Break-even offset (points)
input bool            InpLockTP1AfterTP2  = true;         // Move SL to TP1 after TP2

input group "=== Trend runner / ปล่อยกำไรไหล ==="
input bool            InpTrendRunner      = true;         // Enable trend runner after TP2
input double          InpRunnerADX        = 25.0;         // ADX = strong trend
input double          InpTrailATR         = 1.0;          // Trailing distance x ATR (strong trend)
input double          InpWeakTrailFactor  = 0.6;          // Trail factor when trend weakens
input double          InpRunnerExtendATR  = 2.0;          // Push TP3 ahead of price x ATR (strong trend)

input group "=== Recovery / แก้ไม้ ==="
input ENUM_RECOVERY_MODE InpRecoveryMode  = REC_BOTH;     // Recovery mode
input int             InpRecMaxLevels     = 3;            // Grid: max recovery orders
input double          InpRecStepATR       = 1.0;          // Grid: distance between orders x ATR
input double          InpRecLotMult       = 1.5;          // Grid: lot multiplier per level
input double          InpRecTargetATR     = 0.5;          // Grid: basket TP = break-even + x ATR
input double          InpRecBasketSL_ATR  = 5.0;          // Grid: hard basket SL from first entry x ATR
input bool            InpRecNeedTrend     = true;         // Grid: add only if higher-TF trend still valid
input bool            InpRecNeedConfirm   = true;         // Grid: add only after a confirming candle
input double          InpMartiMult        = 1.5;          // After loss: lot multiplier
input int             InpMartiMaxSteps    = 2;            // After loss: max steps

input group "=== Risk control / ควบคุมความเสี่ยง ==="
input int             InpMaxSpreadPts     = 30;           // Max spread (points)
input double          InpDailyTargetPct   = 3.0;          // Daily profit target % (0 = off)
input bool            InpCloseAtTarget    = false;        // Close all when daily target hit
input double          InpDailyMaxLossPct  = 5.0;          // Daily max loss % (0 = off)
input double          InpMaxDDPercent     = 15.0;         // Close all if floating loss > % balance (0 = off)
input int             InpCooldownBars     = 3;            // Bars to wait after a basket closes

input group "=== Trading hours (server) / เวลาเทรด ==="
input bool            InpUseSession       = false;        // Use trading session
input int             InpStartHour        = 8;            // Start hour
input int             InpEndHour          = 22;           // End hour
input bool            InpFridayClose      = true;         // Close all on Friday
input int             InpFridayHour       = 21;           // Friday close hour

input group "=== Dashboard / แดชบอร์ด ==="
input int             InpPanelX           = 12;           // Panel X
input int             InpPanelY           = 28;           // Panel Y
input bool            InpShowCalendar     = true;         // Show P/L calendar
input bool            InpStatsAllTrades   = false;        // Stats: whole account (false = this EA only)
input bool            InpConfirmClose     = true;         // Ask before CLOSE ALL

//--- constants ------------------------------------------------------
#define PFX          "QS_"
#define PANEL_W      330
#define CAL_W        50
#define CAL_H        40
#define CAL_GAP      3
#define REC_OFFSET   10
#define MAGIC_RANGE  40
#define FONT         "Segoe UI"
#define FONT_B       "Segoe UI Semibold"

#define C_BG         C'15,19,30'
#define C_HEADER     C'24,30,48'
#define C_CARD       C'26,33,52'
#define C_BORDER     C'45,55,85'
#define C_TEXT       C'225,230,242'
#define C_MUTED      C'125,135,165'
#define C_ACCENT     C'0,190,255'
#define C_GREEN      C'0,210,140'
#define C_RED        C'255,80,110'
#define C_GOLD       C'255,196,0'
#define C_BTN        C'38,48,75'
#define C_BTN_BUY    C'0,140,95'
#define C_BTN_SELL   C'190,45,75'
#define C_BTN_WARN   C'170,105,0'
#define C_ON         C'0,120,90'
#define C_OFF        C'100,40,58'
#define C_PROFIT_BG  C'12,66,50'
#define C_LOSS_BG    C'90,28,44'
#define C_EMPTY_BG   C'22,28,44'

//--- structures -----------------------------------------------------
struct SPos
  {
   ulong    ticket;
   long     magic;
   int      leg;      // 0,1,2 = TP1/TP2/TP3 legs, >=10 recovery
   int      dir;      // 1 buy, -1 sell
   double   vol;
   double   open;
   double   sl;
   double   tp;
   double   profit;
  };

//--- globals --------------------------------------------------------
CTrade   g_trade;
int      hEmaF = INVALID_HANDLE, hEmaS = INVALID_HANDLE, hEmaT = INVALID_HANDLE;
int      hRsi  = INVALID_HANDLE, hAdx  = INVALID_HANDLE, hAtr  = INVALID_HANDLE;

bool     g_hedging    = true;
bool     g_autoTrade  = true;
bool     g_recoveryOn = true;
bool     g_runnerOn   = true;
bool     g_showCal    = true;
bool     g_minimized  = false;
double   g_manualLot  = 0.03;

// market cache (closed bar values)
bool     g_marketOK = false;
double   g_atr = 0, g_adx = 0, g_pdi = 0, g_mdi = 0, g_rsi1 = 50, g_rsi2 = 50;
double   g_emaF = 0, g_emaS = 0, g_emaT1 = 0, g_emaT3 = 0;
int      g_trend = 0;
int      g_signal = 0;
datetime g_lastBar = 0;

// basket / recovery state
int      g_lossStreak     = 0;
int      g_prevCount[2]   = {0, 0};
datetime g_lastBasketClose = 0;

// risk lock
bool     g_dayLocked  = false;
string   g_lockReason = "";
int      g_dayOfYear  = -1;

// stats
double   g_todayPL = 0, g_weekPL = 0, g_monthPL = 0, g_dayStartBal = 0;
int      g_monthWins = 0, g_monthLosses = 0;
double   g_calPL[32];
int      g_calTrades[32];
int      g_calYear = 0, g_calMonth = 0;
bool     g_needStats = true;
datetime g_lastStats = 0;
string   g_msg = "Ready";
color    g_msgClr = C_MUTED;
uint     g_lastPanelMs = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                     |
//+------------------------------------------------------------------+
bool   IsOurMagic(const long m)  { return (m >= InpMagic && m < InpMagic + MAGIC_RANGE); }
bool   GridEnabled()             { return g_recoveryOn && g_hedging && (InpRecoveryMode == REC_GRID || InpRecoveryMode == REC_BOTH) && InpRecMaxLevels > 0; }
bool   AfterLossEnabled()        { return g_recoveryOn && (InpRecoveryMode == REC_AFTER_LOSS || InpRecoveryMode == REC_BOTH) && InpMartiMaxSteps > 0; }
double Bid()                     { return SymbolInfoDouble(_Symbol, SYMBOL_BID); }
double Ask()                     { return SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
double NP(const double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0) return NormalizeDouble(p, _Digits);
   return NormalizeDouble(MathRound(p / ts) * ts, _Digits);
  }
double MinStopDist()
  {
   long sl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long fz = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(MathMax(sl, fz) + 2) * _Point;
  }
double TPmult(const int leg)
  {
   if(leg == 0) return InpTP1_ATR;
   if(leg == 1) return InpTP2_ATR;
   return InpTP3_ATR;
  }
// "better" stop for the direction (higher for buy, lower for sell). 0 = none
double BetterSL(const double cur, const double cand, const int dir)
  {
   if(cand <= 0) return cur;
   if(cur <= 0)  return cand;
   return (dir == 1) ? MathMax(cur, cand) : MathMin(cur, cand);
  }
string Money(const double v, const bool sign = true)
  {
   string s = DoubleToString(MathAbs(v), 2);
   if(!sign) return s;
   return (v > 0 ? "+" : (v < 0 ? "-" : "")) + s;
  }
string ShortMoney(const double v)
  {
   double a = MathAbs(v);
   string s;
   if(a >= 100000)     s = DoubleToString(a / 1000.0, 0) + "k";
   else if(a >= 1000)  s = DoubleToString(a / 1000.0, 1) + "k";
   else if(a >= 100)   s = DoubleToString(a, 0);
   else                s = DoubleToString(a, 1);
   return (v > 0 ? "+" : (v < 0 ? "-" : "")) + s;
  }
color PLColor(const double v) { return v > 0 ? C_GREEN : (v < 0 ? C_RED : C_TEXT); }
void  Msg(const string s, const color c = C_MUTED) { g_msg = s; g_msgClr = c; Print("[QS] ", s); }

//--- lots -----------------------------------------------------------
double LotStep() { double s = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); return s > 0 ? s : 0.01; }
double LotMin()  { return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); }
double LotMax()  { return MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), InpMaxLot); }
int    LotDigits()
  {
   double st = LotStep();
   int d = 0;
   while(d < 8 && MathAbs(st * MathPow(10, d) - MathRound(st * MathPow(10, d))) > 1e-7) d++;
   return d;
  }
double NormLotDown(const double lot)
  {
   double st = LotStep();
   double v = MathFloor(lot / st + 1e-9) * st;
   return NormalizeDouble(v, LotDigits());
  }
double NormLot(const double lot)
  {
   double v = NormLotDown(lot);
   if(v < LotMin()) v = LotMin();
   if(v > LotMax()) v = NormLotDown(LotMax());
   return v;
  }

//--- global variables (persist entry ATR / initial volume per ticket) -
string GVName(const string tag, const ulong ticket) { return "QS" + IntegerToString(InpMagic) + "_" + tag + "_" + IntegerToString((long)ticket); }
string GVKey(const string tag)                       { return "QS" + IntegerToString(InpMagic) + "_" + _Symbol + "_" + tag; }

double EntryATR(const SPos &p)
  {
   string n = GVName("A", p.ticket);
   if(GlobalVariableCheck(n)) { double v = GlobalVariableGet(n); if(v > 0) return v; }
   if(p.leg < 3 && p.tp > 0 && TPmult(p.leg) > 0)
     {
      double d = MathAbs(p.tp - p.open) / TPmult(p.leg);
      if(d > 0) return d;
     }
   return g_atr;
  }

void CleanupGV()
  {
   string pfx = "QS" + IntegerToString(InpMagic) + "_";
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string n = GlobalVariableName(i);
      if(StringFind(n, pfx) != 0) continue;
      string rest = StringSubstr(n, StringLen(pfx));
      if(StringFind(rest, "A_") != 0 && StringFind(rest, "V_") != 0) continue;
      ulong t = (ulong)StringToInteger(StringSubstr(rest, 2));
      if(t > 0 && !PositionSelectByTicket(t)) GlobalVariableDel(n);
     }
  }

//+------------------------------------------------------------------+
//| Position collection                                               |
//+------------------------------------------------------------------+
int Collect(const int dir, SPos &arr[])
  {
   ArrayResize(arr, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long m = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(m)) continue;
      int d = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      if(dir != 0 && d != dir) continue;
      int n = ArraySize(arr);
      ArrayResize(arr, n + 1);
      arr[n].ticket = t;
      arr[n].magic  = m;
      arr[n].leg    = (int)(m - InpMagic);
      arr[n].dir    = d;
      arr[n].vol    = PositionGetDouble(POSITION_VOLUME);
      arr[n].open   = PositionGetDouble(POSITION_PRICE_OPEN);
      arr[n].sl     = PositionGetDouble(POSITION_SL);
      arr[n].tp     = PositionGetDouble(POSITION_TP);
      arr[n].profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return ArraySize(arr);
  }

int CountDir(const int dir) { SPos a[]; return Collect(dir, a); }

double Floating()
  {
   SPos a[]; int n = Collect(0, a); double s = 0;
   for(int i = 0; i < n; i++) s += a[i].profit;
   return s;
  }

//+------------------------------------------------------------------+
//| Market data                                                       |
//+------------------------------------------------------------------+
bool UpdateMarket()
  {
   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(hAtr, 0, 1, 1, a) != 1) return false; g_atr = a[0];
   if(CopyBuffer(hAdx, 0, 1, 1, a) != 1) return false; g_adx = a[0];
   if(CopyBuffer(hAdx, 1, 1, 1, a) != 1) return false; g_pdi = a[0];
   if(CopyBuffer(hAdx, 2, 1, 1, a) != 1) return false; g_mdi = a[0];
   if(CopyBuffer(hRsi, 0, 1, 2, a) != 2) return false; g_rsi1 = a[0]; g_rsi2 = a[1];
   if(CopyBuffer(hEmaF, 0, 1, 1, a) != 1) return false; g_emaF = a[0];
   if(CopyBuffer(hEmaS, 0, 1, 1, a) != 1) return false; g_emaS = a[0];
   if(CopyBuffer(hEmaT, 0, 1, 3, a) != 3) return false; g_emaT1 = a[0]; g_emaT3 = a[2];

   double c1 = iClose(_Symbol, InpSignalTF, 1);
   bool up = (g_emaF > g_emaS && c1 > g_emaT1 && g_emaT1 > g_emaT3 && g_pdi > g_mdi);
   bool dn = (g_emaF < g_emaS && c1 < g_emaT1 && g_emaT1 < g_emaT3 && g_mdi > g_pdi);
   g_trend = up ? 1 : (dn ? -1 : 0);
   g_signal = ComputeSignal();
   g_marketOK = true;
   return true;
  }

bool HTFTrendOK(const int dir)
  {
   double c1 = iClose(_Symbol, InpSignalTF, 1);
   if(dir == 1)  return (c1 > g_emaT1 && g_emaT1 >= g_emaT3);
   return (c1 < g_emaT1 && g_emaT1 <= g_emaT3);
  }

bool TrendStrong(const int dir)
  {
   if(g_adx < InpRunnerADX) return false;
   if(dir == 1)  return (g_emaF > g_emaS && g_pdi > g_mdi);
   return (g_emaF < g_emaS && g_mdi > g_pdi);
  }

int ComputeSignal()
  {
   if(g_trend == 0 || g_adx < InpADXMin || g_atr <= 0) return 0;
   double o1 = iOpen(_Symbol, InpSignalTF, 1), c1 = iClose(_Symbol, InpSignalTF, 1);
   double h1 = iHigh(_Symbol, InpSignalTF, 1), l1 = iLow(_Symbol, InpSignalTF, 1);
   if(h1 - l1 > InpMaxCandleATR * g_atr) return 0;     // spike filter
   if(g_trend == 1)
     {
      bool rsiCross  = (g_rsi2 < InpRSIBuyLevel && g_rsi1 >= InpRSIBuyLevel);
      bool emaBounce = (l1 <= g_emaF && c1 > g_emaF && c1 > o1);
      if((rsiCross || emaBounce) && g_rsi1 < 70) return 1;
     }
   else
     {
      bool rsiCross  = (g_rsi2 > InpRSISellLevel && g_rsi1 <= InpRSISellLevel);
      bool emaBounce = (h1 >= g_emaF && c1 < g_emaF && c1 < o1);
      if((rsiCross || emaBounce) && g_rsi1 > 30) return -1;
     }
   return 0;
  }

bool IsNewBar()
  {
   datetime t = iTime(_Symbol, InpSignalTF, 0);
   if(t == 0 || t == g_lastBar) return false;
   g_lastBar = t;
   return true;
  }

bool SpreadOK() { return (Ask() - Bid()) / _Point <= InpMaxSpreadPts; }

bool SessionOK()
  {
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(InpFridayClose && t.day_of_week == 5 && t.hour >= InpFridayHour) return false;
   if(!InpUseSession) return true;
   if(InpStartHour <= InpEndHour) return (t.hour >= InpStartHour && t.hour < InpEndHour);
   return (t.hour >= InpStartHour || t.hour < InpEndHour);
  }

//+------------------------------------------------------------------+
//| Lot sizing                                                        |
//+------------------------------------------------------------------+
double CalcAutoLot(const double slDist, const double atr, const bool grid)
  {
   double lot = InpFixedLot;
   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tv <= 0) tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double risk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      // worst case = first entry + every grid level all stopped at basket SL
      double weight = slDist;
      if(grid)
        {
         double step = InpRecStepATR * atr;
         for(int i = 1; i <= InpRecMaxLevels; i++)
           {
            double d = slDist - i * step;
            if(d > 0) weight += MathPow(InpRecLotMult, i) * d;
           }
        }
      double lossPerLot = (ts > 0) ? weight / ts * tv : 0;
      if(lossPerLot > 0) lot = risk / lossPerLot;
     }
   if(AfterLossEnabled() && g_lossStreak > 0)
      lot *= MathPow(InpMartiMult, MathMin(g_lossStreak, InpMartiMaxSteps));
   return NormLot(lot);
  }

// split total into TP1/TP2/TP3 legs
void SplitLots(const double total, double &lots[])
  {
   ArrayResize(lots, 3);
   lots[0] = 0; lots[1] = 0; lots[2] = 0;
   double st = LotStep();
   int U    = (int)MathRound(total / st);
   int minU = (int)MathMax(1, MathRound(LotMin() / st));
   if(!g_hedging || U < 2 * minU) { lots[2] = NormLot(total); return; }
   if(U < 3 * minU)
     {
      int u0 = (int)MathMax(minU, MathFloor(U * InpTP1_Pct / 100.0));
      if(U - u0 < minU) u0 = U - minU;
      lots[0] = NormalizeDouble(u0 * st, LotDigits());
      lots[2] = NormalizeDouble((U - u0) * st, LotDigits());
      return;
     }
   int a = (int)MathMax(minU, MathFloor(U * InpTP1_Pct / 100.0));
   int b = (int)MathMax(minU, MathFloor(U * InpTP2_Pct / 100.0));
   int c = U - a - b;
   while(c < minU && b > minU) { b--; c++; }
   while(c < minU && a > minU) { a--; c++; }
   lots[0] = NormalizeDouble(a * st, LotDigits());
   lots[1] = NormalizeDouble(b * st, LotDigits());
   lots[2] = NormalizeDouble(c * st, LotDigits());
  }

bool MarginOK(const int dir, const double lot)
  {
   double margin = 0;
   double price = (dir == 1) ? Ask() : Bid();
   if(!OrderCalcMargin(dir == 1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lot, price, margin)) return true;
   return margin < AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.95;
  }

//+------------------------------------------------------------------+
//| Trade operations                                                  |
//+------------------------------------------------------------------+
ulong SendOrder(const int dir, const double lot, const double sl, const double tp, const long magic, const string tag)
  {
   g_trade.SetExpertMagicNumber((ulong)magic);
   string cmt = InpComment + " " + tag;
   bool ok = (dir == 1) ? g_trade.Buy(lot, _Symbol, 0, sl, tp, cmt)
                        : g_trade.Sell(lot, _Symbol, 0, sl, tp, cmt);
   if(!ok || (g_trade.ResultRetcode() != TRADE_RETCODE_DONE && g_trade.ResultRetcode() != TRADE_RETCODE_PLACED))
     {
      Msg(StringFormat("Order failed %s %.2f: %d %s", dir == 1 ? "BUY" : "SELL", lot,
                       g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()), C_RED);
      return 0;
     }
   return g_trade.ResultOrder();
  }

bool OpenBasket(const int dir, const double manualTotal)
  {
   if(!g_marketOK || g_atr <= 0) { Msg("Market data not ready", C_RED); return false; }
   if(!g_hedging && CountDir(-dir) > 0) { Msg("Netting account: opposite position exists", C_RED); return false; }

   double atr    = g_atr;
   bool   grid   = GridEnabled();
   double slDist = (grid ? InpRecBasketSL_ATR : InpSL_ATR) * atr;
   double minD   = MinStopDist() + (Ask() - Bid());
   if(slDist < minD) slDist = minD;

   double total = (manualTotal > 0) ? NormLot(manualTotal) : CalcAutoLot(slDist, atr, grid);
   double lots[];
   SplitLots(total, lots);

   double sum = lots[0] + lots[1] + lots[2];
   if(!MarginOK(dir, sum)) { Msg("Not enough free margin", C_RED); return false; }

   double price = (dir == 1) ? Ask() : Bid();
   double sl    = NP(price - dir * slDist);
   int    opened = 0;
   for(int k = 0; k < 3; k++)
     {
      if(lots[k] <= 0) continue;
      double tpd = MathMax(TPmult(k) * atr, minD);
      double tp  = NP(price + dir * tpd);
      ulong t = SendOrder(dir, lots[k], sl, tp, InpMagic + k, "TP" + IntegerToString(k + 1));
      if(t > 0)
        {
         GlobalVariableSet(GVName("A", t), atr);
         GlobalVariableSet(GVName("V", t), lots[k]);
         opened++;
        }
     }
   if(opened > 0)
     {
      GlobalVariableSet(GVKey(dir == 1 ? "BS_B" : "BS_S"), (double)TimeCurrent());
      Msg(StringFormat("%s basket %.2f lot  SL %s  (streak %d)", dir == 1 ? "BUY" : "SELL", sum,
                       DoubleToString(sl, _Digits), g_lossStreak), dir == 1 ? C_GREEN : C_RED);
      g_needStats = true;
     }
   return opened > 0;
  }

bool ModifyPos(const SPos &p, double sl, double tp)
  {
   sl = NP(sl); tp = NP(tp);
   double minD  = MinStopDist();
   double bid = Bid(), ask = Ask();
   // validate against current price; keep old value if invalid
   if(p.dir == 1)
     {
      if(sl > 0 && sl > bid - minD) sl = p.sl;
      if(tp > 0 && tp < bid + minD) tp = p.tp;
     }
   else
     {
      if(sl > 0 && sl < ask + minD) sl = p.sl;
      if(tp > 0 && tp > ask - minD) tp = p.tp;
     }
   if(sl <= 0 || tp <= 0) return false;                 // never leave a position without SL/TP
   double thr = MathMax(2 * _Point, 0.03 * g_atr);
   bool chg = (MathAbs(sl - p.sl) >= thr) || (MathAbs(tp - p.tp) >= thr) || p.sl == 0 || p.tp == 0;
   if(!chg) return false;
   g_trade.SetExpertMagicNumber((ulong)p.magic);
   if(!g_trade.PositionModify(p.ticket, sl, tp))
     {
      Print("[QS] Modify failed #", p.ticket, ": ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      return false;
     }
   return true;
  }

bool ClosePos(const SPos &p)
  {
   g_trade.SetExpertMagicNumber((ulong)p.magic);
   return g_trade.PositionClose(p.ticket);
  }

// mode: 0 all, 1 buy, -1 sell, 2 profit, 3 loss
int CloseWhere(const int mode)
  {
   SPos a[]; int n = Collect(0, a), c = 0;
   for(int i = 0; i < n; i++)
     {
      bool take = (mode == 0) || (mode == 1 && a[i].dir == 1) || (mode == -1 && a[i].dir == -1) ||
                  (mode == 2 && a[i].profit > 0) || (mode == 3 && a[i].profit < 0);
      if(take && ClosePos(a[i])) c++;
     }
   g_needStats = true;
   return c;
  }

void CloseHalf()
  {
   SPos a[]; int n = Collect(0, a), c = 0;
   for(int i = 0; i < n; i++)
     {
      double half = NormLotDown(a[i].vol / 2.0);
      if(half < LotMin() || a[i].vol - half < LotMin() - 1e-9) continue;
      g_trade.SetExpertMagicNumber((ulong)a[i].magic);
      if(g_trade.PositionClosePartial(a[i].ticket, half)) c++;
     }
   Msg(StringFormat("Closed 50%% of %d position(s)", c), C_GOLD);
  }

void BreakEvenAll()
  {
   SPos a[]; int n = Collect(0, a), c = 0;
   for(int i = 0; i < n; i++)
     {
      double be  = a[i].open + a[i].dir * InpBEOffsetPts * _Point;
      double px  = (a[i].dir == 1) ? Bid() : Ask();
      if((px - be) * a[i].dir <= MinStopDist()) continue;   // not enough profit yet
      double nsl = BetterSL(a[i].sl, be, a[i].dir);
      if(ModifyPos(a[i], nsl, a[i].tp)) c++;
     }
   Msg(StringFormat("Break-even set on %d position(s)", c), C_GOLD);
  }

//+------------------------------------------------------------------+
//| Basket management                                                 |
//+------------------------------------------------------------------+
void ManageLeg(const SPos &p)
  {
   int    dir   = p.dir;
   double atrE  = EntryATR(p);
   double price = (dir == 1) ? Bid() : Ask();
   double move  = (price - p.open) * dir;
   double tp1d  = InpTP1_ATR * atrE;
   double tp2d  = InpTP2_ATR * atrE;
   double nsl   = p.sl;
   double ntp   = p.tp;

   //--- netting: virtual partial closes at TP1/TP2
   if(!g_hedging)
     {
      string vn = GVName("V", p.ticket);
      double iv = GlobalVariableCheck(vn) ? GlobalVariableGet(vn) : p.vol;
      double keep1 = NormLotDown(iv * (1.0 - InpTP1_Pct / 100.0));
      double keep2 = NormLotDown(iv * (1.0 - (InpTP1_Pct + InpTP2_Pct) / 100.0));
      double keep  = -1;
      if(move >= tp2d && keep2 >= LotMin() && p.vol - keep2 >= LotMin() - 1e-9) keep = keep2;
      else if(move >= tp1d && keep1 >= LotMin() && p.vol - keep1 >= LotMin() - 1e-9) keep = keep1;
      if(keep > 0 && p.vol - keep > 1e-9)
        {
         g_trade.SetExpertMagicNumber((ulong)p.magic);
         if(g_trade.PositionClosePartial(p.ticket, NormLotDown(p.vol - keep)))
            Msg(StringFormat("Partial take profit %.2f lot", p.vol - keep), C_GREEN);
         return;
        }
     }

   if(InpMoveBEAfterTP1 && move >= tp1d)
      nsl = BetterSL(nsl, p.open + dir * InpBEOffsetPts * _Point, dir);
   if(InpLockTP1AfterTP2 && move >= tp2d)
      nsl = BetterSL(nsl, p.open + dir * tp1d, dir);

   bool lockedTP1 = (p.sl > 0 && (p.sl - p.open) * dir >= tp1d * 0.95);
   bool runner = g_runnerOn && InpTrendRunner && (move >= tp2d || lockedTP1);
   if(runner && g_atr > 0)
     {
      bool strong = TrendStrong(dir);
      double trail = InpTrailATR * g_atr * (strong ? 1.0 : InpWeakTrailFactor);
      nsl = BetterSL(nsl, price - dir * trail, dir);
      // let profit run: keep TP3 ahead of price while trend is strong (TP always exists)
      if(strong && p.leg == 2)
        {
         double want = price + dir * InpRunnerExtendATR * g_atr;
         if((want - p.tp) * dir > 0.25 * g_atr) ntp = want;
        }
     }
   if(nsl != p.sl || ntp != p.tp) ModifyPos(p, nsl, ntp);
  }

void ManageRecoveryBasket(const int dir, SPos &a[], const int n)
  {
   double sumV = 0, sumPV = 0, atrRef = 0, basketSL = 0;
   for(int i = 0; i < n; i++)
     {
      sumV  += a[i].vol;
      sumPV += a[i].vol * a[i].open;
      if(a[i].leg < 3 && atrRef <= 0) atrRef = EntryATR(a[i]);
      if(a[i].sl > 0) basketSL = (basketSL <= 0) ? a[i].sl : ((dir == 1) ? MathMin(basketSL, a[i].sl) : MathMax(basketSL, a[i].sl));
     }
   if(sumV <= 0) return;
   if(atrRef <= 0) atrRef = g_atr;
   double be     = sumPV / sumV;
   double target = NP(be + dir * InpRecTargetATR * atrRef);
   double price  = (dir == 1) ? Bid() : Ask();

   // price already beyond target (gap / missed tick) -> take the basket profit now
   if((price - target) * dir >= 0)
     {
      for(int i = 0; i < n; i++) ClosePos(a[i]);
      Msg("Recovery basket closed in profit", C_GREEN);
      g_needStats = true;
      return;
     }
   if(basketSL <= 0) basketSL = be - dir * InpRecBasketSL_ATR * atrRef;
   for(int i = 0; i < n; i++)
      ModifyPos(a[i], basketSL, target);
  }

void ManageBasket(const int dir)
  {
   SPos a[];
   int n = Collect(dir, a);
   if(n == 0) return;
   bool hasRec = false;
   for(int i = 0; i < n; i++) if(a[i].leg >= REC_OFFSET) { hasRec = true; break; }
   if(hasRec) { ManageRecoveryBasket(dir, a, n); return; }
   for(int i = 0; i < n; i++)
     {
      // safety: a position without SL/TP gets one immediately
      if(a[i].sl == 0 || a[i].tp == 0)
        {
         double atrE = EntryATR(a[i]);
         double sl = (a[i].sl > 0) ? a[i].sl : a[i].open - a[i].dir * InpSL_ATR * atrE;
         double tp = (a[i].tp > 0) ? a[i].tp : a[i].open + a[i].dir * TPmult(MathMin(a[i].leg, 2)) * atrE;
         ModifyPos(a[i], sl, tp);
         continue;
        }
      ManageLeg(a[i]);
     }
  }

void TryRecovery(const int dir)
  {
   if(!GridEnabled() || !g_marketOK) return;
   SPos a[];
   int n = Collect(dir, a);
   if(n == 0) return;
   int    rec = 0;
   double initLots = 0, worst = 0, atrRef = 0, basketSL = 0;
   for(int i = 0; i < n; i++)
     {
      if(a[i].leg >= REC_OFFSET) rec++;
      else
        {
         initLots += a[i].vol;
         if(atrRef <= 0) atrRef = EntryATR(a[i]);
         // stage already secured (SL at BE or better) -> no recovery needed
         if(a[i].sl > 0 && (a[i].sl - a[i].open) * dir >= 0) return;
        }
      if(worst == 0 || (a[i].open - worst) * dir < 0) worst = a[i].open;
      if(a[i].sl > 0) basketSL = (basketSL <= 0) ? a[i].sl : ((dir == 1) ? MathMin(basketSL, a[i].sl) : MathMax(basketSL, a[i].sl));
     }
   if(rec >= InpRecMaxLevels) return;
   if(initLots <= 0) { for(int i = 0; i < n; i++) initLots = MathMax(initLots, a[i].vol); }
   if(atrRef <= 0) atrRef = g_atr;

   double price   = (dir == 1) ? Ask() : Bid();
   double adverse = (worst - price) * dir;
   double step    = InpRecStepATR * atrRef;
   if(adverse < step) return;
   if(basketSL > 0 && (price - basketSL) * dir < 0.5 * step) return;   // too close to hard SL
   if(InpRecNeedTrend && !HTFTrendOK(dir)) return;
   if(InpRecNeedConfirm)
     {
      double o1 = iOpen(_Symbol, InpSignalTF, 1), c1 = iClose(_Symbol, InpSignalTF, 1);
      if((c1 - o1) * dir <= 0) return;
     }
   if(!SpreadOK()) return;

   double lot = NormLot(initLots * MathPow(InpRecLotMult, rec + 1));
   if(!MarginOK(dir, lot)) { Msg("Recovery skipped: margin", C_RED); return; }
   if(basketSL <= 0) basketSL = NP(worst - dir * InpRecBasketSL_ATR * atrRef);

   // provisional TP = new break-even + target; basket sync runs next tick
   double sumV = lot, sumPV = lot * price;
   for(int i = 0; i < n; i++) { sumV += a[i].vol; sumPV += a[i].vol * a[i].open; }
   double tp = NP(sumPV / sumV + dir * InpRecTargetATR * atrRef);
   ulong t = SendOrder(dir, lot, basketSL, tp, InpMagic + REC_OFFSET + rec, "REC" + IntegerToString(rec + 1));
   if(t > 0)
     {
      GlobalVariableSet(GVName("A", t), atrRef);
      GlobalVariableSet(GVName("V", t), lot);
      Msg(StringFormat("Recovery L%d %.2f lot @ %s", rec + 1, lot, DoubleToString(price, _Digits)), C_GOLD);
     }
  }

void TryEntry()
  {
   if(!g_autoTrade || g_dayLocked || !g_marketOK) return;
   if(!SessionOK() || !SpreadOK()) return;
   if(CountDir(0) > 0) return;
   if(g_lastBasketClose > 0 && TimeCurrent() - g_lastBasketClose < InpCooldownBars * PeriodSeconds(InpSignalTF)) return;
   if(g_signal == 0) return;
   OpenBasket(g_signal, 0);
  }

//+------------------------------------------------------------------+
//| Basket close detection, loss streak                               |
//+------------------------------------------------------------------+
void OnBasketClosed(const int dir)
  {
   string key = GVKey(dir == 1 ? "BS_B" : "BS_S");
   datetime start = GlobalVariableCheck(key) ? (datetime)GlobalVariableGet(key) : TimeCurrent() - 86400;
   double res = 0;
   if(HistorySelect(start - 5, TimeCurrent() + 60))
     {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
         if(!IsOurMagic(HistoryDealGetInteger(d, DEAL_MAGIC))) continue;
         long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
         long type  = HistoryDealGetInteger(d, DEAL_TYPE);
         bool closing = (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT);
         bool sameDir = (dir == 1 && type == DEAL_TYPE_SELL) || (dir == -1 && type == DEAL_TYPE_BUY);
         if(closing && sameDir)
            res += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
        }
     }
   if(res < 0) g_lossStreak++;
   else if(res > 0) g_lossStreak = 0;
   GlobalVariableSet(GVKey("STREAK"), g_lossStreak);
   GlobalVariableDel(key);
   g_lastBasketClose = TimeCurrent();
   g_needStats = true;
   CleanupGV();
   Msg(StringFormat("%s basket closed %s  | loss streak %d", dir == 1 ? "BUY" : "SELL", Money(res), g_lossStreak),
       res >= 0 ? C_GREEN : C_RED);
  }

void DetectBasketClose()
  {
   for(int k = 0; k < 2; k++)
     {
      int dir = (k == 0) ? 1 : -1;
      int n = CountDir(dir);
      if(g_prevCount[k] > 0 && n == 0) OnBasketClosed(dir);
      g_prevCount[k] = n;
     }
  }

//+------------------------------------------------------------------+
//| Risk guards                                                       |
//+------------------------------------------------------------------+
void CheckNewDay()
  {
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(t.day_of_year != g_dayOfYear)
     {
      g_dayOfYear  = t.day_of_year;
      g_dayLocked  = false;
      g_lockReason = "";
      g_needStats  = true;
     }
  }

void Lock(const string why) { if(!g_dayLocked || g_lockReason != why) Msg("Trading locked: " + why, C_GOLD); g_dayLocked = true; g_lockReason = why; }

void RiskGuards()
  {
   double fl   = Floating();
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double base = (g_dayStartBal > 0) ? g_dayStartBal : bal;
   double day  = g_todayPL + fl;

   if(InpMaxDDPercent > 0 && fl <= -bal * InpMaxDDPercent / 100.0)
     {
      CloseWhere(0);
      Lock("MAX DRAWDOWN");
      return;
     }
   if(InpDailyMaxLossPct > 0 && day <= -base * InpDailyMaxLossPct / 100.0)
     {
      CloseWhere(0);
      Lock("DAILY MAX LOSS");
      return;
     }
   if(InpDailyTargetPct > 0 && day >= base * InpDailyTargetPct / 100.0)
     {
      if(InpCloseAtTarget && CountDir(0) > 0) CloseWhere(0);
      Lock("DAILY TARGET HIT");
     }
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(InpFridayClose && t.day_of_week == 5 && t.hour >= InpFridayHour && CountDir(0) > 0)
     {
      CloseWhere(0);
      Msg("Friday close", C_GOLD);
     }
  }

//+------------------------------------------------------------------+
//| Statistics + calendar data                                        |
//+------------------------------------------------------------------+
datetime DayStart(const datetime t) { long v = (long)t; return (datetime)(v - v % 86400); }
datetime DTMin(const datetime a, const datetime b) { return (a < b) ? a : b; }
datetime DTMax(const datetime a, const datetime b) { return (a > b) ? a : b; }

datetime MonthStart(const int y, const int m) { return StringToTime(StringFormat("%04d.%02d.01 00:00", y, m)); }

int DaysInMonth(const int y, const int m)
  {
   int ny = (m == 12) ? y + 1 : y, nm = (m == 12) ? 1 : m + 1;
   return (int)((MonthStart(ny, nm) - MonthStart(y, m)) / 86400);
  }

void RefreshStats()
  {
   datetime now = TimeCurrent();
   MqlDateTime t; TimeToStruct(now, t);
   datetime today = DayStart(now);
   datetime week  = today - ((t.day_of_week + 6) % 7) * 86400;    // Monday
   datetime month = MonthStart(t.year, t.mon);
   if(g_calYear == 0) { g_calYear = t.year; g_calMonth = t.mon; }
   datetime calFrom = MonthStart(g_calYear, g_calMonth);
   datetime calTo   = calFrom + DaysInMonth(g_calYear, g_calMonth) * 86400;

   datetime from = DTMin(DTMin(week, month), calFrom);
   datetime to   = DTMax(now + 86400, calTo);

   g_todayPL = 0; g_weekPL = 0; g_monthPL = 0; g_monthWins = 0; g_monthLosses = 0;
   ArrayInitialize(g_calPL, 0);
   ArrayInitialize(g_calTrades, 0);

   if(!HistorySelect(from, to)) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;      // skip balance/credit
      if(!InpStatsAllTrades)
        {
         if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
         if(!IsOurMagic(HistoryDealGetInteger(d, DEAL_MAGIC))) continue;
        }
      datetime dt = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      double profit = HistoryDealGetDouble(d, DEAL_PROFIT);
      double pl = profit + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      bool closing = (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT);

      if(dt >= today) g_todayPL += pl;
      if(dt >= week)  g_weekPL  += pl;
      if(dt >= month)
        {
         g_monthPL += pl;
         if(closing) { if(profit > 0) g_monthWins++; else if(profit < 0) g_monthLosses++; }
        }
      if(dt >= calFrom && dt < calTo)
        {
         MqlDateTime dd; TimeToStruct(dt, dd);
         g_calPL[dd.day] += pl;
         if(closing) g_calTrades[dd.day]++;
        }
     }
   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE) - g_todayPL;
   g_lastStats = now;
   g_needStats = false;
  }

//+------------------------------------------------------------------+
//| Chart object helpers                                              |
//+------------------------------------------------------------------+
void ObjBase(const string n)
  {
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_BACK, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
  }

void Rect(const string id, const int x, const int y, const int w, const int h, const color bg, const color border)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjBase(n);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_COLOR, border);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 0);
  }

void Label(const string id, const int x, const int y, const string text, const color clr, const int size,
           const string font, const ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_UPPER)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjBase(n);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, anchor);
   ObjectSetString(0, n, OBJPROP_TEXT, text);
   ObjectSetString(0, n, OBJPROP_FONT, font);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 1);
  }

void Button(const string id, const int x, const int y, const int w, const int h, const string text,
            const color bg, const color fg, const int size = 8)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0) ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
   ObjBase(n);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetString(0, n, OBJPROP_TEXT, text);
   ObjectSetString(0, n, OBJPROP_FONT, FONT_B);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, n, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, C_BORDER);
   ObjectSetInteger(0, n, OBJPROP_STATE, false);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 10);
  }

void SetText(const string id, const string text, const color clr = clrNONE)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) < 0) return;
   ObjectSetString(0, n, OBJPROP_TEXT, text);
   if(clr != clrNONE) ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
  }

void SetBg(const string id, const color bg)
  {
   string n = PFX + id;
   if(ObjectFind(0, n) >= 0) ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
  }

void Card(const string id, const int x, const int y, const int w, const int h, const string caption)
  {
   Rect(id, x, y, w, h, C_CARD, C_BORDER);
   Label(id + "_c", x + 8, y + 5, caption, C_MUTED, 7, FONT);
   Label(id + "_v", x + 8, y + 19, "-", C_TEXT, 11, FONT_B);
  }

void Section(const string id, const int x, const int y, const int w, const string title)
  {
   Label(id, x + 12, y, title, C_ACCENT, 8, FONT_B);
   Rect(id + "_ln", x + 12 + 8 * StringLen(title) + 6, y + 8, w - 30 - 8 * StringLen(title), 1, C_BORDER, C_BORDER);
  }

void KV(const string id, const int xl, const int xr, const int y, const string key)
  {
   Label(id + "_k", xl, y, key, C_MUTED, 8, FONT);
   Label(id + "_v", xr, y, "-", C_TEXT, 8, FONT_B, ANCHOR_RIGHT_UPPER);
  }

//+------------------------------------------------------------------+
//| Dashboard build                                                   |
//+------------------------------------------------------------------+
void BuildPanel()
  {
   ObjectsDeleteAll(0, PFX);
   int x = InpPanelX, y = InpPanelY, w = PANEL_W;

   Rect("bg", x, y, w, 100, C_BG, C_BORDER);
   Rect("hdr", x, y, w, 46, C_HEADER, C_BORDER);
   Rect("hdr_acc", x, y, 4, 46, C_ACCENT, C_ACCENT);
   Label("title", x + 14, y + 6, "QUANTUM SCALPER", C_TEXT, 12, FONT_B);
   Label("subtitle", x + 14, y + 27, _Symbol + "  |  M1 scalper  |  v1.00", C_MUTED, 7, FONT);
   Rect("pill", x + w - 128, y + 13, 92, 20, C_ON, C_ON);
   Label("pill_t", x + w - 82, y + 16, "AUTO ON", C_TEXT, 8, FONT_B, ANCHOR_UPPER);
   Button("btn_min", x + w - 30, y + 12, 22, 22, g_minimized ? "+" : "-", C_BTN, C_TEXT, 10);

   if(g_minimized)
     {
      ObjectSetInteger(0, PFX + "bg", OBJPROP_YSIZE, 46);
      ChartRedraw();
      return;
     }

   int cy = y + 54;
   int cw = (w - 24 - 12) / 3;
   string c1[3] = {"BALANCE", "EQUITY", "FLOATING P/L"};
   string c2[3] = {"TODAY", "THIS WEEK", "THIS MONTH"};
   for(int i = 0; i < 3; i++) Card("c1_" + IntegerToString(i), x + 12 + i * (cw + 6), cy, cw, 42, c1[i]);
   cy += 48;
   for(int i = 0; i < 3; i++) Card("c2_" + IntegerToString(i), x + 12 + i * (cw + 6), cy, cw, 42, c2[i]);
   cy += 50;

   Label("tgt_l", x + 12, cy, "Daily target progress", C_MUTED, 8, FONT);
   Label("tgt_v", x + w - 12, cy, "-", C_TEXT, 8, FONT_B, ANCHOR_RIGHT_UPPER);
   cy += 16;
   Rect("tgt_bg", x + 12, cy, w - 24, 6, C_CARD, C_BORDER);
   Rect("tgt_fill", x + 12, cy, 2, 6, C_GREEN, C_GREEN);
   cy += 14;

   int xl1 = x + 12, xr1 = x + w / 2 - 8, xl2 = x + w / 2 + 8, xr2 = x + w - 12;
   Section("sec_m", x, cy, w, "MARKET"); cy += 18;
   KV("m_trend", xl1, xr1, cy, "Trend");     KV("m_adx", xl2, xr2, cy, "ADX");        cy += 17;
   KV("m_rsi",   xl1, xr1, cy, "RSI");       KV("m_atr", xl2, xr2, cy, "ATR");        cy += 17;
   KV("m_spr",   xl1, xr1, cy, "Spread");    KV("m_sig", xl2, xr2, cy, "Signal");     cy += 22;

   Section("sec_p", x, cy, w, "POSITIONS"); cy += 18;
   KV("p_buy",   xl1, xr1, cy, "Buy");       KV("p_sell", xl2, xr2, cy, "Sell");      cy += 17;
   KV("p_stage", xl1, xr1, cy, "Stage");     KV("p_rec",  xl2, xr2, cy, "Recovery");  cy += 17;
   KV("p_lot",   xl1, xr1, cy, "Next lot");  KV("p_strk", xl2, xr2, cy, "Loss streak"); cy += 17;
   KV("p_win",   xl1, xr1, cy, "Win rate M"); KV("p_trd", xl2, xr2, cy, "Closed M");  cy += 22;

   Section("sec_c", x, cy, w, "CONTROLS"); cy += 18;
   int bw = (w - 24 - 12) / 3, bh = 28, bg = 5;
   int bx0 = x + 12, bx1 = bx0 + bw + 6, bx2 = bx1 + bw + 6;
   Button("btn_buy",    bx0, cy, bw, bh, "BUY",          C_BTN_BUY,  clrWhite, 9);
   Button("btn_sell",   bx1, cy, bw, bh, "SELL",         C_BTN_SELL, clrWhite, 9);
   Button("btn_close",  bx2, cy, bw, bh, "CLOSE ALL",    C_BTN_WARN, clrWhite, 8);  cy += bh + bg;
   Button("btn_cbuy",   bx0, cy, bw, bh, "CLOSE BUY",    C_BTN, C_TEXT);
   Button("btn_csell",  bx1, cy, bw, bh, "CLOSE SELL",   C_BTN, C_TEXT);
   Button("btn_be",     bx2, cy, bw, bh, "BREAK-EVEN",   C_BTN, C_GOLD);            cy += bh + bg;
   Button("btn_cprof",  bx0, cy, bw, bh, "CLOSE PROFIT", C_BTN, C_GREEN);
   Button("btn_closs",  bx1, cy, bw, bh, "CLOSE LOSS",   C_BTN, C_RED);
   Button("btn_half",   bx2, cy, bw, bh, "CLOSE 50%",    C_BTN, C_TEXT);            cy += bh + bg;
   Button("btn_auto",   bx0, cy, bw, bh, "AUTO",         C_ON,  clrWhite);
   Button("btn_rec",    bx1, cy, bw, bh, "RECOVERY",     C_ON,  clrWhite);
   Button("btn_run",    bx2, cy, bw, bh, "RUNNER",       C_ON,  clrWhite);          cy += bh + bg;
   Button("btn_lotdn",  bx0, cy, bw, bh, "LOT  -",       C_BTN, C_TEXT, 9);
   Button("btn_lot",    bx1, cy, bw, bh, "0.03",         C_CARD, C_ACCENT, 10);
   Button("btn_lotup",  bx2, cy, bw, bh, "LOT  +",       C_BTN, C_TEXT, 9);         cy += bh + bg;
   Button("btn_cal",    bx0, cy, bw, bh, "CALENDAR",     C_BTN, C_ACCENT);
   Button("btn_unlock", bx1, cy, bw, bh, "UNLOCK DAY",   C_BTN, C_TEXT);
   Button("btn_ref",    bx2, cy, bw, bh, "REFRESH",      C_BTN, C_TEXT);            cy += bh + 10;

   Rect("msg_bg", x + 12, cy, w - 24, 22, C_CARD, C_BORDER);
   Label("msg", x + 20, cy + 4, g_msg, g_msgClr, 8, FONT);
   cy += 30;
   ObjectSetInteger(0, PFX + "bg", OBJPROP_YSIZE, cy - y);

   if(g_showCal) BuildCalendar();
   UpdatePanel(true);
  }

void BuildCalendar()
  {
   int x = InpPanelX + PANEL_W + 8, y = InpPanelY;
   int w = 7 * CAL_W + 6 * CAL_GAP + 24;
   Rect("cal_bg", x, y, w, 100, C_BG, C_BORDER);
   Rect("cal_hdr", x, y, w, 46, C_HEADER, C_BORDER);
   Button("cal_prev",  x + 10,      y + 12, 26, 22, "<", C_BTN, C_TEXT, 10);
   Button("cal_today", x + 40,      y + 12, 50, 22, "TODAY", C_BTN, C_ACCENT, 7);
   Button("cal_next",  x + w - 36,  y + 12, 26, 22, ">", C_BTN, C_TEXT, 10);
   Label("cal_title", x + w / 2 + 20, y + 7, "-", C_TEXT, 11, FONT_B, ANCHOR_UPPER);
   Label("cal_sub",   x + w / 2 + 20, y + 27, "Daily profit / loss", C_MUTED, 7, FONT, ANCHOR_UPPER);

   int cy = y + 54;
   string wd[7] = {"SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"};
   for(int i = 0; i < 7; i++)
      Label("cal_wd" + IntegerToString(i), x + 12 + i * (CAL_W + CAL_GAP) + CAL_W / 2, cy, wd[i],
            (i == 0 || i == 6) ? C_GOLD : C_MUTED, 7, FONT_B, ANCHOR_UPPER);
   cy += 16;
   for(int r = 0; r < 6; r++)
      for(int c = 0; c < 7; c++)
        {
         string idx = IntegerToString(r * 7 + c);
         int cx = x + 12 + c * (CAL_W + CAL_GAP), ry = cy + r * (CAL_H + CAL_GAP);
         Rect("cal_c" + idx, cx, ry, CAL_W, CAL_H, C_EMPTY_BG, C_BORDER);
         Label("cal_d" + idx, cx + 4, ry + 2, "", C_MUTED, 7, FONT);
         Label("cal_p" + idx, cx + CAL_W / 2, ry + 15, "", C_TEXT, 8, FONT_B, ANCHOR_UPPER);
         Label("cal_n" + idx, cx + CAL_W - 4, ry + 2, "", C_MUTED, 6, FONT, ANCHOR_RIGHT_UPPER);
        }
   cy += 6 * (CAL_H + CAL_GAP) + 6;
   int sw = (w - 24 - 18) / 4;
   string cap[4] = {"MONTH P/L", "GREEN DAYS", "RED DAYS", "BEST DAY"};
   for(int i = 0; i < 4; i++) Card("cal_s" + IntegerToString(i), x + 12 + i * (sw + 6), cy, sw, 42, cap[i]);
   cy += 50;
   ObjectSetInteger(0, PFX + "cal_bg", OBJPROP_YSIZE, cy - y);
  }

//+------------------------------------------------------------------+
//| Dashboard update                                                  |
//+------------------------------------------------------------------+
string StageText(int &recLevel)
  {
   recLevel = 0;
   SPos a[]; int n = Collect(0, a);
   if(n == 0) return "FLAT";
   for(int i = 0; i < n; i++) if(a[i].leg >= REC_OFFSET) recLevel++;
   if(recLevel > 0) return "RECOVERY";
   int best = 0;
   for(int i = 0; i < n; i++)
     {
      double atrE = EntryATR(a[i]);
      double lock = (a[i].sl > 0) ? (a[i].sl - a[i].open) * a[i].dir : -1;
      int st = 0;
      if(lock >= 0) st = 1;
      if(lock >= InpTP1_ATR * atrE * 0.95) st = 2;
      best = MathMax(best, st);
     }
   if(best == 2) return "RUNNER >>";
   if(best == 1) return "TP1 + BE";
   return "OPEN";
  }

void UpdateCalendar()
  {
   if(!g_showCal || g_minimized) return;
   string mn[12] = {"JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"};
   SetText("cal_title", mn[g_calMonth - 1] + " " + IntegerToString(g_calYear));
   MqlDateTime f; TimeToStruct(MonthStart(g_calYear, g_calMonth), f);
   int first = f.day_of_week;
   int dim   = DaysInMonth(g_calYear, g_calMonth);
   MqlDateTime now; TimeToStruct(TimeCurrent(), now);
   double tot = 0, best = 0; int gd = 0, rd = 0, bestDay = 0;
   for(int i = 0; i < 42; i++)
     {
      string idx = IntegerToString(i);
      int day = i - first + 1;
      if(day < 1 || day > dim)
        {
         SetBg("cal_c" + idx, C_BG);
         ObjectSetInteger(0, PFX + "cal_c" + idx, OBJPROP_COLOR, C_BG);
         SetText("cal_d" + idx, ""); SetText("cal_p" + idx, ""); SetText("cal_n" + idx, "");
         continue;
        }
      double pl = g_calPL[day];
      int    tr = g_calTrades[day];
      bool   isToday = (now.year == g_calYear && now.mon == g_calMonth && now.day == day);
      bool   has = (tr > 0 || pl != 0);
      SetBg("cal_c" + idx, !has ? C_EMPTY_BG : (pl >= 0 ? C_PROFIT_BG : C_LOSS_BG));
      ObjectSetInteger(0, PFX + "cal_c" + idx, OBJPROP_COLOR, isToday ? C_GOLD : C_BORDER);
      SetText("cal_d" + idx, IntegerToString(day), isToday ? C_GOLD : C_MUTED);
      SetText("cal_p" + idx, has ? ShortMoney(pl) : "", pl > 0 ? C_GREEN : (pl < 0 ? C_RED : C_TEXT));
      SetText("cal_n" + idx, tr > 0 ? IntegerToString(tr) + "T" : "");
      tot += pl;
      if(has && pl > 0) gd++;
      if(has && pl < 0) rd++;
      if(pl > best) { best = pl; bestDay = day; }
     }
   SetText("cal_s0_v", Money(tot), PLColor(tot));
   SetText("cal_s1_v", IntegerToString(gd), C_GREEN);
   SetText("cal_s2_v", IntegerToString(rd), C_RED);
   SetText("cal_s3_v", bestDay > 0 ? ShortMoney(best) + " (" + IntegerToString(bestDay) + ")" : "-", bestDay > 0 ? C_GREEN : C_TEXT);
  }

void UpdatePanel(const bool force = false)
  {
   uint ms = GetTickCount();
   if(!force && ms - g_lastPanelMs < 400) return;
   g_lastPanelMs = ms;

   // status pill
   string st; color sc;
   if(g_dayLocked)        { st = "LOCKED";   sc = C_BTN_WARN; }
   else if(!g_autoTrade)  { st = "PAUSED";   sc = C_OFF; }
   else if(!SessionOK())  { st = "OFF HOURS"; sc = C_BTN; }
   else                   { st = "AUTO ON";  sc = C_ON; }
   SetBg("pill", sc); ObjectSetInteger(0, PFX + "pill", OBJPROP_COLOR, sc);
   SetText("pill_t", st);
   if(g_minimized) { ChartRedraw(); return; }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double fl  = Floating();
   SetText("c1_0_v", Money(bal, false));
   SetText("c1_1_v", Money(eq, false), eq >= bal ? C_GREEN : C_RED);
   SetText("c1_2_v", Money(fl), PLColor(fl));
   double today = g_todayPL + fl;
   SetText("c2_0_v", Money(today), PLColor(today));
   SetText("c2_1_v", Money(g_weekPL), PLColor(g_weekPL));
   SetText("c2_2_v", Money(g_monthPL), PLColor(g_monthPL));

   // target progress
   double base = (g_dayStartBal > 0) ? g_dayStartBal : bal;
   double pct  = base > 0 ? today / base * 100.0 : 0;
   if(InpDailyTargetPct > 0)
     {
      SetText("tgt_v", StringFormat("%+.2f%% / %.1f%%", pct, InpDailyTargetPct), PLColor(pct));
      double frac = MathMax(0.0, MathMin(1.0, pct / InpDailyTargetPct));
      int full = PANEL_W - 24;
      ObjectSetInteger(0, PFX + "tgt_fill", OBJPROP_XSIZE, (int)MathMax(2, frac * full));
      color fc = frac >= 1.0 ? C_GOLD : C_GREEN;
      SetBg("tgt_fill", fc); ObjectSetInteger(0, PFX + "tgt_fill", OBJPROP_COLOR, fc);
     }
   else SetText("tgt_v", StringFormat("%+.2f%%  (no target)", pct), PLColor(pct));

   // market
   SetText("m_trend_v", g_trend == 1 ? "UP" : (g_trend == -1 ? "DOWN" : "RANGE"),
           g_trend == 1 ? C_GREEN : (g_trend == -1 ? C_RED : C_MUTED));
   SetText("m_adx_v", DoubleToString(g_adx, 1) + (g_adx >= InpRunnerADX ? "  strong" : (g_adx >= InpADXMin ? "  ok" : "  weak")),
           g_adx >= InpRunnerADX ? C_GREEN : (g_adx >= InpADXMin ? C_TEXT : C_MUTED));
   SetText("m_rsi_v", DoubleToString(g_rsi1, 1));
   SetText("m_atr_v", DoubleToString(g_atr / _Point, 0) + " pts");
   double spr = (Ask() - Bid()) / _Point;
   SetText("m_spr_v", DoubleToString(spr, 0) + " pts", spr <= InpMaxSpreadPts ? C_TEXT : C_RED);
   SetText("m_sig_v", g_signal == 1 ? "BUY SETUP" : (g_signal == -1 ? "SELL SETUP" : "WAIT"),
           g_signal == 1 ? C_GREEN : (g_signal == -1 ? C_RED : C_MUTED));

   // positions
   SPos a[]; int n = Collect(0, a);
   int nb = 0, ns = 0; double lb = 0, ls = 0, pb = 0, ps = 0;
   for(int i = 0; i < n; i++)
     {
      if(a[i].dir == 1) { nb++; lb += a[i].vol; pb += a[i].profit; }
      else              { ns++; ls += a[i].vol; ps += a[i].profit; }
     }
   SetText("p_buy_v",  nb > 0 ? StringFormat("%d | %.2f | %s", nb, lb, Money(pb)) : "-", nb > 0 ? PLColor(pb) : C_MUTED);
   SetText("p_sell_v", ns > 0 ? StringFormat("%d | %.2f | %s", ns, ls, Money(ps)) : "-", ns > 0 ? PLColor(ps) : C_MUTED);
   int rl = 0;
   string stg = StageText(rl);
   SetText("p_stage_v", stg, stg == "RUNNER >>" ? C_GREEN : (stg == "RECOVERY" ? C_GOLD : C_TEXT));
   SetText("p_rec_v", GridEnabled() ? StringFormat("L%d / %d", rl, InpRecMaxLevels) : (g_recoveryOn ? "after-loss" : "OFF"),
           rl > 0 ? C_GOLD : C_TEXT);
   double nl = (g_atr > 0) ? CalcAutoLot((GridEnabled() ? InpRecBasketSL_ATR : InpSL_ATR) * g_atr, g_atr, GridEnabled()) : 0;
   SetText("p_lot_v", DoubleToString(nl, 2));
   SetText("p_strk_v", IntegerToString(g_lossStreak) + (AfterLossEnabled() ? StringFormat("  (x%.2f)", MathPow(InpMartiMult, MathMin(g_lossStreak, InpMartiMaxSteps))) : ""),
           g_lossStreak > 0 ? C_GOLD : C_TEXT);
   int tc = g_monthWins + g_monthLosses;
   SetText("p_win_v", tc > 0 ? StringFormat("%.1f%%", 100.0 * g_monthWins / tc) : "-", tc > 0 && g_monthWins * 2 >= tc ? C_GREEN : C_TEXT);
   SetText("p_trd_v", StringFormat("%dW / %dL", g_monthWins, g_monthLosses));

   // toggles
   SetBg("btn_auto", g_autoTrade ? C_ON : C_OFF);  SetText("btn_auto", g_autoTrade ? "AUTO: ON" : "AUTO: OFF");
   SetBg("btn_rec",  g_recoveryOn ? C_ON : C_OFF); SetText("btn_rec",  g_recoveryOn ? "RECOVERY: ON" : "RECOVERY: OFF");
   SetBg("btn_run",  g_runnerOn ? C_ON : C_OFF);   SetText("btn_run",  g_runnerOn ? "RUNNER: ON" : "RUNNER: OFF");
   SetText("btn_lot", DoubleToString(g_manualLot, 2));
   SetBg("btn_cal", g_showCal ? C_HEADER : C_BTN);
   SetText("msg", (g_dayLocked ? "[" + g_lockReason + "]  " : "") + g_msg, g_dayLocked ? C_GOLD : g_msgClr);

   UpdateCalendar();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Expert events                                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpTP1_Pct + InpTP2_Pct >= 100.0) { Print("TP1% + TP2% must be < 100"); return INIT_PARAMETERS_INCORRECT; }
   if(!(InpTP1_ATR < InpTP2_ATR && InpTP2_ATR < InpTP3_ATR)) { Print("Need TP1 < TP2 < TP3"); return INIT_PARAMETERS_INCORRECT; }
   if(InpRecStepATR * InpRecMaxLevels >= InpRecBasketSL_ATR)
      Print("[QS] Warning: grid step x levels >= basket SL; deepest levels will never trigger.");

   g_hedging = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(!g_hedging) Print("[QS] Netting account: single position with virtual TP1/TP2 partial close, grid recovery disabled.");

   hEmaF = iMA(_Symbol, InpSignalTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEmaS = iMA(_Symbol, InpSignalTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEmaT = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRsi  = iRSI(_Symbol, InpSignalTF, InpRSIPeriod, PRICE_CLOSE);
   hAdx  = iADX(_Symbol, InpSignalTF, InpADXPeriod);
   hAtr  = iATR(_Symbol, InpSignalTF, InpATRPeriod);
   if(hEmaF == INVALID_HANDLE || hEmaS == INVALID_HANDLE || hEmaT == INVALID_HANDLE ||
      hRsi == INVALID_HANDLE || hAdx == INVALID_HANDLE || hAtr == INVALID_HANDLE)
     { Print("Indicator init failed"); return INIT_FAILED; }

   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_autoTrade  = InpAutoTrade;
   g_recoveryOn = (InpRecoveryMode != REC_OFF);
   g_runnerOn   = InpTrendRunner;
   g_showCal    = InpShowCalendar;
   g_manualLot  = NormLot(InpManualLot);
   g_lossStreak = GlobalVariableCheck(GVKey("STREAK")) ? (int)GlobalVariableGet(GVKey("STREAK")) : 0;
   g_prevCount[0] = CountDir(1);
   g_prevCount[1] = CountDir(-1);

   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   g_calYear = t.year; g_calMonth = t.mon;
   CleanupGV();
   CheckNewDay();
   UpdateMarket();
   RefreshStats();

   ChartSetInteger(0, CHART_FOREGROUND, false);
   BuildPanel();
   EventSetMillisecondTimer(500);
   if(Period() != PERIOD_M1 && InpSignalTF == PERIOD_M1) Print("[QS] Tip: attach to an M1 chart to see the signal candles.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   IndicatorRelease(hEmaF); IndicatorRelease(hEmaS); IndicatorRelease(hEmaT);
   IndicatorRelease(hRsi);  IndicatorRelease(hAdx);  IndicatorRelease(hAtr);
   ChartRedraw();
  }

void OnTick()
  {
   CheckNewDay();
   bool nb = IsNewBar();
   if(nb || !g_marketOK) UpdateMarket();

   DetectBasketClose();
   if(g_needStats) RefreshStats();
   RiskGuards();
   ManageBasket(1);
   ManageBasket(-1);
   if(nb)
     {
      TryRecovery(1);
      TryRecovery(-1);
      TryEntry();
     }
   if(MQLInfoInteger(MQL_TESTER) && MQLInfoInteger(MQL_VISUAL_MODE)) UpdatePanel();
  }

void OnTimer()
  {
   if(g_needStats || TimeCurrent() - g_lastStats >= 5) RefreshStats();
   UpdatePanel();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) g_needStats = true;
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(StringFind(sparam, PFX) != 0) return;
   string b = StringSubstr(sparam, StringLen(PFX));
   if(ObjectGetInteger(0, sparam, OBJPROP_TYPE) == OBJ_BUTTON) ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

   if(b == "btn_buy")        OpenBasket(1, g_manualLot);
   else if(b == "btn_sell")  OpenBasket(-1, g_manualLot);
   else if(b == "btn_close")
     {
      if(!InpConfirmClose || MQLInfoInteger(MQL_TESTER) ||
         MessageBox("Close ALL positions of this EA?", "QuantumScalper", MB_YESNO | MB_ICONQUESTION) == IDYES)
         Msg(StringFormat("Closed %d position(s)", CloseWhere(0)), C_GOLD);
     }
   else if(b == "btn_cbuy")   Msg(StringFormat("Closed %d BUY", CloseWhere(1)), C_GOLD);
   else if(b == "btn_csell")  Msg(StringFormat("Closed %d SELL", CloseWhere(-1)), C_GOLD);
   else if(b == "btn_cprof")  Msg(StringFormat("Closed %d in profit", CloseWhere(2)), C_GREEN);
   else if(b == "btn_closs")  Msg(StringFormat("Closed %d in loss", CloseWhere(3)), C_RED);
   else if(b == "btn_be")     BreakEvenAll();
   else if(b == "btn_half")   CloseHalf();
   else if(b == "btn_auto")   { g_autoTrade = !g_autoTrade;   Msg(g_autoTrade ? "Auto trading ON" : "Auto trading OFF"); }
   else if(b == "btn_rec")
     {
      if(InpRecoveryMode == REC_OFF) Msg("Recovery mode is OFF in inputs", C_GOLD);
      else { g_recoveryOn = !g_recoveryOn; Msg(g_recoveryOn ? "Recovery ON" : "Recovery OFF"); }
     }
   else if(b == "btn_run")    { g_runnerOn = !g_runnerOn;     Msg(g_runnerOn ? "Trend runner ON" : "Trend runner OFF"); }
   else if(b == "btn_lotdn")  g_manualLot = NormLot(g_manualLot - LotStep());
   else if(b == "btn_lotup")  g_manualLot = NormLot(g_manualLot + LotStep());
   else if(b == "btn_unlock") { g_dayLocked = false; g_lockReason = ""; Msg("Day lock cleared"); }
   else if(b == "btn_ref")    { g_needStats = true; UpdateMarket(); RefreshStats(); }
   else if(b == "btn_cal")    { g_showCal = !g_showCal; BuildPanel(); return; }
   else if(b == "btn_min")    { g_minimized = !g_minimized; BuildPanel(); return; }
   else if(b == "cal_prev")   { g_calMonth--; if(g_calMonth < 1)  { g_calMonth = 12; g_calYear--; } RefreshStats(); }
   else if(b == "cal_next")   { g_calMonth++; if(g_calMonth > 12) { g_calMonth = 1;  g_calYear++; } RefreshStats(); }
   else if(b == "cal_today")  { MqlDateTime t; TimeToStruct(TimeCurrent(), t); g_calYear = t.year; g_calMonth = t.mon; RefreshStats(); }
   else return;
   UpdatePanel(true);
  }
//+------------------------------------------------------------------+

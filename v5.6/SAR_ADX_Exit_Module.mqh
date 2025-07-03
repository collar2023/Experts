//+------------------------------------------------------------------+
//|                                     SAR_ADX_Exit_Module.mqh       |
//|        动态R倍数 + SAR/ADX 协同出场模块 v3.0 (2025-07-01)         |
//|  • 核心升级: 引入“动态R倍数”止盈，由ADX值协同调整止盈目标。      |
//|  • 增强盈利: 强趋势时放大盈利目标，弱趋势时提前锁定利润。        |
//|  • 继承修复: 完整保留v2.1版本对ATR后备计算的所有安全修复。       |
//+------------------------------------------------------------------+

#property strict

//==================================================================
//  输入参数 (v3.0 核心升级)
//==================================================================

input group    "--- Reversal Exit Settings (SAR & ADX) ---"
input bool     UseSARReversal   = false;     // [开关] 是否使用SAR反转信号平全仓
input bool     UseADXFilter     = true;     // [开关] SAR信号是否需要ADX确认
input double   SAR_Step         = 0.02;     // SAR 步长
input double   SAR_Maximum      = 0.2;      // SAR 最大值
input int      ADX_Period       = 10;       // ADX 周期
input double   ADX_MinLevel     = 25.0;     // ADX 最小阈值 (用于确认趋势)
input double   SAR_MinRRatio    = 1.5;      // SAR信号生效的最小R倍数
input int      ATR_Period       = 10;       // ATR周期 (当SL失效时使用)

input group    "--- Step Take Profit Settings (RRR) ---"
input bool     EnableStepTP     = true;     // [开关] 是否启用分步止盈
input double   RRratio          = 2.0;      // 基础风险回报比 (用于TP1)
input double   Step1Pct         = 40.0;     // TP1 平仓百分比
input double   Step2Pct         = 30.0;     // TP2 平仓百分比
input double   Step2Factor      = 1.5;      // TP2 触发因子 (实际RRR = RRratio * Step2Factor)

// ★★★ v3.0 新增参数 ★★★
input group    "--- Dynamic RRR Settings (ADX Synergy) ---"
input bool     Enable_Dynamic_RRR   = true;   // [总开关] 是否启用动态R倍数功能
input double   ADX_Strong_Threshold = 40.0;   // ADX极强趋势的阈值
input double   Strong_Trend_Factor  = 1.5;    // 极强趋势下，R倍数目标的放大因子
input double   ADX_Weak_Threshold   = 20.0;   // ADX趋势减弱的阈值
input double   Weak_Trend_Factor    = 0.75;   // 趋势减弱时，R倍数目标的缩小因子


//==================================================================
//  全局变量与枚举 (无修改)
//==================================================================

int sar_handle_exit = INVALID_HANDLE;
int adx_handle_exit = INVALID_HANDLE;
int atr_handle_exit = INVALID_HANDLE;

enum EXIT_REASON { NO_EXIT, EXIT_LONG, EXIT_SHORT };

//==================================================================
//  模块初始化与清理函数 (无修改)
//==================================================================

bool InitExitModule(const string symbol, const ENUM_TIMEFRAMES period)
{
   sar_handle_exit = iSAR(symbol, period, SAR_Step, SAR_Maximum);
   if(sar_handle_exit == INVALID_HANDLE) { Print("出场模块: SAR指标初始化失败. Error: ", GetLastError()); return false; }
   
   adx_handle_exit = iADX(symbol, period, ADX_Period);
   if(adx_handle_exit == INVALID_HANDLE) { Print("出场模块: ADX指标初始化失败. Error: ", GetLastError()); return false; }
   
   atr_handle_exit = iATR(symbol, period, ATR_Period);
   if(atr_handle_exit == INVALID_HANDLE) { Print("出场模块: ATR指标初始化失败. Error: ", GetLastError()); return false; }
   
   Print("动态R倍数+SAR/ADX 协同出场模块 v3.0 初始化成功");
   return true;
}

void DeinitExitModule()
{
   if(sar_handle_exit != INVALID_HANDLE) IndicatorRelease(sar_handle_exit);
   if(adx_handle_exit != INVALID_HANDLE) IndicatorRelease(adx_handle_exit);
   if(atr_handle_exit != INVALID_HANDLE) IndicatorRelease(atr_handle_exit);
}

//==================================================================
//  辅助计算函数 (v3.0 核心升级)
//==================================================================

// 计算交易逻辑的R倍数风险单位 (v2.1版，已修复)
double CalculateRiskUnit(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
   double riskPoints = 0.0;
   if(originalSL > 0)
   {
      riskPoints = (posType == POSITION_TYPE_BUY) ? (openPrice - originalSL) : (originalSL - openPrice);
      riskPoints /= _Point;
   }
   if(riskPoints <= 0)
   {
      double atr[1];
      if(atr_handle_exit != INVALID_HANDLE && CopyBuffer(atr_handle_exit, 0, 1, 1, atr) == 1 && atr[0] > 0)
      {
         double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(refPrice > 0 && atr[0] < refPrice)
         {
            riskPoints = atr[0] / _Point;
         }
      }
   }
   return riskPoints;
}

// 计算当前盈利的R倍数
double CalculateCurrentRMultiple(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
   if(openPrice <= 0) return 0.0;
   double riskPoints = CalculateRiskUnit(openPrice, originalSL, posType);
   if(riskPoints <= 0) return 0.0;
   double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitPoints = (posType == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
   return profitPoints / riskPoints;
}

//+------------------------------------------------------------------+
//| ★ v3.0 新增: 获取动态调整后的R倍数目标                         |
//+------------------------------------------------------------------+
double GetDynamicRRR_Target(double baseRRR)
{
   if(!Enable_Dynamic_RRR) return baseRRR;

   double adx_value[1];
   if(adx_handle_exit == INVALID_HANDLE || CopyBuffer(adx_handle_exit, MAIN_LINE, 0, 1, adx_value) < 1)
   {
      return baseRRR;
   }
   
   if(adx_value[0] >= ADX_Strong_Threshold)
   {
      // 返回一个放大的目标
      return baseRRR * Strong_Trend_Factor;
   }
   else if(adx_value[0] < ADX_Weak_Threshold)
   {
      // 返回一个缩小的目标
      return baseRRR * Weak_Trend_Factor;
   }
   
   return baseRRR;
}

//==================================================================
//  模块核心逻辑 (v3.0 核心升级)
//==================================================================

EXIT_REASON GetReversalSignal(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
    double sar[3];
    if(CopyBuffer(sar_handle_exit, 0, 0, 3, sar) < 3) return NO_EXIT;
    bool trend_is_up_on_bar1 = iLow(_Symbol, _Period, 1) > sar[1];
    bool trend_is_up_on_bar2 = iLow(_Symbol, _Period, 2) > sar[2];
    if(trend_is_up_on_bar1 == trend_is_up_on_bar2) return NO_EXIT;
    static datetime last_reversal_time = 0;
    datetime signal_bar_time = (datetime)iTime(_Symbol, _Period, 1);
    if(signal_bar_time <= last_reversal_time) return NO_EXIT;
    EXIT_REASON reason = trend_is_up_on_bar1 ? EXIT_SHORT : EXIT_LONG;
    double currentRMultiple = CalculateCurrentRMultiple(openPrice, originalSL, posType);
    if(currentRMultiple < SAR_MinRRatio) return NO_EXIT;
    if(UseADXFilter)
    {
        double adx[2], plus[2], minus[2];
        if(CopyBuffer(adx_handle_exit, MAIN_LINE, 0, 2, adx) < 2 || CopyBuffer(adx_handle_exit, PLUSDI_LINE, 0, 2, plus) < 2 || CopyBuffer(adx_handle_exit, MINUSDI_LINE, 0, 2, minus) < 2) return NO_EXIT;
        bool isStrong = adx[1] > ADX_MinLevel;
        bool isWeakening = adx[1] < adx[0]; 
        bool di_cross_confirms_exit_long = (minus[1] > plus[1]);
        bool di_cross_confirms_exit_short = (plus[1] > minus[1]);
        if(reason == EXIT_LONG && posType == POSITION_TYPE_BUY) { if(!(isStrong && (isWeakening || di_cross_confirms_exit_long))) return NO_EXIT; }
        if(reason == EXIT_SHORT && posType == POSITION_TYPE_SELL) { if(!(isStrong && (isWeakening || di_cross_confirms_exit_short))) return NO_EXIT; }
    }
    last_reversal_time = signal_bar_time;
    return reason;
}

//+------------------------------------------------------------------+
//| 主函数：获取多头出场指令 (v3.0 动态R倍数版)                     |
//+------------------------------------------------------------------+
double GetLongExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   if(UseSARReversal && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_BUY) == EXIT_LONG)
   {
      Print("SAR反转信号(收盘确认): 触发多头平仓.");
      return 100.0;
   }

   if(EnableStepTP)
   {
      if(openPrice <= 0 || RRratio <= 0) return 0.0;
      double riskPts = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_BUY);
      if(riskPts <= 0) return 0.0;
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profitPts = (currentPrice - openPrice) / _Point;

      // ★★★ 核心修改: 计算并使用动态目标 ★★★
      double dynamic_target_1_rr = GetDynamicRRR_Target(RRratio);
      double dynamic_target_2_rr = GetDynamicRRR_Target(RRratio * Step2Factor);

      if(!step2Done && Step2Pct > 0 && profitPts >= riskPts * dynamic_target_2_rr) 
      {
         // Print("动态R倍数止盈2触发: 目标 " + DoubleToString(dynamic_target_2_rr,2) + "R"); // 可以在主文件日志中体现
         step2Done = true;
         return Step2Pct;
      }
      if(!step1Done && Step1Pct > 0 && profitPts >= riskPts * dynamic_target_1_rr) 
      {
         // Print("动态R倍数止盈1触发: 目标 " + DoubleToString(dynamic_target_1_rr,2) + "R"); // 可以在主文件日志中体现
         step1Done = true;
         return Step1Pct;
      }
   }
   return 0.0;
}

//+------------------------------------------------------------------+
//| 主函数：获取空头出场指令 (v3.0 动态R倍数版)                     |
//+------------------------------------------------------------------+
double GetShortExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   if(UseSARReversal && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_SELL) == EXIT_SHORT)
   {
      Print("SAR反转信号(收盘确认): 触发空头平仓.");
      return 100.0;
   }

   if(EnableStepTP)
   {
      if(openPrice <= 0 || RRratio <= 0) return 0.0;
      double riskPts = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_SELL);
      if(riskPts <= 0) return 0.0;
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = (openPrice - currentPrice) / _Point;

      // ★★★ 核心修改: 计算并使用动态目标 ★★★
      double dynamic_target_1_rr = GetDynamicRRR_Target(RRratio);
      double dynamic_target_2_rr = GetDynamicRRR_Target(RRratio * Step2Factor);

      if(!step2Done && Step2Pct > 0 && profitPts >= riskPts * dynamic_target_2_rr) 
      {
         // Print("动态R倍数止盈2触发: 目标 " + DoubleToString(dynamic_target_2_rr,2) + "R");
         step2Done = true;
         return Step2Pct;
      }
      if(!step1Done && Step1Pct > 0 && profitPts >= riskPts * dynamic_target_1_rr) 
      {
         // Print("动态R倍数止盈1触发: 目标 " + DoubleToString(dynamic_target_1_rr,2) + "R");
         step1Done = true;
         return Step1Pct;
      }
   }
   return 0.0;
}
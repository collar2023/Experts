//+------------------------------------------------------------------+
//|                                     SAR_ADX_Exit_Module.mqh       |
//|          SAR/ADX 离场模块 v6.1 (编译修复版)                    |
//+------------------------------------------------------------------+

#property strict

//==================================================================
//  模块内部全局变量
//==================================================================

static SSarAdxExitInputs g_module_sarAdxInputs; // ★ 用于存储传入的参数
static int sar_handle_exit = INVALID_HANDLE;
static int adx_handle_exit = INVALID_HANDLE;
static int atr_handle_exit = INVALID_HANDLE;
extern CLogModule* g_Logger; // ★ 声明外部全局变量

enum EXIT_REASON { NO_EXIT, EXIT_LONG, EXIT_SHORT };

//==================================================================
//  模块初始化与清理函数
//==================================================================

bool InitExitModule(const string symbol, const ENUM_TIMEFRAMES period, const SSarAdxExitInputs &inputs)
{
   g_module_sarAdxInputs = inputs; // ★ 保存传入的参数

   sar_handle_exit = iSAR(symbol, period, g_module_sarAdxInputs.sarStep, g_module_sarAdxInputs.sarMaximum);
   if(sar_handle_exit == INVALID_HANDLE) { if(g_Logger) g_Logger.WriteError("出场模块: SAR指标初始化失败."); return false; }
   
   adx_handle_exit = iADX(symbol, period, g_module_sarAdxInputs.adxPeriod);
   if(adx_handle_exit == INVALID_HANDLE) { if(g_Logger) g_Logger.WriteError("出场模块: ADX指标初始化失败."); return false; }
   
   atr_handle_exit = iATR(symbol, period, g_module_sarAdxInputs.atrPeriod);
   if(atr_handle_exit == INVALID_HANDLE) { if(g_Logger) g_Logger.WriteError("出场模块: ATR指标初始化失败."); return false; }
   
   if(g_Logger) g_Logger.WriteInfo("动态R倍数+SAR/ADX 协同出场模块 v6.0 初始化成功");
   return true;
}

void DeinitExitModule()
{
   if(sar_handle_exit != INVALID_HANDLE) IndicatorRelease(sar_handle_exit);
   if(adx_handle_exit != INVALID_HANDLE) IndicatorRelease(adx_handle_exit);
   if(atr_handle_exit != INVALID_HANDLE) IndicatorRelease(atr_handle_exit);
}

//==================================================================
//  辅助计算函数
//==================================================================

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

double CalculateCurrentRMultiple(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
   if(openPrice <= 0) return 0.0;
   double riskPoints = CalculateRiskUnit(openPrice, originalSL, posType);
   if(riskPoints <= 0) return 0.0;
   double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitPoints = (posType == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
   return profitPoints / riskPoints;
}

double GetDynamicRRR_Target(double baseRRR)
{
   if(!g_module_sarAdxInputs.enableDynamicRRR) return baseRRR;

   double adx_value[1];
   if(adx_handle_exit == INVALID_HANDLE || CopyBuffer(adx_handle_exit, MAIN_LINE, 0, 1, adx_value) < 1)
   {
      return baseRRR;
   }
   
   if(adx_value[0] >= g_module_sarAdxInputs.adxStrongThreshold)
   {
      return baseRRR * g_module_sarAdxInputs.strongTrendFactor;
   }
   else if(adx_value[0] < g_module_sarAdxInputs.adxWeakThreshold)
   {
      return baseRRR * g_module_sarAdxInputs.weakTrendFactor;
   }
   
   return baseRRR;
}

//==================================================================
//  模块核心逻辑
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
    if(currentRMultiple < g_module_sarAdxInputs.sarMinRRatio) return NO_EXIT;
    if(g_module_sarAdxInputs.useADXFilter)
    {
        double adx[2], plus[2], minus[2];
        if(CopyBuffer(adx_handle_exit, MAIN_LINE, 0, 2, adx) < 2 || CopyBuffer(adx_handle_exit, PLUSDI_LINE, 0, 2, plus) < 2 || CopyBuffer(adx_handle_exit, MINUSDI_LINE, 0, 2, minus) < 2) return NO_EXIT;
        bool isStrong = adx[1] > g_module_sarAdxInputs.adxMinLevel;
        bool isWeakening = adx[1] < adx[0]; 
        bool di_cross_confirms_exit_long = (minus[1] > plus[1]);
        bool di_cross_confirms_exit_short = (plus[1] > minus[1]);
        if(reason == EXIT_LONG && posType == POSITION_TYPE_BUY) { if(!(isStrong && (isWeakening || di_cross_confirms_exit_long))) return NO_EXIT; }
        if(reason == EXIT_SHORT && posType == POSITION_TYPE_SELL) { if(!(isStrong && (isWeakening || di_cross_confirms_exit_short))) return NO_EXIT; }
    }
    last_reversal_time = signal_bar_time;
    return reason;
}

double GetLongExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   if(g_module_sarAdxInputs.useSARReversal && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_BUY) == EXIT_LONG)
   {
      return 100.0;
   }

   if(g_module_sarAdxInputs.enableStepTP)
   {
      if(openPrice <= 0 || g_module_sarAdxInputs.rrRatio <= 0) return 0.0;
      double riskPts = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_BUY);
      if(riskPts <= 0) return 0.0;
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profitPts = (currentPrice - openPrice) / _Point;

      double dynamic_target_1_rr = GetDynamicRRR_Target(g_module_sarAdxInputs.rrRatio);
      double dynamic_target_2_rr = GetDynamicRRR_Target(g_module_sarAdxInputs.rrRatio * g_module_sarAdxInputs.step2Factor);

      if(!step2Done && g_module_sarAdxInputs.step2Pct > 0 && profitPts >= riskPts * dynamic_target_2_rr) 
      {
         step2Done = true;
         return g_module_sarAdxInputs.step2Pct;
      }
      if(!step1Done && g_module_sarAdxInputs.step1Pct > 0 && profitPts >= riskPts * dynamic_target_1_rr) 
      {
         step1Done = true;
         return g_module_sarAdxInputs.step1Pct;
      }
   }
   return 0.0;
}

double GetShortExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   if(g_module_sarAdxInputs.useSARReversal && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_SELL) == EXIT_SHORT)
   {
      return 100.0;
   }

   if(g_module_sarAdxInputs.enableStepTP)
   {
      if(openPrice <= 0 || g_module_sarAdxInputs.rrRatio <= 0) return 0.0;
      double riskPts = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_SELL);
      if(riskPts <= 0) return 0.0;
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = (openPrice - currentPrice) / _Point;

      double dynamic_target_1_rr = GetDynamicRRR_Target(g_module_sarAdxInputs.rrRatio);
      double dynamic_target_2_rr = GetDynamicRRR_Target(g_module_sarAdxInputs.rrRatio * g_module_sarAdxInputs.step2Factor);

      if(!step2Done && g_module_sarAdxInputs.step2Pct > 0 && profitPts >= riskPts * dynamic_target_2_rr) 
      {
         step2Done = true;
         return g_module_sarAdxInputs.step2Pct;
      }
      if(!step1Done && g_module_sarAdxInputs.step1Pct > 0 && profitPts >= riskPts * dynamic_target_1_rr) 
      {
         step1Done = true;
         return g_module_sarAdxInputs.step1Pct;
      }
   }
   return 0.0;
}
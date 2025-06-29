//+------------------------------------------------------------------+
//|                                     SAR_ADX_Exit_Module.mqh       |
//|        SAR+ADX联合出场 与 RRR分步止盈 整合出场模块             |
//|          (修复版: 适配紧急止损保护机制)                        |
//+------------------------------------------------------------------+

#property strict

//==================================================================
//  输入参数
//==================================================================

input group    "--- Reversal Exit Settings (SAR & ADX) ---"
input bool     UseSARReversal   = true;     // [开关] 是否使用SAR反转信号平全仓
input bool     UseADXFilter     = true;     // [开关] SAR信号是否需要ADX确认
input double   SAR_Step         = 0.02;     // SAR 步长
input double   SAR_Maximum      = 0.2;      // SAR 最大值
input int      ADX_Period       = 14;       // ADX 周期
input double   ADX_MinLevel     = 25.0;     // ADX 最小阈值 (用于确认趋势)
input double   SAR_MinRRatio    = 1.5;      // SAR信号生效的最小R倍数
input int      ATR_Period       = 14;       // ATR周期 (当SL失效时使用)

input group    "--- Step Take Profit Settings (RRR) ---"
input bool     EnableStepTP     = true;     // [开关] 是否启用分步止盈
input double   RRratio          = 2.0;      // 基础风险回报比 (用于TP1)
input double   Step1Pct         = 40.0;     // TP1 平仓百分比
input double   Step2Pct         = 30.0;     // TP2 平仓百分比
input double   Step2Factor      = 1.5;      // TP2 触发因子 (实际RRR = RRratio * Step2Factor)

input group    "--- Emergency SL Adaptation ---"
// 注意：紧急止损是安全保护机制，与交易逻辑的R倍数计算分离

//==================================================================
//  全局变量与枚举
//==================================================================

int sar_handle_exit = INVALID_HANDLE;
int adx_handle_exit = INVALID_HANDLE;
int atr_handle_exit = INVALID_HANDLE;

enum EXIT_REASON { NO_EXIT, EXIT_LONG, EXIT_SHORT };

//==================================================================
//  模块核心功能函数
//==================================================================

bool InitExitModule(const string symbol, const ENUM_TIMEFRAMES period)
{
   sar_handle_exit = iSAR(symbol, period, SAR_Step, SAR_Maximum);
   if(sar_handle_exit == INVALID_HANDLE) 
   {
      Print("出场模块: SAR指标初始化失败. Error: ", GetLastError());
      return false;
   }
   
   adx_handle_exit = iADX(symbol, period, ADX_Period);
   if(adx_handle_exit == INVALID_HANDLE) 
   {
      Print("出场模块: ADX指标初始化失败. Error: ", GetLastError());
      return false;
   }
   
   atr_handle_exit = iATR(symbol, period, ATR_Period);
   if(atr_handle_exit == INVALID_HANDLE) 
   {
      Print("出场模块: ATR指标初始化失败. Error: ", GetLastError());
      return false;
   }
   
   Print("SAR+ADX+StepTP 统一出场模块初始化成功 (适配紧急止损保护)");
   return true;
}

void DeinitExitModule()
{
   if(sar_handle_exit != INVALID_HANDLE) IndicatorRelease(sar_handle_exit);
   if(adx_handle_exit != INVALID_HANDLE) IndicatorRelease(adx_handle_exit);
   if(atr_handle_exit != INVALID_HANDLE) IndicatorRelease(atr_handle_exit);
}

// 计算交易逻辑的R倍数风险单位 (与止损保护系统分离)
double CalculateRiskUnit(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
   double riskPoints = 0.0;
   
   // 只使用原始交易计划的SL计算R倍数
   if(originalSL > 0)
   {
      if(posType == POSITION_TYPE_BUY)
         riskPoints = (openPrice - originalSL) / _Point;
      else
         riskPoints = (originalSL - openPrice) / _Point;
   }
   
   // 如果原始SL无效，使用ATR作为默认风险单位 (但这与紧急止损无关)
   if(riskPoints <= 0)
   {
      double atr[1];
      if(CopyBuffer(atr_handle_exit, 0, 1, 1, atr) >= 1)
      {
         riskPoints = atr[0] / _Point;  // 标准1倍ATR，不是紧急止损的2倍
      }
   }
   
   return riskPoints;
}

// 计算当前盈利的R倍数 (修复版)
double CalculateCurrentRMultiple(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
   if(openPrice <= 0) return 0.0;
   
   double riskPoints = CalculateRiskUnit(openPrice, originalSL, posType);
   if(riskPoints <= 0) return 0.0;
   
   // 计算当前盈利点数
   double currentPrice = (posType == POSITION_TYPE_BUY) 
                        ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double profitPoints = 0.0;
   if(posType == POSITION_TYPE_BUY)
      profitPoints = (currentPrice - openPrice) / _Point;
   else
      profitPoints = (openPrice - currentPrice) / _Point;
   
   return profitPoints / riskPoints;
}

// 判断是否为紧急止损 (通过比较当前SL与原始SL)
// 注意：这个函数现在仅用于日志记录，不影响交易逻辑
bool IsEmergencyStopLoss(const double originalSL)
{
   if(originalSL <= 0) return true;  // 原始SL无效，必定是紧急SL
   
   double currentSL = PositionGetDouble(POSITION_SL);
   if(currentSL <= 0) return false;  // 当前无SL
   
   // 比较差异：如果当前SL与原始SL差异超过阈值，认为是紧急SL
   double slDiff = MathAbs(currentSL - originalSL);
   double atr[1];
   if(CopyBuffer(atr_handle_exit, 0, 1, 1, atr) >= 1)
   {
      double atrThreshold = atr[0] * 0.5;  // 0.5ATR作为判断阈值
      return slDiff > atrThreshold;
   }
   
   return false;
}

// 内部逻辑：获取反转信号 (适配紧急止损)
EXIT_REASON GetReversalSignal(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
   double sar[2];
   if(CopyBuffer(sar_handle_exit, 0, 0, 2, sar) < 2) return NO_EXIT;

   double high_prev = iHigh(_Symbol, _Period, 1);
   double low_prev = iLow(_Symbol, _Period, 1);
   double high_curr = iHigh(_Symbol, _Period, 0);
   double low_curr = iLow(_Symbol, _Period, 0);

   bool sarReversedToDown = (high_prev > sar[1] && low_curr < sar[0]);
   bool sarReversedToUp = (low_prev < sar[1] && high_curr > sar[0]);

   if(!sarReversedToDown && !sarReversedToUp) return NO_EXIT;
   
   EXIT_REASON reason = sarReversedToDown ? EXIT_LONG : EXIT_SHORT;
   
// 检查R倍数条件 (基于原始交易逻辑，与紧急止损无关)
   double currentRMultiple = CalculateCurrentRMultiple(openPrice, originalSL, posType);
   if(currentRMultiple < SAR_MinRRatio) return NO_EXIT;

   if(UseADXFilter)
   {
      double adx[2], plus[2], minus[2];
      if(CopyBuffer(adx_handle_exit, MAIN_LINE, 0, 2, adx) < 2 ||
         CopyBuffer(adx_handle_exit, PLUSDI_LINE, 0, 2, plus) < 2 ||
         CopyBuffer(adx_handle_exit, MINUSDI_LINE, 0, 2, minus) < 2) 
         return NO_EXIT;

      bool isStrong = adx[0] > ADX_MinLevel;
      bool isWeakening = adx[0] < adx[1];
      
      if(reason == EXIT_LONG && isStrong && (isWeakening || (minus[0] > plus[0] && minus[1] <= plus[1]))) return EXIT_LONG;
      if(reason == EXIT_SHORT && isStrong && (isWeakening || (plus[0] > minus[0] && plus[1] <= minus[1]))) return EXIT_SHORT;
      
      return NO_EXIT;
   }
   
   return reason;
}

// 主函数：获取多头出场指令 (修复版)
double GetLongExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   // 1. SAR反转信号触发，直接全平
   if(UseSARReversal && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_BUY) == EXIT_LONG)
      return 100.0;

   // 2. 分步止盈逻辑 (使用智能风险单位计算)
   if(EnableStepTP)
   {
      if(openPrice <= 0 || RRratio <= 0)
         return 0.0;

      double riskPts = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_BUY);
      if(riskPts <= 0)
         return 0.0;

      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profitPts = (currentPrice - openPrice) / _Point;

      // TP2优先判断
      if(!step2Done && Step2Pct > 0 && profitPts >= riskPts * RRratio * Step2Factor) 
      {
         step2Done = true;
         return Step2Pct;
      }
      // TP1判断
      if(!step1Done && Step1Pct > 0 && profitPts >= riskPts * RRratio) 
      {
         step1Done = true;
         return Step1Pct;
      }
   }
   return 0.0;
}

// 主函数：获取空头出场指令 (修复版)
double GetShortExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   // 1. SAR反转信号触发，直接全平
   if(UseSARReversal && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_SELL) == EXIT_SHORT)
      return 100.0;

   // 2. 分步止盈逻辑 (使用智能风险单位计算)
   if(EnableStepTP)
   {
      if(openPrice <= 0 || RRratio <= 0)
         return 0.0;

      double riskPts = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_SELL);
      if(riskPts <= 0)
         return 0.0;

      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = (openPrice - currentPrice) / _Point;

      // TP2优先判断
      if(!step2Done && Step2Pct > 0 && profitPts >= riskPts * RRratio * Step2Factor) 
      {
         step2Done = true;
         return Step2Pct;
      }
      // TP1判断
      if(!step1Done && Step1Pct > 0 && profitPts >= riskPts * RRratio) 
      {
         step1Done = true;
         return Step1Pct;
      }
   }
   return 0.0;
}
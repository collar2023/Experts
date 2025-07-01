//+------------------------------------------------------------------+
//|                                     SAR_ADX_Exit_Module.mqh      |
//|        SAR+ADX联合出场 与 RRR分步止盈 整合出场模块 v2.3          |
//|       (核心升级: 修复ATR天文数字Bug + 增加止损合法性校验)        |
//+------------------------------------------------------------------+

#property strict

//==================================================================
//  全局控制开关（建议主EA里 OnInit 动态赋值）
//==================================================================
bool g_SARReversalEnabled = false;  // 是否启用SAR反转出场信号
bool g_ADXFilterEnabled   = true;
//==================================================================
//  输入参数（保留其余参数）
//==================================================================
input group    "--- SAR+ADX 指标参数 ---"
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

//==================================================================
//  全局变量与枚举
//==================================================================
int sar_handle_exit = INVALID_HANDLE;
int adx_handle_exit = INVALID_HANDLE;
int atr_handle_exit = INVALID_HANDLE;

enum EXIT_REASON { NO_EXIT, EXIT_LONG, EXIT_SHORT };

//==================================================================
//  模块初始化与清理函数（无修改）
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
   
   Print("SAR+ADX+StepTP 出场模块初始化成功.");
   return true;
}

void DeinitExitModule()
{
   if(sar_handle_exit != INVALID_HANDLE) IndicatorRelease(sar_handle_exit);
   if(adx_handle_exit != INVALID_HANDLE) IndicatorRelease(adx_handle_exit);
   if(atr_handle_exit != INVALID_HANDLE) IndicatorRelease(atr_handle_exit);
}

//==================================================================
//  计算风险单位（已修复ATR天文数字问题，新增安全检测）
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
      if(atr_handle_exit != INVALID_HANDLE &&
         CopyBuffer(atr_handle_exit, 0, 1, 1, atr) == 1 &&
         atr[0] > 0 && atr[0] < 1e6)
      {
         double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(refPrice > 0 && atr[0] < refPrice)
            riskPoints = atr[0] / _Point;
      }
   }
   return riskPoints;
}

//==================================================================
//  当前盈利R倍数计算
//==================================================================
double CalculateCurrentRMultiple(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
   if(openPrice <= 0) return 0.0;
   double riskPoints = CalculateRiskUnit(openPrice, originalSL, posType);
   if(riskPoints <= 0) return 0.0;
   double currentPrice = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double profitPoints = (posType == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
   return profitPoints / riskPoints;
}

//==================================================================
//  获取SAR反转信号（含ADX过滤，新增ADX强度及方向校验）
//==================================================================
EXIT_REASON GetReversalSignal(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
   double sar[3];
   if(CopyBuffer(sar_handle_exit, 0, 0, 3, sar) < 3) return NO_EXIT;

   bool trend_up_1 = iLow(_Symbol, _Period, 1) > sar[1];
   bool trend_up_2 = iLow(_Symbol, _Period, 2) > sar[2];
   if(trend_up_1 == trend_up_2) return NO_EXIT;

   static datetime lastTime = 0;
   datetime barTime = (datetime)iTime(_Symbol, _Period, 1);
   if(barTime <= lastTime) return NO_EXIT;

   EXIT_REASON reason = trend_up_1 ? EXIT_SHORT : EXIT_LONG;

   double r = CalculateCurrentRMultiple(openPrice, originalSL, posType);
   if(r < SAR_MinRRatio) return NO_EXIT;

   if(g_ADXFilterEnabled)
   {
      double adx[2], plus[2], minus[2];
      if(CopyBuffer(adx_handle_exit, MAIN_LINE, 0, 2, adx) < 2 ||
         CopyBuffer(adx_handle_exit, PLUSDI_LINE, 0, 2, plus) < 2 ||
         CopyBuffer(adx_handle_exit, MINUSDI_LINE, 0, 2, minus) < 2)
         return NO_EXIT;

      bool strong = adx[1] > ADX_MinLevel;
      bool weaken = adx[1] < adx[0];
      bool di_exit_long = (minus[1] > plus[1]);
      bool di_exit_short = (plus[1] > minus[1]);

      if(reason == EXIT_LONG && posType == POSITION_TYPE_BUY && !(strong && (weaken || di_exit_long))) return NO_EXIT;
      if(reason == EXIT_SHORT && posType == POSITION_TYPE_SELL && !(strong && (weaken || di_exit_short))) return NO_EXIT;
   }

   lastTime = barTime;
   return reason;
}

//==================================================================
//  多头出场判断逻辑（含Step TP）
//==================================================================
double GetLongExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   if(g_SARReversalEnabled && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_BUY) == EXIT_LONG)
   {
      Print("SAR反转触发多头平仓.");
      return 100.0;
   }
   if(EnableStepTP)
   {
      if(openPrice <= 0 || RRratio <= 0) return 0.0;
      double risk = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_BUY);
      if(risk <= 0) return 0.0;
      double profit = (SymbolInfoDouble(_Symbol, SYMBOL_BID) - openPrice) / _Point;

      if(!step2Done && Step2Pct > 0 && profit >= risk * RRratio * Step2Factor) { step2Done = true; return Step2Pct; }
      if(!step1Done && Step1Pct > 0 && profit >= risk * RRratio) { step1Done = true; return Step1Pct; }
   }
   return 0.0;
}

//==================================================================
//  空头出场判断逻辑（含Step TP）
//==================================================================
double GetShortExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   if(g_SARReversalEnabled && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_SELL) == EXIT_SHORT)
   {
      Print("SAR反转触发空头平仓.");
      return 100.0;
   }
   if(EnableStepTP)
   {
      if(openPrice <= 0 || RRratio <= 0) return 0.0;
      double risk = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_SELL);
      if(risk <= 0) return 0.0;
      double profit = (openPrice - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

      if(!step2Done && Step2Pct > 0 && profit >= risk * RRratio * Step2Factor) { step2Done = true; return Step2Pct; }
      if(!step1Done && Step1Pct > 0 && profit >= risk * RRratio) { step1Done = true; return Step1Pct; }
   }
   return 0.0;
}

//+------------------------------------------------------------------+
//|                                     SAR_ADX_Exit_Module.mqh       |
//|        SAR+ADX联合出场 与 RRR分步止盈 整合出场模块 v2.0         |
//|          (核心升级: SAR反转信号基于K线收盘确认)                |
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
//  模块初始化与清理函数 (保持不变)
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
   
   Print("SAR+ADX+StepTP 统一出场模块 v2.0 初始化成功 (SAR收盘确认)");
   return true;
}

void DeinitExitModule()
{
   if(sar_handle_exit != INVALID_HANDLE) IndicatorRelease(sar_handle_exit);
   if(adx_handle_exit != INVALID_HANDLE) IndicatorRelease(adx_handle_exit);
   if(atr_handle_exit != INVALID_HANDLE) IndicatorRelease(atr_handle_exit);
}

//==================================================================
//  辅助计算函数 (保持不变)
//==================================================================

// 计算交易逻辑的R倍数风险单位 (与止损保护系统分离)
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
      if(CopyBuffer(atr_handle_exit, 0, 1, 1, atr) >= 1 && atr[0] > 0)
      {
         riskPoints = atr[0] / _Point;
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
   
   double currentPrice = (posType == POSITION_TYPE_BUY) 
                        ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double profitPoints = (posType == POSITION_TYPE_BUY)
                        ? (currentPrice - openPrice) / _Point
                        : (openPrice - currentPrice) / _Point;
   
   return profitPoints / riskPoints;
}

//==================================================================
//  模块核心逻辑 (核心修改区域)
//==================================================================

//+------------------------------------------------------------------+
//| 内部逻辑：获取反转信号 (v2.0 - K线收盘确认版)                     |
//+------------------------------------------------------------------+
EXIT_REASON GetReversalSignal(const double openPrice, const double originalSL, ENUM_POSITION_TYPE posType)
{
    // 1. 获取稳定的历史数据
    double sar[3];
    if(CopyBuffer(sar_handle_exit, 0, 0, 3, sar) < 3) return NO_EXIT;

    // 2. 【核心修改】基于已收盘的K线[1]和[2]判断趋势方向
    // 趋势定义：如果K线的最低价高于其SAR点，视为上升趋势；反之亦然。
    bool trend_is_up_on_bar1 = iLow(_Symbol, _Period, 1) > sar[1];
    bool trend_is_up_on_bar2 = iLow(_Symbol, _Period, 2) > sar[2];

    // 3. 检测趋势是否在上一根K线[1]发生反转
    if(trend_is_up_on_bar1 == trend_is_up_on_bar2)
    {
        return NO_EXIT; // 趋势未反转
    }
    
    // 【新增】防重复平仓机制
    static datetime last_reversal_time = 0;
    datetime signal_bar_time = (datetime)iTime(_Symbol, _Period, 1);
    if(signal_bar_time <= last_reversal_time)
    {
        return NO_EXIT;
    }

    // 确定反转方向
    EXIT_REASON reason = trend_is_up_on_bar1 ? EXIT_SHORT : EXIT_LONG; // 注意：趋势向上反转，是平空头仓(EXIT_SHORT)；反之平多头(EXIT_LONG)

    // 4. 检查R倍数盈利条件 (逻辑不变，依然重要)
    double currentRMultiple = CalculateCurrentRMultiple(openPrice, originalSL, posType);
    if(currentRMultiple < SAR_MinRRatio)
    {
       // 虽然有信号，但盈利未达标，不平仓
       return NO_EXIT;
    }

    // 5. ADX过滤器 (如果启用)
    if(UseADXFilter)
    {
        double adx[2], plus[2], minus[2];
        if(CopyBuffer(adx_handle_exit,  MAIN_LINE , 0, 2, adx)   < 2 ||
          CopyBuffer(adx_handle_exit,  PLUSDI_LINE, 0, 2, plus) < 2 ||
          CopyBuffer(adx_handle_exit,  MINUSDI_LINE, 0, 2, minus)< 2)
        {
          return NO_EXIT;
        }

        bool isStrong = adx[1] > ADX_MinLevel;      // 在信号K线[1]上趋势是否强劲
        bool isWeakening = adx[1] < adx[0];       // 趋势从K线[0]到K线[1]是否在减弱 (adx[0]是更早的数据)
        
        // 逻辑简化和加强：当趋势减弱(isWeakening)或DI线发生死叉/金叉时，确认信号
        bool di_cross_confirms_exit_long = (minus[1] > plus[1]); // -DI上穿+DI，确认多头离场
        bool di_cross_confirms_exit_short = (plus[1] > minus[1]); // +DI上穿-DI，确认空头离场
        
        // 多头离场确认 (EXIT_LONG)
        if(reason == EXIT_LONG && posType == POSITION_TYPE_BUY)
        {
           if(isStrong && (isWeakening || di_cross_confirms_exit_long))
           {
              // 条件满足，可以离场
           }
           else
           {
              return NO_EXIT; // ADX未确认
           }
        }
        
        // 空头离场确认 (EXIT_SHORT)
        if(reason == EXIT_SHORT && posType == POSITION_TYPE_SELL)
        {
           if(isStrong && (isWeakening || di_cross_confirms_exit_short))
           {
               // 条件满足，可以离场
           }
           else
           {
              return NO_EXIT; // ADX未确认
           }
        }
    }
    
    last_reversal_time = signal_bar_time; // 记录已处理的信号K线
    return reason;
}

//+------------------------------------------------------------------+
//| 主函数：获取多头出场指令 (调用新版反转检测)                       |
//+------------------------------------------------------------------+
double GetLongExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   // 1. SAR反转信号触发，直接全平
   if(UseSARReversal && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_BUY) == EXIT_LONG)
   {
      Print("SAR反转信号(收盘确认): 触发多头平仓.");
      return 100.0;
   }

   // 2. 分步止盈逻辑 (逻辑不变)
   if(EnableStepTP)
   {
      if(openPrice <= 0 || RRratio <= 0) return 0.0;

      double riskPts = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_BUY);
      if(riskPts <= 0) return 0.0;

      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double profitPts = (currentPrice - openPrice) / _Point;

      if(!step2Done && Step2Pct > 0 && profitPts >= riskPts * RRratio * Step2Factor) 
      {
         step2Done = true;
         return Step2Pct;
      }
      if(!step1Done && Step1Pct > 0 && profitPts >= riskPts * RRratio) 
      {
         step1Done = true;
         return Step1Pct;
      }
   }
   return 0.0;
}

//+------------------------------------------------------------------+
//| 主函数：获取空头出场指令 (调用新版反转检测)                       |
//+------------------------------------------------------------------+
double GetShortExitAction(const double openPrice, const double originalSL, bool &step1Done, bool &step2Done)
{
   // 1. SAR反转信号触发，直接全平
   if(UseSARReversal && GetReversalSignal(openPrice, originalSL, POSITION_TYPE_SELL) == EXIT_SHORT)
   {
      Print("SAR反转信号(收盘确认): 触发空头平仓.");
      return 100.0;
   }

   // 2. 分步止盈逻辑 (逻辑不变)
   if(EnableStepTP)
   {
      if(openPrice <= 0 || RRratio <= 0) return 0.0;

      double riskPts = CalculateRiskUnit(openPrice, originalSL, POSITION_TYPE_SELL);
      if(riskPts <= 0) return 0.0;

      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPts = (openPrice - currentPrice) / _Point;

      if(!step2Done && Step2Pct > 0 && profitPts >= riskPts * RRratio * Step2Factor) 
      {
         step2Done = true;
         return Step2Pct;
      }
      if(!step1Done && Step1Pct > 0 && profitPts >= riskPts * RRratio) 
      {
         step1Done = true;
         return Step1Pct;
      }
   }
   return 0.0;
}
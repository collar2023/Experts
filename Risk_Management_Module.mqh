//+------------------------------------------------------------------+
//|                                     Risk_Management_Module.mqh   |
//|          核心风控与资金管理模块 v2.0 (增强版)                   |
//|      (负责: 日亏损限制、交易许可、手数计算、滑点、止损保护)       |
//+------------------------------------------------------------------+

#property strict
#include <Trade\Trade.mqh>

//==================================================================
//  输入参数
//==================================================================
input group "--- Position Sizing ---"
input bool     Risk_useFixedLot        = false;   // 使用固定手数
input double   Risk_fixedLot           = 0.01;   // 固定手数大小
input double   Risk_riskPercent        = 1.0;    // 风险百分比 (动态手数)

input group "--- Stop Loss Protection ---"
input double   Risk_minStopATRMultiple = 1.5;    // 最小止损距离 (ATR倍数)
input int      Risk_atrPeriod          = 14;     // ATR计算周期
input double   Risk_minStopPoints      = 15.0;   // 最小止损点数 (备用)

input group "--- Position Size Limits ---"
input double   Risk_maxLotByBalance    = 5.0;    // 最大手数限制 (账户余额百分比)
input double   Risk_maxAbsoluteDeposit = 1000.0; // 最大绝对保证金 (美金)
input bool     Risk_enableLotLimit     = true;   // 启用手数上限保护

input group "--- Trade Execution & Global Risk ---"
input double   Risk_slippage           = 3;      // 允许滑点 (points)
input double   Risk_dailyLossLimitPct  = 10.0;   // 日内最大亏损百分比 (0=禁用)
input bool     Risk_AllowNewTrade      = true;   // [总开关] 允许新交易

//==================================================================
//  模块内部全局变量
//==================================================================
static int      rm_currentDay        = -1;
static double   rm_dayStartBalance   = 0.0;
static bool     rm_dayLossLimitHit   = false;
static int      rm_atrHandle         = INVALID_HANDLE;

//==================================================================
//  模块核心功能函数
//==================================================================

//+------------------------------------------------------------------+
//| 初始化风控模块                                                  |
//+------------------------------------------------------------------+
void InitRiskModule()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   rm_currentDay      = dt.day_of_year;
   rm_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   rm_dayLossLimitHit = false;
   
   // 初始化ATR指标句柄
   rm_atrHandle = iATR(_Symbol, _Period, Risk_atrPeriod);
   if(rm_atrHandle == INVALID_HANDLE)
   {
      Print("[风控模块] 警告: ATR指标初始化失败，将使用固定点数作为最小止损距离");
   }
   
   Print("风控模块v2.0: 初始化成功. 今日起始余额: ", rm_dayStartBalance);
   Print("风控配置: 最小止损=", Risk_minStopATRMultiple, "xATR, 最大手数限制=", 
         Risk_maxLotByBalance, "%余额");
}

//+------------------------------------------------------------------+
//| 清理风控模块资源                                                |
//+------------------------------------------------------------------+
void DeinitRiskModule()
{
   if(rm_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(rm_atrHandle);
      rm_atrHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| 配置交易对象 (如滑点)                                           |
//+------------------------------------------------------------------+
void ConfigureTrader(CTrade &trade_object)
{
   trade_object.SetDeviationInPoints(int(Risk_slippage));
   trade_object.SetTypeFillingBySymbol(_Symbol);
}

//+------------------------------------------------------------------+
//| 获取最小止损距离 (点数)                                         |
//+------------------------------------------------------------------+
double GetMinStopDistance()
{
   double minDistance = Risk_minStopPoints * _Point;
   
   if(rm_atrHandle != INVALID_HANDLE)
   {
      double atr[1];
      if(CopyBuffer(rm_atrHandle, 0, 1, 1, atr) > 0 && atr[0] > 0)
      {
         double atrDistance = atr[0] * Risk_minStopATRMultiple;
         minDistance = MathMax(minDistance, atrDistance);
      }
   }
   
   return minDistance;
}

//+------------------------------------------------------------------+
//| 获取最大允许手数                                               |
//+------------------------------------------------------------------+
double GetMaxAllowedLotSize()
{
   if(!Risk_enableLotLimit)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double marginRequired = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_INITIAL);
   
   if(marginRequired <= 0)
      marginRequired = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_MAINTENANCE);
   
   double maxLotByBalance = 0;
   double maxLotByMargin = 0;
   
   // 方法1: 按账户余额百分比
   if(Risk_maxLotByBalance > 0)
   {
      double allowedMargin = balance * Risk_maxLotByBalance / 100.0;
      if(marginRequired > 0)
         maxLotByBalance = allowedMargin / marginRequired;
   }
   
   // 方法2: 按绝对保证金金额
   if(Risk_maxAbsoluteDeposit > 0 && marginRequired > 0)
   {
      maxLotByMargin = Risk_maxAbsoluteDeposit / marginRequired;
   }
   
   // 取较小值，确保不超过平台限制
   double platformMaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double finalMaxLot = platformMaxLot;
   
   if(maxLotByBalance > 0)
      finalMaxLot = MathMin(finalMaxLot, maxLotByBalance);
   
   if(maxLotByMargin > 0)
      finalMaxLot = MathMin(finalMaxLot, maxLotByMargin);
   
   return MathMax(finalMaxLot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
}

//+------------------------------------------------------------------+
//| 调整止损价格到最小距离 (如果需要)                                |
//+------------------------------------------------------------------+
double AdjustStopLossToMinDistance(double entryPrice, double originalSL, ENUM_ORDER_TYPE orderType)
{
   double minDistance = GetMinStopDistance();
   double adjustedSL = originalSL;
   
   if(orderType == ORDER_TYPE_BUY)
   {
      double minSL = entryPrice - minDistance;
      if(originalSL > minSL)  // 原始SL距离太近
      {
         adjustedSL = minSL;
         Print("[风控] 买单SL调整: ", originalSL, " -> ", adjustedSL, 
               " (最小距离保护: ", minDistance/_Point, "点)");
      }
   }
   else if(orderType == ORDER_TYPE_SELL)
   {
      double minSL = entryPrice + minDistance;
      if(originalSL < minSL)  // 原始SL距离太近
      {
         adjustedSL = minSL;
         Print("[风控] 卖单SL调整: ", originalSL, " -> ", adjustedSL, 
               " (最小距离保护: ", minDistance/_Point, "点)");
      }
   }
   
   return adjustedSL;
}

//+------------------------------------------------------------------+
//| 主函数：检查是否可以开立新仓位                                  |
//+------------------------------------------------------------------+
bool CanOpenNewTrade(bool enable_debug_print = false)
{
   // 1. 检查手动总开关
   if(!Risk_AllowNewTrade)
      return false;
   
   // 2. 检查日内风控
   if(Risk_dailyLossLimitPct > 0)
   {
       MqlDateTime dt;
       TimeToStruct(TimeCurrent(), dt);
       if(dt.day_of_year != rm_currentDay)
       {
           rm_currentDay      = dt.day_of_year;
           rm_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
           rm_dayLossLimitHit = false;
           if(enable_debug_print) Print("[风控] 新的一天，重置日内亏损状态.");
       }

       if(rm_dayLossLimitHit)
       {
           if(enable_debug_print) Print("[风控] 日内亏损限额已达，禁止开新仓.");
           return false;
       }

       if(AccountInfoDouble(ACCOUNT_BALANCE) < rm_dayStartBalance * (1 - Risk_dailyLossLimitPct / 100.0))
       {
           rm_dayLossLimitHit = true;
           if(enable_debug_print) Print("[风控] 日内亏损已达限额! 今日停止新开仓.");
           return false;
       }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| 主函数：计算最终交易手数 (含所有保护逻辑)                        |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_price, ENUM_ORDER_TYPE type)
{
    double lot = 0.0;
    
    // 获取当前价格
    double currentPrice = (type == ORDER_TYPE_BUY) ? 
                          SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                          SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    if(currentPrice <= 0)
    {
        Print("[风控] 无法获取当前价格，手数计算返回0");
        return 0.0;
    }
    
    // === 第一步：止损距离保护 === //
    double adjustedSL = AdjustStopLossToMinDistance(currentPrice, sl_price, type);
    double actualRiskPoints = MathAbs(currentPrice - adjustedSL);
    
    if(actualRiskPoints <= 0)
    {
        Print("[风控] 调整后止损点数仍 <= 0，手数计算返回0");
        return 0.0;
    }

    // === 第二步：计算基础手数 === //
    if(Risk_useFixedLot)
    {
        lot = Risk_fixedLot;
    }
    else
    {
        double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        
        if(tickValue <= 0)
        {
            tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
            if(tickValue <= 0)
            {
                Print("[风控] 无法获取有效 tickValue，手数计算返回0");
                return 0.0;
            }
        }

        double riskAmount = balance * Risk_riskPercent / 100.0;
        lot = riskAmount / (actualRiskPoints / _Point * tickValue);
    }

    // === 第三步：应用手数限制 === //
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    // 获取风控最大手数限制
    double riskMaxLot = GetMaxAllowedLotSize();
    maxLot = MathMin(maxLot, riskMaxLot);
    
    // 检查最小手数要求
    if(lot < minLot)
    {
        if(Risk_useFixedLot)
        {
            lot = minLot;  // 固定手数模式：强制使用最小手数
        }
        else
        {
            Print("[风控] 计算手数 ", lot, " 小于最小手数 ", minLot, "，跳过交易");
            return 0.0;    // 动态手数模式：拒绝交易
        }
    }
    
    // 标准化到合法步进
    lot = MathFloor(lot / stepLot) * stepLot;
    lot = MathMax(lot, minLot);
    lot = MathMin(lot, maxLot);
    
    // === 第四步：最终安全检查与日志 === //
    if(lot != Risk_fixedLot && Risk_useFixedLot)
    {
        Print("[风控] 固定手数已调整: ", Risk_fixedLot, " -> ", lot);
    }
    
    if(lot < riskMaxLot * 0.9)  // 如果被风控大幅限制
    {
        Print("[风控] 原计算手数被限制. 最终手数: ", lot, ", 风控上限: ", riskMaxLot);
    }
    
    // 输出调试信息
    Print("[风控] 手数计算完成: 入场价=", currentPrice, ", 调整SL=", adjustedSL, 
          ", 风险点数=", actualRiskPoints/_Point, ", 最终手数=", lot);
    
    return lot;
}

//+------------------------------------------------------------------+
//| 获取调整后的止损价格 (供外部调用)                                |
//+------------------------------------------------------------------+
double GetAdjustedStopLossPrice(double entryPrice, double originalSL, ENUM_ORDER_TYPE orderType)
{
    return AdjustStopLossToMinDistance(entryPrice, originalSL, orderType);
}
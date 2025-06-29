//+------------------------------------------------------------------+
//|                                     Risk_Management_Module.mqh   |
//|          核心风控与资金管理模块 v1.0                            |
//|      (负责: 日亏损限制、交易许可、手数计算、滑点)                |
//+------------------------------------------------------------------+

#property strict
#include <Trade\Trade.mqh>


//==================================================================
//  输入参数
//==================================================================
input group "--- Position Sizing ---"
input bool     Risk_useFixedLot        = true;  // 使用固定手数
input double   Risk_fixedLot           = 0.01;   // 固定手数大小
input double   Risk_riskPercent        = 2.0;    // 风险百分比 (动态手数)

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
   Print("风控模块: 初始化成功. 今日起始余额: ", rm_dayStartBalance);
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
//| 主函数：计算最终交易手数                                        |
//+------------------------------------------------------------------+
double CalculateLotSize(double sl_price, ENUM_ORDER_TYPE type)
{
    double lot = 0.0;

    if(Risk_useFixedLot)
    {
        lot = Risk_fixedLot;
    }
    else
    {
        double bal = AccountInfoDouble(ACCOUNT_BALANCE);
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        if(tickValue <= 0)
        {
            tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
            if(tickValue <= 0)
            {
                Print("[风险管理] 无法获取有效 tickValue，手数计算返回0");
                return 0.0;
            }
        }

        double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double risk_points = MathAbs(price - sl_price);

        if(risk_points <= 0)
        {
            Print("[风险管理] 止损点数 <= 0，手数计算返回0");
            return 0.0;
        }

        lot = (bal * Risk_riskPercent / 100.0) / (risk_points / _Point * tickValue);
    }

    // 获取品种手数限制参数
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(Risk_useFixedLot)
    {
        // 固定手数，向上取整到合法步进，确保不低于最小手数
        lot = MathCeil(lot / stepLot) * stepLot;
        lot = MathMax(lot, minLot);
        return MathMin(lot, maxLot);
    }
    else
    {
        if(lot < minLot)
            return 0.0;

        lot = MathFloor(lot / stepLot) * stepLot;
        return MathMin(lot, maxLot);
    }
}

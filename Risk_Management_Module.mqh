//+------------------------------------------------------------------+
//|                                   Risk_Management_Module.mqh     |
//|     核心风控与资金管理模块  v2.2  （2025‑06‑29）                 |
//|  • 新增：手数计算加入滑点缓冲（Risk_slippage）                   |
//|  • 优化：TickValue 读取先试 SYMBOL_TRADE_TICK_VALUE_PROFIT       |
//|  • 其余逻辑承接 v2.1（最小止损距离、每日亏损封顶等）             |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//==================================================================
//  输入参数
//==================================================================
input group "--- Position Sizing ---"
input bool     Risk_useFixedLot        = false;   // 是否固定手数
input double   Risk_fixedLot           = 0.01;    // 固定手数
input double   Risk_riskPercent        = 1.0;     // 账户百分比风险

input group "--- Stop Loss Protection ---"
input double   Risk_minStopATRMultiple = 1.0;     // 最小 SL = ATR×系数
input int      Risk_atrPeriod          = 14;      // ATR 周期
input double   Risk_minStopPoints      = 10.0;    // 最小 SL = 固定点数

input group "--- Position Size Limits ---"
input double   Risk_maxLotByBalance    = 50.0;    // 余额 / 此值 = 上限手数
input double   Risk_maxAbsoluteDeposit = 1000.0;  // 存款 1000 USD ≈ 1 手
input bool     Risk_enableLotLimit     = true;    // 是否启用手数上限

input group "--- Trade Execution & Global Risk ---"
input double   Risk_slippage           = 3;       // 允许滑点 (Points)
input double   Risk_dailyLossLimitPct  = 10.0;    // 每日亏损上限 %
input bool     Risk_AllowNewTrade      = true;    // 全局开关

//==================================================================
//  模块内部全局变量
//==================================================================
static int      rm_currentDay        = -1;
static double   rm_dayStartBalance   = 0.0;
static bool     rm_dayLossLimitHit   = false;
static int      rm_atrHandle         = INVALID_HANDLE;

//==================================================================
//  初始化和清理函数
//==================================================================
void InitRiskModule()
{
   rm_currentDay      = -1;
   rm_dayStartBalance = 0.0;
   rm_dayLossLimitHit = false;

   rm_atrHandle = iATR(_Symbol, _Period, Risk_atrPeriod);
   if(rm_atrHandle == INVALID_HANDLE)
      Print("[风控] ATR 初始化失败");
   else
      Print("[风控] 风控模块初始化完成");
}
//------------------------------------------------------------------
void DeinitRiskModule()
{
   if(rm_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(rm_atrHandle);
      rm_atrHandle = INVALID_HANDLE;
   }
   Print("[风控] 风控模块清理完成");
}
//------------------------------------------------------------------
void ConfigureTrader(CTrade &t)
{
   t.SetExpertMagicNumber(123456);
   t.SetDeviationInPoints((ulong)Risk_slippage);
   t.SetTypeFillingBySymbol(_Symbol);
   Print("[风控] 交易对象配置完成");
}

//==================================================================
//  手数计算（v2.2 重点改动）
//==================================================================
double CalculateLotSize(double original_sl_price, ENUM_ORDER_TYPE type)
{
   // ① 估计开仓价 + 滑点缓冲
   double estPrice = (type == ORDER_TYPE_BUY)
                   ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                   : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(estPrice <= 0)
   {
      Print("[风控] 无法获取市价，手数=0");
      return 0.0;
   }

   double buffer = Risk_slippage * _Point;          // 滑点→点差
   if(type == ORDER_TYPE_BUY)  estPrice += buffer;  // 买价向上偏移
   else                        estPrice -= buffer;  // 卖价向下偏移

   double riskPoints = MathAbs(estPrice - original_sl_price);
   if(riskPoints <= 0)
   {
      Print("[风控] 风险点数<=0，手数=0");
      return 0.0;
   }

   // ② 计算理论手数
   double lot = 0.0;
   if(Risk_useFixedLot)
   {
      lot = Risk_fixedLot;
   }
   else
   {
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
      if(tickValue <= 0)
         tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

      if(tickValue <= 0)
      {
         Print("[风控] TickValue 无效，手数=0");
         return 0.0;
      }

      double riskAmt = balance * Risk_riskPercent / 100.0;
      lot = riskAmt / (riskPoints / _Point * tickValue);
   }

   // ③ 手数边界
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(lot, minLot);
   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMin(lot, GetMaxAllowedLotSize());

   Print("[风控] 手数计算: Price=", estPrice,
         ", RiskPts=", riskPoints/_Point,
         ", Lot=", lot);
   return lot;
}

//==================================================================
//  止损相关工具函数
//==================================================================
double CalculateFinalStopLoss(double actualOpenPrice,
                              double originalSL,
                              ENUM_ORDER_TYPE orderType)
{
   double minDist = GetMinStopDistance();
   double sl = originalSL;

   if(orderType == ORDER_TYPE_BUY)
   {
      double minSL = actualOpenPrice - minDist;
      if(originalSL > minSL)
      {
         sl = minSL;
         Print("[风控] 买单 SL 调整 → ", sl);
      }
   }
   else
   {
      double minSL = actualOpenPrice + minDist;
      if(originalSL < minSL)
      {
         sl = minSL;
         Print("[风控] 卖单 SL 调整 → ", sl);
      }
   }
   return sl;
}
//------------------------------------------------------------------
bool SetStopLossWithRetry(CTrade &t,
                          double stopLoss,
                          double takeProfit,
                          int maxRetries = 3)
{
   for(int i = 0; i < maxRetries; ++i)
   {
      if(t.PositionModify(_Symbol, stopLoss, takeProfit))
      {
         Print("[风控] 止损设置成功 (第", i+1, "次)");
         return true;
      }
      Print("[风控] 止损设置失败 (第", i+1, "次) err=", GetLastError());
      if(i < maxRetries - 1) Sleep(200);
   }
   return false;
}

//==================================================================
//  备用开仓包装（供高精度需求时调用，可留作工具函数）
//==================================================================
bool OpenMarketOrderWithPreciseStopLoss(CTrade &t,
                                        ENUM_ORDER_TYPE orderType,
                                        double volume,
                                        double originalSL,
                                        double takeProfit = 0,
                                        string comment    = "")
{
   bool ok = false;
   if(orderType == ORDER_TYPE_BUY)
        ok = t.Buy(volume, _Symbol, 0, 0, takeProfit, comment);
   else ok = t.Sell(volume, _Symbol, 0, 0, takeProfit, comment);

   if(!ok)
   {
      Print("[风控] 开仓失败: ", t.ResultRetcodeDescription());
      return false;
   }

   if(!PositionSelect(_Symbol))
   {
      Print("[风控] 开仓后选仓失败");
      return false;
   }

   double openP  = PositionGetDouble(POSITION_PRICE_OPEN);
   double finalSL = CalculateFinalStopLoss(openP, originalSL, orderType);

   if(!SetStopLossWithRetry(t, finalSL, takeProfit))
   {
      Print("[风控] 止损设置失败 → 保护性平仓");
      t.PositionClose(_Symbol);
      return false;
   }
   Print("[风控] 开仓完成: SL=", finalSL);
   return true;
}

//==================================================================
//  辅助函数
//==================================================================
double GetMinStopDistance()
{
   double dist = Risk_minStopPoints * _Point;

   if(rm_atrHandle != INVALID_HANDLE)
   {
      double atr[1];
      if(CopyBuffer(rm_atrHandle, 0, 0, 1, atr) > 0)
         dist = MathMax(dist, atr[0] * Risk_minStopATRMultiple);
   }
   double brokerMin = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   return MathMax(dist, brokerMin);
}
//------------------------------------------------------------------
double GetMaxAllowedLotSize()
{
   if(!Risk_enableLotLimit)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double byBalance  = balance / Risk_maxLotByBalance;
   double byDeposit  = Risk_maxAbsoluteDeposit / 1000.0;  // 1000 USD ≈ 1 手

   return MathMin(byBalance, byDeposit);
}
//------------------------------------------------------------------
bool CanOpenNewTrade(bool dbg=false)
{
   if(!Risk_AllowNewTrade)
   {
      if(dbg) Print("[风控] 交易已全局关闭");
      return false;
   }

   // —每日亏损封顶—
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   if(rm_currentDay != dt.day_of_year)
   {
      rm_currentDay      = dt.day_of_year;
      rm_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      rm_dayLossLimitHit = false;
      if(dbg) Print("[风控] 新的一天，统计重置");
   }

   if(rm_dayLossLimitHit)
   {
      if(dbg) Print("[风控] 当日亏损上限已达，禁止新单");
      return false;
   }

   double balNow   = AccountInfoDouble(ACCOUNT_BALANCE);
   double loss     = rm_dayStartBalance - balNow;
   double limitVal = rm_dayStartBalance * Risk_dailyLossLimitPct / 100.0;

   if(loss >= limitVal)
   {
      rm_dayLossLimitHit = true;
      if(dbg) Print("[风控] 当日亏损 ", loss, " ≥ 限额 ", limitVal);
      return false;
   }
   return true;
}

//==================================================================
//  废弃兼容函数（保留占位，提示用新版）
//==================================================================
double AdjustStopLossToMinDistance(double eP, double oSL, ENUM_ORDER_TYPE t)
{
   Print("[风控] AdjustStopLossToMinDistance() 已废弃 → 用 CalculateFinalStopLoss()");
   return CalculateFinalStopLoss(eP, oSL, t);
}
//------------------------------------------------------------------
double GetAdjustedStopLossPrice(double eP, double oSL, ENUM_ORDER_TYPE t)
{
   Print("[风控] GetAdjustedStopLossPrice() 已废弃 → 用 CalculateFinalStopLoss()");
   return CalculateFinalStopLoss(eP, oSL, t);
}
//+------------------------------------------------------------------+

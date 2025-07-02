//+------------------------------------------------------------------+
//|                                   Risk_Management_Module.mqh     |
//|     核心风控与资金管理模块  v2.4  (终极修复版)                   |
//|  • 修复: 重构CalculateFinalStopLoss，使其只做合规审查。          |
//|  • 新增: 添加IsStopLossValid函数，用于统一的止损合法性检查。     |
//|  • 继承 v2.3 所有功能。                                         |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//==================================================================
//  输入参数 (无修改)
//==================================================================
input group "--- Position Sizing ---"
input bool     Risk_useFixedLot        = false;
input double   Risk_fixedLot           = 0.01;
input double   Risk_riskPercent        = 1.0;

input group "--- Stop Loss Protection ---"
input double   Risk_minStopATRMultiple = 1.0;
input int      Risk_atrPeriod          = 14;
input double   Risk_minStopPoints      = 10.0;

input group "--- Position Size Limits ---"
input double   Risk_maxLotByBalance    = 50.0;
input double   Risk_maxAbsoluteLot     = 1.0;
input bool     Risk_enableLotLimit     = true;

input group "--- Trade Execution & Global Risk ---"
input double   Risk_slippage           = 3;
input double   Risk_dailyLossLimitPct  = 10.0;
input bool     Risk_AllowNewTrade      = true;

//==================================================================
//  模块内部全局变量
//==================================================================
static int      rm_currentDay        = -1;
static double   rm_dayStartBalance   = 0.0;
static bool     rm_dayLossLimitHit   = false;
static int      rm_atrHandle         = INVALID_HANDLE;
extern CLogModule* g_Logger;

extern bool ST_Debug;


//==================================================================
//  初始化和清理函数
//==================================================================
void InitRiskModule()
{
   rm_currentDay      = -1;
   rm_dayStartBalance = 0.0;
   rm_dayLossLimitHit = false;

   rm_atrHandle = iATR(_Symbol, _Period, Risk_atrPeriod);
   if(rm_atrHandle == INVALID_HANDLE) Print("[风控] ATR 初始化失败");
   else Print("[风控] 风控模块 v2.4 初始化完成 (终极修复版)");
}

void DeinitRiskModule()
{
   if(rm_atrHandle != INVALID_HANDLE) IndicatorRelease(rm_atrHandle);
}

void ConfigureTrader(CTrade &t)
{
   t.SetExpertMagicNumber(123456);
   t.SetDeviationInPoints((ulong)Risk_slippage);
   t.SetTypeFillingBySymbol(_Symbol);
}

//==================================================================
//  手数计算
//==================================================================
double CalculateLotSize(double original_sl_price, ENUM_ORDER_TYPE type)
{
   if (!MathIsValidNumber(original_sl_price)) return 0.0;
   double estPrice = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(estPrice <= 0) return 0.0;
   double buffer = Risk_slippage * _Point;
   if(type == ORDER_TYPE_BUY)  estPrice += buffer; else estPrice -= buffer;
   double riskPoints = MathAbs(estPrice - original_sl_price);
   if(riskPoints <= 0 || !MathIsValidNumber(riskPoints)) return 0.0;
   double lot = 0.0;
   if(Risk_useFixedLot) lot = Risk_fixedLot;
   else
   {
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
      if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickValue <= 0) return 0.0;
      double riskAmt = balance * Risk_riskPercent / 100.0;
      lot = riskAmt / (riskPoints / _Point * tickValue);
   }
   if(!MathIsValidNumber(lot)) return 0.0;
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMin(lot, GetMaxAllowedLotSize());
   lot = MathMax(lot, minLot);
   lot = MathFloor(lot / stepLot) * stepLot;
   return lot;
}

//==================================================================
//  止损相关工具函数 (核心修复区域)
//==================================================================
double NormalizePrice(double price)
{
   if (!MathIsValidNumber(price)) return 0.0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 1e-10 || !MathIsValidNumber(tickSize)) return NormalizeDouble(price, (int)_Digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, (int)_Digits);
}

// ★★★ 函数已重构，逻辑更清晰严谨 ★★★
double CalculateFinalStopLoss(double actualOpenPrice, double originalSL, ENUM_ORDER_TYPE orderType)
{
   if (!MathIsValidNumber(actualOpenPrice) || !MathIsValidNumber(originalSL)) return 0.0;
   
   double minDist = GetMinStopDistance();
   double finalSL = originalSL;

   if(orderType == ORDER_TYPE_BUY)
   {
      double requiredMinSL = actualOpenPrice - minDist;
      if(finalSL > requiredMinSL) 
      {
         finalSL = requiredMinSL;
         if(g_Logger != NULL && ST_Debug) g_Logger.WriteWarning(StringFormat("原始SL (%.5f) 不满足最小距离，强制拓宽至 %.5f", originalSL, finalSL));
      }
   }
   else
   {
      double requiredMinSL = actualOpenPrice + minDist;
      if(finalSL < requiredMinSL)
      {
         finalSL = requiredMinSL;
         if(g_Logger != NULL && ST_Debug) g_Logger.WriteWarning(StringFormat("原始SL (%.5f) 不满足最小距离，强制拓宽至 %.5f", originalSL, finalSL));
      }
   }
   
   if (!MathIsValidNumber(finalSL)) return 0.0;
   return NormalizePrice(finalSL);
}

// ★★★ 新增：统一的止损合法性检查函数 ★★★
bool IsStopLossValid(double sl, ENUM_POSITION_TYPE posType)
{
   if (!MathIsValidNumber(sl) || sl == 0) return false;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if (bid <= 0 || ask <= 0) return false;
   
   double minStopDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double freezeDist  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;

   if(posType == POSITION_TYPE_BUY)
   {
      if(sl >= bid - minStopDist) return false;
      if(freezeDist > 0 && (bid - sl) <= freezeDist) return false;
   }
   else // POSITION_TYPE_SELL
   {
      if(sl <= ask + minStopDist) return false;
      if(freezeDist > 0 && (sl - ask) <= freezeDist) return false;
   }
   return true;
}

bool SetStopLossWithRetry(CTrade &t, double stopLoss, double takeProfit, int maxRetries = 3)
{
   for(int i = 0; i < maxRetries; ++i)
   {
      if(t.PositionModify(_Symbol, stopLoss, takeProfit))
      {
         if(g_Logger && ST_Debug) Print("[风控] 止损设置成功 (第", i+1, "次)");
         return true;
      }
      if(g_Logger && ST_Debug) Print("[风控] 止损设置失败 (第", i+1, "次) err=", GetLastError());
      if(i < maxRetries - 1) Sleep(200);
   }
   return false;
}

//==================================================================
//  辅助函数 (无修改)
//==================================================================
double GetMinStopDistance()
{
   double dist = Risk_minStopPoints * _Point;
   if(rm_atrHandle != INVALID_HANDLE)
   {
      double atr[1];
      if(CopyBuffer(rm_atrHandle, 0, 0, 1, atr) > 0 && atr[0] > 0)
         dist = MathMax(dist, atr[0] * Risk_minStopATRMultiple);
   }
   double brokerMin = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   return MathMax(dist, brokerMin);
}
double GetMaxAllowedLotSize()
{
   if(!Risk_enableLotLimit) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double byBalance = (Risk_maxLotByBalance > 0) ? (balance / Risk_maxLotByBalance) : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return MathMin(byBalance, Risk_maxAbsoluteLot);
}
bool CanOpenNewTrade(bool dbg=false)
{
   if(!Risk_AllowNewTrade) return false;
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   if(rm_currentDay != dt.day_of_year)
   {
      rm_currentDay      = dt.day_of_year;
      rm_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      rm_dayLossLimitHit = false;
   }
   if(rm_dayLossLimitHit) return false;
   double balNow   = AccountInfoDouble(ACCOUNT_BALANCE);
   double loss     = rm_dayStartBalance - balNow;
   double limitVal = rm_dayStartBalance * Risk_dailyLossLimitPct / 100.0;
   if(loss > 0 && limitVal > 0 && loss >= limitVal)
   {
      rm_dayLossLimitHit = true;
      if(g_Logger && dbg) g_Logger.WriteError(StringFormat("当日亏损 %.2f >= 限额 %.2f. 停止新交易。", loss, limitVal));
      return false;
   }
   return true;
}
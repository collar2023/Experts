//+------------------------------------------------------------------+
//| Risk_Management_Module.mqh – 核心风控与资金管理 v2.6 (2025‑07‑04)|
//| ★ v2.6: 终极修复版 - 全面部署 MathIsValidNumber() 防护          |
//|   1) 所有价格计算函数入口和出口均增加有效性检查。                |
//|   2) NormalizePrice() 增加对无效数字的输入检查。               |
//|   3) 彻底杜绝因计算过程产生的 inf/nan 导致止损设置失败。       |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

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
//  模块内部全局变量 (无修改)
//==================================================================
static int      rm_currentDay        = -1;
static double   rm_dayStartBalance   = 0.0;
static bool     rm_dayLossLimitHit   = false;
static int      rm_atrHandle         = INVALID_HANDLE;

//==================================================================
//  初始化和清理函数 (无修改)
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
      Print("[风控] 风控模块 v2.6 初始化完成 (MathIsValidNumber 终极保护)");
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
//  手数计算 (无修改)
//==================================================================
double CalculateLotSize(double original_sl_price, ENUM_ORDER_TYPE type)
{
   if(!MathIsValidNumber(original_sl_price)) return 0.0; // ★ 防护
   double estPrice = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(estPrice <= 0) return 0.0;
   double buffer = Risk_slippage * _Point;
   if(type == ORDER_TYPE_BUY)  estPrice += buffer;
   else                        estPrice -= buffer;
   double riskPoints = MathAbs(estPrice - original_sl_price);
   if(riskPoints <= 0 || !MathIsValidNumber(riskPoints)) return 0.0; // ★ 防护
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
   if(!MathIsValidNumber(lot)) return 0.0; // ★ 防护
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMin(lot, GetMaxAllowedLotSize());
   lot = MathMax(lot, minLot);
   lot = MathFloor(lot / stepLot) * stepLot;
   return lot;
}

//==================================================================
//  止损相关工具函数 (终极修复区域)
//==================================================================
double NormalizePrice(double price)
{
   // ★★★ 终极入口设防 ★★★
   if (!MathIsValidNumber(price)) return 0.0;
   
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 1e-10) return NormalizeDouble(price, _Digits);
   
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

double CalculateFinalStopLoss(double actualOpenPrice, double originalSL, ENUM_ORDER_TYPE orderType)
{
   // ★★★ 源头设防 ★★★
   if (!MathIsValidNumber(actualOpenPrice) || !MathIsValidNumber(originalSL)) return 0.0;
   
   double minDist = GetMinStopDistance();
   double sl = originalSL;
   if(orderType == ORDER_TYPE_BUY)
   {
      double minSL = actualOpenPrice - minDist;
      if(originalSL > minSL) sl = minSL;
   }
   else
   {
      double minSL = actualOpenPrice + minDist;
      if(originalSL < minSL) sl = minSL;
   }
   
   // ★★★ 出口设防 ★★★
   if (!MathIsValidNumber(sl)) return 0.0;
   return sl;
}

bool IsStopLossValid(double sl, ENUM_POSITION_TYPE posType)
{
   if (!MathIsValidNumber(sl) || sl == 0) return false; // ★ 防护
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pt  = _Point;
   double minStopDist   = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pt;
   double minFreezeDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * pt;
   if(posType == POSITION_TYPE_BUY)
   {
      if(sl >= bid - minStopDist) return false;
      if(minFreezeDist > 0 && (bid - sl) <= minFreezeDist) return false;
   }
   else
   {
      if(sl <= ask + minStopDist) return false;
      if(minFreezeDist > 0 && (sl - ask) <= minFreezeDist) return false;
   }
   return true;
}

bool SetStopLossWithRetry(CTrade &t, double stopLoss, double takeProfit, int maxRetries = 3)
{
   if(!PositionSelect(_Symbol)) return false;
   
   ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   double validStopLoss = NormalizePrice(stopLoss);
   double validTakeProfit = (takeProfit > 0) ? NormalizePrice(takeProfit) : 0;

   if(!IsStopLossValid(validStopLoss, pType))
   {
      PrintFormat("[风控] ❌ SL %.5f (校准后 %.5f) 不满足距离/冻结规则 → 取消", stopLoss, validStopLoss);
      return false;
   }

   for(int i = 0; i < maxRetries; ++i)
   {
      if(t.PositionModify(_Symbol, validStopLoss, validTakeProfit)) return true;
      if(i < maxRetries - 1) Sleep(250);
   }
   PrintFormat("[风控] 止损设置失败 (已重试%d次) ret=%d", maxRetries, t.ResultRetcode());
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
      if(CopyBuffer(rm_atrHandle, 0, 0, 1, atr) == 1 && atr[0] > 0)
      {
         double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(refPrice > 0 && atr[0] < refPrice)
            dist = MathMax(dist, atr[0] * Risk_minStopATRMultiple);
      }
   }
   double brokerMin = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   return MathMax(dist, brokerMin);
}

double GetMaxAllowedLotSize()
{
   if(!Risk_enableLotLimit) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double byBalance = (Risk_maxLotByBalance > 0) ? balance / Risk_maxLotByBalance : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return MathMin(byBalance, Risk_maxAbsoluteLot);
}

bool CanOpenNewTrade(bool dbg=false)
{
   if(!Risk_AllowNewTrade) return false;
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   if(rm_currentDay != dt.day_of_year)
   {
      rm_currentDay = dt.day_of_year;
      rm_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      rm_dayLossLimitHit = false;
   }
   if(rm_dayLossLimitHit) return false;
   double balNow = AccountInfoDouble(ACCOUNT_BALANCE);
   double loss = rm_dayStartBalance - balNow;
   double limitVal = rm_dayStartBalance * Risk_dailyLossLimitPct / 100.0;
   if(loss > 0 && limitVal > 0 && loss >= limitVal)
   {
      rm_dayLossLimitHit = true;
      return false;
   }
   return true;
}
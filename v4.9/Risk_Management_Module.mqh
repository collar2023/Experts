//+------------------------------------------------------------------+
//| Risk_Management_Module.mqh – v4.9 (参数显性化版)                 |
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>

static int      rm_currentDay        = -1;
static double   rm_dayStartBalance   = 0.0;
static bool     rm_dayLossLimitHit   = false;
static int      rm_atrHandle         = INVALID_HANDLE;
extern CLogModule* g_Logger;


//==================================================================
//  ★ 辅助函数前置定义
//==================================================================
double GetMinStopDistance(const SRiskInputs &inputs)
{
   double dist = inputs.minStopPoints * _Point;
   if(rm_atrHandle != INVALID_HANDLE)
   {
      double atr[1];
      if(CopyBuffer(rm_atrHandle, 0, 0, 1, atr) > 0 && atr[0] > 0)
         dist = MathMax(dist, atr[0] * inputs.minStopATRMultiple);
   }
   double brokerMin = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   return MathMax(dist, brokerMin);
}

double GetMaxAllowedLotSize(const SRiskInputs &inputs)
{
   if(!inputs.enableLotLimit) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double byBalance = (inputs.maxLotByBalance > 0) ? (balance / inputs.maxLotByBalance) : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return MathMin(byBalance, inputs.maxAbsoluteLot);
}

//==================================================================
//  初始化和清理函数
//==================================================================
void InitRiskModule(const SRiskInputs &inputs)
{
   rm_currentDay      = -1;
   rm_dayStartBalance = 0.0;
   rm_dayLossLimitHit = false;

   rm_atrHandle = iATR(_Symbol, _Period, inputs.atrPeriod);
   if(rm_atrHandle == INVALID_HANDLE) { if(g_Logger) g_Logger.WriteError("[风控] ATR 初始化失败"); }
   else { if(g_Logger) g_Logger.WriteInfo("[风控] 风控模块 v4.9 初始化完成"); }
}

void DeinitRiskModule()
{
   if(rm_atrHandle != INVALID_HANDLE) IndicatorRelease(rm_atrHandle);
}

void ConfigureTrader(CTrade &t, const SRiskInputs &inputs)
{
   t.SetExpertMagicNumber(inputs.magicNumber);
   t.SetDeviationInPoints((ulong)inputs.slippage);
   t.SetTypeFillingBySymbol(_Symbol);
}

//==================================================================
//  手数计算
//==================================================================
double CalculateLotSize(double original_sl_price, ENUM_ORDER_TYPE type, const SRiskInputs &inputs)
{
   if (!MathIsValidNumber(original_sl_price)) return 0.0;
   double estPrice = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(estPrice <= 0) return 0.0;
   double buffer = inputs.slippage * _Point;
   if(type == ORDER_TYPE_BUY)  estPrice += buffer; else estPrice -= buffer;
   double riskPoints = MathAbs(estPrice - original_sl_price);
   if(riskPoints <= 0) return 0.0;
   double lot = 0.0;
   if(inputs.useFixedLot) lot = inputs.fixedLot;
   else
   {
      double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
      if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickValue <= 0) return 0.0;
      double riskAmt = balance * inputs.riskPercent / 100.0;
      lot = riskAmt / (riskPoints / _Point * tickValue);
   }
   if(!MathIsValidNumber(lot)) return 0.0;
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMin(lot, GetMaxAllowedLotSize(inputs));
   lot = MathMax(lot, minLot);
   lot = MathFloor(lot / stepLot) * stepLot;
   return lot;
}

//==================================================================
//  止损相关工具函数
//==================================================================
double NormalizePrice(double price)
{
   if (!MathIsValidNumber(price)) return 0.0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 1e-10 || !MathIsValidNumber(tickSize)) return NormalizeDouble(price, (int)_Digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, (int)_Digits);
}

double CalculateFinalStopLoss(double actualOpenPrice, double originalSL, ENUM_ORDER_TYPE orderType, const SRiskInputs &inputs)
{
   if (!MathIsValidNumber(actualOpenPrice) || !MathIsValidNumber(originalSL)) return 0.0;
   
   double minDist = GetMinStopDistance(inputs);
   double finalSL = originalSL;

   if(orderType == ORDER_TYPE_BUY)
   {
      double requiredMinSL = actualOpenPrice - minDist;
      if(finalSL > requiredMinSL) 
      {
         finalSL = requiredMinSL;
         if(g_Logger && EnableDebug) g_Logger.WriteWarning(StringFormat("原始SL (%.5f) 不满足最小距离，强制拓宽至 %.5f", originalSL, finalSL));
      }
   }
   else
   {
      double requiredMinSL = actualOpenPrice + minDist;
      if(finalSL < requiredMinSL)
      {
         finalSL = requiredMinSL;
         if(g_Logger && EnableDebug) g_Logger.WriteWarning(StringFormat("原始SL (%.5f) 不满足最小距离，强制拓宽至 %.5f", originalSL, finalSL));
      }
   }
   
   if (!MathIsValidNumber(finalSL)) return 0.0;
   return NormalizePrice(finalSL);
}

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
   else
   {
      if(sl <= ask + minStopDist) return false;
      if(freezeDist > 0 && (sl - ask) <= freezeDist) return false;
   }
   return true;
}

bool SetStopLossWithRetry(CTrade &t, double stopLoss, double takeProfit, int maxRetries, const SRiskInputs &inputs)
{
   for(int i = 0; i < maxRetries; ++i)
   {
      if(t.PositionModify(_Symbol, stopLoss, takeProfit)) return true;
      if(i < maxRetries - 1) Sleep(200);
   }
   return false;
}

bool CanOpenNewTrade(const SRiskInputs &inputs)
{
   if(!inputs.allowNewTrade) return false;
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
   double limitVal = rm_dayStartBalance * inputs.dailyLossLimitPct / 100.0;
   if(loss > 0 && limitVal > 0 && loss >= limitVal)
   {
      rm_dayLossLimitHit = true;
      if(g_Logger) g_Logger.WriteError(StringFormat("当日亏损 %.2f >= 限额 %.2f. 停止新交易。", loss, limitVal));
      return false;
   }
   return true;
}
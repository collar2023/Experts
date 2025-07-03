//+------------------------------------------------------------------+
//| Risk_Management_Module.mqh – v6.2 (终极编译修复版)               |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

//==================================================================
//  模块内部全局变量
//==================================================================
static int      rm_currentDay        = -1;
static double   rm_dayStartBalance   = 0.0;
static bool     rm_dayLossLimitHit   = false;
static int      rm_atrHandle         = INVALID_HANDLE;
extern CLogModule* g_Logger; // ★ 声明外部全局变量

//==================================================================
//  ★ 辅助函数前置定义 (FIX)
//==================================================================
double GetMinStopDistance(const SRiskInputs &inputs)
{
   double dist = inputs.minStopPoints * _Point;
   if(rm_atrHandle != INVALID_HANDLE)
   {
      double atr[1];
      if(CopyBuffer(rm_atrHandle, 0, 0, 1, atr) == 1 && atr[0] > 0)
      {
         double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(refPrice > 0 && atr[0] < refPrice)
            dist = MathMax(dist, atr[0] * inputs.minStopATRMultiple);
      }
   }
   double brokerMin = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   return MathMax(dist, brokerMin);
}

double GetMaxAllowedLotSize(const SRiskInputs &inputs)
{
   if(!inputs.enableLotLimit) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double byBalance = (inputs.maxLotByBalance > 0) ? balance / inputs.maxLotByBalance : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
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
   if(rm_atrHandle == INVALID_HANDLE)
   {
      if(g_Logger) g_Logger.WriteError("[风控] ATR 初始化失败");
   }
   else
   {
      if(g_Logger) g_Logger.WriteInfo("[风控] 风控模块 v6.2 初始化完成");
   }
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
   if(!MathIsValidNumber(original_sl_price)) return 0.0;
   double estPrice = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(estPrice <= 0) return 0.0;
   double buffer = inputs.slippage * _Point;
   if(type == ORDER_TYPE_BUY)  estPrice += buffer; else estPrice -= buffer;
   double riskPoints = MathAbs(estPrice - original_sl_price);
   if(riskPoints <= 0 || !MathIsValidNumber(riskPoints)) return 0.0;
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
   if(tickSize <= 1e-10) return NormalizeDouble(price, _Digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
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
         if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning(StringFormat("原始SL (%.5f) 不满足最小距离，强制拓宽至 %.5f", originalSL, finalSL));
      }
   }
   else
   {
      double requiredMinSL = actualOpenPrice + minDist;
      if(finalSL < requiredMinSL)
      {
         finalSL = requiredMinSL;
         if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning(StringFormat("原始SL (%.5f) 不满足最小距离，强制拓宽至 %.5f", originalSL, finalSL));
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
      if(g_Logger) g_Logger.WriteError(StringFormat("[风控] ❌ SL %.5f (校准后 %.5f) 不满足距离/冻结规则 → 取消", stopLoss, validStopLoss));
      return false;
   }
   for(int i = 0; i < maxRetries; ++i)
   {
      if(t.PositionModify(_Symbol, validStopLoss, validTakeProfit)) return true;
      if(i < maxRetries - 1) Sleep(250);
   }
   if(g_Logger) g_Logger.WriteError(StringFormat("[风控] 止损设置失败 (已重试%d次) ret=%d", maxRetries, t.ResultRetcode()));
   return false;
}


bool CanOpenNewTrade(const SRiskInputs &inputs, bool dbg=false)
{
   if(!inputs.AllowNewTrade) return false;
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
   double limitVal = rm_dayStartBalance * inputs.dailyLossLimitPct / 100.0;
   if(loss > 0 && limitVal > 0 && loss >= limitVal)
   {
      rm_dayLossLimitHit = true;
      if(g_Logger) g_Logger.WriteWarning(StringFormat("已达到每日亏损限制 (%.2f%%)，今日停止开新仓。", inputs.dailyLossLimitPct));
      return false;
   }
   return true;
}
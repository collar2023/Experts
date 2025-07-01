//+------------------------------------------------------------------+
//| SuperTrend EA – v4.0 (二次进场 + 止损三级防御 + 冷却期)          |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "4.0"
#property strict

//===================== 模块引入 =====================================
#include <Trade/Trade.mqh>
#include <Arrays/ArrayDouble.mqh>          // CArrayDouble 用
#include "SuperTrend_LogModule.mqh"
#include "Risk_Management_Module.mqh"      // v2.6.1
#include "SuperTrend_Entry_Module.mqh"
#include "SAR_ADX_Exit_Module.mqh"
#include "Common_Defines.mqh"

//===================== 全局对象 & 变量 ===============================
CLogModule* g_Logger   = NULL;     // 指针，但 MQL5 允许用点号调用
CTrade      g_trade;

input group "--- Core Settings ---"
input bool   EnableDebug             = true;
input int    EmergencyATRPeriod      = 14;
input double EmergencyATRMultiplier  = 1.5;
input int    Entry_CooldownBars      = 3;
input double MinATRMultipleToTrade   = 0.1;

//——— 二次进场极值记录 ——//
double g_lastTrendHigh = 0.0;
double g_lastTrendLow  = 0.0;

//——— 运行时变量 ——//
datetime g_lastOpenTime       = 0;
int      g_emergencyAtrHandle = INVALID_HANDLE;

bool   g_step1Done = false;
bool   g_step2Done = false;
double g_initialSL = 0.0;
static int bars_to_wait_for_next_trade = 0;

//===================== 工具函数 =====================================
double MarketBid(){ double v; SymbolInfoDouble(_Symbol,SYMBOL_BID ,v); return v; }
double MarketAsk(){ double v; SymbolInfoDouble(_Symbol,SYMBOL_ASK ,v); return v; }

//===================== 止损候选计算 (三级防御) =======================
double CalculateAndValidateStopLosses(double openPrice,
                                      double baseSL,
                                      ENUM_ORDER_TYPE type,
                                      CArrayDouble   &validSLs)
{
   validSLs.Clear();
   double baseFinalSL = CalculateFinalStopLoss(openPrice, baseSL, type);
   double emergencySL = GetSaferEmergencyStopLoss(openPrice, baseSL, type);

   ENUM_POSITION_TYPE pType = (type==ORDER_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);

   if(MathIsValidNumber(baseFinalSL) && IsStopLossValid(baseFinalSL,pType))
      validSLs.Add(baseFinalSL);

   if(MathIsValidNumber(emergencySL) && IsStopLossValid(emergencySL,pType))
      validSLs.Add(emergencySL);

   if(validSLs.Total()==0)
      return (MathIsValidNumber(baseSL) && IsStopLossValid(baseSL,pType)) ? baseSL : 0.0;

   double finalSL = validSLs.At(0);
   for(int i=1;i<validSLs.Total();i++)
      finalSL = (type==ORDER_TYPE_BUY) ? MathMin(finalSL,validSLs.At(i))
                                       : MathMax(finalSL,validSLs.At(i));
   return finalSL;
}

//===================== 紧急 ATR 止损 ================================
double GetSaferEmergencyStopLoss(double openP,double originalSL,ENUM_ORDER_TYPE orderType)
{
   double safeDist = MathAbs(openP-originalSL);
   double atr[1];
   if(g_emergencyAtrHandle!=INVALID_HANDLE &&
      CopyBuffer(g_emergencyAtrHandle,0,0,1,atr)>0 && atr[0]>0)
      safeDist = MathMax(safeDist, atr[0]*EmergencyATRMultiplier);

   return (orderType==ORDER_TYPE_BUY)
          ? NormalizePrice(openP-safeDist)
          : NormalizePrice(openP+safeDist);
}

//===================== 开仓函数 (含三级防御) =========================
bool OpenMarketOrder_Fixed(ENUM_ORDER_TYPE orderType,
                           double originalSL,
                           double tpPrice      = 0,
                           string comment      = "ST‑EA v4.0")
{
   double lot = CalculateLotSize(originalSL, orderType);
   if(lot<=0)
   { if(EnableDebug && g_Logger!=NULL) g_Logger.WriteWarning("手数=0，跳过"); return false; }

   double estPrice = (orderType==ORDER_TYPE_BUY)?MarketAsk():MarketBid();
   g_trade.SetDeviationInPoints((int)Risk_slippage);
   if(!g_trade.PositionOpen(_Symbol,orderType,lot,estPrice,0,0,comment))
   { if(g_Logger) g_Logger.WriteError(StringFormat("开仓失败 %d",GetLastError())); return false; }

   if(!PositionSelect(_Symbol))
   { if(g_Logger) g_Logger.WriteError("选中仓位失败"); return false; }

   double openP = PositionGetDouble(POSITION_PRICE_OPEN);

   CArrayDouble slPool;
   double finalSL = CalculateAndValidateStopLosses(openP,originalSL,orderType,slPool);
   if(finalSL==0.0)
   { g_trade.PositionClose(_Symbol); return false; }

   if(!SetStopLossWithRetry(g_trade,finalSL,tpPrice,3))
   { g_trade.PositionClose(_Symbol); return false; }

   if(g_Logger) g_Logger.WriteInfo(StringFormat("开仓 %.2f 手，SL=%.5f",lot,finalSL));
   return true;
}

//=========================== OnInit =================================
int OnInit()
{
   if(!InitializeLogger(LOG_LEVEL_INFO))
   { Print("日志初始化失败"); return INIT_FAILED; }

   g_Logger.WriteInfo("SuperTrend EA v4.0 启动");

   InitRiskModule();                                  // void，无返回
   if(!InitEntryModule(_Symbol,_Period))
   { g_Logger.WriteError("Entry 模块失败"); return INIT_FAILED; }
   if(!InitExitModule (_Symbol,_Period))
   { g_Logger.WriteError("Exit 模块失败");  return INIT_FAILED; }

   g_emergencyAtrHandle = iATR(_Symbol,_Period,EmergencyATRPeriod);
   if(g_emergencyAtrHandle==INVALID_HANDLE)
   { g_Logger.WriteError("ATR 句柄失败"); return INIT_FAILED; }

   ConfigureTrader(g_trade);
   return INIT_SUCCEEDED;
}

//=========================== OnDeinit ===============================
void OnDeinit(const int reason)
{
   DeinitEntryModule(); DeinitExitModule(); DeinitRiskModule();
   if(g_emergencyAtrHandle!=INVALID_HANDLE) IndicatorRelease(g_emergencyAtrHandle);
   if(g_Logger){ g_Logger.WriteInfo("EA 停止"); CleanupLogger(); }
}

//=========================== OnTick =================================
void OnTick()
{
   if(bars_to_wait_for_next_trade>0){ bars_to_wait_for_next_trade--; return; }

   if(PositionSelect(_Symbol)){ ManagePosition(); return; }

   if(!CanOpenNewTrade(EnableDebug)) return;

   double sl_price=0; ENUM_ORDER_TYPE sig=GetEntrySignal(sl_price);
   if(sig==ORDER_TYPE_NONE) return;

   // 二次进场过滤
   if(sig==ORDER_TYPE_BUY && g_lastTrendHigh>0 && MarketAsk()<=g_lastTrendHigh) return;
   if(sig==ORDER_TYPE_SELL&& g_lastTrendLow >0 && MarketBid() >=g_lastTrendLow) return;

   // ATR 距离过滤
   if(g_emergencyAtrHandle!=INVALID_HANDLE)
   {
      double atr[1];
      if(CopyBuffer(g_emergencyAtrHandle,0,0,1,atr)>0 && atr[0]>0)
      {
         double price=(sig==ORDER_TYPE_BUY)?MarketAsk():MarketBid();
         double distPts=fabs(price-sl_price)/_Point;
         if(distPts<(atr[0]/_Point)*MinATRMultipleToTrade) return;
      }
   }

   OpenPosition(sig,sl_price);
}

//=========================== OpenPosition ===========================
void OpenPosition(ENUM_ORDER_TYPE type,double sl)
{
   if(OpenMarketOrder_Fixed(type,sl))
   {
      g_initialSL=sl; g_step1Done=g_step2Done=false;
      g_lastOpenTime=TimeCurrent();
      g_lastTrendHigh=0.0; g_lastTrendLow=0.0;
      bars_to_wait_for_next_trade=Entry_CooldownBars;
   }
}

//======================== ManagePosition ===========================
void ManagePosition()
{
   ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   if(pt==POSITION_TYPE_BUY)
   {
      double h=iHigh(_Symbol,_Period,0);
      if(g_lastTrendHigh==0.0||h>g_lastTrendHigh) g_lastTrendHigh=h;
   }
   else
   {
      double l=iLow(_Symbol,_Period,0);
      if(g_lastTrendLow ==0.0||l<g_lastTrendLow ) g_lastTrendLow =l;
   }

   double openP=PositionGetDouble(POSITION_PRICE_OPEN);
   double pct  =(pt==POSITION_TYPE_BUY)?
                 GetLongExitAction(openP,g_initialSL,g_step1Done,g_step2Done):
                 GetShortExitAction(openP,g_initialSL,g_step1Done,g_step2Done);
   if(pct<=0) return;

   if(pct>=100)
   { g_trade.PositionClose(_Symbol); bars_to_wait_for_next_trade=Entry_CooldownBars; return; }

   double vol=PositionGetDouble(POSITION_VOLUME);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double cls=MathFloor((vol*pct/100.0)/step)*step;
   cls=MathMax(cls,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   if(cls>0 && cls<vol)
   {
      g_trade.PositionClosePartial(_Symbol,cls);
      bars_to_wait_for_next_trade=Entry_CooldownBars;
   }
}
//+------------------------------------------------------------------+

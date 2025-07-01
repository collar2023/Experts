//+------------------------------------------------------------------+
//| SuperTrend EA – v5.6 (最终版 - 日志增强)                         |
//+------------------------------------------------------------------+
//|                                     © 2025                       |
//|  • 日志增强: 在 ManagePosition 函数中为R倍数部分平仓添加了明确的 |
//|    日志记录，便于回测分析。                                      |
//|  • 继承修复: 完整继承v5.5版本的所有终极修复方案。                |
//|  • 架构: 依赖 v2.6 风控模块与 v1.7 结构性出场模块。              |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "5.6"
#property strict

//===================== 模块引入 =====================================
#include <Trade/Trade.mqh>
#include <Arrays/ArrayDouble.mqh>
#include "SuperTrend_LogModule.mqh"
#include "Risk_Management_Module.mqh"
#include "SuperTrend_Entry_Module.mqh"
#include "SAR_ADX_Exit_Module.mqh"
#include "Structural_Exit_Module.mqh"
#include "Common_Defines.mqh"

//===================== 全局对象 & 变量 ===============================
CLogModule* g_Logger = NULL;
CTrade      g_trade;

enum ENUM_BASE_EXIT_MODE { EXIT_MODE_STRUCTURAL, EXIT_MODE_SAR, EXIT_MODE_NONE };
input group "--- Strategy Mode ---"
input ENUM_BASE_EXIT_MODE BaseExitStrategy = EXIT_MODE_STRUCTURAL;
input bool Enable_R_Multiple_Exit = true;
input group "--- Core Settings ---"
input bool   EnableDebug             = true;
input int    EmergencyATRPeriod      = 14;
input double EmergencyATRMultiplier  = 1.5;
input int    Entry_CooldownSeconds   = 0;
input double MinATRMultipleToTrade   = 0.1;
input group "--- Structural Exit Settings (Mode 1) ---"
input bool   SE_EnableBreakeven      = true;
input double SE_BreakevenTriggerRR   = 1.0;
input double SE_BreakevenBufferPips  = 5.0;
input bool   SE_EnableStructureStop  = true;
input int    SE_StructureLookback    = 21;
input double SE_StructureBufferPips  = 10.0;
input bool   SE_EnableATRFallback    = true;
input int    SE_ATRTrailPeriod       = 14;
input double SE_ATRTrailMultiplier   = 2.5;

SStructuralExitInputs g_structExitInputs;
double       g_lastTrendHigh         = 0.0;
double       g_lastTrendLow          = 0.0;
datetime     g_lastOpenTime          = 0;
int          g_emergencyAtrHandle    = INVALID_HANDLE;
bool   g_step1Done = false;
bool   g_step2Done = false;
double g_initialSL = 0.0;

//===================== 工具函数 =====================================
double MarketBid() { double v; SymbolInfoDouble(_Symbol, SYMBOL_BID,  v); return v; }
double MarketAsk() { double v; SymbolInfoDouble(_Symbol, SYMBOL_ASK, v); return v; }

//===================== 开仓函数 (v5.5 终极修复版) ======================
bool OpenMarketOrder_Fixed(ENUM_ORDER_TYPE orderType, double originalSL, double tpPrice = 0, string comment = "ST-EA")
{
   double lot = CalculateLotSize(originalSL, orderType);
   if(lot <= 0.0) return false;
   double estPrice = (orderType == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
   if(!g_trade.PositionOpen(_Symbol, orderType, lot, estPrice, 0, 0, comment)) return false;
   if(!PositionSelect(_Symbol)) return false;
   
   double openP = PositionGetDouble(POSITION_PRICE_OPEN);

   // 全新、安全的三级防御止损决策逻辑
   double baseFinalSL = CalculateFinalStopLoss(openP, originalSL, orderType);
   double emergencySL = GetSaferEmergencyStopLoss(openP, originalSL, orderType);

   CArrayDouble valid_sl_candidates;
   if(orderType == ORDER_TYPE_BUY)
   {
      if(baseFinalSL != 0 && baseFinalSL < openP) valid_sl_candidates.Add(baseFinalSL);
      if(emergencySL != 0 && emergencySL < openP) valid_sl_candidates.Add(emergencySL);
   }
   else
   {
      if(baseFinalSL != 0 && baseFinalSL > openP) valid_sl_candidates.Add(baseFinalSL);
      if(emergencySL != 0 && emergencySL > openP) valid_sl_candidates.Add(emergencySL);
   }

   double finalSL = 0;
   if(valid_sl_candidates.Total() > 0)
   {
      finalSL = valid_sl_candidates.At(0);
      for(int i = 1; i < valid_sl_candidates.Total(); i++)
      {
         finalSL = (orderType == ORDER_TYPE_BUY) ? MathMin(finalSL, valid_sl_candidates.At(i)) : MathMax(finalSL, valid_sl_candidates.At(i));
      }
   }
   else
   {
      finalSL = baseFinalSL;
      if(g_Logger != NULL && finalSL != 0) g_Logger.WriteWarning("所有候选SL方向/有效性均不合法，启用最终后备SL。");
   }

   if(finalSL == 0 || !MathIsValidNumber(finalSL))
   {
       if(g_Logger != NULL) g_Logger.WriteError("🚨 无法计算出任何有效的止损价，执行保护性平仓！");
       g_trade.PositionClose(_Symbol);
       return false;
   }

   if(!SetStopLossWithRetry(g_trade, finalSL, tpPrice, 3))
   {
      if(g_Logger != NULL) g_Logger.WriteError("🚨 无法设置最终安全止损，执行保护性平仓");
      g_trade.PositionClose(_Symbol);
      return false;
   }
   
   if(g_Logger != NULL) g_Logger.WriteInfo(StringFormat("开仓成功: %.2f 手 @ %.5f | Final SL=%.5f (已通过全程监控+三级防御)", lot, openP, finalSL));
   return true;
}

//===================== 安全应急 SL 计算 (v5.5 终极修复版) ==============
double GetSaferEmergencyStopLoss(double openP, double originalSL, ENUM_ORDER_TYPE orderType)
{
   if (!MathIsValidNumber(openP) || !MathIsValidNumber(originalSL)) return 0.0;
   double oriRisk = MathAbs(openP - originalSL);
   if (!MathIsValidNumber(oriRisk)) return 0.0;

   double atr[1];
   double safeDist = oriRisk; 
   if(g_emergencyAtrHandle != INVALID_HANDLE && CopyBuffer(g_emergencyAtrHandle, 0, 0, 1, atr) == 1 && atr[0] > 0)
   {
      double currentPrice = (orderType == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
      if(atr[0] < currentPrice)
      {
         double atrDist = atr[0] * EmergencyATRMultiplier;
         safeDist = MathMax(oriRisk, atrDist);
      }
   }
   
   double finalSL = (orderType == ORDER_TYPE_BUY) ? (openP - safeDist) : (openP + safeDist);
   if (!MathIsValidNumber(finalSL)) return 0.0;
   return finalSL;
}

//=========================== OnInit =================================
int OnInit()
{
   if(!InitializeLogger(LOG_LEVEL_INFO)) { Print("日志初始化失败"); return INIT_FAILED; }
   g_Logger.WriteInfo("EA v5.6 启动 (日志增强版)");
   InitRiskModule();
   if(!InitEntryModule(_Symbol, _Period)) return INIT_FAILED;
   if(!InitExitModule(_Symbol, _Period)) return INIT_FAILED;
   if(BaseExitStrategy == EXIT_MODE_STRUCTURAL)
   {
      g_structExitInputs.EnableStructuralExit = true; g_structExitInputs.EnableBreakeven = SE_EnableBreakeven;
      g_structExitInputs.BreakevenTriggerRR = SE_BreakevenTriggerRR; g_structExitInputs.BreakevenBufferPips = SE_BreakevenBufferPips;
      g_structExitInputs.EnableStructureStop = SE_EnableStructureStop; g_structExitInputs.StructureLookback = SE_StructureLookback;
      g_structExitInputs.StructureBufferPips = SE_StructureBufferPips; g_structExitInputs.EnableATRFallback = SE_EnableATRFallback;
      g_structExitInputs.ATRTrailPeriod = SE_ATRTrailPeriod; g_structExitInputs.ATRTrailMultiplier = SE_ATRTrailMultiplier;
      if(!InitStructuralExitModule(g_structExitInputs)) return INIT_FAILED;
   }
   g_emergencyAtrHandle = iATR(_Symbol, _Period, EmergencyATRPeriod);
   if(g_emergencyAtrHandle == INVALID_HANDLE) return INIT_FAILED;
   ConfigureTrader(g_trade);
   return INIT_SUCCEEDED;
}

//=========================== OnDeinit ===============================
void OnDeinit(const int reason)
{
   DeinitRiskModule(); DeinitEntryModule(); DeinitExitModule(); 
   if(BaseExitStrategy == EXIT_MODE_STRUCTURAL) DeinitStructuralExitModule();
   if(g_emergencyAtrHandle != INVALID_HANDLE) IndicatorRelease(g_emergencyAtrHandle);
   if(g_Logger != NULL) g_Logger.WriteInfo("EA 停止，清理模块");
}

//=========================== OnTick =================================
void OnTick()
{
   if(PositionSelect(_Symbol)) { ManagePosition(); return; }
   if(!CanOpenNewTrade(EnableDebug)) return;
   if(g_lastOpenTime > 0 && TimeCurrent() - g_lastOpenTime < Entry_CooldownSeconds) return;
   double sl_price = 0;
   ENUM_ORDER_TYPE sig = GetEntrySignal(sl_price);
   if(sig == ORDER_TYPE_NONE) return;
   if(sig == ORDER_TYPE_BUY) { if(g_lastTrendHigh > 0 && MarketAsk() <= g_lastTrendHigh) return; }
   else if(sig == ORDER_TYPE_SELL) { if(g_lastTrendLow > 0 && MarketBid() >= g_lastTrendLow) return; }
   if(g_emergencyAtrHandle != INVALID_HANDLE)
   {
      double atrBuf[1];
      if(CopyBuffer(g_emergencyAtrHandle, 0, 0, 1, atrBuf) == 1 && atrBuf[0] > 0)
      {
         double price = (sig == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
         double distPts = MathAbs(price - sl_price) / _Point;
         double minDist = (atrBuf[0] / _Point) * MinATRMultipleToTrade;
         if(distPts < minDist) return;
      }
   }
   OpenPosition(sig, sl_price);
}

//=========================== 开仓接口 ================================
void OpenPosition(ENUM_ORDER_TYPE type, double sl)
{
   bool ok = OpenMarketOrder_Fixed(type, sl, 0, "ST-EA v5.6");
   if(ok)
   {
      g_initialSL = sl; g_step1Done = false; g_step2Done = false;
      g_lastOpenTime = TimeCurrent(); g_lastTrendHigh = 0.0; g_lastTrendLow = 0.0;
   }
}

//======================== 持仓管理函数 (v5.6 日志增强版) ======================
void ManagePosition()
{
   static datetime last_bar_time = 0;
   datetime current_bar_time = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(current_bar_time > last_bar_time)
   {
      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pType == POSITION_TYPE_BUY) { double prevHigh = iHigh(_Symbol, _Period, 1); if(g_lastTrendHigh == 0.0 || prevHigh > g_lastTrendHigh) g_lastTrendHigh = prevHigh; }
      else { double prevLow = iLow(_Symbol, _Period, 1); if(g_lastTrendLow == 0.0 || prevLow < g_lastTrendLow) g_lastTrendLow = prevLow; }
      last_bar_time = current_bar_time;
   }
   
   if(BaseExitStrategy == EXIT_MODE_STRUCTURAL) ManageStructuralExit(g_trade, g_structExitInputs, g_initialSL);
   
   if(Enable_R_Multiple_Exit)
   {
      if(!PositionSelect(_Symbol)) return;
      double openP = PositionGetDouble(POSITION_PRICE_OPEN); ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double pct = (pType == POSITION_TYPE_BUY) ? GetLongExitAction(openP, g_initialSL, g_step1Done, g_step2Done) : GetShortExitAction(openP, g_initialSL, g_step1Done, g_step2Done);
      
      if(pct > 0.0)
      {
         // 全仓平仓（通常由SAR触发）的日志由其模块内部的Print()函数负责
         if(pct >= 100.0) 
         {
            g_trade.PositionClose(_Symbol);
         }
         else // 部分平仓
         {
            double vol = PositionGetDouble(POSITION_VOLUME); double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double volClose = MathFloor((vol * pct / 100.0) / step) * step; volClose = MathMax(volClose, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
            
            if(volClose > 0 && volClose < vol)
            {
               // ★★★ 核心修复：在这里添加明确的日志记录 ★★★
               if(g_trade.PositionClosePartial(_Symbol, volClose))
               {
                  if(g_Logger != NULL) 
                     g_Logger.WriteInfo(StringFormat("R-Multiple 部分止盈: 平仓 %.2f 手 (目标平仓比例 %.1f%%)", volClose, pct));

                  if(g_step1Done == false) g_step1Done = true;
                  else if(g_step2Done == false) g_step2Done = true;
               }
            }
         }
      }
   }
}
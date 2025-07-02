//+------------------------------------------------------------------+
//| SuperTrend EA – v5.6(参数显性化终极版)                          |
//+------------------------------------------------------------------+
//|                                     © 2025                       |
//|  • 终极重构: 将所有风控参数显性化，通过结构体传递。                |
//|    彻底解决了所有编译报错和参数作用域问题。                        |
//|  • 继承 v5.6.3 的所有功能，包括异步止损、v1.8模块接口等。          |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "5.6" // 参数显性化终极版
#property strict

//===================== 模块引入 =====================================
#include <Trade/Trade.mqh>
#include <Arrays/ArrayDouble.mqh>
#include "SuperTrend_LogModule.mqh"
#include "Risk_Management_Module.mqh" // v2.7
#include "SuperTrend_Entry_Module.mqh"
#include "SAR_ADX_Exit_Module.mqh"
#include "Structural_Exit_Module.mqh"
#include "Common_Defines.mqh"

//===================== 全局对象 & 变量 ===============================
CLogModule* g_Logger = NULL;
CTrade      g_trade;

enum ENUM_BASE_EXIT_MODE { EXIT_MODE_STRUCTURAL, EXIT_MODE_SAR, EXIT_MODE_NONE };
enum ENUM_SE_UPDATE_FREQ { SE_FREQ_EVERY_TICK, SE_FREQ_EVERY_BAR, SE_FREQ_EVERY_N_BARS };

input group "--- Strategy Mode ---"
input ENUM_BASE_EXIT_MODE BaseExitStrategy = EXIT_MODE_STRUCTURAL;
input bool Enable_R_Multiple_Exit = true;

input group "--- Core Settings ---"
input bool   EnableDebug             = true;
input int    EmergencyATRPeriod      = 14;
input double EmergencyATRMultiplier  = 1.5;
input int    Entry_CooldownSeconds   = 0;
input double MinATRMultipleToTrade   = 0.1;

input group "--- Risk Management Settings ---" // ★★★ 风控参数集中于此 ★★★
input bool     Risk_useFixedLot        = false;
input double   Risk_fixedLot           = 0.01;
input double   Risk_riskPercent        = 1.0;
input double   Risk_minStopATRMultiple = 1.0;
input int      Risk_atrPeriod          = 14;
input double   Risk_minStopPoints      = 10.0;
input double   Risk_maxLotByBalance    = 50.0;
input double   Risk_maxAbsoluteLot     = 1.0;
input bool     Risk_enableLotLimit     = true;
input double   Risk_slippage           = 3;
input double   Risk_dailyLossLimitPct  = 10.0;
input bool     Risk_AllowNewTrade      = true;

input group "--- Structural Exit Settings (Mode 1) ---"
input bool   SE_EnableBreakeven      = true;
input double SE_BreakevenTriggerRR   = 1.0;
input double SE_BreakevenBufferPips  = 5.0;
input bool   SE_EnableStructureStop  = true;
input int    SE_StructureLookback    = 21;
input double SE_StructureBufferPips  = 20.0;
input bool   SE_EnableATRFallback    = true;
input int    SE_ATRTrailPeriod       = 14;
input double SE_ATRTrailMultiplier   = 2.5;

input group "--- Structural Exit v1.8 Frequency Control ---"
input ENUM_SE_UPDATE_FREQ SE_UpdateFrequency = SE_FREQ_EVERY_BAR;
input int                 SE_UpdateInterval  = 3;
input int                 SE_CooldownBars    = 5;
input int                 SE_MinHoldBars     = 3;

// ★★★ 参数结构体实例 ★★★
SStructuralExitInputs g_structExitInputs;
SRiskInputs           g_riskInputs;

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

//===================== 开仓函数 ==================
bool OpenMarketOrder_Fixed(ENUM_ORDER_TYPE orderType, double originalSL, double tpPrice = 0, string comment = "ST-EA")
{
   double lot = CalculateLotSize(originalSL, orderType, g_riskInputs);
   if(lot <= 0.0) return false;
   
   double estPrice = (orderType == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
   if(!g_trade.PositionOpen(_Symbol, orderType, lot, estPrice, 0, 0, comment))
   {
      if(g_Logger != NULL) g_Logger.WriteError(StringFormat("裸单开仓失败，错误代码: %d", g_trade.ResultRetcode()));
      return false;
   }
   
   if(!PositionSelect(_Symbol)) 
   {
      if(g_Logger != NULL) g_Logger.WriteError("裸单开仓后无法选中仓位，无法设置止损！");
      return true;
   }
   
   if(g_Logger != NULL) g_Logger.WriteInfo(StringFormat("裸单开仓成功: %.2f 手 @ %.5f。立即开始设置止损...", lot, PositionGetDouble(POSITION_PRICE_OPEN)));

   double openP = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)orderType;
   
   CArrayDouble valid_sl_candidates;
   double normalized_originalSL = NormalizePrice(originalSL);
   if (IsStopLossValid(normalized_originalSL, posType)) valid_sl_candidates.Add(normalized_originalSL);
   
   double baseFinalSL = CalculateFinalStopLoss(openP, originalSL, orderType, g_riskInputs);
   if (IsStopLossValid(baseFinalSL, posType) && valid_sl_candidates.Search(baseFinalSL) < 0) valid_sl_candidates.Add(baseFinalSL);
   
   double emergencySL = GetSaferEmergencyStopLoss(openP, originalSL, orderType);
   if (IsStopLossValid(emergencySL, posType) && valid_sl_candidates.Search(emergencySL) < 0) valid_sl_candidates.Add(emergencySL);

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
      if(g_Logger != NULL) g_Logger.WriteError("🚨 严重警告：所有候选SL均不合法，仓位暂时无止损保护！");
      return true;
   }

   if(finalSL != 0 && MathIsValidNumber(finalSL))
   {
      if(!SetStopLossWithRetry(g_trade, finalSL, tpPrice, 3))
      {
         if(g_Logger != NULL) g_Logger.WriteError("🚨 警告：异步设置止损失败，仓位暂时无止损保护！EA将在下一Tick重试。");
      }
      else
      {
         if(g_Logger != NULL) g_Logger.WriteInfo(StringFormat("异步设置止损成功: Final SL=%.5f", finalSL));
      }
   }
   
   return true;
}

//===================== 安全应急 SL 计算 =====================
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
   return NormalizePrice(finalSL);
}

//=========================== OnInit =================================
int OnInit()
{
   if(!InitializeLogger(LOG_LEVEL_INFO)) { Print("日志初始化失败"); return INIT_FAILED; }
   g_Logger.WriteInfo("EA v5.6.4 启动 (参数显性化终极版)");

   // ★★★ 核心修改：填充风控参数结构体 ★★★
   g_riskInputs.useFixedLot        = Risk_useFixedLot;
   g_riskInputs.fixedLot           = Risk_fixedLot;
   g_riskInputs.riskPercent        = Risk_riskPercent;
   g_riskInputs.minStopATRMultiple = Risk_minStopATRMultiple;
   g_riskInputs.atrPeriod          = Risk_atrPeriod;
   g_riskInputs.minStopPoints      = Risk_minStopPoints;
   g_riskInputs.maxLotByBalance    = Risk_maxLotByBalance;
   g_riskInputs.maxAbsoluteLot     = Risk_maxAbsoluteLot;
   g_riskInputs.enableLotLimit     = Risk_enableLotLimit;
   g_riskInputs.slippage           = Risk_slippage;
   g_riskInputs.dailyLossLimitPct  = Risk_dailyLossLimitPct;
   g_riskInputs.AllowNewTrade      = Risk_AllowNewTrade;

   InitRiskModule(g_riskInputs);
   if(!InitEntryModule(_Symbol, _Period)) return INIT_FAILED;
   if(!InitExitModule(_Symbol, _Period)) return INIT_FAILED;
   
   if(BaseExitStrategy == EXIT_MODE_STRUCTURAL)
   {
      g_structExitInputs.EnableStructuralExit = true; 
      g_structExitInputs.EnableBreakeven = SE_EnableBreakeven;
      g_structExitInputs.BreakevenTriggerRR = SE_BreakevenTriggerRR; 
      g_structExitInputs.BreakevenBufferPips = SE_BreakevenBufferPips;
      g_structExitInputs.EnableStructureStop = SE_EnableStructureStop; 
      g_structExitInputs.StructureLookback = SE_StructureLookback;
      g_structExitInputs.StructureBufferPips = SE_StructureBufferPips; 
      g_structExitInputs.EnableATRFallback = SE_EnableATRFallback;
      g_structExitInputs.ATRTrailPeriod = SE_ATRTrailPeriod; 
      g_structExitInputs.ATRTrailMultiplier = SE_ATRTrailMultiplier;
      g_structExitInputs.UpdateFrequency = (int)SE_UpdateFrequency;
      g_structExitInputs.UpdateInterval = SE_UpdateInterval;
      g_structExitInputs.CooldownBars = SE_CooldownBars;
      g_structExitInputs.MinHoldBars = SE_MinHoldBars;
      if(!InitStructuralExitModule(g_structExitInputs)) return INIT_FAILED;
   }
   
   g_emergencyAtrHandle = iATR(_Symbol, _Period, EmergencyATRPeriod);
   if(g_emergencyAtrHandle == INVALID_HANDLE) return INIT_FAILED;
   ConfigureTrader(g_trade, g_riskInputs);
   return INIT_SUCCEEDED;
}

//=========================== OnDeinit ===============================
void OnDeinit(const int reason)
{
   DeinitRiskModule(); DeinitEntryModule(); DeinitExitModule(); 
   if(BaseExitStrategy == EXIT_MODE_STRUCTURAL)
   {
      DeinitStructuralExitModule();
      ResetPositionRecord();
   }
   if(g_emergencyAtrHandle != INVALID_HANDLE) IndicatorRelease(g_emergencyAtrHandle);
   if(g_Logger != NULL) g_Logger.WriteInfo("EA 停止，清理模块");
}

//=========================== OnTick =================================
void OnTick()
{
   if(PositionSelect(_Symbol)) 
   {
      ManagePosition();
   }
   else
   {
      if(BaseExitStrategy == EXIT_MODE_STRUCTURAL) ResetPositionRecord(); 
      if(!CanOpenNewTrade(g_riskInputs, EnableDebug)) return;
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
}

//=========================== 开仓接口 ================================
void OpenPosition(ENUM_ORDER_TYPE type, double sl)
{
   bool ok = OpenMarketOrder_Fixed(type, sl, 0, "ST-EA v5.6.3");
   if(ok)
   {
      g_initialSL = sl; g_step1Done = false; g_step2Done = false;
      g_lastOpenTime = TimeCurrent(); g_lastTrendHigh = 0.0; g_lastTrendLow = 0.0;
      if(BaseExitStrategy == EXIT_MODE_STRUCTURAL && PositionSelect(_Symbol))
      {
         ulong ticket = PositionGetTicket(0);
         RecordPositionOpen(ticket);
         if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("v1.8模块已记录新开仓位，票据: %d", ticket));
      }
   }
}

//======================== 持仓管理函数 ======================
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
   
   if(BaseExitStrategy == EXIT_MODE_STRUCTURAL) 
   {
      if(PositionSelect(_Symbol))
      {
         ulong ticket = PositionGetTicket(0);
         ProcessStructuralExit(g_structExitInputs, ticket);
      }
   }
   
   if(Enable_R_Multiple_Exit)
   {
      if(!PositionSelect(_Symbol)) return;
      double openP = PositionGetDouble(POSITION_PRICE_OPEN); ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double pct = (pType == POSITION_TYPE_BUY) ? GetLongExitAction(openP, g_initialSL, g_step1Done, g_step2Done) : GetShortExitAction(openP, g_initialSL, g_step1Done, g_step2Done);
      
      if(pct > 0.0)
      {
         if(pct >= 100.0) 
         {
            g_trade.PositionClose(_Symbol);
            if(BaseExitStrategy == EXIT_MODE_STRUCTURAL) ResetPositionRecord(); 
         }
         else
         {
            double vol = PositionGetDouble(POSITION_VOLUME); double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double volClose = MathFloor((vol * pct / 100.0) / step) * step; volClose = MathMax(volClose, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
            
            if(volClose > 0 && volClose < vol)
            {
               if(g_trade.PositionClosePartial(_Symbol, volClose))
               {
                  if(g_Logger != NULL) g_Logger.WriteInfo(StringFormat("R-Multiple 部分止盈: 平仓 %.2f 手 (目标平仓比例 %.1f%%)", volClose, pct));
                  if(g_step1Done == false) g_step1Done = true;
                  else if(g_step2Done == false) g_step2Done = true;
               }
            }
         }
      }
   }
}
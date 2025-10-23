//+------------------------------------------------------------------+
//| SuperTrend EA – v4.9(实盘修正版)                              |
//+------------------------------------------------------------------+
//|                                     © 2025                       |
//|  • 修复: 为平仓事件检测添加触发锁，彻底解决日志刷屏问题。        |
//|  • 修复: 优化二次进场观察点记录逻辑，使日志更清晰、准确。        |
//|  • 继承: 所有v4.9的协同二次进场和参数化功能。                    |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "4.9" // 实盘修正版

const string G_EA_VERSION = "4.9";

//===================== 模块引入 =====================================
#include <Trade/Trade.mqh>
#include <Trade/DealInfo.mqh>
#include <Arrays/ArrayDouble.mqh>

#include "EA_Parameter_Structs_v4.9.mqh"
#include "SuperTrend_LogModule.mqh"
#include "Risk_Management_Module.mqh"
#include "SuperTrend_Entry_Module.mqh"
#include "Structural_Exit_Module.mqh"

//===================== 全局对象 & 变量 ===============================
CLogModule* g_Logger = NULL;
CTrade      g_trade;

// --- General Settings ---
input group "--- General Settings ---"
input long   InpMagicNumber          = 123456;
input bool   EnableDebug             = true;

// --- Core Logic ---
input group "--- Core Logic ---"
input int    EmergencyATRPeriod      = 14;
input double EmergencyATRMultiplier  = 1.5;
input int    Entry_CooldownSeconds   = 0;
input double MinATRMultipleToTrade   = 0.1;

// --- Logging Settings ---
input group "--- Logging Settings ---";
input LOG_EB_LEVEL InpLogLevel           = LOG_LEVEL_INFO;
input bool         InpEnableFileLog      = true;
input bool         InpEnableConsoleLog   = true;

// --- Risk Management Settings ---
input group "--- Risk Management Settings ---"
input bool     Risk_useFixedLot        = false;
input double   Risk_fixedLot           = 0.01;
input double   Risk_riskPercent        = 1.0;
input double   Risk_minStopATRMultiple = 1.0;
input int      Risk_atrPeriod          = 14;
input double   Risk_minStopPoints      = 10.0;
input double   Risk_maxLotByBalance    = 50.0;
input double   Risk_maxAbsoluteLot     = 1.0;
input bool     Risk_enableLotLimit     = true;
input double   Risk_slippage           = 3.0;
input double   Risk_dailyLossLimitPct  = 10.0;
input bool     Risk_AllowNewTrade      = true;

// --- SuperTrend Entry Settings ---
input group    "--- SuperTrend Entry Settings ---"
input string   Entry_stIndicatorName    = "supertrend-free";
input int      Entry_atrPeriod          = 10;
input double   Entry_atrMultiplier      = 3.0;
input double   Entry_stopLossBufferPips = 10;
input group    "--- Dynamic Stop Loss Optimization ---"
input bool     Entry_useDynamicBuffer   = true;
input double   Entry_minBufferPips      = 5.0;
input double   Entry_maxBufferPips      = 30.0;
input double   Entry_sessionMultiplier  = 1.2;
input double   Entry_volatilityFactor   = 0.8;
input group    "--- Market Anomaly Detection ---"
input bool     Entry_useAnomalyDetection = true;
input double   Entry_newsBufferMultiplier = 1.5;
input double   Entry_highVolMultiplier   = 1.3;
input double   Entry_rangeBoundMultiplier = 0.8;
input group    "--- Entry Filter (ADX) ---"
input bool     Entry_useADXFilter       = false;
input int      Entry_adxPeriod          = 14;
input double   Entry_adxMinStrength     = 23.0;

// --- Structural Exit Settings ---
input group "--- Structural Exit Settings ---"
input bool   SE_EnableBreakeven      = true;
input double SE_BreakevenTriggerRR   = 1.5;
input double SE_BreakevenBufferPips  = 5.0;
input bool   SE_EnableStructureStop  = true;
input int    SE_StructureLookback    = 21;
input double SE_StructureBufferPips  = 3.0;
input bool   SE_EnableATRFallback    = true;
input int    SE_ATRTrailPeriod       = 14;
input double SE_ATRTrailMultiplier   = 1.5;
input group "--- Structural Exit Frequency Control ---"
input ENUM_SE_UPDATE_FREQ SE_UpdateFrequency = SE_FREQ_EVERY_BAR;
input int    SE_UpdateInterval              = 1;
input int    SE_CooldownBars                = 3;
input int    SE_MinHoldBars                 = 5;
input int    SE_ModifyRequestCooldownSeconds = 15;

// --- Re-Entry (After Exit) Settings ---
input group "--- Re-Entry (After Exit) Settings ---"
input bool   ReEntry_Enable         = true;
input double ReEntry_BufferPips     = 1.0;

// ★★★ 参数结构体实例 ★★★
SRiskInputs           g_riskInputs;
SEntryInputs          g_entryInputs;
SStructuralExitInputs g_structExitInputs;
SReEntryInputs        g_reEntryInputs;

//--- 内部状态变量 ---
datetime g_lastOpenTime           = 0;
int      g_emergencyAtrHandle     = INVALID_HANDLE;
double   g_initialSL              = 0.0;
bool     g_wasInPosition_lastTick = false;
double   g_reEntryHigh            = 0.0;
double   g_reEntryLow             = 0.0;

//===================== 工具函数 =====================================
double MarketBid() { double v; SymbolInfoDouble(_Symbol, SYMBOL_BID,  v); return v; }
double MarketAsk() { double v; SymbolInfoDouble(_Symbol, SYMBOL_ASK, v); return v; }

//===================== 开仓函数 =====================================
bool OpenPosition(ENUM_ORDER_TYPE orderType, double originalSL)
{
   string comment = "ST-EA v" + G_EA_VERSION;
   double lot = CalculateLotSize(originalSL, orderType, g_riskInputs);
   if(lot <= 0.0) return false;

   if(!g_trade.PositionOpen(_Symbol, orderType, lot, (orderType == ORDER_TYPE_BUY ? MarketAsk() : MarketBid()), 0, 0, comment))
   {
      if(g_Logger) g_Logger.WriteError(StringFormat("裸单开仓失败，错误代码: %d", g_trade.ResultRetcode()));
      return false;
   }

   if(!PositionSelect(_Symbol))
   {
      if(g_Logger) g_Logger.WriteError("裸单开仓后无法选中仓位，无法设置止损！");
      return true;
   }
   
   if(g_Logger) g_Logger.WriteInfo(StringFormat("裸单开仓成功: %.2f 手 @ %.5f。开始设置止损...", lot, PositionGetDouble(POSITION_PRICE_OPEN)));

   double openP = PositionGetDouble(POSITION_PRICE_OPEN);
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)orderType;

   CArrayDouble valid_sl_candidates;
   double normalized_originalSL = NormalizePrice(originalSL);
   if (IsStopLossValid(normalized_originalSL, posType)) valid_sl_candidates.Add(normalized_originalSL);
   
   double baseFinalSL = CalculateFinalStopLoss(openP, originalSL, orderType, g_riskInputs);
   if (IsStopLossValid(baseFinalSL, posType) && valid_sl_candidates.Search(baseFinalSL) < 0) valid_sl_candidates.Add(baseFinalSL);
   
   double atr[1];
   if(g_emergencyAtrHandle != INVALID_HANDLE && CopyBuffer(g_emergencyAtrHandle, 0, 0, 1, atr) == 1 && atr[0] > 0)
   {
        double emergencySL = (orderType == ORDER_TYPE_BUY) ? openP - (atr[0] * EmergencyATRMultiplier) : openP + (atr[0] * EmergencyATRMultiplier);
        emergencySL = NormalizePrice(emergencySL);
        if (IsStopLossValid(emergencySL, posType) && valid_sl_candidates.Search(emergencySL) < 0) valid_sl_candidates.Add(emergencySL);
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
      if(g_Logger) g_Logger.WriteError("🚨 严重警告：所有候选SL均不合法，仓位暂时无止损保护！");
      return true;
   }

   if(finalSL != 0 && MathIsValidNumber(finalSL))
   {
      if(!SetStopLossWithRetry(g_trade, finalSL, 0, 3, g_riskInputs))
      {
         if(g_Logger) g_Logger.WriteError("🚨 警告：异步设置止损失败，仓位暂时无止损保护！EA将在下一Tick重试。");
      }
      else
      {
         if(g_Logger) g_Logger.WriteInfo(StringFormat("异步设置止损成功: Final SL=%.5f", finalSL));
         g_initialSL = finalSL;
      }
   }
   return true;
}

//=========================== OnInit =================================
int OnInit()
{
   SLogInputs logInputs;
   logInputs.logLevel = InpLogLevel;
   logInputs.enableFileLog = InpEnableFileLog;
   logInputs.enableConsoleLog = InpEnableConsoleLog;
   logInputs.eaVersion = G_EA_VERSION;
   if(!InitializeLogger(logInputs)) { Print("日志初始化失败"); return INIT_FAILED; }
   g_Logger.WriteInfo("EA v" + G_EA_VERSION + " 启动 (实盘修正版)");

   g_riskInputs.magicNumber        = InpMagicNumber;
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
   g_riskInputs.allowNewTrade      = Risk_AllowNewTrade;

   g_entryInputs.stIndicatorName       = Entry_stIndicatorName;
   g_entryInputs.atrPeriod             = Entry_atrPeriod;
   g_entryInputs.atrMultiplier         = Entry_atrMultiplier;
   g_entryInputs.stopLossBufferPips    = Entry_stopLossBufferPips;
   g_entryInputs.useDynamicBuffer      = Entry_useDynamicBuffer;
   g_entryInputs.minBufferPips         = Entry_minBufferPips;
   g_entryInputs.maxBufferPips         = Entry_maxBufferPips;
   g_entryInputs.sessionMultiplier     = Entry_sessionMultiplier;
   g_entryInputs.volatilityFactor      = Entry_volatilityFactor;
   g_entryInputs.useAnomalyDetection   = Entry_useAnomalyDetection;
   g_entryInputs.newsBufferMultiplier  = Entry_newsBufferMultiplier;
   g_entryInputs.highVolMultiplier     = Entry_highVolMultiplier;
   g_entryInputs.rangeBoundMultiplier  = Entry_rangeBoundMultiplier;
   g_entryInputs.useADXFilter          = Entry_useADXFilter;
   g_entryInputs.adxPeriod             = Entry_adxPeriod;
   g_entryInputs.adxMinStrength        = Entry_adxMinStrength;

   g_structExitInputs.enableBreakeven      = SE_EnableBreakeven;
   g_structExitInputs.breakevenTriggerRR   = SE_BreakevenTriggerRR;
   g_structExitInputs.breakevenBufferPips  = SE_BreakevenBufferPips;
   g_structExitInputs.enableStructureStop  = SE_EnableStructureStop;
   g_structExitInputs.structureLookback    = SE_StructureLookback;
   g_structExitInputs.structureBufferPips  = SE_StructureBufferPips;
   g_structExitInputs.enableATRFallback    = SE_EnableATRFallback;
   g_structExitInputs.atrTrailPeriod       = SE_ATRTrailPeriod;
   g_structExitInputs.atrTrailMultiplier   = SE_ATRTrailMultiplier;
   g_structExitInputs.updateFrequency      = (int)SE_UpdateFrequency;
   g_structExitInputs.updateInterval       = SE_UpdateInterval;
   g_structExitInputs.cooldownBars         = SE_CooldownBars;
   g_structExitInputs.minHoldBars          = SE_MinHoldBars;
   g_structExitInputs.modifyRequestCooldownSeconds = SE_ModifyRequestCooldownSeconds;
   
   g_reEntryInputs.enableReEntry       = ReEntry_Enable;
   g_reEntryInputs.breakoutBufferPips  = ReEntry_BufferPips;
   
   InitRiskModule(g_riskInputs);
   if(!InitEntryModule(_Symbol, _Period, g_entryInputs)) return INIT_FAILED;
   if(!InitStructuralExitModule(g_structExitInputs)) return INIT_FAILED;

   g_emergencyAtrHandle = iATR(_Symbol, _Period, EmergencyATRPeriod);
   if(g_emergencyAtrHandle == INVALID_HANDLE) return INIT_FAILED;
   ConfigureTrader(g_trade, g_riskInputs);
   
   g_wasInPosition_lastTick = PositionSelect(_Symbol);
   return INIT_SUCCEEDED;
}

//=========================== OnDeinit ===============================
void OnDeinit(const int reason)
{
   DeinitRiskModule();
   DeinitEntryModule();
   DeinitStructuralExitModule();
   if(g_emergencyAtrHandle != INVALID_HANDLE) IndicatorRelease(g_emergencyAtrHandle);
   if(g_Logger) { g_Logger.WriteInfo("EA 停止，清理模块"); CleanupLogger(); }
}

//=========================== OnTick =================================
void OnTick()
{
   bool isInPosition_thisTick = PositionSelect(_Symbol);

   // ★★★ 核心协同逻辑：检测平仓事件 (v4.9.1 终极修复版) ★★★
   if(g_wasInPosition_lastTick && !isInPosition_thisTick)
   {
      // 触发锁: 只有在观察哨兵未设立时，才执行检测，防止刷屏
      if(g_reEntryInputs.enableReEntry && g_reEntryHigh == 0.0 && g_reEntryLow == 0.0)
      {
         if(HistorySelect(0, TimeCurrent()))
         {
            int totalDeals = HistoryDealsTotal();
            if(totalDeals > 0)
            {
               for(int i = totalDeals - 1; i >= 0; i--)
               {
                  ulong dealTicket = HistoryDealGetTicket(i);
                  if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == g_riskInputs.magicNumber &&
                     HistoryDealGetString(dealTicket, DEAL_SYMBOL) == _Symbol)
                  {
                     ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
                     
                     if(dealEntry == DEAL_ENTRY_OUT)
                     {
                        datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
                        ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
                        string log_msg = "[系统] 检测到平仓，";

                        MqlRates rates[1];
                        if(CopyRates(_Symbol, _Period, dealTime, 1, rates) > 0)
                        {
                           // 平掉一个BUY持仓，记录高点
                           if(dealType == DEAL_TYPE_SELL) 
                           {
                              g_reEntryHigh = rates[0].high;
                              g_reEntryLow = 0.0; // 明确重置另一个
                              log_msg += StringFormat("激活高点观察哨 at %.5f", g_reEntryHigh);
                           }
                           // 平掉一个SELL持仓，记录低点
                           else if(dealType == DEAL_TYPE_BUY) 
                           {
                              g_reEntryLow = rates[0].low;
                              g_reEntryHigh = 0.0; // 明确重置另一个
                              log_msg += StringFormat("激活低点观察哨 at %.5f", g_reEntryLow);
                           }
                           if(g_Logger) g_Logger.WriteInfo(log_msg);
                        }
                        break; // 找到最近的平仓成交后就跳出循环
                     }
                  }
               }
            }
         }
      }
   }

   if(isInPosition_thisTick) 
   {
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      ProcessStructuralExit(g_structExitInputs, ticket);
   }
   else
   {
      if(!CanOpenNewTrade(g_riskInputs)) return;
      if(g_lastOpenTime > 0 && TimeCurrent() - g_lastOpenTime < Entry_CooldownSeconds) return;

      double sl_price = 0;
      ENUM_ORDER_TYPE sig = GetEntrySignal(sl_price);
      if(sig == ORDER_TYPE_NONE) return;

      if(g_reEntryInputs.enableReEntry)
      {
          double buffer = g_reEntryInputs.breakoutBufferPips * _Point;
          if(sig == ORDER_TYPE_BUY && g_reEntryHigh > 0 && MarketAsk() <= g_reEntryHigh + buffer)
          {
              if(g_Logger && EnableDebug) g_Logger.WriteDebug(StringFormat("二次做多过滤: 等待突破 %.5f", g_reEntryHigh));
              return;
          }
          if(sig == ORDER_TYPE_SELL && g_reEntryLow > 0 && MarketBid() >= g_reEntryLow - buffer)
          {
              if(g_Logger && EnableDebug) g_Logger.WriteDebug(StringFormat("二次做空过滤: 等待跌破 %.5f", g_reEntryLow));
              return;
          }
      }
      
      if(g_emergencyAtrHandle != INVALID_HANDLE)
      {
         double atrBuf[1];
         if(CopyBuffer(g_emergencyAtrHandle, 0, 0, 1, atrBuf) > 0 && atrBuf[0] > 0)
         {
            double price    = (sig == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
            double distPts  = MathAbs(price - sl_price) / _Point;
            double minDist  = (atrBuf[0] / _Point) * MinATRMultipleToTrade;
            if(distPts < minDist) return;
         }
      }
      
      if(OpenPosition(sig, sl_price))
      {
         g_lastOpenTime = TimeCurrent();
         g_reEntryHigh = 0.0;
         g_reEntryLow  = 0.0;
         if(g_Logger) g_Logger.WriteInfo("开仓成功，二次进场观察点已重置。");
      }
   }
   
   g_wasInPosition_lastTick = isInPosition_thisTick;
}
//+------------------------------------------------------------------+
//| SuperTrend EA – v5.6(决策逻辑终极修复版 + 结构化退出v1.8整合)   |
//+------------------------------------------------------------------+
//|                                     © 2025                       |
//|  • 终极修复: 彻底重构了OpenMarketOrder_Fixed中的止损决策逻辑。     |
//|    确保基于趋势线的原始止损(originalSL)作为最高优先级候选方案，    |
//|    并从所有合法的候选方案中选择最远的止损，解决了止损过窄问题。    |
//|  • 整合 v1.8 结构化退出模块: 降频优化版，保本快速响应+结构化降频   |
//|  • 继承 v5.6 的所有功能，包括日志增强等。                          |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "5.6" // 标记为已修复决策逻辑并整合v1.8结构化模块的版本
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
enum ENUM_SE_UPDATE_FREQ { SE_FREQ_EVERY_TICK = 0, SE_FREQ_EVERY_BAR = 1, SE_FREQ_EVERY_N_BARS = 2 };

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
input double SE_StructureBufferPips  = 20.0;
input bool   SE_EnableATRFallback    = true;
input int    SE_ATRTrailPeriod       = 14;
input double SE_ATRTrailMultiplier   = 2.5;

input group "--- Structural Exit v1.8 频率控制 ---"
input ENUM_SE_UPDATE_FREQ SE_UpdateFrequency = SE_FREQ_EVERY_BAR;  // 结构化止损更新频率
input int    SE_UpdateInterval       = 3;     // 当频率=每N根K线时的间隔数
input int    SE_CooldownBars         = 5;     // 冷却期：持仓后N根K线内不更新结构化止损
input int    SE_MinHoldBars          = 3;     // 最小持仓K线数：N根K线后才允许结构化出场

SStructuralExitInputs g_structExitInputs;
double       g_lastTrendHigh         = 0.0;
double       g_lastTrendLow          = 0.0;
datetime     g_lastOpenTime          = 0;
int          g_emergencyAtrHandle    = INVALID_HANDLE;
bool   g_step1Done = false;
bool   g_step2Done = false;
double g_initialSL = 0.0;

// ★★★ v1.8 新增：持仓跟踪变量 ★★★
ulong        g_currentPositionTicket = 0;     // 当前持仓票据
datetime     g_positionOpenTime      = 0;     // 持仓开启时间记录

//===================== 工具函数 =====================================
double MarketBid() { double v; SymbolInfoDouble(_Symbol, SYMBOL_BID,  v); return v; }
double MarketAsk() { double v; SymbolInfoDouble(_Symbol, SYMBOL_ASK, v); return v; }

//===================== 开仓函数 (v5.6.1 终极决策逻辑修复版) ======================
bool OpenMarketOrder_Fixed(ENUM_ORDER_TYPE orderType, double originalSL, double tpPrice = 0, string comment = "ST-EA")
{
   double lot = CalculateLotSize(originalSL, orderType);
   if(lot <= 0.0) return false;
   double estPrice = (orderType == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
   if(!g_trade.PositionOpen(_Symbol, orderType, lot, estPrice, 0, 0, comment)) return false;
   if(!PositionSelect(_Symbol)) return false;
   
   double openP = PositionGetDouble(POSITION_PRICE_OPEN);

   // --- ★★★ 全新、安全的终极止损决策逻辑 (v5.6.1) ★★★ ---

   CArrayDouble valid_sl_candidates;
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)orderType;
   
   // --- 步骤 1: 将最理想的、基于趋势线的原始SL作为第一候选人 ---
   double normalized_originalSL = NormalizePrice(originalSL);
   if (IsStopLossValid(normalized_originalSL, posType))
   {
      valid_sl_candidates.Add(normalized_originalSL);
      if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("SL候选 (原始趋势线): %.5f", normalized_originalSL));
   }
   else
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning(StringFormat("SL候选 (原始趋势线) %.5f 不合法, 被舍弃.", normalized_originalSL));
   }

   // --- 步骤 2: 计算并添加其他"安全网"方案作为备用候选人 ---
   double baseFinalSL = CalculateFinalStopLoss(openP, originalSL, orderType);
   double emergencySL = GetSaferEmergencyStopLoss(openP, originalSL, orderType);
   
   // 检查并添加"最小距离保障SL"
   if (IsStopLossValid(baseFinalSL, posType))
   {
      if (valid_sl_candidates.Search(baseFinalSL) < 0) 
      {
         valid_sl_candidates.Add(baseFinalSL);
         if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("SL候选 (最小距离保障): %.5f", baseFinalSL));
      }
   }
   else
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning(StringFormat("SL候选 (最小距离保障) %.5f 不合法, 被舍弃.", baseFinalSL));
   }

   // 检查并添加"紧急ATR止损"
   if (IsStopLossValid(emergencySL, posType))
   {
      if (valid_sl_candidates.Search(emergencySL) < 0)
      {
         valid_sl_candidates.Add(emergencySL);
         if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("SL候选 (紧急ATR): %.5f", emergencySL));
      }
   }
   else
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning(StringFormat("SL候选 (紧急ATR) %.5f 不合法, 被舍弃.", emergencySL));
   }

   // --- 步骤 3: 从所有合法的候选人中，选择最远的那个 ---
   double finalSL = 0;
   if(valid_sl_candidates.Total() > 0)
   {
      finalSL = valid_sl_candidates.At(0);
      for(int i = 1; i < valid_sl_candidates.Total(); i++)
      {
         finalSL = (orderType == ORDER_TYPE_BUY) ? MathMin(finalSL, valid_sl_candidates.At(i)) : MathMax(finalSL, valid_sl_candidates.At(i));
      }
      if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("决策完成: 从 %d 个合法候选中选择了最远的SL: %.5f", valid_sl_candidates.Total(), finalSL));
   }
   else
   {
      if(g_Logger != NULL) g_Logger.WriteError("🚨 严重错误：所有候选SL均不合法，无法确定止损！");
      g_trade.PositionClose(_Symbol);
      return false;
   }

   // --- 步骤 4: 对最终选定的SL进行最后一次校验并设置 ---
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
   
   if(g_Logger != NULL) g_Logger.WriteInfo(StringFormat("开仓成功: %.2f 手 @ %.5f | Final SL=%.5f (已通过终极决策逻辑)", lot, openP, finalSL));
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
   // 确保返回的价格也被标准化
   return NormalizePrice(finalSL);
}

//=========================== OnInit =================================
int OnInit()
{
   if(!InitializeLogger(LOG_LEVEL_INFO)) { Print("日志初始化失败"); return INIT_FAILED; }
   g_Logger.WriteInfo("EA v5.6.1 启动 (决策逻辑修复版 + 结构化退出v1.8整合)");
   
   InitRiskModule();
   if(!InitEntryModule(_Symbol, _Period)) return INIT_FAILED;
   if(!InitExitModule(_Symbol, _Period)) return INIT_FAILED;
   
   if(BaseExitStrategy == EXIT_MODE_STRUCTURAL)
   {
      // ★★★ v1.8 结构体参数完整初始化 ★★★
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
      
      // ★★★ v1.8 新增频率控制参数 ★★★
      g_structExitInputs.UpdateFrequency = (int)SE_UpdateFrequency;
      g_structExitInputs.UpdateInterval = SE_UpdateInterval;
      g_structExitInputs.CooldownBars = SE_CooldownBars;
      g_structExitInputs.MinHoldBars = SE_MinHoldBars;
      
      if(!InitStructuralExitModule(g_structExitInputs)) return INIT_FAILED;
      
      if(g_Logger != NULL)
      {
         g_Logger.WriteInfo("结构化退出v1.8已启用:");
         g_Logger.WriteInfo("  - 保本操作: 每tick更新 (快速响应)");
         g_Logger.WriteInfo(StringFormat("  - 结构化止损: %s更新", 
            SE_UpdateFrequency == SE_FREQ_EVERY_TICK ? "每tick" : 
            SE_UpdateFrequency == SE_FREQ_EVERY_BAR ? "每K线" : 
            StringFormat("每%d根K线", SE_UpdateInterval)));
         g_Logger.WriteInfo(StringFormat("  - 冷却期: %d根K线, 最小持仓: %d根K线", SE_CooldownBars, SE_MinHoldBars));
      }
   }
   
   g_emergencyAtrHandle = iATR(_Symbol, _Period, EmergencyATRPeriod);
   if(g_emergencyAtrHandle == INVALID_HANDLE) return INIT_FAILED;
   
   ConfigureTrader(g_trade);
   return INIT_SUCCEEDED;
}

//=========================== OnDeinit ===============================
void OnDeinit(const int reason)
{
   DeinitRiskModule(); 
   DeinitEntryModule(); 
   DeinitExitModule(); 
   
   if(BaseExitStrategy == EXIT_MODE_STRUCTURAL) 
   {
      DeinitStructuralExitModule();
      // ★★★ v1.8 清理持仓记录 ★★★
      ResetPositionRecord();
   }
   
   if(g_emergencyAtrHandle != INVALID_HANDLE) IndicatorRelease(g_emergencyAtrHandle);
   
   if(g_Logger != NULL) g_Logger.WriteInfo("EA 停止，清理模块 (v1.8整合版)");
}

//=========================== OnTick =================================
void OnTick()
{
   if(PositionSelect(_Symbol)) 
   { 
      // ★★★ v1.8 持仓管理增强 ★★★
      ManagePosition(); 
      return; 
   }
   
   // ★★★ v1.8 持仓关闭时重置记录 ★★★
   if(g_currentPositionTicket > 0)
   {
      g_currentPositionTicket = 0;
      if(BaseExitStrategy == EXIT_MODE_STRUCTURAL)
      {
         ResetPositionRecord();
         if(g_Logger != NULL && EnableDebug) 
            g_Logger.WriteInfo("持仓已关闭，重置v1.8持仓记录");
      }
   }
   
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
   bool ok = OpenMarketOrder_Fixed(type, sl, 0, "ST-EA v5.6.1");
   if(ok)
   {
      g_initialSL = sl; 
      g_step1Done = false; 
      g_step2Done = false;
      g_lastOpenTime = TimeCurrent(); 
      g_lastTrendHigh = 0.0; 
      g_lastTrendLow = 0.0;
      
      // ★★★ v1.8 记录持仓开启 ★★★
      if(PositionSelect(_Symbol))
      {
         g_currentPositionTicket = PositionGetTicket(0);
         g_positionOpenTime = TimeCurrent();
         
         if(BaseExitStrategy == EXIT_MODE_STRUCTURAL)
         {
            RecordPositionOpen(g_currentPositionTicket);
            if(g_Logger != NULL && EnableDebug) 
               g_Logger.WriteInfo(StringFormat("v1.8持仓跟踪已启动: 票据=%d, 冷却期=%d根K线", g_currentPositionTicket, SE_CooldownBars));
         }
      }
   }
}

//======================== 持仓管理函数 (v5.6.1 + v1.8 整合版) ======================
void ManagePosition()
{
   static datetime last_bar_time = 0;
   datetime current_bar_time = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   
   // ★★★ 保持原有趋势高低点跟踪逻辑 ★★★
   if(current_bar_time > last_bar_time)
   {
      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pType == POSITION_TYPE_BUY) 
      { 
         double prevHigh = iHigh(_Symbol, _Period, 1); 
         if(g_lastTrendHigh == 0.0 || prevHigh > g_lastTrendHigh) 
            g_lastTrendHigh = prevHigh; 
      }
      else 
      { 
         double prevLow = iLow(_Symbol, _Period, 1); 
         if(g_lastTrendLow == 0.0 || prevLow < g_lastTrendLow) 
            g_lastTrendLow = prevLow; 
      }
      last_bar_time = current_bar_time;
   }
   
   // ★★★ v1.8 结构化退出处理 (使用持仓票据) ★★★
   if(BaseExitStrategy == EXIT_MODE_STRUCTURAL) 
   {
      if(g_currentPositionTicket > 0)
      {
         ProcessStructuralExit(g_structExitInputs, g_currentPositionTicket);
      }
      else
      {
         // 如果票据丢失，尝试重新获取
         if(PositionSelect(_Symbol))
         {
            g_currentPositionTicket = PositionGetTicket(0);
            if(g_Logger != NULL && EnableDebug) 
               g_Logger.WriteWarning(StringFormat("重新获取持仓票据: %d", g_currentPositionTicket));
         }
      }
   }
   
   // ★★★ 原有R-Multiple退出逻辑保持不变 ★★★
   if(Enable_R_Multiple_Exit)
   {
      if(!PositionSelect(_Symbol)) return;
      double openP = PositionGetDouble(POSITION_PRICE_OPEN); 
      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double pct = (pType == POSITION_TYPE_BUY) ? 
                   GetLongExitAction(openP, g_initialSL, g_step1Done, g_step2Done) : 
                   GetShortExitAction(openP, g_initialSL, g_step1Done, g_step2Done);
      
      if(pct > 0.0)
      {
         // 全仓平仓（通常由SAR触发）的日志由其模块内部的Print()函数负责
         if(pct >= 100.0) 
         {
            g_trade.PositionClose(_Symbol);
            // ★★★ v1.8 全仓平仓时重置记录 ★★★
            if(BaseExitStrategy == EXIT_MODE_STRUCTURAL)
            {
               ResetPositionRecord();
               g_currentPositionTicket = 0;
            }
         }
         else // 部分平仓
         {
            double vol = PositionGetDouble(POSITION_VOLUME); 
            double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double volClose = MathFloor((vol * pct / 100.0) / step) * step; 
            volClose = MathMax(volClose, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
            
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
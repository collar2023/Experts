//+------------------------------------------------------------------+
//| SuperTrend EA – v4.0(终极修复版)                              |
//| © 2025                                                           |
//| • 异步止损: 重构开仓逻辑，先"裸单开仓"确保入场，再异步设置止损。 |
//| • 决策升级: 止损计算采用"三级防御体系"，确保选择最远的止损。     |
//| • 修复: 移除了主文件中重复定义的NormalizePrice等函数。           |
//| • 继承 v4.0 所有功能，包括二次进场、结构化止损等。               |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "4.0" // 标记为终极修复版
#property strict

#include <Trade/Trade.mqh>
#include <Arrays/ArrayDouble.mqh>
#include "SuperTrend_LogModule.mqh"
#include "Risk_Management_Module.mqh"
#include "SuperTrend_Entry_Module.mqh"
#include "SAR_ADX_Exit_Module.mqh"
#include "Common_Defines.mqh"
#include "Structural_Exit_Module.mqh"

//===================== 全局对象 & 变量 ===============================
CLogModule* g_Logger = NULL;
CTrade      g_trade;

//----------------- Core Settings ------------------------------------
input group "--- Core Settings ---"
input bool   EnableDebug             = true;
input int    EmergencyATRPeriod      = 14;
input double EmergencyATRMultiplier  = 1.5;
input int    Entry_CooldownSeconds   = 0;
input double MinATRMultipleToTrade   = 0.1;

//----------------- Structural Exit – Breakeven ----------------------
input group "--- Structural Exit (Breakeven) ---"
input double SE_BreakevenTriggerRR   = 1.5;
input double SE_BreakevenBufferPips  = 2.0;

//----------------- 二次进场确认变量 ----------------------------------
double   g_lastTrendHigh  = 0.0;
double   g_lastTrendLow   = 0.0;
datetime g_lastOpenTime   = 0;
int      g_emergencyAtrHandle = INVALID_HANDLE;

bool   g_step1Done = false;
bool   g_step2Done = false;
double g_initialSL = 0.0;

//================== 结构化止损配置实例 ===============================
SStructuralExitInputs g_structExitConfig;

//===================== 工具函数 =====================================
double MarketBid() { double v; SymbolInfoDouble(_Symbol, SYMBOL_BID,  v); return v; }
double MarketAsk() { double v; SymbolInfoDouble(_Symbol, SYMBOL_ASK, v); return v; }
// ★★★ 核心修复：已移除主文件中重复定义的 NormalizePrice 和 IsStopLossValid 函数 ★★★

//===================== 紧急 ATR 止损计算 =============================
double GetSaferEmergencyStopLoss(double openP, double originalSL, ENUM_ORDER_TYPE orderType)
{
   if (!MathIsValidNumber(openP) || !MathIsValidNumber(originalSL)) return 0.0;
   double oriRisk = MathAbs(openP - originalSL);
   double atr[1];
   double safeDist = oriRisk;

   if(g_emergencyAtrHandle != INVALID_HANDLE &&
      CopyBuffer(g_emergencyAtrHandle, 0, 0, 1, atr) > 0 && atr[0] > 0)
   {
      double atrDist = atr[0] * EmergencyATRMultiplier;
      safeDist = MathMax(oriRisk, atrDist);
   }
   // ★★★ 调用 Risk_Management_Module.mqh 中的 NormalizePrice 函数 ★★★
   return NormalizePrice((orderType == ORDER_TYPE_BUY) ? (openP - safeDist) : (openP + safeDist));
}


//===================== 开仓函数 (v4.0.4 异步止损 + 三级防御终极版) ================
bool OpenMarketOrder_Fixed(ENUM_ORDER_TYPE orderType,
                           double originalSL,
                           double tpPrice = 0,
                           string comment = "ST-EA")
{
   // --- 步骤 1: 计算手数 (风控的第一步) ---
   double lot = CalculateLotSize(originalSL, orderType);
   if(lot <= 0.0)
   {
      if(g_Logger && EnableDebug) g_Logger.WriteWarning("风控后手数=0，跳过交易");
      return false;
   }

   // --- 步骤 2: 执行"裸单开仓"，不带止损 ---
   double estPrice = (orderType == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
   g_trade.SetDeviationInPoints((int)Risk_slippage);
   if(!g_trade.PositionOpen(_Symbol, orderType, lot, estPrice, 0, 0, comment))
   {
      if(g_Logger) g_Logger.WriteError(StringFormat("裸单开仓失败 err=%d", GetLastError()));
      return false;
   }

   // --- 开仓成功，立即进入止损设置阶段 ---
   if(!PositionSelect(_Symbol))
   {
      if(g_Logger) g_Logger.WriteError("裸单开仓后无法选中仓位，无法设置止损！");
      return true; // 开仓已成功
   }
   
   double openP = PositionGetDouble(POSITION_PRICE_OPEN);
   if(g_Logger) g_Logger.WriteInfo(StringFormat("裸单开仓成功: %.2f 手 @ %.5f。立即开始设置止损...", lot, openP));

   // --- 步骤 3: 异步设置止损 (使用三级防御体系) ---
   CArrayDouble valid_sl_candidates;
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)orderType;

   // 3.1: 收集所有合法的候选止损价
   // 候选人A: 原始趋势线止损
   double normalized_originalSL = NormalizePrice(originalSL);
   if (IsStopLossValid(normalized_originalSL, posType))
   {
      valid_sl_candidates.Add(normalized_originalSL);
      if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("SL候选 (原始趋势线): %.5f", normalized_originalSL));
   }
   // 候选人B: 最小距离保障止损
   double baseFinalSL = CalculateFinalStopLoss(openP, originalSL, orderType, EnableDebug);
   if (IsStopLossValid(baseFinalSL, posType) && valid_sl_candidates.Search(baseFinalSL) < 0)
   {
      valid_sl_candidates.Add(baseFinalSL);
      if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("SL候选 (最小距离保障): %.5f", baseFinalSL));
   }
   // 候选人C: 紧急ATR止损
   double emergencySL = GetSaferEmergencyStopLoss(openP, originalSL, orderType);
   if (IsStopLossValid(emergencySL, posType) && valid_sl_candidates.Search(emergencySL) < 0)
   {
      valid_sl_candidates.Add(emergencySL);
      if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("SL候选 (紧急ATR): %.5f", emergencySL));
   }

   // 3.2: 从中选择最远的那个
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
      if(g_Logger) g_Logger.WriteError("🚨 严重警告：所有候选SL均不合法，仓位暂时无止损保护！");
      return true; // 开仓已成功
   }

   // 3.3: 异步设置最终止损
   if(finalSL != 0 && MathIsValidNumber(finalSL))
   {
      if(!SetStopLossWithRetry(g_trade, finalSL, tpPrice, 3, EnableDebug))
      {
         if(g_Logger) g_Logger.WriteError("🚨 警告：异步设置止损失败，仓位暂时无止损保护！EA将在下一Tick重试。");
      }
      else
      {
         if(g_Logger) g_Logger.WriteInfo(StringFormat("异步设置止损成功: Final SL=%.5f", finalSL));
      }
   }
   
   return true;
}

//===================== OnInit =======================================
int OnInit()
{
   if(!InitializeLogger(LOG_LEVEL_INFO))
   {
      Print("日志初始化失败");
      return INIT_FAILED;
   }
   g_Logger.WriteInfo("EA v4.0.4 启动 (终极修复版)");

   InitRiskModule();
   if(!InitEntryModule(_Symbol, _Period)) { g_Logger.WriteError("入场模块初始化失败"); return INIT_FAILED; }
   if(!InitExitModule(_Symbol, _Period)) { g_Logger.WriteError("出场模块初始化失败"); return INIT_FAILED; }

   g_emergencyAtrHandle = iATR(_Symbol, _Period, EmergencyATRPeriod);
   if(g_emergencyAtrHandle == INVALID_HANDLE) { g_Logger.WriteError("紧急 ATR 指标初始化失败"); return INIT_FAILED; }
   
   g_structExitConfig.EnableStructuralExit = true;
   g_structExitConfig.EnableBreakeven = true; 
   g_structExitConfig.BreakevenTriggerRR = SE_BreakevenTriggerRR;
   g_structExitConfig.BreakevenBufferPips = SE_BreakevenBufferPips;
   g_structExitConfig.EnableStructureStop = true;
   g_structExitConfig.StructureLookback = 20;
   g_structExitConfig.StructureBufferPips = 3.0;
   g_structExitConfig.EnableATRFallback = true;
   g_structExitConfig.ATRTrailPeriod = 14;
   g_structExitConfig.ATRTrailMultiplier = 1.5;
   g_structExitConfig.UpdateFrequency = 1;
   g_structExitConfig.UpdateInterval = 1;
   g_structExitConfig.CooldownBars = 3;
   g_structExitConfig.MinHoldBars = 5;

   if(!InitStructuralExitModule(g_structExitConfig))
   {
      g_Logger.WriteError("结构化止损模块初始化失败");
      return INIT_FAILED;
   }

   ConfigureTrader(g_trade);
   g_Logger.WriteInfo("架构: SuperTrend 入场 · SAR/ADX 出场 · 风控增强 · 二次进场 · 结构化止损");

   return INIT_SUCCEEDED;
}

//===================== OnDeinit =====================================
void OnDeinit(const int reason)
{
   DeinitEntryModule();
   DeinitExitModule();
   DeinitRiskModule();
   if(g_emergencyAtrHandle != INVALID_HANDLE) IndicatorRelease(g_emergencyAtrHandle);
   DeinitStructuralExitModule();
   if(g_Logger) { g_Logger.WriteInfo("EA 停止，清理模块"); CleanupLogger(); }
}

//===================== OnTick =======================================
void OnTick()
{
   if(PositionSelect(_Symbol))
   {
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      if(PositionGetDouble(POSITION_SL) == 0)
      {
          if(g_Logger && EnableDebug) g_Logger.WriteWarning("检测到无SL的持仓，将由管理逻辑处理...");
      }
      ProcessStructuralExit(g_structExitConfig, ticket);
      ManagePosition();
   }
   else
   {
      if(!CanOpenNewTrade(EnableDebug)) return;
      if(g_lastOpenTime > 0 && TimeCurrent() - g_lastOpenTime < Entry_CooldownSeconds) return;
      double sl_price = 0;
      ENUM_ORDER_TYPE sig = GetEntrySignal(sl_price);
      if(sig == ORDER_TYPE_NONE) return;
      if(sig == ORDER_TYPE_BUY && g_lastTrendHigh > 0 && MarketAsk() <= g_lastTrendHigh)
      {
         if(g_Logger && EnableDebug) g_Logger.WriteInfo(StringFormat("二次做多过滤: 等待突破 %.5f", g_lastTrendHigh));
         return;
      }
      else if(sig == ORDER_TYPE_SELL && g_lastTrendLow > 0 && MarketBid() >= g_lastTrendLow)
      {
         if(g_Logger && EnableDebug) g_Logger.WriteInfo(StringFormat("二次做空过滤: 等待跌破 %.5f", g_lastTrendLow));
         return;
      }
      if(g_emergencyAtrHandle != INVALID_HANDLE)
      {
         double atrBuf[1];
         if(CopyBuffer(g_emergencyAtrHandle, 0, 0, 1, atrBuf) > 0 && atrBuf[0] > 0)
         {
            double price    = (sig == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
            double distPts  = MathAbs(price - sl_price) / _Point;
            double minDist  = (atrBuf[0] / _Point) * MinATRMultipleToTrade;
            if(distPts < minDist)
            {
               if(g_Logger) g_Logger.WriteInfo(StringFormat("信号过滤(ATR距离): SL %.1f 点 < 最小 %.1f 点", distPts, minDist));
               return;
            }
         }
      }
      if(OpenMarketOrder_Fixed(sig, sl_price, 0, "ST-EA v4.0"))
      {
         g_initialSL   = sl_price;
         g_step1Done   = false;
         g_step2Done   = false;
         g_lastOpenTime = TimeCurrent();
         g_lastTrendHigh = 0.0;
         g_lastTrendLow  = 0.0;
      }
   }
}

//===================== 持仓管理 =====================================
void ManagePosition()
{
   ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openP   = PositionGetDouble(POSITION_PRICE_OPEN);
   
   double pct = (pType == POSITION_TYPE_BUY)
                ? GetLongExitAction(openP, g_initialSL, g_step1Done, g_step2Done)
                : GetShortExitAction(openP, g_initialSL, g_step1Done, g_step2Done);
   if(pct <= 0.0) return;

   if(pct >= 100.0)
   {
      if(pType == POSITION_TYPE_BUY) g_lastTrendHigh = iHigh(_Symbol, _Period, 0);
      else g_lastTrendLow  = iLow (_Symbol, _Period, 0);
      if(g_trade.PositionClose(_Symbol) && g_Logger != NULL) g_Logger.WriteInfo("全仓平仓成功，进入二次进场观察模式");
      return;
   }

   double vol = PositionGetDouble(POSITION_VOLUME);
   double volClose = vol * pct / 100.0;
   volClose = MathMax(volClose, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   volClose = MathFloor(volClose / step) * step;

   if(volClose > 0 && volClose < vol && g_trade.PositionClosePartial(_Symbol, volClose) && g_Logger != NULL)
   {
      g_Logger.WriteInfo(StringFormat("部分止盈 %.1f%% 成功", pct));
      if(g_step1Done == false) g_step1Done = true;
      else g_step2Done = true;
   }
}
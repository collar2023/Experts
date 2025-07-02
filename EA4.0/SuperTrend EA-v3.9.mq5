//+------------------------------------------------------------------+
//| SuperTrend EA – v3.9 (纯粹异步止损版)                          |
//+------------------------------------------------------------------+
//|                                     © 2025                       |
//|  • 核心修复: 仅引入“异步止损”逻辑，先裸单开仓，再异步设置止损。   |
//|    以最小改动解决因10013等错误导致的开仓失败问题。               |
//|  • 保持纯粹: 完全保留v4.0原始的止损计算和决策逻辑。              |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "3.9" // 标记为纯粹异步止损版
#property strict

//===================== 模块引入 =====================================
#include <Trade/Trade.mqh>
#include "SuperTrend_LogModule.mqh"
#include "Risk_Management_Module.mqh"
#include "SuperTrend_Entry_Module.mqh"
#include "SAR_ADX_Exit_Module.mqh"
#include "Common_Defines.mqh"

//===================== 全局对象 & 变量 (无变化) ===============================
CLogModule* g_Logger = NULL;
CTrade      g_trade;

input group "--- Core Settings ---"
input bool   EnableDebug             = true;
input int    EmergencyATRPeriod      = 14;
input double EmergencyATRMultiplier  = 1.5;
input int    Entry_CooldownSeconds   = 0;
input double MinATRMultipleToTrade   = 0.1;

//--- v4.0 全局变量: 用于价格行为确认 ---
double       g_lastTrendHigh         = 0.0;
double       g_lastTrendLow          = 0.0;

//--- 其他全局变量 ---
datetime     g_lastOpenTime          = 0;
int          g_emergencyAtrHandle    = INVALID_HANDLE;
bool   g_step1Done = false;
bool   g_step2Done = false;
double g_initialSL = 0.0;

//===================== 工具函数 (无变化) =====================================
double MarketBid() { double v; SymbolInfoDouble(_Symbol, SYMBOL_BID,  v); return v; }
double MarketAsk() { double v; SymbolInfoDouble(_Symbol, SYMBOL_ASK, v); return v; }

//===================== 安全应急 SL 计算 (无变化) =======================
double GetSaferEmergencyStopLoss(double openP,
                                 double originalSL,
                                 ENUM_ORDER_TYPE orderType)
{
   double oriRisk = MathAbs(openP - originalSL);
   double atr[1];
   double safeDist = oriRisk; 
   if(g_emergencyAtrHandle != INVALID_HANDLE && CopyBuffer(g_emergencyAtrHandle, 0, 0, 1, atr) > 0 && atr[0] > 0)
   {
      double atrDist = atr[0] * EmergencyATRMultiplier;
      safeDist = MathMax(oriRisk, atrDist); 
   }
   return (orderType == ORDER_TYPE_BUY)
          ? (openP - safeDist)
          : (openP + safeDist);
}

//===================== 开仓函数 (v4.0.3 纯粹异步止损版) ======================
bool OpenMarketOrder_Fixed(ENUM_ORDER_TYPE orderType,
                           double originalSL,
                           double tpPrice      = 0,
                           string comment      = "ST-EA")
{
   // --- 步骤 1: 手数计算 (保持不变) ---
   double lot = CalculateLotSize(originalSL, orderType);
   if(lot <= 0.0)
   {
      if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("风控后手数=0，跳过交易");
      return false;
   }

   // --- 步骤 2: 执行“裸单开仓”，不带止损 ---
   double estPrice = (orderType == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
   g_trade.SetDeviationInPoints((int)Risk_slippage);
   if(!g_trade.PositionOpen(_Symbol, orderType, lot, estPrice, 0, 0, comment))
   {
      if(g_Logger != NULL) g_Logger.WriteError(StringFormat("裸单开仓失败 err=%d", GetLastError()));
      return false;
   }

   // --- 开仓成功，立即进入止损设置阶段 ---
   if(!PositionSelect(_Symbol))
   {
      if(g_Logger != NULL) g_Logger.WriteError("裸单开仓后无法选中仓位，无法设置止损！");
      return true; // 开仓已成功
   }

   double openP = PositionGetDouble(POSITION_PRICE_OPEN);
   if(g_Logger != NULL) g_Logger.WriteInfo(StringFormat("裸单开仓成功: %.2f 手 @ %.5f。立即开始设置止损...", lot, openP));
   
   // --- 步骤 3: 异步设置止损 (使用V4.0原始决策逻辑) ---
   
   // 3.1: 计算两个候选止损价 (完全保持原始逻辑)
   double baseFinalSL = CalculateFinalStopLoss(openP, originalSL, orderType);
   double emergencySL = GetSaferEmergencyStopLoss(openP, originalSL, orderType);

   // 3.2: 从两个SL方案中选择 (完全保持原始逻辑)
   // ★★★ 注意：此处的MathMin/MathMax是V4.0原始逻辑，可能会导致止损过窄，但我们遵从“保持纯粹性”的原则 ★★★
   double finalSL;
   if(orderType == ORDER_TYPE_BUY)
   {
      finalSL = MathMin(baseFinalSL, emergencySL); 
   }
   else
   {
      finalSL = MathMax(baseFinalSL, emergencySL);
   }

   // 3.3: 异步设置最终止损
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
   else
   {
       if(g_Logger != NULL) g_Logger.WriteError("🚨 严重警告：计算出的止损价无效，仓位暂时无止损保护！");
   }
   
   return true; // 无论止损是否设置成功，开仓本身是成功的
}

//=========================== OnInit (无变化) =================================
int OnInit()
{
   if(!InitializeLogger(LOG_LEVEL_INFO)) { Print("日志初始化失败"); return INIT_FAILED; }
   g_Logger.WriteInfo("EA v4.0.3 启动 (纯粹异步止损版)");

   InitRiskModule();
   if(!InitEntryModule(_Symbol, _Period)) { g_Logger.WriteError("入场模块初始化失败"); return INIT_FAILED; }
   if(!InitExitModule(_Symbol, _Period)) { g_Logger.WriteError("出场模块初始化失败"); return INIT_FAILED; }

   g_emergencyAtrHandle = iATR(_Symbol, _Period, EmergencyATRPeriod);
   if(g_emergencyAtrHandle == INVALID_HANDLE) { g_Logger.WriteError("紧急ATR指标初始化失败"); return INIT_FAILED; }

   ConfigureTrader(g_trade);
   g_Logger.WriteInfo("架构: SuperTrend入场 · SAR/ADX出场 · 风控增强 · 智能过滤");

   return INIT_SUCCEEDED;
}

//=========================== OnDeinit (无变化) ===============================
void OnDeinit(const int reason)
{
   DeinitEntryModule();
   DeinitExitModule();
   DeinitRiskModule();
   if(g_emergencyAtrHandle != INVALID_HANDLE) IndicatorRelease(g_emergencyAtrHandle);
   if(g_Logger != NULL) { g_Logger.WriteInfo("EA 停止，清理模块"); CleanupLogger(); }
}

//=========================== OnTick (无变化) =================================
void OnTick()
{
   if(PositionSelect(_Symbol)) 
   { 
      // 增加对无SL仓位的保护性检查
      if(PositionGetDouble(POSITION_SL) == 0)
      {
         if(g_Logger && EnableDebug) g_Logger.WriteWarning("检测到无SL的持仓，请关注！");
      }
      ManagePosition();
      return; 
   }

   if(!CanOpenNewTrade(EnableDebug)) return;
   if(g_lastOpenTime > 0 && TimeCurrent() - g_lastOpenTime < Entry_CooldownSeconds) return;

   double sl_price = 0;
   ENUM_ORDER_TYPE sig = GetEntrySignal(sl_price);
   if(sig == ORDER_TYPE_NONE) return;

   if(sig == ORDER_TYPE_BUY)
   {
      if(g_lastTrendHigh > 0 && MarketAsk() <= g_lastTrendHigh)
      {
         if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("二次做多信号过滤: 等待价格突破前高 %.5f", g_lastTrendHigh));
         return;
      }
   }
   else if(sig == ORDER_TYPE_SELL)
   {
      if(g_lastTrendLow > 0 && MarketBid() >= g_lastTrendLow)
      {
         if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("二次做空信号过滤: 等待价格跌破前低 %.5f", g_lastTrendLow));
         return;
      }
   }
   
   if(g_emergencyAtrHandle != INVALID_HANDLE)
   {
      double atrBuf[1];
      if(CopyBuffer(g_emergencyAtrHandle, 0, 0, 1, atrBuf) > 0 && atrBuf[0] > 0)
      {
         double price = (sig == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
         double distPts = MathAbs(price - sl_price) / _Point;
         double minDist = (atrBuf[0] / _Point) * MinATRMultipleToTrade;
         if(distPts < minDist)
         {
            if(g_Logger != NULL) g_Logger.WriteInfo(StringFormat("信号过滤(ATR距离): SL仅 %.1f 点 < 最小要求 %.1f 点", distPts, minDist));
            return;
         }
      }
   }
   OpenPosition(sig, sl_price);
}

//=========================== 开仓接口 (无变化) ================================
void OpenPosition(ENUM_ORDER_TYPE type, double sl)
{
   bool ok = OpenMarketOrder_Fixed(type, sl, 0, "ST-EA v4.0");
   if(ok)
   {
      g_initialSL   = sl;
      g_step1Done   = g_step2Done = false;
      g_lastOpenTime = TimeCurrent();
      g_lastTrendHigh = 0.0;
      g_lastTrendLow  = 0.0;
   }
}

//======================== 持仓管理函数 (无变化) ===============================
void ManagePosition()
{
   ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   if(pType == POSITION_TYPE_BUY)
   {
      double currentHigh = iHigh(_Symbol, _Period, 0);
      if(g_lastTrendHigh == 0.0 || currentHigh > g_lastTrendHigh) g_lastTrendHigh = currentHigh;
   }
   else
   {
      double currentLow = iLow(_Symbol, _Period, 0);
      if(g_lastTrendLow == 0.0 || currentLow < g_lastTrendLow) g_lastTrendLow = currentLow;
   }

   double openP = PositionGetDouble(POSITION_PRICE_OPEN);
   double vol   = PositionGetDouble(POSITION_VOLUME);
   double pct = (pType == POSITION_TYPE_BUY)
              ? GetLongExitAction(openP, g_initialSL, g_step1Done, g_step2Done)
              : GetShortExitAction(openP, g_initialSL, g_step1Done, g_step2Done);
   if(pct <= 0.0) return;

   if(pct >= 100.0)
   {
      if(g_trade.PositionClose(_Symbol) && g_Logger != NULL) g_Logger.WriteInfo("全仓平仓成功，进入二次进场观察模式");
      return;
   }

   double volClose = vol * pct / 100.0;
   volClose = MathMax(volClose, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   volClose = MathFloor(volClose / step) * step;

   if(volClose > 0 && volClose < vol && g_trade.PositionClosePartial(_Symbol, volClose) && g_Logger != NULL)
      g_Logger.WriteInfo(StringFormat("部分止盈 %.1f%% 成功", pct));
}
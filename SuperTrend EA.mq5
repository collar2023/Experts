//+------------------------------------------------------------------+
//| SuperTrend EA – v3.0 (三位一体架构 + 紧急止损 1.5×ATR)           |
//| 修正版：                                                         |
//|  • 移除非法引用语法                                             |
//|  • 所有逻辑与 g_Logger 判断改为 “g_Logger!=NULL && …”            |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "3.00"
#property strict

//===================== 模块引入 =====================================
#include <Trade/Trade.mqh>
#include "SuperTrend_LogModule.mqh"
#include "Risk_Management_Module.mqh"
#include "SuperTrend_Entry_Module.mqh"
#include "SAR_ADX_Exit_Module.mqh"
#include "Common_Defines.mqh"

//===================== 全局对象 & 变量 ===============================
CLogModule* g_Logger = NULL;
CTrade      g_trade;

input bool   EnableDebug            = true;
input int    EmergencyATRPeriod     = 14;
input double EmergencyATRMultiplier = 1.5;

bool   g_step1Done = false;
bool   g_step2Done = false;
double g_initialSL = 0.0;

//===================== 工具函数 =====================================
double MarketBid() { double v; SymbolInfoDouble(_Symbol, SYMBOL_BID,  v); return v; }
double MarketAsk() { double v; SymbolInfoDouble(_Symbol, SYMBOL_ASK, v); return v; }

//===================== 新版开仓函数 =================================
bool OpenMarketOrder_Fixed(ENUM_ORDER_TYPE orderType,
                           double originalSL,
                           double tpPrice      = 0,
                           string comment      = "ST-EA")
{
   /* 1️⃣ 手数计算（含滑点缓冲） */
   double lot = CalculateLotSize(originalSL, orderType);
   if(lot <= 0.0)
   {
      if(g_Logger != NULL && EnableDebug)
         g_Logger.WriteWarning("风控后手数=0，跳过交易");
      return false;
   }

   /* 2️⃣ 裸单开仓（直接用全局 g_trade） */
   double estPrice = (orderType == ORDER_TYPE_BUY) ? MarketAsk() : MarketBid();
   g_trade.SetDeviationInPoints((int)Risk_slippage);

   if(!g_trade.PositionOpen(_Symbol, orderType, lot, estPrice, 0, 0, comment))
   {
      if(g_Logger != NULL)
         g_Logger.WriteError(StringFormat("开仓失败 err=%d", GetLastError()));
      return false;
   }

   /* 3️⃣ 获取实际价 & 风险偏差提示 */
   if(!PositionSelect(_Symbol))
   {
      if(g_Logger != NULL) g_Logger.WriteError("开仓后无法选中仓位");
      return false;
   }
   double openP        = PositionGetDouble(POSITION_PRICE_OPEN);
   double estRiskPts   = MathAbs(estPrice - originalSL) / _Point;
   double actRiskPts   = MathAbs(openP   - originalSL) / _Point;

   if(MathAbs(actRiskPts - estRiskPts) > estRiskPts * 0.1 && g_Logger != NULL)
      g_Logger.WriteWarning(StringFormat("滑点导致风险偏差: 预期 %.1f → 实际 %.1f 点",
                                         estRiskPts, actRiskPts));

   /* 4️⃣ 计算一次性最终 SL */
   double finalSL = CalculateFinalStopLoss(openP, originalSL, orderType);

   /* 5️⃣ 更严格应急 SL */
   double safeSL  = GetSaferEmergencyStopLoss(openP, originalSL, orderType);
   if(orderType == ORDER_TYPE_BUY)  finalSL = MathMax(finalSL, safeSL);
   else                             finalSL = MathMin(finalSL, safeSL);

   /* 6️⃣ 设置止损（带重试） */
   if(!SetStopLossWithRetry(g_trade, finalSL, tpPrice, 3))
   {
      if(g_Logger != NULL)
         g_Logger.WriteError("🚨 无法设置安全止损，执行保护性平仓");
      g_trade.PositionClose(_Symbol);
      return false;
   }

   if(g_Logger != NULL)
      g_Logger.WriteInfo(StringFormat("开仓成功: %.2f 手 @ %.5f | SL=%.5f",
                                      lot, openP, finalSL));
   return true;
}

//===================== 安全应急 SL 计算 =============================
double GetSaferEmergencyStopLoss(double openP,
                                 double originalSL,
                                 ENUM_ORDER_TYPE orderType)
{
   double oriRisk = MathAbs(openP - originalSL);

   int    hATR = iATR(_Symbol, _Period, EmergencyATRPeriod);
   double atr[1];
   double safeDist = oriRisk;
   if(hATR != INVALID_HANDLE && CopyBuffer(hATR, 0, 0, 1, atr) > 0)
   {
      double atrDist = atr[0] * EmergencyATRMultiplier;
      safeDist = MathMin(oriRisk, atrDist);
      IndicatorRelease(hATR);
   }

   return (orderType == ORDER_TYPE_BUY)
          ? (openP - safeDist)
          : (openP + safeDist);
}

//=========================== OnInit =================================
int OnInit()
{
   if(!InitializeLogger(LOG_LEVEL_INFO))
   { Print("日志初始化失败"); return INIT_FAILED; }

   g_Logger.WriteInfo("EA v3.0 启动成功 (修正版)");

   InitRiskModule();
   if(!InitEntryModule(_Symbol, _Period))
   { g_Logger.WriteError("入场模块初始化失败"); return INIT_FAILED; }
   if(!InitExitModule(_Symbol, _Period))
   { g_Logger.WriteError("出场模块初始化失败"); return INIT_FAILED; }

   ConfigureTrader(g_trade);
   g_Logger.WriteInfo("架构: SuperTrend入场 · SAR/ADX出场 · 风控增强");

   return INIT_SUCCEEDED;
}

//=========================== OnDeinit ===============================
void OnDeinit(const int reason)
{
   DeinitEntryModule();
   DeinitExitModule();
   DeinitRiskModule();

   if(g_Logger != NULL)
   {
      g_Logger.WriteInfo("EA 停止，清理模块");
      CleanupLogger();
   }
}

//=========================== OnTick =================================
void OnTick()
{
   if(PositionSelect(_Symbol)) { ManagePosition(); return; }

   if(!CanOpenNewTrade(EnableDebug)) return;

   double sl_price = 0;
   ENUM_ORDER_TYPE sig = GetEntrySignal(sl_price);
   if(sig == ORDER_TYPE_NONE) return;

   OpenPosition(sig, sl_price);
}

//=========================== 开仓接口 ================================
void OpenPosition(ENUM_ORDER_TYPE type, double sl)
{
   bool ok = OpenMarketOrder_Fixed(type, sl, 0, "ST-EA");
   if(ok)
   {
      g_initialSL = sl;
      g_step1Done = g_step2Done = false;
   }
}

//======================== 持仓管理函数 ===============================
void ManagePosition()
{
   double openP = PositionGetDouble(POSITION_PRICE_OPEN);
   double vol   = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double pct = (pType == POSITION_TYPE_BUY)
              ? GetLongExitAction(openP, g_initialSL, g_step1Done, g_step2Done)
              : GetShortExitAction(openP, g_initialSL, g_step1Done, g_step2Done);
   if(pct <= 0.0) return;

   if(pct >= 100.0)
   {
      if(g_trade.PositionClose(_Symbol) && g_Logger != NULL)
         g_Logger.WriteInfo("全仓平仓成功");
      return;
   }

   double volClose = vol * pct / 100.0;
   volClose = MathMax(volClose, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   volClose = MathFloor(volClose / step) * step;

   if(volClose > 0 &&
      g_trade.PositionClosePartial(_Symbol, volClose) &&
      g_Logger != NULL)
      g_Logger.WriteInfo(StringFormat("部分止盈 %.1f%% 成功", pct));
}
//+------------------------------------------------------------------+

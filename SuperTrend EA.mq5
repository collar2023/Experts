//+------------------------------------------------------------------+
//| SuperTrend EA – v4.0 (重大升级：二次进场的价格行为确认)          |
//+------------------------------------------------------------------+
//|                                     © 2025                       |
//|  • 新增特性：引入基于价格行为的二次进场确认机制。                |
//|    平仓后，EA会记录上次趋势的最高/最低点。                       |
//|    只有当价格突破此关键点后，才允许在同方向再次进场。            |
//|  • 核心目的：过滤盘整期的无效信号，只在趋势强力回归时追击。      |
//|  • 架构升级：v3.1的稳健风控 + v4.0的智能入场过滤。               |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "4.0"
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

input group "--- Core Settings ---"
input bool   EnableDebug             = true;
input int    EmergencyATRPeriod      = 14;      // 用于紧急止损和信号过滤的ATR周期
input double EmergencyATRMultiplier  = 1.5;     // 紧急止损 = ATR × 系数 (作为安全垫)
input int    Entry_CooldownSeconds   = 0;       // [兼容旧版] 冷却期：开仓后至少等待 N 秒
input double MinATRMultipleToTrade   = 0.1;     // 原始 SL 距离需 ≥ ATR×系数

//--- v4.0 全局变量: 用于价格行为确认 ---
double       g_lastTrendHigh         = 0.0;     // **v4.0新增**: 记录上次多头趋势期间的最高点
double       g_lastTrendLow          = 0.0;     // **v4.0新增**: 记录上次空头趋势期间的最低点

//--- 其他全局变量 ---
datetime     g_lastOpenTime          = 0;       // 上一次成功开仓时间
int          g_emergencyAtrHandle    = INVALID_HANDLE; // 全局紧急ATR句柄

bool   g_step1Done = false;
bool   g_step2Done = false;
double g_initialSL = 0.0;

//===================== 工具函数 =====================================
double MarketBid() { double v; SymbolInfoDouble(_Symbol, SYMBOL_BID,  v); return v; }
double MarketAsk() { double v; SymbolInfoDouble(_Symbol, SYMBOL_ASK, v); return v; }

//===================== 开仓函数 (无修改，承接v3.1) =================================
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

   /* 4️⃣ 计算基础安全SL (来自风控模块的最小距离保障) */
   double baseFinalSL = CalculateFinalStopLoss(openP, originalSL, orderType);

   /* 5️⃣ 计算波动性增强的紧急SL (方案A: 作为更宽的安全垫) */
   double emergencySL = GetSaferEmergencyStopLoss(openP, originalSL, orderType);

   /* 5b.【核心决策】: 从两个SL方案中选择离入场价最远的那个，作为最终执行的SL */
   double finalSL;
   if(orderType == ORDER_TYPE_BUY)
   {
      finalSL = MathMin(baseFinalSL, emergencySL); 
   }
   else
   {
      finalSL = MathMax(baseFinalSL, emergencySL);
   }

   /* 6️⃣ 设置最终止损（带重试） */
   if(!SetStopLossWithRetry(g_trade, finalSL, tpPrice, 3))
   {
      if(g_Logger != NULL)
         g_Logger.WriteError("🚨 无法设置最终安全止损，执行保护性平仓");
      g_trade.PositionClose(_Symbol);
      return false;
   }

   if(g_Logger != NULL)
      g_Logger.WriteInfo(StringFormat("开仓成功: %.2f 手 @ %.5f | Final SL=%.5f (Safe)",
                                      lot, openP, finalSL));
   return true;
}

//===================== 安全应急 SL 计算 (无修改，承接v3.1) =======================
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

//=========================== OnInit =================================
int OnInit()
{
   if(!InitializeLogger(LOG_LEVEL_INFO))
   { Print("日志初始化失败"); return INIT_FAILED; }

   g_Logger.WriteInfo("EA v4.0 启动 (重大升级：二次进场的价格行为确认)");

   InitRiskModule();
   if(!InitEntryModule(_Symbol, _Period))
   { g_Logger.WriteError("入场模块初始化失败"); return INIT_FAILED; }
   if(!InitExitModule(_Symbol, _Period))
   { g_Logger.WriteError("出场模块初始化失败"); return INIT_FAILED; }

   g_emergencyAtrHandle = iATR(_Symbol, _Period, EmergencyATRPeriod);
   if(g_emergencyAtrHandle == INVALID_HANDLE)
   {
       g_Logger.WriteError("紧急ATR指标初始化失败");
       return INIT_FAILED;
   }

   ConfigureTrader(g_trade);
   g_Logger.WriteInfo("架构: SuperTrend入场 · SAR/ADX出场 · 风控增强 · 智能过滤");

   return INIT_SUCCEEDED;
}

//=========================== OnDeinit ===============================
void OnDeinit(const int reason)
{
   DeinitEntryModule();
   DeinitExitModule();
   DeinitRiskModule();
   
   if(g_emergencyAtrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_emergencyAtrHandle);
   }

   if(g_Logger != NULL)
   {
      g_Logger.WriteInfo("EA 停止，清理模块");
      CleanupLogger();
   }
}

//=========================== OnTick (核心修改区域) =================================
void OnTick()
{
   /* ---- 持仓管理优先 ---- */
   if(PositionSelect(_Symbol)) 
   { 
      ManagePosition(); // ManagePosition内部已包含v4.0的逻辑
      return; 
   }

   /* ---- 开仓前置检查 ---- */
   if(!CanOpenNewTrade(EnableDebug)) return;

   // [兼容旧版] 冷却期控制
   if(g_lastOpenTime > 0 && TimeCurrent() - g_lastOpenTime < Entry_CooldownSeconds)
   {
      return;
   }

   /* ---- 1. 获取原始信号 ---- */
   double sl_price = 0;
   ENUM_ORDER_TYPE sig = GetEntrySignal(sl_price);
   if(sig == ORDER_TYPE_NONE) return;

   /* ---- 2. v4.0核心：基于价格行为的二次进场确认 ---- */
   if(sig == ORDER_TYPE_BUY)
   {
      // 检查是否处于“二次做多观察模式” (即上次平掉的是多单)
      if(g_lastTrendHigh > 0) 
      {
         // 确认价格是否已突破上次趋势的最高点，以证明趋势回归
         if(MarketAsk() <= g_lastTrendHigh)
         {
            if(g_Logger != NULL && EnableDebug)
               g_Logger.WriteInfo(StringFormat("二次做多信号过滤: 等待价格突破前高 %.5f", g_lastTrendHigh));
            return; // 未突破，过滤信号，继续等待
         }
      }
   }
   else if(sig == ORDER_TYPE_SELL)
   {
      // 检查是否处于“二次做空观察模式” (即上次平掉的是空单)
      if(g_lastTrendLow > 0)
      {
         // 确认价格是否已跌破上次趋势的最低点，以证明趋势回归
         if(MarketBid() >= g_lastTrendLow)
         {
            if(g_Logger != NULL && EnableDebug)
               g_Logger.WriteInfo(StringFormat("二次做空信号过滤: 等待价格跌破前低 %.5f", g_lastTrendLow));
            return; // 未跌破，过滤信号，继续等待
         }
      }
   }
   
   /* ---- 3. ATR × MinMultiple 距离过滤 ---- */
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
            if(g_Logger != NULL)
               g_Logger.WriteInfo(StringFormat(
                 "⚠️ 信号过滤(ATR距离): SL仅 %.1f 点 < 最小要求 %.1f 点，跳过",
                 distPts, minDist));
            return;
         }
      }
   }

   /* ---- 4. 所有检查通过，执行开仓 ---- */
   OpenPosition(sig, sl_price);
}

//=========================== 开仓接口 (v4.0 修改) ================================
void OpenPosition(ENUM_ORDER_TYPE type, double sl)
{
   bool ok = OpenMarketOrder_Fixed(type, sl, 0, "ST-EA v4.0");
   if(ok)
   {
      g_initialSL   = sl;
      g_step1Done   = g_step2Done = false;
      g_lastOpenTime = TimeCurrent();
      
      // **v4.0新增**: 开仓成功后，重置“记忆”，为新的趋势周期做准备。
      // 这意味着我们不再处于任何二次进场的观察模式中。
      g_lastTrendHigh = 0.0;
      g_lastTrendLow  = 0.0;
   }
}

//======================== 持仓管理函数 (v4.0 修改) ===============================
void ManagePosition()
{
   /* ---- v4.0新增：持仓期间，实时记录趋势的极值点 ---- */
   // 这个动作是在为下一次可能的二次进场做准备，记录下当前趋势的“战绩高点”
   ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   if(pType == POSITION_TYPE_BUY)
   {
      double currentHigh = iHigh(_Symbol, _Period, 0); // 获取当前K线的最高价
      // 如果是第一根K线或者创了新高，就更新记录
      if(g_lastTrendHigh == 0.0 || currentHigh > g_lastTrendHigh)
      {
         g_lastTrendHigh = currentHigh;
      }
   }
   else // POSITION_TYPE_SELL
   {
      double currentLow = iLow(_Symbol, _Period, 0); // 获取当前K线的最低价
      // 如果是第一根K线或者创了新低，就更新记录
      if(g_lastTrendLow == 0.0 || currentLow < g_lastTrendLow)
      {
         g_lastTrendLow = currentLow;
      }
   }

   /* ---- 原有的出场逻辑 ---- */
   double openP = PositionGetDouble(POSITION_PRICE_OPEN);
   double vol   = PositionGetDouble(POSITION_VOLUME);
   
   double pct = (pType == POSITION_TYPE_BUY)
              ? GetLongExitAction(openP, g_initialSL, g_step1Done, g_step2Done)
              : GetShortExitAction(openP, g_initialSL, g_step1Done, g_step2Done);
   if(pct <= 0.0) return;

   // 如果决定平仓，相应的 g_lastTrendHigh/Low 的值会被保留下来
   // 作为下一次同向开仓的过滤器。
   
   if(pct >= 100.0)
   {
      if(g_trade.PositionClose(_Symbol) && g_Logger != NULL)
         g_Logger.WriteInfo("全仓平仓成功，进入二次进场观察模式");
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
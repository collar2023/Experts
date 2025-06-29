//+------------------------------------------------------------------+
//| SuperTrend EA – v3.0 (三位一体架构)                              |
//| 主框架文件                                                      |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "3.0"
#property strict

//===================== 模块引入 =====================================
#include <Trade/Trade.mqh>
#include "SuperTrend_LogModule.mqh"   // ← 日志模块头文件 - 移到前面
#include "Risk_Management_Module.mqh"
#include "SuperTrend_Entry_Module.mqh"
#include "SAR_ADX_Exit_Module.mqh"
#include "Common_Defines.mqh"

//===================== 全局对象 & 变量 ===============================
CLogModule* g_Logger = NULL;      // 日志指针 - 确保声明在这里
CTrade      g_trade;              // 交易对象

input bool EnableDebug = true;    // 全局调试开关

bool   g_step1Done = false;
bool   g_step2Done = false;
double g_initialSL = 0.0;

//===================== 裸单开仓 + 合法补 SL + 紧急止损保护 ==============
bool OpenMarketOrder_NoStopsThenModify(ENUM_ORDER_TYPE orderType,
                                       double lot,
                                       double slPrice,
                                       double tpPrice,
                                       string comment="ST-EA")
{
   CTrade trd;
   trd.SetTypeFillingBySymbol(_Symbol);
   trd.SetDeviationInPoints(int(Risk_slippage));

   double price = (orderType==ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price<=0)
   {
      if(g_Logger != NULL) g_Logger.WriteError("价格获取失败");
      return false;
   }

   if(!trd.PositionOpen(_Symbol, orderType, lot, price, 0, 0, comment))
   {
      if(g_Logger != NULL) g_Logger.WriteError("开仓失败 err="+IntegerToString(GetLastError()));
      return false;
   }

   // —— 合法距离计算 —— //
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   int    stopPnts  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopLevel = stopPnts * _Point;

   bool needAdjust=false;
   if(slPrice>0)
   {
      if(orderType==ORDER_TYPE_BUY &&
         (slPrice>=openPrice || (openPrice-slPrice)<stopLevel))
         needAdjust=true;

      if(orderType==ORDER_TYPE_SELL &&
         (slPrice<=openPrice || (slPrice-openPrice)<stopLevel))
         needAdjust=true;

      if(needAdjust)
      {
         slPrice = (orderType==ORDER_TYPE_BUY)
                   ? openPrice - stopLevel - 3*_Point
                   : openPrice + stopLevel + 3*_Point;
         if(g_Logger != NULL && EnableDebug)
            g_Logger.WriteInfo(StringFormat("🔧 SL自动调整为 %.5f", slPrice));
      }
   }

   // —— 修改 SL/TP，最多3次 —— //
   if(slPrice>0 || tpPrice>0)
   {
      bool ok=false;
      for(int i=0;i<3 && !ok;i++)
      {
         ok = trd.PositionModify(_Symbol, slPrice, tpPrice);
         if(!ok && g_Logger != NULL)
            g_Logger.WriteWarning("PositionModify 第"+IntegerToString(i+1)+
                                   "次失败 err="+IntegerToString(GetLastError()));
         if(!ok) Sleep(200);
      }
      
      // === 新增：应急止损兜底保护 === //
      if(!ok && slPrice > 0)
      {
         // 获取ATR作为应急止损距离
         int atr_handle = iATR(_Symbol, _Period, 14);
         if(atr_handle != INVALID_HANDLE)
         {
            double atr[1];
            if(CopyBuffer(atr_handle, 0, 1, 1, atr) > 0)
            {
               double emergencySL = 0;
               
               if(orderType == ORDER_TYPE_BUY)
                  emergencySL = openPrice - atr[0] * 2.0;  // 2倍ATR作应急距离
               else
                  emergencySL = openPrice + atr[0] * 2.0;
               
               // 尝试设置应急SL
               if(trd.PositionModify(_Symbol, emergencySL, tpPrice))
               {
                  if(g_Logger != NULL)
                     g_Logger.WriteWarning(StringFormat("⚠️ 应急SL生效: %.5f (2xATR)", emergencySL));
               }
               else
               {
                  // 最后手段：直接平仓
                  if(g_Logger != NULL)
                     g_Logger.WriteError("🚨 无法设置任何SL，执行保护性平仓");
                  trd.PositionClose(_Symbol);
               }
            }
            else
            {
               // ATR数据获取失败，直接平仓保护
               if(g_Logger != NULL)
                  g_Logger.WriteError("🚨 ATR数据获取失败，执行保护性平仓");
               trd.PositionClose(_Symbol);
            }
            IndicatorRelease(atr_handle);
         }
         else
         {
            // ATR句柄创建失败，直接平仓保护
            if(g_Logger != NULL)
               g_Logger.WriteError("🚨 ATR句柄创建失败，执行保护性平仓");
            trd.PositionClose(_Symbol);
         }
      }
      else if(!ok && g_Logger != NULL) 
      {
         g_Logger.WriteError("最终仍未能设置止损！");
      }
   }
   return true;
}

//========================== OnInit ==================================
int OnInit()
{
   // 初始化日志
   if(!InitializeLogger(LOG_LEVEL_INFO))
   {
      Print("日志模块初始化失败");
      return INIT_FAILED;
   }
   g_Logger.WriteInfo("EA v3.0 启动成功 (含紧急止损保护)");

   // 各子模块
   InitRiskModule();
   if(!InitEntryModule(_Symbol,_Period))
   {
      g_Logger.WriteError("入场模块初始化失败");
      return INIT_FAILED;
   }
   if(!InitExitModule(_Symbol,_Period))
   {
      g_Logger.WriteError("出场模块初始化失败");
      return INIT_FAILED;
   }
   ConfigureTrader(g_trade);

   g_Logger.WriteInfo("架构: SuperTrend 入场 · SAR/ADX 出场 · 风控统一 · 紧急止损保护");
   return INIT_SUCCEEDED;
}

//========================== OnDeinit ================================
void OnDeinit(const int reason)
{
   DeinitEntryModule();
   DeinitExitModule();
   if(g_Logger != NULL)
   {
      g_Logger.WriteInfo("EA 停止，清理日志模块");
      CleanupLogger();
   }
}

//=========================== OnTick =================================
void OnTick()
{
   // 已有持仓 → 交给管理函数
   if(PositionSelect(_Symbol))
   {
      ManagePosition();
      return;
   }
   // 风控判定
   if(!CanOpenNewTrade(EnableDebug))
      return;

   // 入场信号
   double sl_price=0;
   ENUM_ORDER_TYPE sig = GetEntrySignal(sl_price);
   if(sig==ORDER_TYPE_NONE) return;

   OpenPosition(sig, sl_price);
}

//======================== 开仓函数 ==================================
void OpenPosition(ENUM_ORDER_TYPE type, double sl)
{
   double lot = CalculateLotSize(sl, type);
   if(lot<=0)
   {
      if(EnableDebug && g_Logger != NULL)
         g_Logger.WriteWarning("信号有效，但手数=0，跳过交易");
      return;
   }

   bool ok = OpenMarketOrder_NoStopsThenModify(type, lot, sl, 0, "ST-EA");
   if(ok)
   {
      g_initialSL = sl;
      g_step1Done = g_step2Done = false;
      if(g_Logger != NULL)
         g_Logger.WriteInfo(StringFormat("开仓成功: %s %.2f手 SL=%.5f",
                                          EnumToString(type), lot, sl));
   }
   else if(g_Logger != NULL)
      g_Logger.WriteError("开仓总体失败，见前面日志");
}

//====================== 持仓管理 ====================================
void ManagePosition()
{
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume    = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE pType=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double pctToClose = (pType==POSITION_TYPE_BUY)
                      ? GetLongExitAction(openPrice,g_initialSL,g_step1Done,g_step2Done)
                      : GetShortExitAction(openPrice,g_initialSL,g_step1Done,g_step2Done);
   if(pctToClose<=0.0) return;

   // 全平
   if(pctToClose>=100.0)
   {
      if(g_trade.PositionClose(_Symbol) && g_Logger != NULL)
         g_Logger.WriteInfo("全仓平仓成功");
      return;
   }

   // 部分平
   double volClose = volume * pctToClose/100.0;
   volClose = MathMax(volClose, SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN));
   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   volClose = MathFloor(volClose/step)*step;

   if(volClose>0 && g_trade.PositionClosePartial(_Symbol,volClose) && g_Logger != NULL)
      g_Logger.WriteInfo(StringFormat("部分止盈 %.2f%% 成功", pctToClose));
}
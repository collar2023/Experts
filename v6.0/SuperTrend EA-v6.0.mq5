//+------------------------------------------------------------------+
//| SuperTrend EA – v6.2 (终极编译修复版)                            |
//+------------------------------------------------------------------+
//|                                     © 2025                       |
//|  • 修复: 解决了所有 'extern' 和函数声明导致的编译错误。          |
//|  • 优化: 使用常量统一管理版本号，遵循两级编码规则。              |
//+------------------------------------------------------------------+
#property copyright "© 2025"
#property version   "6.2" // 终极编译修复版

// ★ FIX: 定义版本号常量，确保统一
const string G_EA_VERSION = "6.2";

//===================== 模块引入 (★ 修正了顺序) ========================
#include <Trade/Trade.mqh>
#include <Arrays/ArrayDouble.mqh>

#include "EA_Parameter_Structs.mqh"   // 1. 结构体和枚举定义 (最先)
#include "SuperTrend_LogModule.mqh"   // 2. 日志模块定义 (被其他模块依赖)
#include "Risk_Management_Module.mqh"   // 3. 其他模块
#include "SuperTrend_Entry_Module.mqh"
#include "SAR_ADX_Exit_Module.mqh"
#include "Structural_Exit_Module.mqh"


//===================== 全局对象 & 变量 (★ 唯一真实定义处) ===============
CLogModule* g_Logger = NULL;
CTrade      g_trade;

//===================== EA 输入参数 (所有模块参数集中于此) =====================

// --- General Settings ---
input group "--- General Settings ---"
input long   InpMagicNumber          = 123456;
input bool   EnableDebug             = true;

// --- Strategy Mode & Core Logic ---
input group "--- Strategy Mode & Core Logic ---"
input ENUM_BASE_EXIT_MODE BaseExitStrategy = EXIT_MODE_STRUCTURAL;
input bool   Enable_R_Multiple_Exit  = true;
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

// --- Structural Exit Settings (Mode 1) ---
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
input group "--- Structural Exit v1.9 Frequency Control ---"
input ENUM_SE_UPDATE_FREQ SE_UpdateFrequency = SE_FREQ_EVERY_BAR;
input int    SE_UpdateInterval              = 3;
input int    SE_CooldownBars                = 5;
input int    SE_MinHoldBars                 = 3;
input int    SE_ModifyRequestCooldownSeconds = 15;

// --- SAR/ADX & RRR Exit Settings (Mode 2) ---
input group    "--- Reversal Exit Settings (SAR & ADX) ---"
input bool     SAR_UseSARReversal   = false;
input bool     SAR_UseADXFilter     = true;
input double   SAR_Step             = 0.02;
input double   SAR_Maximum          = 0.2;
input int      SAR_ADX_Period       = 10;
input double   SAR_ADX_MinLevel     = 25.0;
input double   SAR_MinRRatio        = 1.5;
input int      SAR_ATR_Period       = 10;
input group    "--- Step Take Profit Settings (RRR) ---"
input bool     RRR_EnableStepTP     = true;
input double   RRR_ratio            = 2.0;
input double   RRR_Step1Pct         = 40.0;
input double   RRR_Step2Pct         = 30.0;
input double   RRR_Step2Factor      = 1.5;
input group    "--- Dynamic RRR Settings (ADX Synergy) ---"
input bool     RRR_Enable_Dynamic   = true;
input double   RRR_ADX_Strong_Threshold = 40.0;
input double   RRR_Strong_Trend_Factor  = 1.5;
input double   RRR_ADX_Weak_Threshold   = 20.0;
input double   RRR_Weak_Trend_Factor    = 0.75;

// ★★★ 参数结构体实例 ★★★
SRiskInputs           g_riskInputs;
SEntryInputs          g_entryInputs;
SStructuralExitInputs g_structExitInputs;
SSarAdxExitInputs     g_sarAdxExitInputs;

//--- 内部状态变量 ---
double       g_lastTrendHigh         = 0.0;
double       g_lastTrendLow          = 0.0;
datetime     g_lastOpenTime          = 0;
int          g_emergencyAtrHandle    = INVALID_HANDLE;
bool         g_step1Done             = false;
bool         g_step2Done             = false;
double       g_initialSL             = 0.0;

//===================== 工具函数 =====================================
double MarketBid() { double v; SymbolInfoDouble(_Symbol, SYMBOL_BID,  v); return v; }
double MarketAsk() { double v; SymbolInfoDouble(_Symbol, SYMBOL_ASK, v); return v; }

//===================== 开仓函数 ==================
bool OpenMarketOrder_Fixed(ENUM_ORDER_TYPE orderType, double originalSL, double tpPrice = 0, string comment = "")
{
   if(comment == "") comment = "ST-EA v" + G_EA_VERSION; // 使用版本常量
   
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
   // 1. 初始化日志模块 (最先)
   SLogInputs logInputs;
   logInputs.logLevel = InpLogLevel;
   logInputs.enableFileLog = InpEnableFileLog;
   logInputs.enableConsoleLog = InpEnableConsoleLog;
   logInputs.eaVersion = G_EA_VERSION; // ★ FIX: 使用版本常量
   if(!InitializeLogger(logInputs)) { Print("日志初始化失败"); return INIT_FAILED; }
   g_Logger.WriteInfo("EA v" + G_EA_VERSION + " 启动 (参数完全显性化版)");

   // 2. 填充所有参数结构体
   // -- 填充风控参数 --
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
   g_riskInputs.AllowNewTrade      = Risk_AllowNewTrade;

   // -- 填充入场参数 --
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

   // -- 填充结构化离场参数 --
   g_structExitInputs.EnableStructuralExit = (BaseExitStrategy == EXIT_MODE_STRUCTURAL);
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
   g_structExitInputs.ModifyRequestCooldownSeconds = SE_ModifyRequestCooldownSeconds;
   
   // -- 填充SAR/ADX离场参数 --
   g_sarAdxExitInputs.useSARReversal       = SAR_UseSARReversal;
   g_sarAdxExitInputs.useADXFilter         = SAR_UseADXFilter;
   g_sarAdxExitInputs.sarStep              = SAR_Step;
   g_sarAdxExitInputs.sarMaximum           = SAR_Maximum;
   g_sarAdxExitInputs.adxPeriod            = SAR_ADX_Period;
   g_sarAdxExitInputs.adxMinLevel          = SAR_ADX_MinLevel;
   g_sarAdxExitInputs.sarMinRRatio         = SAR_MinRRatio;
   g_sarAdxExitInputs.atrPeriod            = SAR_ATR_Period;
   g_sarAdxExitInputs.enableStepTP         = RRR_EnableStepTP;
   g_sarAdxExitInputs.rrRatio              = RRR_ratio;
   g_sarAdxExitInputs.step1Pct             = RRR_Step1Pct;
   g_sarAdxExitInputs.step2Pct             = RRR_Step2Pct;
   g_sarAdxExitInputs.step2Factor          = RRR_Step2Factor;
   g_sarAdxExitInputs.enableDynamicRRR     = RRR_Enable_Dynamic;
   g_sarAdxExitInputs.adxStrongThreshold   = RRR_ADX_Strong_Threshold;
   g_sarAdxExitInputs.strongTrendFactor    = RRR_Strong_Trend_Factor;
   g_sarAdxExitInputs.adxWeakThreshold     = RRR_ADX_Weak_Threshold;
   g_sarAdxExitInputs.weakTrendFactor      = RRR_Weak_Trend_Factor;
   
   // 3. 使用填充好的结构体初始化所有模块
   InitRiskModule(g_riskInputs);
   if(!InitEntryModule(_Symbol, _Period, g_entryInputs)) return INIT_FAILED;
   if(!InitExitModule(_Symbol, _Period, g_sarAdxExitInputs)) return INIT_FAILED;
   if(g_structExitInputs.EnableStructuralExit)
   {
      if(!InitStructuralExitModule(g_structExitInputs)) return INIT_FAILED;
   }
   
   // 4. 初始化EA自身所需的其他资源
   g_emergencyAtrHandle = iATR(_Symbol, _Period, EmergencyATRPeriod);
   if(g_emergencyAtrHandle == INVALID_HANDLE) return INIT_FAILED;
   ConfigureTrader(g_trade, g_riskInputs);
   
   g_Logger.LogParameterSettings();
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
      ResetPositionRecord();
   }
   if(g_emergencyAtrHandle != INVALID_HANDLE) IndicatorRelease(g_emergencyAtrHandle);
   if(g_Logger != NULL) 
   {
      g_Logger.WriteInfo("EA 停止，清理模块");
      CleanupLogger();
   }
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
   bool ok = OpenMarketOrder_Fixed(type, sl);
   if(ok)
   {
      g_initialSL = sl; g_step1Done = false; g_step2Done = false;
      g_lastOpenTime = TimeCurrent(); g_lastTrendHigh = 0.0; g_lastTrendLow = 0.0;
      if(BaseExitStrategy == EXIT_MODE_STRUCTURAL && PositionSelect(_Symbol))
      {
         ulong ticket = PositionGetTicket(0);
         RecordPositionOpen(ticket);
         if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("结构化离场模块已记录新仓位，票据: %d", ticket));
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
      double openP = PositionGetDouble(POSITION_PRICE_OPEN); 
      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      double pct = (pType == POSITION_TYPE_BUY) ? 
                   GetLongExitAction(openP, g_initialSL, g_step1Done, g_step2Done) : 
                   GetShortExitAction(openP, g_initialSL, g_step1Done, g_step2Done);
      
      if(pct > 0.0)
      {
         if(pct >= 100.0) 
         {
            string reason = (BaseExitStrategy == EXIT_MODE_SAR) ? "SAR反转" : "R-Multiple全仓";
            if(g_Logger != NULL) g_Logger.WriteInfo(reason + "信号触发，平掉所有仓位。");
            g_trade.PositionClose(_Symbol);
            if(BaseExitStrategy == EXIT_MODE_STRUCTURAL) ResetPositionRecord(); 
         }
         else
         {
            double vol = PositionGetDouble(POSITION_VOLUME); 
            double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double volClose = MathFloor((vol * pct / 100.0) / step) * step; 
            volClose = MathMax(volClose, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
            
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
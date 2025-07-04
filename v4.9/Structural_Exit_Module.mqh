//+------------------------------------------------------------------+
//| Structural_Exit_Module.mqh v4.9(健壮性优化版)                 |
//| • 优化: 模块内部管理初始止损，不再依赖外部传入，提高逻辑健壮性。 |
//+------------------------------------------------------------------+

// ★★★ 移除 #property strict

//==================================================================
//  模块内部句柄与静态变量
//==================================================================
static int      se_fractalHandle = INVALID_HANDLE;
static int      se_atrHandle     = INVALID_HANDLE;
static datetime se_last_processed_bar = 0;
static int      se_bar_counter = 0;
static datetime se_position_open_time = 0;
static int      se_position_hold_bars = 0;
static ulong    se_last_modify_request_ticket = 0;
static datetime se_last_modify_request_time = 0;

// ★ NEW: 用于独立跟踪仓位初始状态的变量
static ulong    se_tracked_ticket = 0;
static double   se_initial_sl_for_ticket = 0.0;

extern CLogModule* g_Logger;

//==================================================================
//  ★ 辅助函数前置定义 (集成日志保护)
//==================================================================
bool ModifyPosition(const SStructuralExitInputs &in, ulong ticket, double new_sl, double new_tp = 0)
{
   if(ticket == se_last_modify_request_ticket && TimeCurrent() - se_last_modify_request_time < in.modifyRequestCooldownSeconds)
   {
      return false;
   }
   MqlTradeRequest request={}; MqlTradeResult result={};
   if(!PositionSelectByTicket(ticket)) return false;
   if(NormalizePrice(new_sl) == NormalizePrice(PositionGetDouble(POSITION_SL))) return true;
   request.action = TRADE_ACTION_SLTP;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.sl = new_sl;
   request.tp = (new_tp == 0) ? PositionGetDouble(POSITION_TP) : new_tp;
   request.magic = PositionGetInteger(POSITION_MAGIC);
   se_last_modify_request_ticket = ticket;
   se_last_modify_request_time = TimeCurrent();
   if(!OrderSend(request,result))
   {
      if(result.retcode != TRADE_RETCODE_NO_CHANGES && result.retcode != 10036 && result.retcode != 10027 && result.retcode != 10018)
      {
         if(g_Logger) g_Logger.WriteWarning(StringFormat("[SE] 修改持仓失败: %s (%d)", result.comment, result.retcode));
      }
      return false;
   }
   if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ 修改请求已发送: SL->%.5f", new_sl));
   return true;
}

//==================================================================
//  模块初始化与清理
//==================================================================
bool InitStructuralExitModule(const SStructuralExitInputs &in)
{
   if(in.enableStructureStop)
   {
      se_fractalHandle = iFractals(_Symbol, _Period);
      if(se_fractalHandle==INVALID_HANDLE) { if(g_Logger) g_Logger.WriteError("[SE] 分形指标初始化失败!"); return false; }
   }
   if(in.enableATRFallback)
   {
      se_atrHandle = iATR(_Symbol, _Period, in.atrTrailPeriod);
      if(se_atrHandle==INVALID_HANDLE) { if(g_Logger) g_Logger.WriteError("[SE] ATR指标初始化失败!"); return false; }
   }
   se_last_processed_bar=0; se_bar_counter=0; se_position_open_time=0; se_position_hold_bars=0;
   se_last_modify_request_ticket=0; se_last_modify_request_time=0;
   se_tracked_ticket = 0; se_initial_sl_for_ticket = 0.0; // 初始化新变量
   if(g_Logger) g_Logger.WriteInfo("[SE] 结构化离场模块 v4.9.2 初始化完成 (健壮性优化版)");
   return true;
}

void DeinitStructuralExitModule()
{
   if(se_fractalHandle != INVALID_HANDLE) IndicatorRelease(se_fractalHandle);
   if(se_atrHandle != INVALID_HANDLE) IndicatorRelease(se_atrHandle);
}

//==================================================================
//  频率与时间控制函数
//==================================================================
bool ShouldUpdateStructuralStop(const SStructuralExitInputs &in)
{
   datetime current_bar = iTime(_Symbol, _Period, 0);
   if(in.updateFrequency == SE_FREQ_EVERY_TICK) return true;
   if(current_bar != se_last_processed_bar)
   {
      se_bar_counter++; se_last_processed_bar = current_bar;
      if(in.updateFrequency == SE_FREQ_EVERY_BAR) return true;
      if(in.updateFrequency == SE_FREQ_EVERY_N_BARS && se_bar_counter >= in.updateInterval)
      {
         se_bar_counter = 0; return true;
      }
   }
   return false;
}

bool IsInCooldownPeriod(const SStructuralExitInputs &in)
{
   if(se_position_open_time == 0) return false;
   se_position_hold_bars = Bars(_Symbol, _Period, se_position_open_time, TimeCurrent());
   return (se_position_hold_bars < in.cooldownBars);
}

bool IsMinHoldTimeMet(const SStructuralExitInputs &in)
{
   if(se_position_open_time == 0) return true;
   return (se_position_hold_bars >= in.minHoldBars);
}

//==================================================================
//  核心离场逻辑
//==================================================================
// ★ MODIFIED: 不再需要传入 initialSL
bool ProcessBreakeven(const SStructuralExitInputs &in, ulong ticket)
{
   // ★ 使用模块内部记录的初始SL
   if(!in.enableBreakeven || se_initial_sl_for_ticket == 0) return false;

   if(!PositionSelectByTicket(ticket)) return false;
   double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_sl = PositionGetDouble(POSITION_SL);
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_price = (pos_type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double buffer = in.breakevenBufferPips * _Point;

   // ★ 使用正确的、模块内部存储的初始止损来计算风险
   double risk_dist = MathAbs(entry_price - se_initial_sl_for_ticket);
   if(risk_dist <= 0) return false;

   double profit_dist = (pos_type == POSITION_TYPE_BUY) ? (current_price - entry_price) : (entry_price - current_price);
   if(profit_dist >= risk_dist * in.breakevenTriggerRR)
   {
      double new_sl = (pos_type == POSITION_TYPE_BUY) ? entry_price + buffer : entry_price - buffer;
      bool should_modify = (pos_type == POSITION_TYPE_BUY) ? (new_sl > current_sl) : (current_sl == 0 || new_sl < current_sl);
      if(should_modify && ModifyPosition(in, ticket, new_sl))
      {
         if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ 保本止损已设置: %.5f", new_sl));
         return true;
      }
   }
   return false;
}

bool ProcessStructuralStop(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.enableStructureStop || !ShouldUpdateStructuralStop(in) || IsInCooldownPeriod(in)) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_sl = PositionGetDouble(POSITION_SL);
   double buffer = in.structureBufferPips * _Point;
   double fractal_up[], fractal_down[];
   ArraySetAsSeries(fractal_up, true); ArraySetAsSeries(fractal_down, true);
   int copied_up = CopyBuffer(se_fractalHandle, 0, 1, in.structureLookback, fractal_up);
   int copied_down = CopyBuffer(se_fractalHandle, 1, 1, in.structureLookback, fractal_down);
   if(copied_up <= 0 || copied_down <= 0) return false;
   double new_sl = 0;
   if(pos_type == POSITION_TYPE_BUY)
   {
      for(int i = 0; i < copied_down; i++) { if(fractal_down[i] > 0) { new_sl = fractal_down[i] - buffer; break; } }
      if(new_sl > 0 && new_sl > current_sl && ModifyPosition(in, ticket, new_sl))
      {
         if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ 结构化止损已更新 (买单): %.5f", new_sl));
         return true;
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      for(int i = 0; i < copied_up; i++) { if(fractal_up[i] > 0) { new_sl = fractal_up[i] + buffer; break; } }
      if(new_sl > 0 && (current_sl == 0 || new_sl < current_sl) && ModifyPosition(in, ticket, new_sl))
      {
         if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ 结构化止损已更新 (卖单): %.5f", new_sl));
         return true;
      }
   }
   return false;
}

bool ProcessATRTrail(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.enableATRFallback || !ShouldUpdateStructuralStop(in)) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   double atr_values[1];
   if(CopyBuffer(se_atrHandle, 0, 0, 1, atr_values) <= 0 || atr_values[0] <= 0) return false;
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_sl = PositionGetDouble(POSITION_SL);
   double atr_distance = atr_values[0] * in.atrTrailMultiplier;
   double new_sl = 0;
   if(pos_type == POSITION_TYPE_BUY)
   {
      new_sl = SymbolInfoDouble(_Symbol, SYMBOL_BID) - atr_distance;
      if(new_sl > current_sl && ModifyPosition(in, ticket, new_sl))
      {
         if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ ATR跟踪止损已更新 (买单): %.5f", new_sl));
         return true;
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      new_sl = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + atr_distance;
      if((current_sl == 0 || new_sl < current_sl) && ModifyPosition(in, ticket, new_sl))
      {
         if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ ATR跟踪止损已更新 (卖单): %.5f", new_sl));
         return true;
      }
   }
   return false;
}

//==================================================================
//  主处理与记录函数
//==================================================================
void RecordPositionOpenTime() { se_position_open_time = TimeCurrent(); }

// ★ MODIFIED: 主处理函数，增加了仓位跟踪和初始SL的内部管理
bool ProcessStructuralExit(const SStructuralExitInputs &in, ulong ticket)
{
   // 当检测到新的持仓票据时，记录其初始止损位，并重置模块内部状态
   if(ticket != se_tracked_ticket)
   {
      if(PositionSelectByTicket(ticket))
      {
         se_initial_sl_for_ticket = PositionGetDouble(POSITION_SL);
         se_tracked_ticket = ticket;
         se_position_open_time = 0; // 重置开仓时间，让模块重新计时
         if(g_Logger && se_initial_sl_for_ticket > 0) 
         {
            g_Logger.WriteInfo(StringFormat("[SE] 开始跟踪新仓位 %d, 记录初始SL: %.5f", ticket, se_initial_sl_for_ticket));
         }
      }
      else // 如果按票据找不到仓位，说明仓位已平，重置跟踪状态
      {
          se_tracked_ticket = 0;
          se_initial_sl_for_ticket = 0.0;
          return false;
      }
   }

   if(se_position_open_time == 0) RecordPositionOpenTime();

   // 调用不带 initialSL 参数的保本函数
   bool action_taken = ProcessBreakeven(in, ticket);
   
   if(!IsMinHoldTimeMet(in)) return action_taken;
   if(ProcessStructuralStop(in, ticket)) return true;
   if(ProcessATRTrail(in, ticket)) return true;
   return action_taken;
}
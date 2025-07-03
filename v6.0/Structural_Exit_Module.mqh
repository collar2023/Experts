//+------------------------------------------------------------------+
//| Structural_Exit_Module.mqh v6.2 (终极编译修复版)                 |
//+------------------------------------------------------------------+
#property strict

//==================================================================
//  模块内部句柄与静态变量
//==================================================================
static int se_fractalHandle = INVALID_HANDLE;
static int se_atrHandle     = INVALID_HANDLE;
static datetime se_last_processed_bar = 0;
static int      se_bar_counter = 0;
static double   se_last_failed_sl = 0;
static datetime se_last_failed_bar_time = 0;
static datetime se_position_open_time = 0;
static int      se_position_hold_bars = 0;
static ulong    se_last_modify_request_ticket = 0;
static datetime se_last_modify_request_time = 0;
extern CLogModule* g_Logger;

//==================================================================
//  ★ 辅助函数前置定义 (FIX)
//==================================================================
bool ModifyPosition(const SStructuralExitInputs &in, ulong ticket, double new_sl, double new_tp = 0)
{
   if(ticket == se_last_modify_request_ticket && TimeCurrent() - se_last_modify_request_time < in.ModifyRequestCooldownSeconds)
   {
      return false;
   }

   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   if(!PositionSelectByTicket(ticket)) return false;
   
   if(NormalizeDouble(new_sl, _Digits) == NormalizeDouble(PositionGetDouble(POSITION_SL), _Digits)) return true;

   request.action = TRADE_ACTION_SLTP;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.sl = new_sl;
   request.tp = (new_tp == 0) ? PositionGetDouble(POSITION_TP) : new_tp;
   request.magic = PositionGetInteger(POSITION_MAGIC);
   
   se_last_modify_request_ticket = ticket;
   se_last_modify_request_time = TimeCurrent();
   
   if(!OrderSend(request, result))
   {
      if(result.retcode != 10036 && result.retcode != 10027 && result.retcode != 10018)
      {
         if(g_Logger) g_Logger.WriteWarning(StringFormat("[SE] 修改持仓失败: %s (%d)", result.comment, result.retcode));
      }
      return false;
   }
   
   return true;
}

//==================================================================
//  模块初始化与清理
//==================================================================
bool InitStructuralExitModule(const SStructuralExitInputs &in)
{
   if(in.EnableStructureStop)
   {
      se_fractalHandle = iFractals(_Symbol, _Period);
      if(se_fractalHandle==INVALID_HANDLE)
      {
         if(g_Logger) g_Logger.WriteError("[SE] 模块错误: 分形指标初始化失败!");
         return false;
      }
   }
   if(in.EnableATRFallback)
   {
      se_atrHandle = iATR(_Symbol, _Period, in.ATRTrailPeriod);
      if(se_atrHandle==INVALID_HANDLE)
      {
         if(g_Logger) g_Logger.WriteError("[SE] 模块错误: ATR指标初始化失败!");
         return false;
      }
   }
   
   se_last_processed_bar = 0;
   se_bar_counter = 0;
   se_last_failed_sl = 0;
   se_last_failed_bar_time = 0;
   se_position_open_time = 0;
   se_position_hold_bars = 0;
   se_last_modify_request_ticket = 0;
   se_last_modify_request_time = 0;
   
   if(g_Logger)
   {
       g_Logger.WriteInfo("[SE] 模块 v6.2 初始化完成");
       g_Logger.WriteInfo(StringFormat("[SE] 保本操作: 每tick更新 (触发RR:%.1f, 缓冲:%.1fpips)", in.BreakevenTriggerRR, in.BreakevenBufferPips));
       g_Logger.WriteInfo(StringFormat("[SE] 结构化止损更新频率: %s", (in.UpdateFrequency==0?"每tick":in.UpdateFrequency==1?"每K线":"每"+IntegerToString(in.UpdateInterval)+"根K线")));
       g_Logger.WriteInfo(StringFormat("[SE] 冷却期: %d K线 (请求间隔: %d秒) | 最小持仓: %d K线", in.CooldownBars, in.ModifyRequestCooldownSeconds, in.MinHoldBars));
   }
   return true;
}

void DeinitStructuralExitModule()
{
   if(se_fractalHandle != INVALID_HANDLE) IndicatorRelease(se_fractalHandle);
   if(se_atrHandle != INVALID_HANDLE) IndicatorRelease(se_atrHandle);
   if(g_Logger) g_Logger.WriteInfo("[SE] 模块已清理");
}

//==================================================================
//  频率控制函数
//==================================================================
bool ShouldUpdateStructuralStop(const SStructuralExitInputs &in)
{
   datetime current_bar = iTime(_Symbol, _Period, 0);
   if(in.UpdateFrequency == SE_FREQ_EVERY_TICK) return true;
   if(current_bar != se_last_processed_bar)
   {
      se_bar_counter++;
      se_last_processed_bar = current_bar;
      if(in.UpdateFrequency == SE_FREQ_EVERY_BAR) return true;
      if(in.UpdateFrequency == SE_FREQ_EVERY_N_BARS && se_bar_counter >= in.UpdateInterval)
      {
         se_bar_counter = 0;
         return true;
      }
   }
   return false;
}

//==================================================================
//  时间保护期检查函数
//==================================================================
bool IsInCooldownPeriod(const SStructuralExitInputs &in)
{
   if(se_position_open_time == 0) return false;
   int bars_passed = Bars(_Symbol, _Period, se_position_open_time, TimeCurrent());
   se_position_hold_bars = bars_passed;
   return (bars_passed < in.CooldownBars);
}

bool IsMinHoldTimeMet(const SStructuralExitInputs &in)
{
   if(se_position_open_time == 0) return true;
   return (se_position_hold_bars >= in.MinHoldBars);
}

//==================================================================
//  保本操作
//==================================================================
bool ProcessBreakeven(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.EnableBreakeven) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   
   double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double initial_sl = PositionGetDouble(POSITION_SL);
   if(initial_sl == 0) return false; 
   
   double current_sl = PositionGetDouble(POSITION_SL);
   double current_price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double point = _Point;
   double buffer = in.BreakevenBufferPips * point;

   double risk_dist = (pos_type == POSITION_TYPE_BUY) ? (entry_price - initial_sl) : (initial_sl - entry_price);
   if(risk_dist <= 0) return false;

   double profit_dist = (pos_type == POSITION_TYPE_BUY) ? (current_price - entry_price) : (entry_price - current_price);
   
   if(profit_dist >= risk_dist * in.BreakevenTriggerRR)
   {
      double new_sl = (pos_type == POSITION_TYPE_BUY) ? entry_price + buffer : entry_price - buffer;
      bool should_modify = (pos_type == POSITION_TYPE_BUY) ? (new_sl > current_sl) : (current_sl == 0 || new_sl < current_sl);
      if(should_modify)
      {
         if(ModifyPosition(in, ticket, new_sl))
         {
            if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ 保本止损已设置: %.5f", new_sl));
            return true;
         }
      }
   }
   return false;
}

//==================================================================
//  结构化止损处理
//==================================================================
bool ProcessStructuralStop(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.EnableStructureStop) return false;
   if(!ShouldUpdateStructuralStop(in)) return false;
   if(IsInCooldownPeriod(in)) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_sl = PositionGetDouble(POSITION_SL);
   double buffer = in.StructureBufferPips * _Point;
   
   double fractal_up[], fractal_down[];
   ArraySetAsSeries(fractal_up, true);
   ArraySetAsSeries(fractal_down, true);
   
   int copied_up = CopyBuffer(se_fractalHandle, 0, 1, in.StructureLookback, fractal_up);
   int copied_down = CopyBuffer(se_fractalHandle, 1, 1, in.StructureLookback, fractal_down);

   if(copied_up <= 0 || copied_down <= 0)
   {
      return false;
   }
   
   double new_sl = 0;
   if(pos_type == POSITION_TYPE_BUY)
   {
      for(int i = 0; i < copied_down; i++) { if(fractal_down[i] > 0) { new_sl = fractal_down[i] - buffer; break; } }
      if(new_sl > 0 && new_sl > current_sl)
      {
         if(ModifyPosition(in, ticket, new_sl))
         {
            if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ 结构化止损已更新 (买单): %.5f", new_sl));
            return true;
         }
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      for(int i = 0; i < copied_up; i++) { if(fractal_up[i] > 0) { new_sl = fractal_up[i] + buffer; break; } }
      if(new_sl > 0 && (current_sl == 0 || new_sl < current_sl))
      {
         if(ModifyPosition(in, ticket, new_sl))
         {
            if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ 结构化止损已更新 (卖单): %.5f", new_sl));
            return true;
         }
      }
   }
   return false;
}

//==================================================================
//  ATR跟踪止损
//==================================================================
bool ProcessATRTrail(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.EnableATRFallback) return false;
   if(!ShouldUpdateStructuralStop(in)) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   
   double atr_values[1];
   if(CopyBuffer(se_atrHandle, 0, 0, 1, atr_values) <= 0 || atr_values[0] <= 0) return false;
   
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_sl = PositionGetDouble(POSITION_SL);
   double atr_distance = atr_values[0] * in.ATRTrailMultiplier;
   
   double new_sl = 0;
   if(pos_type == POSITION_TYPE_BUY)
   {
      new_sl = SymbolInfoDouble(_Symbol, SYMBOL_BID) - atr_distance;
      if(new_sl > current_sl)
      {
         if(ModifyPosition(in, ticket, new_sl))
         {
            if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ ATR跟踪止损已更新 (买单): %.5f", new_sl));
            return true;
         }
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      new_sl = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + atr_distance;
      if(current_sl == 0 || new_sl < current_sl)
      {
         if(ModifyPosition(in, ticket, new_sl))
         {
            if(g_Logger) g_Logger.WriteInfo(StringFormat("[SE] ✓ ATR跟踪止损已更新 (卖单): %.5f", new_sl));
            return true;
         }
      }
   }
   return false;
}

//==================================================================
//  持仓记录函数
//==================================================================
void RecordPositionOpen(ulong ticket)
{
   se_position_open_time = TimeCurrent();
   se_position_hold_bars = 0;
   se_last_modify_request_ticket = 0;
   se_last_modify_request_time = 0;
}

void ResetPositionRecord()
{
   se_position_open_time = 0;
   se_position_hold_bars = 0;
   se_last_modify_request_ticket = 0;
   se_last_modify_request_time = 0;
}

//==================================================================
//  主处理函数
//==================================================================
bool ProcessStructuralExit(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.EnableStructuralExit) return false;
   
   bool any_action = ProcessBreakeven(in, ticket);
   if(!IsMinHoldTimeMet(in)) return any_action;
   if(ProcessStructuralStop(in, ticket)) return true;
   if(ProcessATRTrail(in, ticket)) return true;
   
   return any_action;
}
//+------------------------------------------------------------------+
//| Structural_Exit_Module.mqh v1.8 (2025‑07‑06)                     |
//| ★ v1.8: 降频优化版 - 结构化止损降到K线级别，保本操作保持tick级别   |
//|   解决过于敏感导致趋势行情走不出来的问题                          |
//+------------------------------------------------------------------+
#property strict
//==================================================================
//  输入结构体
//==================================================================
struct SStructuralExitInputs
{
   bool   EnableStructuralExit;
   bool   EnableBreakeven;
   double BreakevenTriggerRR;
   double BreakevenBufferPips;
   bool   EnableStructureStop;
   int    StructureLookback;
   double StructureBufferPips;
   bool   EnableATRFallback;
   int    ATRTrailPeriod;
   double ATRTrailMultiplier;
   
   // ★ 新增：更新频率控制 (仅针对结构化止损)
   int    UpdateFrequency;  // 0=每tick, 1=每K线, 2=每N根K线
   int    UpdateInterval;   // 当UpdateFrequency=2时，每N根K线更新一次
   
   // ★ 新增：时间保护期设置
   int    CooldownBars;     // 冷却K线数：持仓开启后N根K线内不更新结构化止损
   int    MinHoldBars;      // 最小持仓K线数：持仓N根K线后才允许结构化出场
};
//==================================================================
//  模块内部句柄与静态变量
//==================================================================
static int se_fractalHandle = INVALID_HANDLE;
static int se_atrHandle     = INVALID_HANDLE;
// ★★★ v1.8 核心新增: K线级别控制变量 (仅用于结构化止损) ★★★
static datetime se_last_processed_bar = 0;    // 上次处理结构化止损的K线时间
static int      se_bar_counter = 0;           // K线计数器
static double   se_last_failed_sl = 0;
static datetime se_last_failed_bar_time = 0;
// ★★★ v1.8 时间保护期变量 ★★★
static datetime se_position_open_time = 0;    // 记录持仓开启时间
static int      se_position_hold_bars = 0;    // 持仓经历的K线数
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
         Print("[SE] 模块错误: 分形指标初始化失败!");
         return false;
      }
   }
   if(in.EnableATRFallback)
   {
      se_atrHandle = iATR(_Symbol, _Period, in.ATRTrailPeriod);
      if(se_atrHandle==INVALID_HANDLE)
      {
         Print("[SE] 模块错误: ATR指标初始化失败!");
         return false;
      }
   }
   
   // 重置所有控制变量
   se_last_processed_bar = 0;
   se_bar_counter = 0;
   se_last_failed_sl = 0;
   se_last_failed_bar_time = 0;
   se_position_open_time = 0;
   se_position_hold_bars = 0;
   
   Print("[SE] 模块 v1.8 初始化完成 (降频+冷却优化版)");
   Print("[SE] 保本操作: 每tick更新 (快速响应)");
   Print("[SE] 结构化止损更新频率: ", (in.UpdateFrequency==0?"每tick":in.UpdateFrequency==1?"每K线":"每"+IntegerToString(in.UpdateInterval)+"根K线"));
   Print("[SE] 冷却期: ", in.CooldownBars, " 根K线");
   Print("[SE] 最小持仓: ", in.MinHoldBars, " 根K线");
   return true;
}

void DeinitStructuralExitModule()
{
   if(se_fractalHandle != INVALID_HANDLE)
   {
      IndicatorRelease(se_fractalHandle);
      se_fractalHandle = INVALID_HANDLE;
   }
   if(se_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(se_atrHandle);
      se_atrHandle = INVALID_HANDLE;
   }
   Print("[SE] 模块已清理");
}

//==================================================================
//  频率控制函数 (仅用于结构化止损)
//==================================================================
bool ShouldUpdateStructuralStop(const SStructuralExitInputs &in)
{
   datetime current_bar = iTime(_Symbol, _Period, 0);
   
   // 如果是每tick更新，直接返回true
   if(in.UpdateFrequency == 0) return true;
   
   // 如果是新K线，更新计数器
   if(current_bar != se_last_processed_bar)
   {
      se_bar_counter++;
      
      // 每K线更新
      if(in.UpdateFrequency == 1)
      {
         se_last_processed_bar = current_bar;
         return true;
      }
      
      // 每N根K线更新
      if(in.UpdateFrequency == 2 && se_bar_counter >= in.UpdateInterval)
      {
         se_bar_counter = 0;
         se_last_processed_bar = current_bar;
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
   
   // 计算持仓经历的K线数
   int bars_passed = Bars(_Symbol, _Period, se_position_open_time, TimeCurrent());
   se_position_hold_bars = bars_passed;
   
   // 检查是否在冷却期内
   if(bars_passed < in.CooldownBars)
   {
      return true;
   }
   
   return false;
}

bool IsMinHoldTimeMet(const SStructuralExitInputs &in)
{
   if(se_position_open_time == 0) return true;
   
   return (se_position_hold_bars >= in.MinHoldBars);
}

//==================================================================
//  保本操作 (保持tick级别更新)
//==================================================================
bool ProcessBreakeven(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.EnableBreakeven) return false;
   
   if(!PositionSelectByTicket(ticket))
   {
      Print("[SE] 保本处理错误: 无法选择持仓 ", ticket);
      return false;
   }
   
   double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_sl = PositionGetDouble(POSITION_SL);
   double current_price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double buffer = in.BreakevenBufferPips * point * ((digits == 5 || digits == 3) ? 10 : 1);
   
   double profit_pips, required_pips, new_sl;
   
   if(pos_type == POSITION_TYPE_BUY)
   {
      profit_pips = (current_price - entry_price) / point;
      required_pips = (entry_price - current_sl) / point * in.BreakevenTriggerRR;
      
      if(profit_pips >= required_pips)
      {
         new_sl = entry_price + buffer;
         if(new_sl > current_sl && new_sl < current_price - buffer)
         {
            if(ModifyPosition(ticket, new_sl))
            {
               Print("[SE] ✓ 保本止损已设置: ", DoubleToString(new_sl, digits),
                     " (利润:", DoubleToString(profit_pips, 1), "pips)");
               return true;
            }
         }
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      profit_pips = (entry_price - current_price) / point;
      required_pips = (current_sl - entry_price) / point * in.BreakevenTriggerRR;
      
      if(profit_pips >= required_pips)
      {
         new_sl = entry_price - buffer;
         if((current_sl == 0 || new_sl < current_sl) && new_sl > current_price + buffer)
         {
            if(ModifyPosition(ticket, new_sl))
            {
               Print("[SE] ✓ 保本止损已设置: ", DoubleToString(new_sl, digits),
                     " (利润:", DoubleToString(profit_pips, 1), "pips)");
               return true;
            }
         }
      }
   }
   
   return false;
}

//==================================================================
//  结构化止损处理 (降频到K线级别)
//==================================================================
bool ProcessStructuralStop(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.EnableStructureStop) return false;
   
   // ★★★ 频率控制：只在指定频率下更新结构化止损 ★★★
   if(!ShouldUpdateStructuralStop(in)) return false;
   
   // ★★★ 时间保护期检查 ★★★
   if(IsInCooldownPeriod(in))
   {
      // Print("[SE] 结构化止损暂停: 冷却期内 (", se_position_hold_bars, "/", in.CooldownBars, " 根K线)");
      return false;
   }
   
   if(!PositionSelectByTicket(ticket))
   {
      Print("[SE] 结构化止损错误: 无法选择持仓 ", ticket);
      return false;
   }
   
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_sl = PositionGetDouble(POSITION_SL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double buffer = in.StructureBufferPips * point * ((digits == 5 || digits == 3) ? 10 : 1);
   
   // 获取分形数据
   double fractal_up[], fractal_down[];
   ArraySetAsSeries(fractal_up, true);
   ArraySetAsSeries(fractal_down, true);
   
   if(CopyBuffer(se_fractalHandle, 0, 0, in.StructureLookback + 10, fractal_up) <= 0 ||
      CopyBuffer(se_fractalHandle, 1, 0, in.StructureLookback + 10, fractal_down) <= 0)
   {
      Print("[SE] 结构化止损错误: 无法获取分形数据");
      return false;
   }
   
   double new_sl = 0;
   
   if(pos_type == POSITION_TYPE_BUY)
   {
      // 寻找最近的下分形
      for(int i = 2; i < ArraySize(fractal_down) && i < in.StructureLookback + 10; i++)
      {
         if(fractal_down[i] != EMPTY_VALUE && fractal_down[i] > 0)
         {
            new_sl = fractal_down[i] - buffer;
            break;
         }
      }
      
      // 验证新止损
      if(new_sl > 0 && new_sl > current_sl)
      {
         double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(new_sl < current_price - buffer)
         {
            // 防止频繁失败
            if(new_sl == se_last_failed_sl && 
               TimeCurrent() - se_last_failed_bar_time < PeriodSeconds(_Period) * 3)
            {
               return false;
            }
            
            if(ModifyPosition(ticket, new_sl))
            {
               Print("[SE] ✓ 结构化止损已更新 (买单): ", DoubleToString(new_sl, digits));
               se_last_failed_sl = 0;
               return true;
            }
            else
            {
               se_last_failed_sl = new_sl;
               se_last_failed_bar_time = TimeCurrent();
            }
         }
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      // 寻找最近的上分形
      for(int i = 2; i < ArraySize(fractal_up) && i < in.StructureLookback + 10; i++)
      {
         if(fractal_up[i] != EMPTY_VALUE && fractal_up[i] > 0)
         {
            new_sl = fractal_up[i] + buffer;
            break;
         }
      }
      
      // 验证新止损
      if(new_sl > 0 && (current_sl == 0 || new_sl < current_sl))
      {
         double current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(new_sl > current_price + buffer)
         {
            // 防止频繁失败
            if(new_sl == se_last_failed_sl && 
               TimeCurrent() - se_last_failed_bar_time < PeriodSeconds(_Period) * 3)
            {
               return false;
            }
            
            if(ModifyPosition(ticket, new_sl))
            {
               Print("[SE] ✓ 结构化止损已更新 (卖单): ", DoubleToString(new_sl, digits));
               se_last_failed_sl = 0;
               return true;
            }
            else
            {
               se_last_failed_sl = new_sl;
               se_last_failed_bar_time = TimeCurrent();
            }
         }
      }
   }
   
   return false;
}

//==================================================================
//  ATR跟踪止损 (降频到K线级别)
//==================================================================
bool ProcessATRTrail(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.EnableATRFallback) return false;
   
   // ★★★ ATR跟踪止损也使用相同的频率控制 ★★★
   if(!ShouldUpdateStructuralStop(in)) return false;
   
   if(!PositionSelectByTicket(ticket))
   {
      Print("[SE] ATR跟踪止损错误: 无法选择持仓 ", ticket);
      return false;
   }
   
   double atr_values[];
   ArraySetAsSeries(atr_values, true);
   
   if(CopyBuffer(se_atrHandle, 0, 0, 2, atr_values) <= 0)
   {
      Print("[SE] ATR跟踪止损错误: 无法获取ATR数据");
      return false;
   }
   
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_sl = PositionGetDouble(POSITION_SL);
   double atr_distance = atr_values[0] * in.ATRTrailMultiplier;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   double new_sl = 0;
   
   if(pos_type == POSITION_TYPE_BUY)
   {
      double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      new_sl = current_price - atr_distance;
      
      if(new_sl > current_sl)
      {
         if(ModifyPosition(ticket, new_sl))
         {
            Print("[SE] ✓ ATR跟踪止损已更新 (买单): ", DoubleToString(new_sl, digits));
            return true;
         }
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      double current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      new_sl = current_price + atr_distance;
      
      if(current_sl == 0 || new_sl < current_sl)
      {
         if(ModifyPosition(ticket, new_sl))
         {
            Print("[SE] ✓ ATR跟踪止损已更新 (卖单): ", DoubleToString(new_sl, digits));
            return true;
         }
      }
   }
   
   return false;
}

//==================================================================
//  持仓记录函数 (用于时间保护期)
//==================================================================
void RecordPositionOpen(ulong ticket)
{
   se_position_open_time = TimeCurrent();
   se_position_hold_bars = 0;
   Print("[SE] 持仓已记录: ", ticket, " 开启时间: ", TimeToString(se_position_open_time));
}

void ResetPositionRecord()
{
   se_position_open_time = 0;
   se_position_hold_bars = 0;
   //Print("[SE] 持仓记录已重置");
}

//==================================================================
//  主处理函数
//==================================================================
bool ProcessStructuralExit(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.EnableStructuralExit) return false;
   
   bool any_action = false;
   
   // ★★★ 保本操作始终在tick级别快速响应 ★★★
   if(ProcessBreakeven(in, ticket))
   {
      any_action = true;
   }
   
   // ★★★ 结构化止损在指定频率下更新 ★★★
   if(ProcessStructuralStop(in, ticket))
   {
      any_action = true;
   }
   
   // ★★★ ATR跟踪止损也在指定频率下更新 ★★★
   if(!any_action && ProcessATRTrail(in, ticket))
   {
      any_action = true;
   }
   
   return any_action;
}

//==================================================================
//  辅助函数
//==================================================================
bool ModifyPosition(ulong ticket, double new_sl, double new_tp = 0)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   if(!PositionSelectByTicket(ticket))
   {
      Print("[SE] 修改持仓错误: 无法选择持仓 ", ticket);
      return false;
   }
   
   request.action = TRADE_ACTION_SLTP;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.sl = new_sl;
   request.tp = (new_tp == 0) ? PositionGetDouble(POSITION_TP) : new_tp;
   request.magic = PositionGetInteger(POSITION_MAGIC);
   
   if(!OrderSend(request, result))
   {
      Print("[SE] 修改持仓失败: ", result.comment, " (", result.retcode, ")");
      return false;
   }
   
   return true;
}
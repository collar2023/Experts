//+------------------------------------------------------------------+
//| Structural_Exit_Module.mqh v1.9 Enhanced (2025‑07‑08)          |
//| ★ v1.9 Enhanced: 请求冷却增强版 - 屏蔽10036刷屏 + 延长冷却期   |
//|   1. 屏蔽10036、10027、10018等常见无害错误码的打印输出          |
//|   2. 冷却期从5秒延长到15秒，进一步减少重复请求                   |
//|   3. 继承所有v1.9原有功能和保护机制                              |
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
   
   int    UpdateFrequency;
   int    UpdateInterval;
   
   int    CooldownBars;
   int    MinHoldBars;
};

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

// ★★★ v1.9 核心: 请求冷却机制变量 ★★★
static ulong    se_last_modify_request_ticket = 0; // 记录上次发送修改请求的票据
static datetime se_last_modify_request_time = 0; // 记录上次发送修改请求的时间


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
   
   se_last_processed_bar = 0;
   se_bar_counter = 0;
   se_last_failed_sl = 0;
   se_last_failed_bar_time = 0;
   se_position_open_time = 0;
   se_position_hold_bars = 0;
   // 初始化请求冷却变量
   se_last_modify_request_ticket = 0;
   se_last_modify_request_time = 0;
   
   Print("[SE] 模块 v1.9 Enhanced 初始化完成 (15秒冷却期 + 静默错误处理)");
   Print("[SE] 保本操作: 每tick更新 (快速响应)");
   Print("[SE] 结构化止损更新频率: ", (in.UpdateFrequency==0?"每tick":in.UpdateFrequency==1?"每K线":"每"+IntegerToString(in.UpdateInterval)+"根K线"));
   Print("[SE] 冷却期: ", in.CooldownBars, " 根K线 (请求间隔: 15秒)");
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
   
   if(in.UpdateFrequency == 0) return true;
   
   if(current_bar != se_last_processed_bar)
   {
      se_bar_counter++;
      if(in.UpdateFrequency == 1)
      {
         se_last_processed_bar = current_bar;
         return true;
      }
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
   
   int bars_passed = Bars(_Symbol, _Period, se_position_open_time, TimeCurrent());
   se_position_hold_bars = bars_passed;
   
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
   double initial_sl = PositionGetDouble(POSITION_SL); // Assuming initial SL is set correctly on position open
   if(initial_sl == 0) return false; // Cannot calculate RR without initial SL

   double current_price = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double buffer = in.BreakevenBufferPips * point;

   double profit_pips, required_pips, new_sl;
   
   if(pos_type == POSITION_TYPE_BUY)
   {
      profit_pips = (current_price - entry_price);
      required_pips = (entry_price - initial_sl) * in.BreakevenTriggerRR;
      
      if(profit_pips >= required_pips)
      {
         new_sl = entry_price + buffer;
         if(new_sl > current_sl)
         {
            if(ModifyPosition(ticket, new_sl))
            {
               Print("[SE] ✓ 保本止损已设置: ", DoubleToString(new_sl, digits));
               return true;
            }
         }
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      profit_pips = (entry_price - current_price);
      required_pips = (initial_sl - entry_price) * in.BreakevenTriggerRR;
      
      if(profit_pips >= required_pips)
      {
         new_sl = entry_price - buffer;
         if((current_sl == 0 || new_sl < current_sl))
         {
            if(ModifyPosition(ticket, new_sl))
            {
               Print("[SE] ✓ 保本止损已设置: ", DoubleToString(new_sl, digits));
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
   if(!ShouldUpdateStructuralStop(in)) return false;
   if(IsInCooldownPeriod(in)) return false;
   
   if(!PositionSelectByTicket(ticket))
   {
      Print("[SE] 结构化止损错误: 无法选择持仓 ", ticket);
      return false;
   }
   
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double current_sl = PositionGetDouble(POSITION_SL);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double buffer = in.StructureBufferPips * point;
   
   double fractal_up[], fractal_down[];
   ArraySetAsSeries(fractal_up, true);
   ArraySetAsSeries(fractal_down, true);
   
   if(CopyBuffer(se_fractalHandle, 0, 1, in.StructureLookback, fractal_up) <= 0 ||
      CopyBuffer(se_fractalHandle, 1, 1, in.StructureLookback, fractal_down) <= 0)
   {
      Print("[SE] 结构化止损错误: 无法获取分形数据");
      return false;
   }
   
   double new_sl = 0;
   
   if(pos_type == POSITION_TYPE_BUY)
   {
      for(int i = 0; i < ArraySize(fractal_down); i++)
      {
         if(fractal_down[i] > 0)
         {
            new_sl = fractal_down[i] - buffer;
            break;
         }
      }
      
      if(new_sl > 0 && new_sl > current_sl)
      {
         if(ModifyPosition(ticket, new_sl))
         {
            Print("[SE] ✓ 结构化止损已更新 (买单): ", DoubleToString(new_sl, digits));
            return true;
         }
      }
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      for(int i = 0; i < ArraySize(fractal_up); i++)
      {
         if(fractal_up[i] > 0)
         {
            new_sl = fractal_up[i] + buffer;
            break;
         }
      }
      
      if(new_sl > 0 && (current_sl == 0 || new_sl < current_sl))
      {
         if(ModifyPosition(ticket, new_sl))
         {
            Print("[SE] ✓ 结构化止损已更新 (卖单): ", DoubleToString(new_sl, digits));
            return true;
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
   if(!ShouldUpdateStructuralStop(in)) return false;
   
   if(!PositionSelectByTicket(ticket))
   {
      Print("[SE] ATR跟踪止损错误: 无法选择持仓 ", ticket);
      return false;
   }
   
   double atr_values[];
   ArraySetAsSeries(atr_values, true);
   
   if(CopyBuffer(se_atrHandle, 0, 0, 1, atr_values) <= 0)
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
   // 开仓时也重置冷却计时器
   se_last_modify_request_ticket = 0;
   se_last_modify_request_time = 0;
   Print("[SE] 持仓已记录: ", ticket, " 开启时间: ", TimeToString(se_position_open_time));
}

void ResetPositionRecord()
{
   se_position_open_time = 0;
   se_position_hold_bars = 0;
   // ★★★ v1.9 新增：重置冷却状态 ★★★
   se_last_modify_request_ticket = 0;
   se_last_modify_request_time = 0;
   //Print("[SE] 持仓记录已重置");
}

//==================================================================
//  主处理函数
//==================================================================
bool ProcessStructuralExit(const SStructuralExitInputs &in, ulong ticket)
{
   if(!in.EnableStructuralExit) return false;
   
   bool any_action = false;
   
   if(ProcessBreakeven(in, ticket))
   {
      any_action = true;
   }
   
   if(!IsMinHoldTimeMet(in)) return any_action; // 最小持仓K线数检查
   
   if(ProcessStructuralStop(in, ticket))
   {
      any_action = true;
   }
   
   if(!any_action && ProcessATRTrail(in, ticket))
   {
      any_action = true;
   }
   
   return any_action;
}

//==================================================================
//  辅助函数 - Enhanced版本
//==================================================================
bool ModifyPosition(ulong ticket, double new_sl, double new_tp = 0)
{
   // ★★★ v1.9 Enhanced: 15秒冷却期的"节流阀" ★★★
   if(ticket == se_last_modify_request_ticket && TimeCurrent() - se_last_modify_request_time < 15) // 从5秒延长到15秒
   {
      return false; // 请求过于频繁，跳过
   }

   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   if(!PositionSelectByTicket(ticket))
   {
      Print("[SE] 修改持仓错误: 无法选择持仓 ", ticket);
      return false;
   }
   
   // 第二层保护: 如果目标SL和当前SL已经一样，也没必要发送
   double current_server_sl = PositionGetDouble(POSITION_SL);
   if(NormalizeDouble(new_sl, _Digits) == NormalizeDouble(current_server_sl, _Digits))
   {
       return true; // 任务已完成
   }

   request.action = TRADE_ACTION_SLTP;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.sl = new_sl;
   request.tp = (new_tp == 0) ? PositionGetDouble(POSITION_TP) : new_tp;
   request.magic = PositionGetInteger(POSITION_MAGIC);
   
   // ★★★ v1.9 核心逻辑：发送前记录状态 ★★★
   se_last_modify_request_ticket = ticket;
   se_last_modify_request_time = TimeCurrent();
   
   if(!OrderSend(request, result))
   {
      // ★★★ Enhanced: 屏蔽常见无害错误码的打印输出 ★★★
      if(result.retcode != 10036 && result.retcode != 10027 && result.retcode != 10018)
      {
         Print("[SE] 修改持仓失败: ", result.comment, " (", result.retcode, ")");
      }
      return false;
   }
   
   Print("[SE] ✓ 修改请求已发送: SL->", DoubleToString(new_sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   return true;
}
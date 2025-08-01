//+------------------------------------------------------------------+
//|                                     QQE-Mod_ZeroCross_EA.mq5 |
//|                                      Copyright 2023, 专业EA定制服务 |
//|                                        https://www.mql5.com      |
//+------------------------------------------------------------------+
#property copyright "专业EA定制服务"
#property link      "https://www.mql5.com"
#property version   "3.04" // [终极版] 简化加仓逻辑并规范函数命名
#property description "基于QQE四色柱的、具备多次加仓和断线重连能力的智能交易框架"

#include <Trade\Trade.mqh>

//--- EA状态定义
enum ENUM_TRADING_STATE
  {
   STATE_IDLE,          // 空闲，寻找初始入场机会
   STATE_IN_POSITION    // 持仓，监控出场或加仓信号
  };

//--- EA 输入参数
input group "QQE Indicator Settings";
input int               Inp_RSI_Period      = 14;      // RSI 周期
input int               Inp_RSI_Smoothing   = 5;       // RSI 平滑周期
input double            Inp_QQE_Factor      = 4.236;   // QQE 因子

input group "Entry & Scale-in Settings";
input double            Inp_Hist_Threshold  = 1.0;     // 初始入场柱体最小高度
input int               Inp_Max_ScaleIn_Times = 2;       // 最大加仓次数 (0=关闭加仓)

input group "Trading Settings";
input double            Inp_Lots            = 0.01;    // 基础仓位手数
input double            Inp_ScaleIn_Lots    = 0.01;    // 加仓手数
input ulong             Inp_MagicNumber     = 65432;   // EA魔术数字
input string            Inp_Comment_Prefix  = "QQE_EA"; // 订单注释前缀

input group "Risk Management Settings";
input bool              Inp_Use_ATR_StopLoss = true;     // 使用ATR动态止损?
input int               Inp_ATR_Period       = 14;     // ATR 周期
input double            Inp_ATR_Multiplier   = 2.5;    // ATR 止损乘数

//--- 全局变量
CTrade              trade;
int                 g_qqe_handle = INVALID_HANDLE;
int                 g_atr_handle = INVALID_HANDLE;
datetime            g_last_bar_time = 0;
ENUM_TRADING_STATE  g_trading_state = STATE_IDLE;
int                 g_scale_in_count = 0; // 加仓计数器

//+------------------------------------------------------------------+
//| EA初始化函数
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(Inp_MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_qqe_handle = iCustom(_Symbol, _Period, "QQE-Mod", Inp_RSI_Period, Inp_RSI_Smoothing, Inp_QQE_Factor);
   if(g_qqe_handle == INVALID_HANDLE)
     {
      Alert("错误: 无法加载 'QQE-Mod' 指标! 请确保V1.10或更高版本已编译。");
      return(INIT_FAILED);
     }

   if(Inp_Use_ATR_StopLoss)
     {
      g_atr_handle = iATR(_Symbol, _Period, Inp_ATR_Period);
      if(g_atr_handle == INVALID_HANDLE) { Alert("错误: 无法加载ATR指标!"); return(INIT_FAILED); }
     }
     
   RestoreEAState();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| EA反初始化函数
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_qqe_handle != INVALID_HANDLE) IndicatorRelease(g_qqe_handle);
   if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
  }

//+------------------------------------------------------------------+
//| EA 'Tick' 函数
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!IsNewBar()) return;
   
   if(GetPositionsCountByComment(Inp_Comment_Prefix) == 0 && g_trading_state == STATE_IN_POSITION)
     {
      g_trading_state = STATE_IDLE;
      g_scale_in_count = 0;
     }

   switch(g_trading_state)
     {
      case STATE_IDLE:
         CheckInitialEntry();
         break;
      case STATE_IN_POSITION:
         ManageInPosition();
         break;
     }
  }
  
//+------------------------------------------------------------------+
//| 状态: 空闲 -> 检查初始入场
//+------------------------------------------------------------------+
void CheckInitialEntry()
  {
   if(GetPositionsCountByComment(Inp_Comment_Prefix) > 0) { g_trading_state = STATE_IN_POSITION; return; }
     
   double qqe_fast[4], hist[4], color_data[4];
   if(!FetchIndicatorData(4, qqe_fast, hist, color_data)) return;

   // --- 多头入场 ---
   bool buy_zero_cross = qqe_fast[3] <= 50.0;
   bool buy_three_bright_green = color_data[1] == 1 && color_data[2] == 1 && color_data[3] == 1;
   bool buy_expanding = hist[1] > hist[2] && hist[2] > hist[3];
   bool buy_threshold = hist[1] > Inp_Hist_Threshold;

   if(buy_zero_cross && buy_three_bright_green && buy_expanding && buy_threshold)
     {
      string comment = StringFormat("%s_Base_Buy", Inp_Comment_Prefix);
      if(OpenPosition(Inp_Lots, POSITION_TYPE_BUY, comment))
        {
         g_trading_state = STATE_IN_POSITION;
         g_scale_in_count = 0;
        }
      return;
     }

   // --- 空头入场 ---
   bool sell_zero_cross = qqe_fast[3] >= 50.0;
   bool sell_three_bright_red = color_data[1] == -1 && color_data[2] == -1 && color_data[3] == -1;
   bool sell_expanding = MathAbs(hist[1]) > MathAbs(hist[2]) && MathAbs(hist[2]) > MathAbs(hist[3]);
   bool sell_threshold = MathAbs(hist[1]) > Inp_Hist_Threshold;

   if(sell_zero_cross && sell_three_bright_red && sell_expanding && sell_threshold)
     {
      string comment = StringFormat("%s_Base_Sell", Inp_Comment_Prefix);
      if(OpenPosition(Inp_Lots, POSITION_TYPE_SELL, comment))
        {
         g_trading_state = STATE_IN_POSITION;
         g_scale_in_count = 0;
        }
     }
  }

//+------------------------------------------------------------------+
//| 状态: 持仓中 -> 管理持仓 (出场或加仓)
//+------------------------------------------------------------------+
void ManageInPosition()
  {
   if(GetPositionsCountByComment(Inp_Comment_Prefix) == 0) { CloseAllPositions(); return; }

   double qqe_fast[3], color_data[3];
   if(CopyBuffer(g_qqe_handle, 0, 0, 3, qqe_fast) < 3 || CopyBuffer(g_qqe_handle, 3, 0, 3, color_data) < 3) return;
     
   ENUM_POSITION_TYPE pos_type = GetPositionType();
   if(pos_type == WRONG_VALUE) { CloseAllPositions(); return; }

   // --- 1. 检查出场信号 (最高优先级) ---
   bool exit_by_singularity = (pos_type == POSITION_TYPE_BUY && (color_data[2] == 1 || color_data[2] == 2) && color_data[1] == -2) ||
                              (pos_type == POSITION_TYPE_SELL && (color_data[2] == -1 || color_data[2] == -2) && color_data[1] == 2);
   if(exit_by_singularity) { CloseAllPositions(); return; }
     
   bool exit_by_zero_cross = (pos_type == POSITION_TYPE_BUY && qqe_fast[1] < 50.0) ||
                             (pos_type == POSITION_TYPE_SELL && qqe_fast[1] > 50.0);
   if(exit_by_zero_cross) { CloseAllPositions(); return; }

   // --- 2. 检查加仓信号 (如果出场信号不满足) ---
   // [优化] 移除HadRecentCallback，直接判断“暗转亮”
   if(Inp_Max_ScaleIn_Times > 0 && g_scale_in_count < Inp_Max_ScaleIn_Times)
     {
      bool scale_in = false;
      if(pos_type == POSITION_TYPE_BUY && color_data[2] == 2 && color_data[1] == 1)
        {
         scale_in = true;
        }
      else if(pos_type == POSITION_TYPE_SELL && color_data[2] == -2 && color_data[1] == -1)
        {
         scale_in = true;
        }
        
      if(scale_in)
        {
         string comment = StringFormat("%s_ScaleIn_%d", Inp_Comment_Prefix, g_scale_in_count + 1);
         if(OpenPosition(Inp_ScaleIn_Lots, pos_type, comment))
           {
            g_scale_in_count++;
           }
        }
     }
  }
  
//+------------------------------------------------------------------+
//| 开仓函数
//+------------------------------------------------------------------+
bool OpenPosition(double lots, ENUM_POSITION_TYPE type, string comment)
  {
   MqlTradeRequest request;
   ZeroMemory(request);
   MqlTradeResult  result;
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lots;
   request.magic = Inp_MagicNumber;
   request.comment = comment;
   request.type_filling = (ENUM_ORDER_TYPE_FILLING)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   request.deviation = 5;
   
   if(type == POSITION_TYPE_BUY)
     {
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.type = ORDER_TYPE_BUY;
     }
   else
     {
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      request.type = ORDER_TYPE_SELL;
     }

   if(Inp_Use_ATR_StopLoss && g_atr_handle != INVALID_HANDLE)
     {
      double atr_value[1];
      if(CopyBuffer(g_atr_handle, 0, 0, 1, atr_value) > 0 && atr_value[0] > 0)
        {
         double sl_distance = atr_value[0] * Inp_ATR_Multiplier;
         request.sl = (type == POSITION_TYPE_BUY) ? request.price - sl_distance : request.price + sl_distance;
        }
      else { Print("ATR值为0或获取失败，本次不开仓。"); return false; }
     }
     
   if(!OrderSend(request, result)) { Print("OrderSend 失败: ", GetLastError()); return false; }
   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED) 
     { 
      Print("开仓失败，错误: ", result.retcode, " - ", result.comment); 
      return false; 
     }
   
   return true;
  }
  
//+------------------------------------------------------------------+
//| 辅助函数: 获取指标数据
//+------------------------------------------------------------------+
bool FetchIndicatorData(int bars, double &qqe_fast[], double &hist[], double &color_data[])
  {
   if(CopyBuffer(g_qqe_handle, 0, 0, bars, qqe_fast) < bars ||
      CopyBuffer(g_qqe_handle, 2, 0, bars, hist) < bars ||
      CopyBuffer(g_qqe_handle, 3, 0, bars, color_data) < bars)
     {
      Print("无法复制指标数据，数据不足。");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| 平掉所有仓位并重置状态
//+------------------------------------------------------------------+
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) == Inp_MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
         trade.PositionClose(ticket);
        }
     }
   g_trading_state = STATE_IDLE;
   g_scale_in_count = 0;
  }

//+------------------------------------------------------------------+
//| 获取当前持仓方向
//+------------------------------------------------------------------+
ENUM_POSITION_TYPE GetPositionType()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
        {
         if(PositionGetInteger(POSITION_MAGIC) == Inp_MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
           {
            return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
           }
        }
     }
   return WRONG_VALUE;
  }

//+------------------------------------------------------------------+
//| 启动时恢复EA状态
//+------------------------------------------------------------------+
void RestoreEAState()
{
    int total_positions = 0;
    int max_scale_in_num = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == Inp_MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
                total_positions++;
                string comment = PositionGetString(POSITION_COMMENT);
                if(StringFind(comment, "_ScaleIn_") >= 0)
                {
                    string scale_num_str = StringSubstr(comment, StringFind(comment, "_ScaleIn_") + 9);
                    int scale_num = (int)StringToInteger(scale_num_str);
                    if(scale_num > max_scale_in_num)
                    {
                        max_scale_in_num = scale_num;
                    }
                }
            }
        }
    }

    if(total_positions > 0)
    {
        g_trading_state = STATE_IN_POSITION;
        g_scale_in_count = max_scale_in_num;
        Print("EA状态已恢复: 持仓中, 已加仓次数 = ", g_scale_in_count);
    }
    else
    {
        g_trading_state = STATE_IDLE;
        g_scale_in_count = 0;
        Print("EA状态已恢复: 空闲");
    }
}

//+------------------------------------------------------------------+
//| [优化] 按注释统计持仓数量，替换与系统函数重名的旧函数
//+------------------------------------------------------------------+
int GetPositionsCountByComment(string comment_prefix)
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == Inp_MagicNumber && 
               PositionGetString(POSITION_SYMBOL) == _Symbol &&
               StringFind(PositionGetString(POSITION_COMMENT), comment_prefix) == 0)
            {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| 检查新K线
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   MqlRates rates[1];
   if(CopyRates(_Symbol, _Period, 0, 1, rates) > 0)
     {
      if(g_last_bar_time != rates[0].time)
        {
         g_last_bar_time = rates[0].time;
         return true;
        }
     }
   return false;
  }
//+------------------------------------------------------------------+
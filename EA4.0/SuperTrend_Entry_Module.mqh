//+------------------------------------------------------------------+
//|                                     SuperTrend_Entry_Module.mqh |
//|          SuperTrend 策略入场模块 (含智能动态止损) v3.1           |
//| (负责: 入场信号检测、ADX过滤、动态止损价计算、市场异常检测)    |
//|     • 核心更新: 信号检测基于已收盘K线，避免震荡市重绘干扰        |
//+------------------------------------------------------------------+
#ifdef ORDER_TYPE_NONE
   #pragma message("ORDER_TYPE_NONE OK!")
#endif

#property strict
//--- 简易平均值工具，等价于 ArrayAverage()
double ArrayAverage(const double &src[], int offset, int count)
{
   int total = ArraySize(src);
   if(offset < 0 || count <= 0 || offset + count > total)
      return 0.0;                        // 防越界
   double sum = 0.0;
   for(int i = 0; i < count; i++)
      sum += src[offset + i];
   return sum / count;
}

#include "Common_Defines.mqh"

//==================================================================
//  结构体定义
//==================================================================
struct MarketAnomalyStatus
{
   bool   is_news_period;      // 是否为新闻发布时段
   bool   is_high_volatility;  // 是否为高波动期
   bool   is_range_bound;      // 是否为区间震荡
   bool   is_holiday_period;   // 是否为假期时段
   double anomaly_multiplier;  // 异常情况倍数
};

//==================================================================
//  输入参数
//==================================================================
input group    "--- SuperTrend Entry Settings ---"
input string   Entry_stIndicatorName    = "supertrend-free"; // SuperTrend指标文件名
input int      Entry_atrPeriod          = 10;                // ATR 周期
input double   Entry_atrMultiplier      = 3.0;               // ATR 乘数
input double   Entry_stopLossBufferPips = 10;               // 基础止损缓冲点数

input group    "--- Dynamic Stop Loss Optimization ---"
input bool     Entry_useDynamicBuffer   = true;              // [开关] 启用动态缓冲优化
input double   Entry_minBufferPips      = 5.0;               // 最小缓冲点数
input double   Entry_maxBufferPips      = 30.0;              // 最大缓冲点数
input double   Entry_sessionMultiplier  = 1.2;               // 交易时段乘数
input double   Entry_volatilityFactor   = 0.8;               // 波动率调整因子

input group    "--- Market Anomaly Detection ---"
input bool     Entry_useAnomalyDetection = true;             // [开关] 启用市场异常检测
input double   Entry_newsBufferMultiplier = 1.5;             // 新闻时段缓冲倍数
input double   Entry_highVolMultiplier   = 1.3;              // 高波动缓冲倍数
input double   Entry_rangeBoundMultiplier = 0.8;             // 区间震荡缓冲倍数

input group    "--- Entry Filter (ADX) ---"
input bool     Entry_useADXFilter       = false;             // [开关] 是否启用ADX入场过滤
input int      Entry_adxPeriod          = 14;                // ADX 周期
input double   Entry_adxMinStrength     = 23.0;              // ADX 最小强度阈值

//==================================================================
//  全局变量
//==================================================================
int st_handle_entry  = INVALID_HANDLE;
int adx_handle_entry = INVALID_HANDLE;
int atr_handle_entry = INVALID_HANDLE; // 用于动态缓冲计算

//==================================================================
//  市场异常检测函数
//==================================================================

//+------------------------------------------------------------------+
//| 市场异常检测主函数                                               |
//+------------------------------------------------------------------+
MarketAnomalyStatus DetectMarketAnomalies()
{
    // 该函数逻辑保持不变
    MarketAnomalyStatus status = {false, false, false, false, 1.0};
    
    // 1. 新闻时段检测（简化版，实际可接入新闻日历API）
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    
    if((dt.hour == 8 && dt.min >= 25 && dt.min <= 35) ||   
       (dt.hour == 12 && dt.min >= 25 && dt.min <= 35) ||  
       (dt.hour == 14 && dt.min >= 25 && dt.min <= 35))
    {
        status.is_news_period = true;
        status.anomaly_multiplier *= Entry_newsBufferMultiplier;
    }
    
    // 2. 高波动期检测
    double atr_current[1], atr_history[20];
    if(atr_handle_entry != INVALID_HANDLE && CopyBuffer(atr_handle_entry, 0, 0, 1, atr_current) >= 1 && CopyBuffer(atr_handle_entry, 0, 0, 20, atr_history) >= 20)
    {
        double avg_atr_20 = ArrayAverage(atr_history, 0, 20);
        if(atr_current[0] > avg_atr_20 * 1.5)
        {
            status.is_high_volatility = true;
            status.anomaly_multiplier *= Entry_highVolMultiplier;
        }
    }
    
    // 3. 区间震荡检测
    double high_20 = iHigh(_Symbol, _Period, iHighest(_Symbol, _Period, MODE_HIGH, 20, 1));
    double low_20 = iLow(_Symbol, _Period, iLowest(_Symbol, _Period, MODE_LOW, 20, 1));
    double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        
    if(high_20 > low_20)
    {
        double range_position = (current_price - low_20) / (high_20 - low_20);
        if(range_position > 0.3 && range_position < 0.7)
        {
            status.is_range_bound = true;
            status.anomaly_multiplier *= Entry_rangeBoundMultiplier;
        }
    }
    
    // 4. 假期时段检测（简化版）
    if(dt.day_of_week == 1 && dt.hour < 3)
    {
        status.is_holiday_period = true;
        status.anomaly_multiplier *= 1.2;
    }
    
    return status;
}

//==================================================================
//  动态缓冲优化辅助函数 (所有辅助函数均保持不变)
//==================================================================

//+------------------------------------------------------------------+
//| 获取当前交易时段乘数                                             |
//+------------------------------------------------------------------+
double GetSessionMultiplier()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;
    
    if(hour >= 0 && hour < 7) return 1.0;
    else if(hour >= 7 && hour < 15) return Entry_sessionMultiplier;
    else if(hour >= 15 && hour < 21) return Entry_sessionMultiplier * 1.1;
    else return 0.9;
}

//+------------------------------------------------------------------+
//| 获取品种波动率调整因子                                           |
//+------------------------------------------------------------------+
double GetSymbolVolatilityFactor()
{
    string symbol = _Symbol;
    if(StringFind(symbol, "JPY") >= 0) return Entry_volatilityFactor * 0.7;
    else if(StringFind(symbol, "GBP") >= 0) return Entry_volatilityFactor * 1.2;
    else if(StringFind(symbol, "EUR") >= 0 || StringFind(symbol, "USD") >= 0) return Entry_volatilityFactor;
    else return Entry_volatilityFactor * 1.1;
}

//+------------------------------------------------------------------+
//| 计算优化的动态缓冲                                               |
//+------------------------------------------------------------------+
double CalculateOptimizedBuffer()
{
    double base_buffer = Entry_stopLossBufferPips * _Point;
    if(!Entry_useDynamicBuffer) return base_buffer;
    
    double session_adjusted = base_buffer * GetSessionMultiplier();
    double volatility_adjusted = session_adjusted * GetSymbolVolatilityFactor();
    double final_buffer = volatility_adjusted;
    
    if(Entry_useAnomalyDetection)
    {
        MarketAnomalyStatus anomaly = DetectMarketAnomalies();
        final_buffer *= anomaly.anomaly_multiplier;
    }
    
    double min_buffer = Entry_minBufferPips * _Point;
    double max_buffer = Entry_maxBufferPips * _Point;
    return MathMax(min_buffer, MathMin(max_buffer, final_buffer));
}

//==================================================================
//  模块初始化与清理函数 (保持不变)
//==================================================================

//+------------------------------------------------------------------+
//| 模块初始化                                                      |
//+------------------------------------------------------------------+
bool InitEntryModule(const string symbol, const ENUM_TIMEFRAMES period)
{
    st_handle_entry = iCustom(symbol, period, Entry_stIndicatorName, Entry_atrPeriod, Entry_atrMultiplier);
    if(st_handle_entry == INVALID_HANDLE)
    {
        Print("入场模块: SuperTrend指标 '", Entry_stIndicatorName, "' 加载失败. Error: ", GetLastError());
        return false;
    }
    
    if(Entry_useDynamicBuffer || Entry_useAnomalyDetection)
    {
        atr_handle_entry = iATR(symbol, period, Entry_atrPeriod);
        if(atr_handle_entry == INVALID_HANDLE)
        {
            Print("入场模块: ATR指标加载失败. Error: ", GetLastError());
            return false;
        }
    }
    
    if(Entry_useADXFilter)
    {
        adx_handle_entry = iADX(symbol, period, Entry_adxPeriod);
        if(adx_handle_entry == INVALID_HANDLE)
        {
            Print("入场模块: ADX指标加载失败. Error: ", GetLastError());
            return false;
        }
    }
    
    Print("SuperTrend 智能入场模块初始化成功.");
    Print("动态缓冲: ", Entry_useDynamicBuffer ? "启用" : "禁用");
    Print("异常检测: ", Entry_useAnomalyDetection ? "启用" : "禁用");
    Print("ADX过滤: ", Entry_useADXFilter ? "启用" : "禁用");
    
    return true;
}

//+------------------------------------------------------------------+
//| 模块反初始化                                                    |
//+------------------------------------------------------------------+
void DeinitEntryModule()
{
    if(st_handle_entry != INVALID_HANDLE) IndicatorRelease(st_handle_entry);
    if(adx_handle_entry != INVALID_HANDLE) IndicatorRelease(adx_handle_entry);
    if(atr_handle_entry != INVALID_HANDLE) IndicatorRelease(atr_handle_entry);
    
    Print("SuperTrend 入场模块已清理.");
}

//==================================================================
//  模块核心功能函数 (核心修改区域)
//==================================================================

//+------------------------------------------------------------------+
//| 主函数: 获取入场信号和优化止损价 (v3.1 - 收盘确认版)             |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetEntrySignal(double &sl_price)
{
    sl_price = 0; // 默认无止损价

    // 1. 获取SuperTrend指标数据 (获取3条，用于稳定判断)
    double trend_buffer[3], dir_buffer[3];
    if(CopyBuffer(st_handle_entry, 0, 0, 3, trend_buffer) < 3 || 
       CopyBuffer(st_handle_entry, 2, 0, 3, dir_buffer) < 3)
    {
        // 在历史数据不足的开始阶段，这是正常情况，不打印错误
        return ORDER_TYPE_NONE; 
    }

    // 2. 【核心修改】基于已收盘的K线[1]和[2]检测SuperTrend反转信号
    // 信号条件: 上一根K线(dir_buffer[1])的方向非0，且与上上根K线(dir_buffer[2])的方向不同
    if(dir_buffer[1] == 0 || dir_buffer[1] == dir_buffer[2])
    {
        return ORDER_TYPE_NONE; // 在已收盘的K线上无反转信号
    }

    // 【新增】防重复开仓机制：确保每个信号K线只触发一次交易
    static datetime last_signal_time = 0;
    datetime signal_bar_time = (datetime)iTime(_Symbol, _Period, 1);
    if(signal_bar_time <= last_signal_time)
    {
       // 这个信号K线已经被处理过，或者时间戳异常，直接跳过，防止重复或错误交易
       return ORDER_TYPE_NONE;
    }

    // 3. 【逻辑调整】ADX过滤器 (在信号K线[1]上检测)
    if(Entry_useADXFilter)
    {
        double adx_buffer[2]; // 获取2个值，用索引[1]
        if(CopyBuffer(adx_handle_entry, MAIN_LINE, 0, 2, adx_buffer) < 2)
        {
            Print("入场模块: ADX数据获取失败");
            return ORDER_TYPE_NONE;
        }
        if(adx_buffer[1] < Entry_adxMinStrength)
        {
            Print("入场模块: 信号在K线 [", TimeToString(signal_bar_time), "] 被ADX过滤. ADX(", DoubleToString(adx_buffer[1], 2) + 
              ") < 阈值(" + DoubleToString(Entry_adxMinStrength, 2) + ")");
            last_signal_time = signal_bar_time; // 即使过滤，也要记录，防止当前K线内不断尝试
            return ORDER_TYPE_NONE; // 趋势强度不足
        }
    }

    // 4. 确定信号方向并计算优化止损价
    ENUM_ORDER_TYPE signal = ORDER_TYPE_NONE;
    // 动态缓冲计算依然基于当前市场情况，这是正确的
    double optimized_buffer = CalculateOptimizedBuffer();
    
    if(dir_buffer[1] == 1) // 上升趋势信号 (BUY)
    {
        signal = ORDER_TYPE_BUY;
        // 止损价基于信号K线[1]的SuperTrend值
        sl_price = trend_buffer[1] - optimized_buffer;
    }
    else if(dir_buffer[1] == -1) // 下降趋势信号 (SELL)
    {
        signal = ORDER_TYPE_SELL;
        // 止损价基于信号K线[1]的SuperTrend值
        sl_price = trend_buffer[1] + optimized_buffer;
    }
    
    // 标准化止损价格并输出日志
    if(signal != ORDER_TYPE_NONE)
    {
        last_signal_time = signal_bar_time; // 关键：记录已处理的信号K线时间戳，防止重复
        sl_price = NormalizeDouble(sl_price, _Digits);
        
        // 更新详细调试信息输出，以反映新逻辑
        Print("=== 入场信号确认 (基于收盘K线) ===");
        Print("信号K线时间: ", TimeToString(signal_bar_time));
        Print("信号类型: " + (signal == ORDER_TYPE_BUY ? "BUY" : "SELL"));
        Print("SuperTrend价格 (在信号K线): " + DoubleToString(trend_buffer[1], _Digits));
        Print("动态缓冲: " + DoubleToString(optimized_buffer/_Point, 1) + "点");
        Print("计算止损价: " + DoubleToString(sl_price, _Digits));
    }

    return signal;
}
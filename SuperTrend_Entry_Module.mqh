//+------------------------------------------------------------------+
//|                                     SuperTrend_Entry_Module.mqh |
//|          SuperTrend 策略入场模块 (含智能动态止损) v3.0           |
//|     (负责: 入场信号检测、ADX过滤、动态止损价计算、市场异常检测)    |
//+------------------------------------------------------------------+
#ifdef ORDER_TYPE_NONE
   #pragma message("ORDER_TYPE_NONE OK!")
#endif

#property strict
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
    Print("=== 市场异常检测 ===");
    
    MarketAnomalyStatus status = {false, false, false, false, 1.0};
    
    // 1. 新闻时段检测（简化版，实际可接入新闻日历API）
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    
    // 重要新闻发布时间（GMT）
    if((dt.hour == 8 && dt.min >= 25 && dt.min <= 35) ||   // 欧洲CPI等
       (dt.hour == 12 && dt.min >= 25 && dt.min <= 35) ||  // 美国CPI等
       (dt.hour == 14 && dt.min >= 25 && dt.min <= 35))    // 美联储决议等
    {
        status.is_news_period = true;
        status.anomaly_multiplier *= Entry_newsBufferMultiplier;
    }
    
    // 2. 高波动期检测
    double atr_current[1], atr_history[20];
    if(CopyBuffer(atr_handle_entry, 0, 0, 1, atr_current) < 1 ||
       CopyBuffer(atr_handle_entry, 0, 0, 20, atr_history) < 20)
    {
        Print("ATR数据获取失败，跳过波动率检测");
    }
    else
    {
        double avg_atr_20 = 0;
        for(int i = 0; i < 20; i++)
            avg_atr_20 += atr_history[i];
        avg_atr_20 /= 20;
        
        if(atr_current[0] > avg_atr_20 * 1.5)
        {
            status.is_high_volatility = true;
            status.anomaly_multiplier *= Entry_highVolMultiplier;
        }
    }
    
    // 3. 区间震荡检测
    double high_20 = 0, low_20 = 0;
    int highest_idx = iHighest(_Symbol, _Period, MODE_HIGH, 20, 0);
    int lowest_idx = iLowest(_Symbol, _Period, MODE_LOW, 20, 0);
    
    if(highest_idx >= 0 && lowest_idx >= 0)
    {
        high_20 = iHigh(_Symbol, _Period, highest_idx);
        low_20 = iLow(_Symbol, _Period, lowest_idx);
        double current_price = (iClose(_Symbol, _Period, 0) + iOpen(_Symbol, _Period, 0)) / 2;
        
        if(high_20 > low_20) // 避免除零错误
        {
            double range_position = (current_price - low_20) / (high_20 - low_20);
            if(range_position > 0.3 && range_position < 0.7) // 在区间中部
            {
                status.is_range_bound = true;
                status.anomaly_multiplier *= Entry_rangeBoundMultiplier; // 区间震荡减少缓冲
            }
        }
    }
    
    // 4. 假期时段检测（简化版）
    if(dt.day_of_week == 1 && dt.hour < 3) // 周一早期（周末后）
    {
        status.is_holiday_period = true;
        status.anomaly_multiplier *= 1.2; // 假期后流动性不足
    }
    
    // 输出检测结果
    string anomaly_desc = "";
    if(status.is_news_period) anomaly_desc += "[新闻期] ";
    if(status.is_high_volatility) anomaly_desc += "[高波动] ";
    if(status.is_range_bound) anomaly_desc += "[区间震荡] ";
    if(status.is_holiday_period) anomaly_desc += "[假期后] ";
    
    Print("异常检测: " + (anomaly_desc == "" ? "正常市场" : anomaly_desc) + 
          " (异常倍数=" + DoubleToString(status.anomaly_multiplier, 2) + ")");
    
    return status;
}

//==================================================================
//  动态缓冲优化辅助函数
//==================================================================

//+------------------------------------------------------------------+
//| 获取当前交易时段乘数                                             |
//+------------------------------------------------------------------+
double GetSessionMultiplier()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour; // GMT时间
    
    // 交易时段划分（GMT时间）
    if(hour >= 0 && hour < 7)        // 亚洲时段尾部 + 欧洲前市场
        return 1.0;
    else if(hour >= 7 && hour < 15)  // 欧洲时段（重叠美国）
        return Entry_sessionMultiplier;
    else if(hour >= 15 && hour < 21) // 美国时段
        return Entry_sessionMultiplier * 1.1; // 美国时段稍高
    else                             // 亚洲时段
        return 0.9; // 亚洲时段相对平稳
}

//+------------------------------------------------------------------+
//| 获取品种波动率调整因子                                           |
//+------------------------------------------------------------------+
double GetSymbolVolatilityFactor()
{
    string symbol = _Symbol;
    
    // 主要货币对波动率分类
    if(StringFind(symbol, "JPY") >= 0)
        return Entry_volatilityFactor * 0.7; // 日元对波动较小
    else if(StringFind(symbol, "GBP") >= 0)
        return Entry_volatilityFactor * 1.2; // 英镑对波动较大
    else if(StringFind(symbol, "EUR") >= 0 || StringFind(symbol, "USD") >= 0)
        return Entry_volatilityFactor;       // 欧美标准
    else
        return Entry_volatilityFactor * 1.1; // 其他货币对稍高
}

//+------------------------------------------------------------------+
//| 计算优化的动态缓冲                                               |
//+------------------------------------------------------------------+
double CalculateOptimizedBuffer()
{
    // 基础缓冲
    double base_buffer = Entry_stopLossBufferPips * _Point;
    
    if(!Entry_useDynamicBuffer)
        return base_buffer; // 如果未启用动态优化，返回固定值
    
    // 时段调整
    double session_adjusted = base_buffer * GetSessionMultiplier();
    
    // 品种波动率调整
    double volatility_adjusted = session_adjusted * GetSymbolVolatilityFactor();
    
    // 市场异常检测调整
    double final_buffer = volatility_adjusted;
    if(Entry_useAnomalyDetection)
    {
        MarketAnomalyStatus anomaly = DetectMarketAnomalies();
        final_buffer *= anomaly.anomaly_multiplier;
    }
    
    // 边界限制
    double min_buffer = Entry_minBufferPips * _Point;
    double max_buffer = Entry_maxBufferPips * _Point;
    final_buffer = MathMax(min_buffer, MathMin(max_buffer, final_buffer));
    
    return final_buffer;
}

//==================================================================
//  模块核心功能函数
//==================================================================

//+------------------------------------------------------------------+
//| 模块初始化                                                      |
//+------------------------------------------------------------------+
bool InitEntryModule(const string symbol, const ENUM_TIMEFRAMES period)
{
    // 初始化SuperTrend指标
    st_handle_entry = iCustom(symbol, period, Entry_stIndicatorName, Entry_atrPeriod, Entry_atrMultiplier);
    if(st_handle_entry == INVALID_HANDLE)
    {
        Print("入场模块: SuperTrend指标 '", Entry_stIndicatorName, "' 加载失败. 请检查文件名和路径. Error: ", GetLastError());
        return false;
    }
    
    // 初始化ATR指标（用于动态缓冲计算）
    if(Entry_useDynamicBuffer || Entry_useAnomalyDetection)
    {
        atr_handle_entry = iATR(symbol, period, Entry_atrPeriod);
        if(atr_handle_entry == INVALID_HANDLE)
        {
            Print("入场模块: ATR指标加载失败. Error: ", GetLastError());
            return false;
        }
    }
    
    // 初始化ADX指标
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

//+------------------------------------------------------------------+
//| 主函数: 获取入场信号和优化止损价                                   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetEntrySignal(double &sl_price)
{
    sl_price = 0; // 默认无止损价

    // 1. 获取SuperTrend指标数据
    double trend_buffer[2], dir_buffer[2];
    if(CopyBuffer(st_handle_entry, 0, 0, 2, trend_buffer) < 2 || 
       CopyBuffer(st_handle_entry, 2, 0, 2, dir_buffer) < 2)
    {
        Print("入场模块: SuperTrend数据获取失败");
        return ORDER_TYPE_NONE; // 数据不足
    }

    // 2. 检测SuperTrend反转信号
    // 信号条件: 当前K线的方向(dir_buffer[0])非0，且与上一根K线(dir_buffer[1])的方向不同
    if(dir_buffer[0] == 0 || dir_buffer[0] == dir_buffer[1])
    {
        return ORDER_TYPE_NONE; // 无反转信号
    }

    // 3. ADX过滤器 (如果启用)
    if(Entry_useADXFilter)
    {
        double adx_buffer[1];
        if(CopyBuffer(adx_handle_entry, MAIN_LINE, 0, 1, adx_buffer) < 1)
        {
            Print("入场模块: ADX数据获取失败");
            return ORDER_TYPE_NONE; // ADX数据获取失败
        }
        if(adx_buffer[0] < Entry_adxMinStrength)
        {
            Print("入场模块: 信号被ADX过滤. ADX(" + DoubleToString(adx_buffer[0], 2) + 
              ") < 阈值(" + DoubleToString(Entry_adxMinStrength, 2) + ")");
            return ORDER_TYPE_NONE; // 趋势强度不足
        }
    }

    // 4. 确定信号方向并计算优化止损价
    ENUM_ORDER_TYPE signal = ORDER_TYPE_NONE;
    double optimized_buffer = CalculateOptimizedBuffer();
    
    if(dir_buffer[0] == 1) // 上升趋势信号 (BUY)
    {
        signal = ORDER_TYPE_BUY;
        sl_price = trend_buffer[0] - optimized_buffer;
    }
    else if(dir_buffer[0] == -1) // 下降趋势信号 (SELL)
    {
        signal = ORDER_TYPE_SELL;
        sl_price = trend_buffer[0] + optimized_buffer;
    }
    
    // 标准化止损价格
    if(signal != ORDER_TYPE_NONE)
    {
        sl_price = NormalizeDouble(sl_price, _Digits);
        
        // 详细调试信息输出
        Print("=== 入场信号确认 ===");
        Print("信号类型: " + (signal == ORDER_TYPE_BUY ? "BUY" : "SELL"));
        Print("SuperTrend价格: " + DoubleToString(trend_buffer[0], _Digits));
        Print("动态缓冲: " + DoubleToString(optimized_buffer/_Point, 1) + "点 (基础" + 
              DoubleToString(Entry_stopLossBufferPips, 1) + " + 时段×" + 
              DoubleToString(GetSessionMultiplier(), 2) + " + 品种×" + 
              DoubleToString(GetSymbolVolatilityFactor(), 2) + ")");
        Print("计算止损价: " + DoubleToString(sl_price, _Digits));
    }

    return signal;
}
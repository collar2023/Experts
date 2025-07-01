//+------------------------------------------------------------------+
//|                                     SuperTrend_Entry_Module.mqh |
//|          SuperTrend 策略入场模块 (含智能动态止损) v3.0           |
//|     (负责: 入场信号检测、ADX过滤、动态止损价计算、市场异常检测)    |
//|     【优化】: 将所有 Print() 函数替换为通过 g_Logger 输出。       |
//+------------------------------------------------------------------+
#ifdef ORDER_TYPE_NONE
   #pragma message("ORDER_TYPE_NONE OK!")
#endif

#property strict
#include "Common_Defines.mqh"

//==================================================================
//  全局变量的声明 (假定 g_Logger 在主文件中已初始化)
//==================================================================
// extern CLogModule* g_Logger; // 需要在主文件中定义 g_Logger

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
// 注意：这些输入参数应该与主EA文件中的设置保持一致，或者在此模块中作为独立的输入参数定义
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

// 假定 g_Logger 是在主EA文件中全局初始化的
extern CLogModule* g_Logger; // 声明外部全局变量，以便使用g_Logger

//==================================================================
//  市场异常检测函数
//==================================================================

//+------------------------------------------------------------------+
//| 市场异常检测主函数                                               |
//+------------------------------------------------------------------+
MarketAnomalyStatus DetectMarketAnomalies()
{
    // [日志增强] - 使用g_Logger输出
    if(g_Logger != NULL && Entry_useAnomalyDetection) g_Logger.WriteDebug("=== 市场异常检测 ===");

    MarketAnomalyStatus status = {false, false, false, false, 1.0};

    // 1. 新闻时段检测（简化版，实际可接入新闻日历API）
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // 重要新闻发布时间（GMT） - 假设这些时间点为高风险时段
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
        if(g_Logger != NULL && Entry_useAnomalyDetection) g_Logger.WriteWarning("ATR数据获取失败，跳过波动率检测");
    }
    else
    {
        double avg_atr_20 = 0;
        for(int i = 0; i < 20; i++)
            avg_atr_20 += atr_history[i];
        avg_atr_20 /= 20;

        // 检查当前ATR是否显著高于最近20根K线的平均ATR
        if(atr_current[0] > avg_atr_20 * 1.5)
        {
            status.is_high_volatility = true;
            status.anomaly_multiplier *= Entry_highVolMultiplier;
        }
    }

    // 3. 区间震荡检测
    double high_20 = 0, low_20 = 0;
    // 找到最近20根K线中的最高价和最低价的索引
    int highest_idx = iHighest(_Symbol, _Period, MODE_HIGH, 20, 0);
    int lowest_idx = iLowest(_Symbol, _Period, MODE_LOW, 20, 0);

    if(highest_idx >= 0 && lowest_idx >= 0)
    {
        high_20 = iHigh(_Symbol, _Period, highest_idx);
        low_20 = iLow(_Symbol, _Period, lowest_idx);
        // 使用当前K线的开盘价和收盘价的平均值作为参考价格，或简单使用收盘价
        double current_price = iClose(_Symbol, _Period, 0);

        if(high_20 > low_20) // 避免除零错误
        {
            // 计算当前价格在过去20根K线价格区间中的位置比例
            double range_position = (current_price - low_20) / (high_20 - low_20);
            // 如果价格处于区间的中部区域 (例如30%到70%之间)，则认为是区间震荡
            if(range_position > 0.3 && range_position < 0.7)
            {
                status.is_range_bound = true;
                status.anomaly_multiplier *= Entry_rangeBoundMultiplier; // 区间震荡时减小缓冲
            }
        }
    }

    // 4. 假期时段检测（简化版）
    // 检查是否是周一开盘早期，可能面临假期后的低流动性
    if(dt.day_of_week == 1 && dt.hour < 3) // GMT时间
    {
        status.is_holiday_period = true;
        status.anomaly_multiplier *= 1.2; // 假期后流动性可能较低，适当放大缓冲
    }

    // 输出检测结果描述
    string anomaly_desc = "";
    if(status.is_news_period) anomaly_desc += "[新闻期] ";
    if(status.is_high_volatility) anomaly_desc += "[高波动] ";
    if(status.is_range_bound) anomaly_desc += "[区间震荡] ";
    if(status.is_holiday_period) anomaly_desc += "[假期后] ";

    // [日志增强] - 输出异常检测结果
    if(g_Logger != NULL && Entry_useAnomalyDetection)
        g_Logger.WriteDebug("异常检测: " + (anomaly_desc == "" ? "正常市场" : anomaly_desc) +
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

    // 交易时段划分（GMT时间） - 根据经验值设定
    if(hour >= 0 && hour < 7)        // 亚洲时段尾部 + 欧洲前市场
        return 1.0;
    else if(hour >= 7 && hour < 15)  // 欧洲时段（重叠美国）
        return Entry_sessionMultiplier;
    else if(hour >= 15 && hour < 21) // 美国时段
        return Entry_sessionMultiplier * 1.1; // 美国时段流动性可能更高
    else                             // 亚洲时段
        return 0.9; // 亚洲时段流动性相对较低
}

//+------------------------------------------------------------------+
//| 获取品种波动率调整因子                                           |
//+------------------------------------------------------------------+
double GetSymbolVolatilityFactor()
{
    string symbol = _Symbol;

    // 主要货币对波动率分类 (根据历史观察设定)
    if(StringFind(symbol, "JPY") >= 0) // 日元货币对通常波动性较低
        return Entry_volatilityFactor * 0.7;
    else if(StringFind(symbol, "GBP") >= 0) // 英镑货币对通常波动性较高
        return Entry_volatilityFactor * 1.2;
    else if(StringFind(symbol, "EUR") >= 0 || StringFind(symbol, "USD") >= 0) // 欧美货币对波动性标准
        return Entry_volatilityFactor;
    else // 其他货币对或交叉盘，波动性可能较高
        return Entry_volatilityFactor * 1.1;
}

//+------------------------------------------------------------------+
//| 计算优化的动态止损缓冲                                             |
//+------------------------------------------------------------------+
double CalculateOptimizedBuffer()
{
    // 基础缓冲（点数）
    double base_buffer_points = Entry_stopLossBufferPips;

    // 如果未启用动态缓冲，则直接返回基础缓冲值
    if(!Entry_useDynamicBuffer)
        return base_buffer_points * _Point;

    // 1. 获取ATR值（用于计算缓冲大小的基础值）
    double atr[1];
    if(CopyBuffer(atr_handle_entry, 0, 0, 1, atr) < 1 || !MathIsValidNumber(atr[0]) || atr[0] <= 0)
    {
        if(g_Logger != NULL) g_Logger.WriteWarning("[CalculateOptimizedBuffer] ATR值无效，使用基础缓冲.");
        return base_buffer_points * _Point; // ATR无效时，返回基础缓冲
    }
    double current_atr_buffer = atr[0]; // 当前ATR值

    // 2. 基于ATR计算基础缓冲的实际价格距离
    double base_buffer_price = current_atr_buffer * base_buffer_points / Entry_atrPeriod; // 假设ATR period 影响 ATR 值，这里简单粗暴处理

    // 3. 应用各种调整因子
    double final_buffer_price = base_buffer_price;

    // 时段调整
    final_buffer_price *= GetSessionMultiplier();

    // 品种波动率调整
    final_buffer_price *= GetSymbolVolatilityFactor();

    // 市场异常检测调整
    if(Entry_useAnomalyDetection)
    {
        MarketAnomalyStatus anomaly = DetectMarketAnomalies();
        final_buffer_price *= anomaly.anomaly_multiplier;
    }

    // 4. 限制最终缓冲在最小和最大值之间
    double min_buffer_price = Entry_minBufferPips * _Point;
    double max_buffer_price = Entry_maxBufferPips * _Point;
    final_buffer_price = MathMax(min_buffer_price, MathMin(max_buffer_price, final_buffer_price));

    // 返回最终计算出的缓冲价格距离
    return final_buffer_price;
}

//==================================================================
//  模块核心功能函数
//==================================================================

//+------------------------------------------------------------------+
//| 模块初始化                                                      |
//+------------------------------------------------------------------+
bool InitEntryModule(const string symbol, const ENUM_TIMEFRAMES period)
{
    // 初始化SuperTrend指标句柄
    st_handle_entry = iCustom(symbol, period, Entry_stIndicatorName, Entry_atrPeriod, Entry_atrMultiplier);
    if(st_handle_entry == INVALID_HANDLE)
    {
        // [日志增强] - 使用g_Logger输出错误信息
        if(g_Logger != NULL)
            g_Logger.WriteError(StringFormat("SuperTrend指标 '%s' 加载失败. 请检查文件名和路径. Error: %d", Entry_stIndicatorName, GetLastError()));
        else
            Print("入场模块: SuperTrend指标 '", Entry_stIndicatorName, "' 加载失败. Error: ", GetLastError());
        return false;
    }

    // 初始化ATR指标（如果启用了动态缓冲或异常检测）
    if(Entry_useDynamicBuffer || Entry_useAnomalyDetection)
    {
        atr_handle_entry = iATR(symbol, period, Entry_atrPeriod);
        if(atr_handle_entry == INVALID_HANDLE)
        {
            if(g_Logger != NULL) g_Logger.WriteError(StringFormat("ATR指标加载失败. Error: %d", GetLastError()));
            else Print("入场模块: ATR指标加载失败. Error: ", GetLastError());
            return false;
        }
    }

    // 初始化ADX指标（如果启用了ADX过滤）
    if(Entry_useADXFilter)
    {
        adx_handle_entry = iADX(symbol, period, Entry_adxPeriod);
        if(adx_handle_entry == INVALID_HANDLE)
        {
            if(g_Logger != NULL) g_Logger.WriteError(StringFormat("ADX指标加载失败. Error: %d", GetLastError()));
            else Print("入场模块: ADX指标加载失败. Error: ", GetLastError());
            return false;
        }
    }

    // [日志增强] - 输出模块初始化状态
    if(g_Logger != NULL)
    {
        g_Logger.WriteInfo("SuperTrend 智能入场模块初始化成功.");
        g_Logger.WriteInfo(StringFormat("动态缓冲: %s", Entry_useDynamicBuffer ? "启用" : "禁用"));
        g_Logger.WriteInfo(StringFormat("异常检测: %s", Entry_useAnomalyDetection ? "启用" : "禁用"));
        g_Logger.WriteInfo(StringFormat("ADX过滤: %s", Entry_useADXFilter ? "启用" : "禁用"));
    }

    return true;
}

//+------------------------------------------------------------------+
//| 模块反初始化                                                    |
//+------------------------------------------------------------------+
void DeinitEntryModule()
{
    // 释放所有指标句柄
    if(st_handle_entry != INVALID_HANDLE) IndicatorRelease(st_handle_entry);
    if(adx_handle_entry != INVALID_HANDLE) IndicatorRelease(adx_handle_entry);
    if(atr_handle_entry != INVALID_HANDLE) IndicatorRelease(atr_handle_entry);

    // [日志增强] - 输出模块清理信息
    if(g_Logger != NULL)
        g_Logger.WriteInfo("SuperTrend 入场模块已清理.");
    else
        Print("SuperTrend 入场模块已清理.");
}

//+------------------------------------------------------------------+
//| 主函数: 获取入场信号和优化止损价                                   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE GetEntrySignal(double &sl_price)
{
    sl_price = 0; // 默认无止损价

    // 1. 获取SuperTrend指标数据
    double trend_buffer[2], dir_buffer[2]; // trend_buffer[0]是当前K线，trend_buffer[1]是前一根K线
    if(CopyBuffer(st_handle_entry, 0, 0, 2, trend_buffer) < 2 || // 获取SuperTrend值
       CopyBuffer(st_handle_entry, 2, 0, 2, dir_buffer) < 2)   // 获取SuperTrend方向 (1:上升, -1:下降, 0:无)
    {
        if(g_Logger != NULL) g_Logger.WriteError("SuperTrend数据获取失败");
        return ORDER_TYPE_NONE; // 数据不足
    }

    // 2. 检测SuperTrend反转信号
    // 条件: 当前K线的方向不为0，且与上一根K线方向不同
    if(dir_buffer[0] == 0 || dir_buffer[0] == dir_buffer[1])
    {
        return ORDER_TYPE_NONE; // 无反转信号
    }

    // 3. ADX过滤器 (如果启用)
    if(Entry_useADXFilter)
    {
        double adx_buffer[1];
        if(CopyBuffer(adx_handle_entry, MAIN_LINE, 0, 1, adx_buffer) < 1) // 获取ADX主线值
        {
            if(g_Logger != NULL) g_Logger.WriteError("ADX数据获取失败");
            return ORDER_TYPE_NONE; // ADX数据获取失败
        }
        // 检查ADX强度是否低于设定的阈值
        if(adx_buffer[0] < Entry_adxMinStrength)
        {
            // [日志增强] - 说明被ADX过滤
            if(g_Logger != NULL)
                g_Logger.WriteInfo(StringFormat("信号被ADX过滤. ADX(%.2f) < 阈值(%.2f)", adx_buffer[0], Entry_adxMinStrength));
            return ORDER_TYPE_NONE; // 趋势强度不足
        }
    }

    // 4. 确定信号方向并计算优化止损价
    ENUM_ORDER_TYPE signal = ORDER_TYPE_NONE;
    double optimized_buffer_price = CalculateOptimizedBuffer(); // 计算最终的缓冲价格距离

    // --- 根据SuperTrend方向确定信号和止损价 ---
    if(dir_buffer[0] == 1) // 上升趋势信号 ( BUY )
    {
        signal = ORDER_TYPE_BUY;
        // 止损价 = SuperTrend值 - 动态缓冲距离
        sl_price = trend_buffer[0] - optimized_buffer_price;
    }
    else if(dir_buffer[0] == -1) // 下降趋势信号 ( SELL )
    {
        signal = ORDER_TYPE_SELL;
        // 止损价 = SuperTrend值 + 动态缓冲距离
        sl_price = trend_buffer[0] + optimized_buffer_price;
    }

    // 5. 对计算出的止损价进行标准化和详细日志输出
    if(signal != ORDER_TYPE_NONE)
    {
        // 标准化止损价格 (由NormalizePrice处理，内部已含防护)
        sl_price = NormalizeDouble(sl_price, _Digits);

        // [日志增强] - 提供详细的入场信号确认信息
        if(g_Logger != NULL)
        {
            g_Logger.WriteInfo("=== 入场信号确认 ===");
            g_Logger.WriteInfo(StringFormat("信号类型: %s", EnumToString(signal)));
            g_Logger.WriteInfo(StringFormat("SuperTrend价格: %.5f", trend_buffer[0]));
            // 缓冲计算的详细说明
            string buffer_details = StringFormat("动态缓冲: %.1f 点 (基础%.1f + 时段×%.2f + 品种×%.2f",
                                                optimized_buffer_price / _Point,
                                                Entry_stopLossBufferPips,
                                                GetSessionMultiplier(),
                                                GetSymbolVolatilityFactor());
            if(Entry_useAnomalyDetection) buffer_details += " + 异常×..."; // 简单标记异常调整
            buffer_details += ")";
            g_Logger.WriteInfo(buffer_details);
            g_Logger.WriteInfo(StringFormat("计算止损价: %.5f", sl_price));
        }
    }

    return signal;
}
//==================================================================
//  辅助函数：将枚举类型转换为字符串，方便日志输出
//==================================================================
string EnumToString(ENUM_ORDER_TYPE type)
{
    switch(type)
    {
        case ORDER_TYPE_BUY: return "BUY";
        case ORDER_TYPE_SELL: return "SELL";
        case ORDER_TYPE_NONE: return "NONE";
        default: return "UNKNOWN";
    }
}
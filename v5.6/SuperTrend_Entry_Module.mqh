//+------------------------------------------------------------------+
//|                                     SuperTrend_Entry_Module.mqh |
//|          SuperTrend 策略入场模块 (含智能动态止损) v3.5           |
//|    (基于你提供的v3.4，修复ATR越界和止损合法性校验)              |
//+------------------------------------------------------------------+

#property strict

//--- 简易平均值工具
double ArrayAverage(const double &src[], int offset, int count)
{
   int total = ArraySize(src);
   if(offset < 0 || count <= 0 || offset + count > total) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < count; i++) sum += src[offset + i];
   return sum / count;
}

#include "Common_Defines.mqh"

//==================================================================
//  结构体定义
//==================================================================
struct MarketAnomalyStatus
{
   bool   is_news_period;
   bool   is_high_volatility;
   bool   is_range_bound;
   bool   is_holiday_period;
   double anomaly_multiplier;
};

//==================================================================
//  输入参数
//==================================================================
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

//==================================================================
//  全局变量
//==================================================================
int st_handle_entry  = INVALID_HANDLE;
int adx_handle_entry = INVALID_HANDLE;
int atr_handle_entry = INVALID_HANDLE;

//==================================================================
//  市场异常检测函数 (v3.5 修复ATR越界 + 添加安全校验)
//==================================================================
MarketAnomalyStatus DetectMarketAnomalies()
{
    MarketAnomalyStatus status = {false, false, false, false, 1.0};
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    if(Entry_useAnomalyDetection)
    {
        if((dt.hour == 8 && dt.min >= 25 && dt.min <= 35) ||
           (dt.hour == 12 && dt.min >= 25 && dt.min <= 35) ||
           (dt.hour == 14 && dt.min >= 25 && dt.min <= 35))
        {
            status.is_news_period = true;
            status.anomaly_multiplier *= Entry_newsBufferMultiplier;
        }

        if(atr_handle_entry != INVALID_HANDLE)
        {
            double atrCur[1];
            if(CopyBuffer(atr_handle_entry, 0, 0, 1, atrCur) == 1 &&
               atrCur[0] > 0 && atrCur[0] < 1e6)
            {
                double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                if(refPrice > 0 && atrCur[0] < refPrice)
                {
                    double atrHist[20];
                    if(CopyBuffer(atr_handle_entry, 0, 1, 20, atrHist) == 20)
                    {
                        bool safe = true;
                        for(int i = 0; i < 20; i++)
                        {
                            if(atrHist[i] <= 0 || atrHist[i] >= refPrice || atrHist[i] > 1e6)
                            {
                                safe = false;
                                break;
                            }
                        }
                        if(safe)
                        {
                            double avg = ArrayAverage(atrHist, 0, 20);
                            if(avg > 0 && atrCur[0] > avg * 1.5)
                            {
                                status.is_high_volatility = true;
                                status.anomaly_multiplier *= Entry_highVolMultiplier;
                            }
                        }
                    }
                }
            }
        }

        double high_20 = iHigh(_Symbol, _Period, iHighest(_Symbol, _Period, MODE_HIGH, 20, 1));
        double low_20 = iLow(_Symbol, _Period, iLowest(_Symbol, _Period, MODE_LOW, 20, 1));
        if(high_20 > low_20)
        {
            double current = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double range = (current - low_20) / (high_20 - low_20);
            if(range > 0.3 && range < 0.7)
            {
                status.is_range_bound = true;
                status.anomaly_multiplier *= Entry_rangeBoundMultiplier;
            }
        }

        if(dt.day_of_week == 1 && dt.hour < 3)
        {
            status.is_holiday_period = true;
            status.anomaly_multiplier *= 1.2;
        }
    }
    return status;
}

//==================================================================
//  动态缓冲优化辅助函数 (无修改)
//==================================================================
double GetSessionMultiplier()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;
    if(hour < 7) return 1.0;
    if(hour < 15) return Entry_sessionMultiplier;
    if(hour < 21) return Entry_sessionMultiplier * 1.1;
    return 0.9;
}

double GetSymbolVolatilityFactor()
{
    string symbol = _Symbol;
    if(StringFind(symbol, "JPY") >= 0) return Entry_volatilityFactor * 0.7;
    if(StringFind(symbol, "GBP") >= 0) return Entry_volatilityFactor * 1.2;
    if(StringFind(symbol, "EUR") >= 0 || StringFind(symbol, "USD") >= 0) return Entry_volatilityFactor;
    return Entry_volatilityFactor * 1.1;
}

double CalculateOptimizedBuffer()
{
    double base = Entry_stopLossBufferPips * _Point;
    if(!Entry_useDynamicBuffer) return base;
    double adj1 = base * GetSessionMultiplier();
    double adj2 = adj1 * GetSymbolVolatilityFactor();
    double finalBuf = adj2 * DetectMarketAnomalies().anomaly_multiplier;
    return MathMax(Entry_minBufferPips * _Point, MathMin(Entry_maxBufferPips * _Point, finalBuf));
}

//==================================================================
//  初始化与清理
//==================================================================
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

    Print("SuperTrend 智能入场模块 v3.5 初始化成功 (ATR越界及止损合法性增强).");
    Print("动态缓冲: ", Entry_useDynamicBuffer ? "启用" : "禁用");
    Print("异常检测: ", Entry_useAnomalyDetection ? "启用" : "禁用");
    Print("ADX过滤: ", Entry_useADXFilter ? "启用" : "禁用");
    return true;
}

void DeinitEntryModule()
{
    if(st_handle_entry != INVALID_HANDLE) IndicatorRelease(st_handle_entry);
    if(adx_handle_entry != INVALID_HANDLE) IndicatorRelease(adx_handle_entry);
    if(atr_handle_entry != INVALID_HANDLE) IndicatorRelease(atr_handle_entry);
    Print("SuperTrend 入场模块已清理.");
}

//==================================================================
//  信号主函数 (新增止损合法性校验，避免开仓时止损无效)
//==================================================================
ENUM_ORDER_TYPE GetEntrySignal(double &sl_price)
{
    sl_price = 0;
    double trend[3], dir[3];
    if(CopyBuffer(st_handle_entry, 0, 0, 3, trend) < 3 ||
       CopyBuffer(st_handle_entry, 2, 0, 3, dir) < 3)
       return ORDER_TYPE_NONE;

    if(dir[1] == 0 || dir[1] == dir[2]) return ORDER_TYPE_NONE;
    static datetime last_time = 0;
    datetime bar_time = (datetime)iTime(_Symbol, _Period, 1);
    if(bar_time <= last_time) return ORDER_TYPE_NONE;

    if(Entry_useADXFilter)
    {
        double adx[2];
        if(CopyBuffer(adx_handle_entry, MAIN_LINE, 0, 2, adx) < 2)
        {
            Print("入场模块: ADX数据获取失败");
            return ORDER_TYPE_NONE;
        }
        if(adx[1] < Entry_adxMinStrength)
        {
            Print("入场模块: 信号在K线 [", TimeToString(bar_time), "] 被ADX过滤. ADX(", DoubleToString(adx[1], 2), ") < 阈值(", DoubleToString(Entry_adxMinStrength, 2), ")");
            last_time = bar_time;
            return ORDER_TYPE_NONE;
        }
    }

    ENUM_ORDER_TYPE signal = ORDER_TYPE_NONE;
    double buffer = CalculateOptimizedBuffer();

    if(dir[1] == 1) // BUY
    {
        double slCandidate = NormalizeDouble(trend[1] - buffer, _Digits);
        // 检查止损合法性（买单止损必须低于买入价且满足最小距离）
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double minStopDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
        if(slCandidate < ask - minStopDist)
        {
            signal = ORDER_TYPE_BUY;
            sl_price = slCandidate;
        }
        else
        {
            Print("[入场模块] 买单止损价格无效，忽略买入信号。");
        }
    }
    else if(dir[1] == -1) // SELL
    {
        double slCandidate = NormalizeDouble(trend[1] + buffer, _Digits);
        // 卖单止损必须高于卖出价且满足最小距离
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double minStopDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
        if(slCandidate > bid + minStopDist)
        {
            signal = ORDER_TYPE_SELL;
            sl_price = slCandidate;
        }
        else
        {
            Print("[入场模块] 卖单止损价格无效，忽略卖出信号。");
        }
    }

    if(signal != ORDER_TYPE_NONE)
    {
        last_time = bar_time;
        Print("=== 入场信号确认 (基于收盘K线) ===");
        Print("信号K线时间: ", TimeToString(bar_time));
        Print("信号类型: ", signal == ORDER_TYPE_BUY ? "BUY" : "SELL");
        Print("SuperTrend价格: ", DoubleToString(trend[1], _Digits));
        Print("动态缓冲: ", DoubleToString(buffer/_Point, 1), "点");
        Print("止损价: ", DoubleToString(sl_price, _Digits));
    }

    return signal;
}

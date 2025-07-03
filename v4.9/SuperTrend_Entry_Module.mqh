//+------------------------------------------------------------------+
//|                                     SuperTrend_Entry_Module.mqh |
//|          SuperTrend 入场模块 v4.9 (编译版)                 |
//+------------------------------------------------------------------+


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
//  模块内部全局变量
//==================================================================
static SEntryInputs g_module_entryInputs; // ★ 用于存储传入的参数
static int st_handle_entry  = INVALID_HANDLE;
static int adx_handle_entry = INVALID_HANDLE;
static int atr_handle_entry = INVALID_HANDLE;
extern CLogModule* g_Logger; // ★ 声明外部全局变量

//--- 简易平均值工具
double ArrayAverage(const double &src[], int offset, int count)
{
   int total = ArraySize(src);
   if(offset < 0 || count <= 0 || offset + count > total) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < count; i++) sum += src[offset + i];
   return sum / count;
}

//==================================================================
//  市场异常检测函数
//==================================================================
MarketAnomalyStatus DetectMarketAnomalies()
{
    MarketAnomalyStatus status = {false, false, false, false, 1.0};
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    if(g_module_entryInputs.useAnomalyDetection)
    {
        if((dt.hour == 8 && dt.min >= 25 && dt.min <= 35) ||
           (dt.hour == 12 && dt.min >= 25 && dt.min <= 35) ||
           (dt.hour == 14 && dt.min >= 25 && dt.min <= 35))
        {
            status.is_news_period = true;
            status.anomaly_multiplier *= g_module_entryInputs.newsBufferMultiplier;
        }

        if(atr_handle_entry != INVALID_HANDLE)
        {
            double atrCur[1];
            if(CopyBuffer(atr_handle_entry, 0, 0, 1, atrCur) == 1 && atrCur[0] > 0 && atrCur[0] < 1e6)
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
                                status.anomaly_multiplier *= g_module_entryInputs.highVolMultiplier;
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
                status.anomaly_multiplier *= g_module_entryInputs.rangeBoundMultiplier;
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
//  动态缓冲优化辅助函数
//==================================================================
double GetSessionMultiplier()
{
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;
    if(hour < 7) return 1.0;
    if(hour < 15) return g_module_entryInputs.sessionMultiplier;
    if(hour < 21) return g_module_entryInputs.sessionMultiplier * 1.1;
    return 0.9;
}

double GetSymbolVolatilityFactor()
{
    string symbol = _Symbol;
    if(StringFind(symbol, "JPY") >= 0) return g_module_entryInputs.volatilityFactor * 0.7;
    if(StringFind(symbol, "GBP") >= 0) return g_module_entryInputs.volatilityFactor * 1.2;
    if(StringFind(symbol, "EUR") >= 0 || StringFind(symbol, "USD") >= 0) return g_module_entryInputs.volatilityFactor;
    return g_module_entryInputs.volatilityFactor * 1.1;
}

double CalculateOptimizedBuffer()
{
    double base = g_module_entryInputs.stopLossBufferPips * _Point;
    if(!g_module_entryInputs.useDynamicBuffer) return base;
    double adj1 = base * GetSessionMultiplier();
    double adj2 = adj1 * GetSymbolVolatilityFactor();
    double finalBuf = adj2 * DetectMarketAnomalies().anomaly_multiplier;
    return MathMax(g_module_entryInputs.minBufferPips * _Point, MathMin(g_module_entryInputs.maxBufferPips * _Point, finalBuf));
}

//==================================================================
//  初始化与清理
//==================================================================
bool InitEntryModule(const string symbol, const ENUM_TIMEFRAMES period, const SEntryInputs &inputs)
{
    g_module_entryInputs = inputs; // ★ 保存传入的参数

    st_handle_entry = iCustom(symbol, period, g_module_entryInputs.stIndicatorName, g_module_entryInputs.atrPeriod, g_module_entryInputs.atrMultiplier);
    if(st_handle_entry == INVALID_HANDLE)
    {
        if(g_Logger) g_Logger.WriteError(StringFormat("入场模块: SuperTrend指标 '%s' 加载失败. Error: %d", g_module_entryInputs.stIndicatorName, GetLastError()));
        return false;
    }

    if(g_module_entryInputs.useDynamicBuffer || g_module_entryInputs.useAnomalyDetection)
    {
        atr_handle_entry = iATR(symbol, period, g_module_entryInputs.atrPeriod);
        if(atr_handle_entry == INVALID_HANDLE)
        {
            if(g_Logger) g_Logger.WriteError(StringFormat("入场模块: ATR指标加载失败. Error: %d", GetLastError()));
            return false;
        }
    }

    if(g_module_entryInputs.useADXFilter)
    {
        adx_handle_entry = iADX(symbol, period, g_module_entryInputs.adxPeriod);
        if(adx_handle_entry == INVALID_HANDLE)
        {
            if(g_Logger) g_Logger.WriteError(StringFormat("入场模块: ADX指标加载失败. Error: %d", GetLastError()));
            return false;
        }
    }
    
    if(g_Logger)
    {
       g_Logger.WriteInfo("SuperTrend 智能入场模块 v6.0 初始化成功");
       g_Logger.WriteInfo("-> 动态缓冲: " + (g_module_entryInputs.useDynamicBuffer ? "启用" : "禁用"));
       g_Logger.WriteInfo("-> 异常检测: " + (g_module_entryInputs.useAnomalyDetection ? "启用" : "禁用"));
       g_Logger.WriteInfo("-> ADX过滤: " + (g_module_entryInputs.useADXFilter ? "启用" : "禁用"));
    }
    return true;
}

void DeinitEntryModule()
{
    if(st_handle_entry != INVALID_HANDLE) IndicatorRelease(st_handle_entry);
    if(adx_handle_entry != INVALID_HANDLE) IndicatorRelease(adx_handle_entry);
    if(atr_handle_entry != INVALID_HANDLE) IndicatorRelease(atr_handle_entry);
    if(g_Logger) g_Logger.WriteInfo("SuperTrend 入场模块已清理.");
}

//==================================================================
//  信号主函数
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

    if(g_module_entryInputs.useADXFilter)
    {
        double adx[2];
        if(CopyBuffer(adx_handle_entry, MAIN_LINE, 0, 2, adx) < 2)
        {
            if(g_Logger) g_Logger.WriteWarning("入场模块: ADX数据获取失败");
            return ORDER_TYPE_NONE;
        }
        if(adx[1] < g_module_entryInputs.adxMinStrength)
        {
            last_time = bar_time;
            return ORDER_TYPE_NONE;
        }
    }

    ENUM_ORDER_TYPE signal = ORDER_TYPE_NONE;
    double buffer = CalculateOptimizedBuffer();

    if(dir[1] == 1) // BUY
    {
        double slCandidate = NormalizeDouble(trend[1] - buffer, _Digits);
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double minStopDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
        if(slCandidate < ask - minStopDist)
        {
            signal = ORDER_TYPE_BUY;
            sl_price = slCandidate;
        }
        else
        {
            if(g_Logger) g_Logger.WriteWarning("[入场模块] 买单止损价格无效，忽略买入信号。");
        }
    }
    else if(dir[1] == -1) // SELL
    {
        double slCandidate = NormalizeDouble(trend[1] + buffer, _Digits);
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double minStopDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
        if(slCandidate > bid + minStopDist)
        {
            signal = ORDER_TYPE_SELL;
            sl_price = slCandidate;
        }
        else
        {
            if(g_Logger) g_Logger.WriteWarning("[入场模块] 卖单止损价格无效，忽略卖出信号。");
        }
    }

    if(signal != ORDER_TYPE_NONE)
    {
        last_time = bar_time;
        if(g_Logger)
        {
            g_Logger.LogEntrySignal(signal == ORDER_TYPE_BUY ? "BUY" : "SELL", 
                                   (signal == ORDER_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID)),
                                   sl_price, 0);
        }
    }

    return signal;
}
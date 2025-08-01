//+------------------------------------------------------------------+
//|                                                      QQE-Mod.mq5 |
//|                        Copyright 2023, 专业EA定制服务              |
//|                         Translated from TradingView Pine Script  |
//+------------------------------------------------------------------+
#property copyright "专业EA定制服务"
#property link      "https://www.mql5.com"
#property version   "1.10" // [功能升级] 增加颜色和直方图缓冲区供EA调用
#property description "QQE-Mod 指标，从PineScript移植。提供快线/慢线/颜色/直方图数据。"

#property indicator_separate_window
#property indicator_plots   2 // 视觉上只绘制快慢线
#property indicator_buffers 4 // 但有4个数据缓冲区

//--- Plot 1: Fast Line
#property indicator_label1  "QQE Fast"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1

//--- Plot 2: Slow Line
#property indicator_label2  "QQE Slow"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDeepPink
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1

//--- 水平线 (50轴)
#property indicator_level1  50.0
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT
#property indicator_levelwidth 1

//--- 输入参数 (Inputs)
input int               RSI_Period      = 14;           // RSI 周期
input int               RSI_Smoothing   = 5;            // RSI 平滑周期
input double            QQE_Factor      = 4.236;        // QQE 因子 (乘数)
input ENUM_APPLIED_PRICE RSI_Source      = PRICE_CLOSE;  // RSI 源数据

//--- 指标缓冲区 (Buffers)
double QQEFastBuffer[];
double QQESlowBuffer[];
double HistogramBuffer[]; // 直方图高度 (快线 - 50)
double ColorBuffer[];     // 颜色状态: 1(亮绿), 2(暗绿), -1(亮红), -2(暗红)
double rsiBuffer[];

//--- 内部变量
int rsi_handle;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- 指标缓冲区映射
   SetIndexBuffer(0, QQEFastBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, QQESlowBuffer, INDICATOR_DATA);
   // 以下缓冲区仅供EA读取，不在图表上绘制
   SetIndexBuffer(2, HistogramBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, ColorBuffer, INDICATOR_CALCULATIONS);
   
   //--- 为RSI计算分配缓冲区
   SetIndexBuffer(4, rsiBuffer, INDICATOR_CALCULATIONS);

   //--- 设置绘图标签
   PlotIndexSetString(0, PLOT_LABEL, "QQE Fast (" + (string)RSI_Period + ")");
   PlotIndexSetString(1, PLOT_LABEL, "QQE Slow");
   
   //--- 设置空值
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   //--- 获取RSI指标句柄
   rsi_handle = iRSI(NULL, 0, RSI_Period, RSI_Source);
   if(rsi_handle == INVALID_HANDLE)
     {
      Print("Error getting RSI handle");
      return(INIT_FAILED);
     }

   IndicatorSetInteger(INDICATOR_DIGITS, 4);
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Custom indicator calculation function                            |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   int start = prev_calculated > 0 ? prev_calculated - 1 : 0;

   if(CopyBuffer(rsi_handle, 0, 0, rates_total, rsiBuffer) <= 0) return 0;

   double qqe_fast_line_temp[];
   ArrayResize(qqe_fast_line_temp, rates_total);
   if(ExponentialMAOnBuffer(rates_total, start, 0, RSI_Smoothing, rsiBuffer, qqe_fast_line_temp) < 0) return 0;
   ArrayCopy(QQEFastBuffer, qqe_fast_line_temp, 0, 0, rates_total);
   
   int wilders_period = RSI_Period * 2 - 1;
   double atr_rsi[], ma_atr_rsi[];
   ArrayResize(atr_rsi, rates_total);
   ArrayResize(ma_atr_rsi, rates_total);
   
   for(int i = 1; i < rates_total; i++)
   {
       atr_rsi[i] = MathAbs(QQEFastBuffer[i] - QQEFastBuffer[i-1]);
   }
   
   if(ExponentialMAOnBuffer(rates_total, start, 0, wilders_period, atr_rsi, ma_atr_rsi) < 0) return 0;

   //--- 计算慢线, 直方图和颜色状态
   for(int i = start; i < rates_total; i++)
   {
       if(i == 0)
       {
           QQESlowBuffer[i] = EMPTY_VALUE;
           HistogramBuffer[i] = EMPTY_VALUE;
           ColorBuffer[i] = 0;
           continue;
       }

       double dar = ma_atr_rsi[i] * QQE_Factor;
       double long_band = QQEFastBuffer[i] - dar;
       double short_band = QQEFastBuffer[i] + dar;
       double prev_qqe_slow_line = QQESlowBuffer[i-1];
       
       if(QQEFastBuffer[i] > prev_qqe_slow_line)
         {
            if(QQEFastBuffer[i-1] > prev_qqe_slow_line)
                QQESlowBuffer[i] = MathMax(prev_qqe_slow_line, long_band);
            else
                QQESlowBuffer[i] = long_band;
         }
       else if(QQEFastBuffer[i] < prev_qqe_slow_line)
         {
            if(QQEFastBuffer[i-1] < prev_qqe_slow_line)
                QQESlowBuffer[i] = MathMin(prev_qqe_slow_line, short_band);
            else
                QQESlowBuffer[i] = short_band;
         }
       else
         {
            QQESlowBuffer[i] = prev_qqe_slow_line;
         }
         
       // 计算直方图
       HistogramBuffer[i] = QQEFastBuffer[i] - 50.0;
       
       // 计算颜色状态
       ColorBuffer[i] = 0;
       if(QQEFastBuffer[i] > QQESlowBuffer[i]) // 多头趋势
         {
          if(QQEFastBuffer[i] > QQEFastBuffer[i-1]) // 动量加速
            {
             if(QQEFastBuffer[i] > 50) ColorBuffer[i] = 1; // 亮绿
             else ColorBuffer[i] = 2; // 暗绿 (50以下)
            }
          else // 动量减速
            {
             ColorBuffer[i] = 2; // 暗绿
            }
         }
       else // 空头趋势
         {
          if(QQEFastBuffer[i] < QQEFastBuffer[i-1]) // 动量加速
            {
             if(QQEFastBuffer[i] < 50) ColorBuffer[i] = -1; // 亮红
             else ColorBuffer[i] = -2; // 暗红 (50以上)
            }
          else // 动量减速
            {
             ColorBuffer[i] = -2; // 暗红
            }
         }
   }
   
   return(rates_total);
  }

//+------------------------------------------------------------------+
int ExponentialMAOnBuffer(int rates_total, int begin, int start, int period, const double &source[], double &dest[])
{
    if(period <= 0) return(-1);
    double alpha = 2.0 / (period + 1.0);
    
    if(begin == 0)
    {
        dest[start] = source[start];
        begin = start + 1;
    }

    for(int i = begin; i < rates_total; i++)
    {
        double prev_val = dest[i-1];
        if(prev_val == EMPTY_VALUE || !MathIsValidNumber(prev_val))
        {
            prev_val = source[i-1]; 
        }
        dest[i] = source[i] * alpha + prev_val * (1.0 - alpha);
    }
    return(0);
}
//+------------------------------------------------------------------+
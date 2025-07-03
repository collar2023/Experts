//+------------------------------------------------------------------+
//|                                     EA_Parameter_Structs_v4.9.mqh|
//|         Central Parameter Structures for SuperTrend EA v4.9      |
//+------------------------------------------------------------------+


#ifndef ORDER_TYPE_NONE
   #define ORDER_TYPE_NONE ((ENUM_ORDER_TYPE)(-1))
#endif

//--- 日志模块参数结构体
enum LOG_EB_LEVEL
{
   LOG_LEVEL_ERROR = 0,
   LOG_LEVEL_WARNING = 1,
   LOG_LEVEL_INFO = 2,
   LOG_LEVEL_DEBUG = 3,
   LOG_LEVEL_TRACE = 4
};

struct SLogInputs
{
   LOG_EB_LEVEL logLevel;
   bool         enableFileLog;
   bool         enableConsoleLog;
   string       eaVersion;
};

//--- 风控模块参数结构体
struct SRiskInputs
{
   long     magicNumber;
   bool     useFixedLot;
   double   fixedLot;
   double   riskPercent;
   double   minStopATRMultiple;
   int      atrPeriod;
   double   minStopPoints;
   double   maxLotByBalance;
   double   maxAbsoluteLot;
   bool     enableLotLimit;
   double   slippage;
   double   dailyLossLimitPct;
   bool     allowNewTrade;
};

//--- SuperTrend 入场模块参数结构体
struct SEntryInputs
{
   string   stIndicatorName;
   int      atrPeriod;
   double   atrMultiplier;
   double   stopLossBufferPips;
   bool     useDynamicBuffer;
   double   minBufferPips;
   double   maxBufferPips;
   double   sessionMultiplier;
   double   volatilityFactor;
   bool     useAnomalyDetection;
   double   newsBufferMultiplier;
   double   highVolMultiplier;
   double   rangeBoundMultiplier;
   bool     useADXFilter;
   int      adxPeriod;
   double   adxMinStrength;
};

//--- 结构化离场模块参数结构体
enum ENUM_SE_UPDATE_FREQ
{
   SE_FREQ_EVERY_TICK,
   SE_FREQ_EVERY_BAR,
   SE_FREQ_EVERY_N_BARS
};

struct SStructuralExitInputs
{
   bool   enableBreakeven;
   double breakevenTriggerRR;
   double breakevenBufferPips;
   bool   enableStructureStop;
   int    structureLookback;
   double structureBufferPips;
   bool   enableATRFallback;
   int    atrTrailPeriod;
   double atrTrailMultiplier;
   int    updateFrequency;
   int    updateInterval;
   int    cooldownBars;
   int    minHoldBars;
   int    modifyRequestCooldownSeconds;
};

//--- 二次进场模块参数结构体
struct SReEntryInputs
{
    bool    enableReEntry;
    double  breakoutBufferPips; // 突破/跌破前高前低的缓冲点数
};
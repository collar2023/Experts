//+------------------------------------------------------------------+
//|                                     EA_Parameter_Structs.mqh     |
//|               Central Parameter Structures for SuperTrend EA     |
//|                                                    Version: 6.4  |
//+------------------------------------------------------------------+
#property strict

// ★ NEW: 动作状态返回枚举，用于模块优先级管理
enum ENUM_ACTION_STATUS
{
   ACTION_NONE,             // 无任何操作
   ACTION_MODIFIED_SL_TP,   // 修改了止损/止盈
   ACTION_PARTIAL_CLOSE,    // 执行了部分平仓
   ACTION_FULL_CLOSE,       // 执行了全部平仓
   ACTION_ERROR             // 发生错误 (预留)
};


//--- 从 Common_Defines.mqh 迁移
#ifndef ORDER_TYPE_NONE
   #define ORDER_TYPE_NONE ((ENUM_ORDER_TYPE)(-1))
#endif

// ★ REMOVED: 废除互斥的离场模式枚举，改用独立的布尔开关
/*
enum ENUM_BASE_EXIT_MODE
{
   EXIT_MODE_STRUCTURAL, // 0: 使用结构化离场模块
   EXIT_MODE_SAR,        // 1: 使用SAR/ADX离场模块 (备注: R-Multiple 分步止盈可与任一模式叠加)
   EXIT_MODE_NONE        // 2: 不使用基础离场策略 (仅依赖R-Multiple或手动)
};
*/

enum ENUM_SE_UPDATE_FREQ
{
   SE_FREQ_EVERY_TICK,   // 0: 每Tick更新
   SE_FREQ_EVERY_BAR,    // 1: 每根K线更新
   SE_FREQ_EVERY_N_BARS  // 2: 每N根K线更新
};

//--- 日志模块参数结构体
enum LOG_EB_LEVEL
{
   LOG_LEVEL_ERROR = 0,    // 错误
   LOG_LEVEL_WARNING = 1,  // 警告
   LOG_LEVEL_INFO = 2,     // 信息
   LOG_LEVEL_DEBUG = 3,    // 调试
   LOG_LEVEL_TRACE = 4     // 追踪
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
   bool     AllowNewTrade;
};

//--- SuperTrend 入场模块参数结构体
struct SEntryInputs
{
   // SuperTrend Core
   string   stIndicatorName;
   int      atrPeriod;
   double   atrMultiplier;
   double   stopLossBufferPips;
   
   // Dynamic Stop Loss
   bool     useDynamicBuffer;
   double   minBufferPips;
   double   maxBufferPips;
   double   sessionMultiplier;
   double   volatilityFactor;
   
   // Anomaly Detection
   bool     useAnomalyDetection;
   double   newsBufferMultiplier;
   double   highVolMultiplier;
   double   rangeBoundMultiplier;
   
   // Entry Filter
   bool     useADXFilter;
   int      adxPeriod;
   double   adxMinStrength;
};

//--- SAR/ADX 离场模块参数结构体
struct SSarAdxExitInputs
{
   // SAR Reversal Exit
   bool     useSARReversal;
   bool     useADXFilter;
   double   sarStep;
   double   sarMaximum;
   int      adxPeriod;
   double   adxMinLevel;
   double   sarMinRRatio;
   int      atrPeriod;
   
   // Step Take Profit (RRR)
   bool     enableStepTP;
   double   rrRatio;
   double   step1Pct;
   double   step2Pct;
   double   step2Factor;
   
   // Dynamic RRR
   bool     enableDynamicRRR;
   double   adxStrongThreshold;
   double   strongTrendFactor;
   double   adxWeakThreshold;
   double   weakTrendFactor;
};

//--- 结构化离场模块参数结构体
struct SStructuralExitInputs
{
   // ★ MODIFIED: 此处开关现在直接由主文件的input bool控制
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
   
   // v1.8 Frequency Control
   int    UpdateFrequency;
   int    UpdateInterval;
   
   // v1.9 Cooldown Control
   int    CooldownBars;
   int    MinHoldBars;
   int    ModifyRequestCooldownSeconds;
};
//+------------------------------------------------------------------+
//| SuperTrend EA 日志模块                                          |
//| 版本: 1.1 修复: AccountBalance 报错问题                          |
//+------------------------------------------------------------------+

#property strict

#include <Trade\AccountInfo.mqh>  // 确保支持 AccountInfo 获取函数

//--- 日志级别枚举
enum LOG_EB_LEVEL
{
   LOG_LEVEL_ERROR = 0,    // 错误
   LOG_LEVEL_WARNING = 1,  // 警告
   LOG_LEVEL_INFO = 2,     // 信息
   LOG_LEVEL_DEBUG = 3,    // 调试
   LOG_LEVEL_TRACE = 4     // 追踪
};

//--- 日志类型枚举
enum LOG_TYPE
{
   LOG_TYPE_SYSTEM = 0,    // 系统日志
   LOG_TYPE_ENTRY = 1,     // 入场日志
   LOG_TYPE_EXIT = 2,      // 出场日志
   LOG_TYPE_RISK = 3,      // 风控日志
   LOG_TYPE_PERFORMANCE = 4 // 性能日志
};

//--- 日志模块类
class CLogModule
{
private:
   string            m_logFileName;
   bool              m_enableFileLog;
   bool              m_enableConsoleLog;
   LOG_EB_LEVEL      m_logLevel;
   int               m_fileHandle;

   int               m_totalTrades;
   int               m_winTrades;
   double            m_totalProfit;
   double            m_maxDrawdown;
   double            m_peakBalance;

   string            GetLevelString(LOG_EB_LEVEL level);
   string            GetTypeString(LOG_TYPE type);
   string            GetTimestamp();
   bool              ShouldLog(LOG_EB_LEVEL level);

public:
                     CLogModule();
                    ~CLogModule();

   bool              Initialize(string fileName = "", LOG_EB_LEVEL level = LOG_LEVEL_INFO);
   void              Cleanup();
   void              SetLogLevel(LOG_EB_LEVEL level) { m_logLevel = level; }
   void              EnableFileLog(bool enable) { m_enableFileLog = enable; }
   void              EnableConsoleLog(bool enable) { m_enableConsoleLog = enable; }

   void              WriteLog(LOG_EB_LEVEL level, LOG_TYPE type, string message);
   void              WriteError(string message) { WriteLog(LOG_LEVEL_ERROR, LOG_TYPE_SYSTEM, message); }
   void              WriteWarning(string message) { WriteLog(LOG_LEVEL_WARNING, LOG_TYPE_SYSTEM, message); }
   void              WriteInfo(string message) { WriteLog(LOG_LEVEL_INFO, LOG_TYPE_SYSTEM, message); }
   void              WriteDebug(string message) { WriteLog(LOG_LEVEL_DEBUG, LOG_TYPE_SYSTEM, message); }

   void              LogEntrySignal(string signal, double price, double stopLoss, double lotSize);
   void              LogExitSignal(string signal, double price, double profit, int reason);
   void              LogRiskManagement(double riskAmount, double lotSize, bool canTrade);
   void              LogTradeExecution(string action, int ticket, double price, double volume);
   void              LogIndicatorValues(string indicator, double value1, double value2 = 0, double value3 = 0);
   void              UpdateTradeStats(bool isWin, double profit);
   void              UpdateDrawdown(double currentBalance);
   void              LogPerformanceReport();
   void              LogModuleStart(string moduleName);
   void              LogModuleEnd(string moduleName, bool success);
   void              LogParameterSettings();
};


CLogModule::CLogModule()
{
   m_logFileName = "";
   m_enableFileLog = true;
   m_enableConsoleLog = true;
   m_logLevel = LOG_LEVEL_INFO;
   m_fileHandle = INVALID_HANDLE;
   m_totalTrades = 0;
   m_winTrades = 0;
   m_totalProfit = 0;
   m_maxDrawdown = 0;
   m_peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
}

CLogModule::~CLogModule()
{
   Cleanup();
}

bool CLogModule::Initialize(string fileName = "", LOG_EB_LEVEL level = LOG_LEVEL_INFO)
{
   m_logLevel = level;

   string symbol   = Symbol();  // 当前交易品种
   string date     = TimeToString(TimeCurrent(), TIME_DATE);
   string subDir   = "Logs\\" + symbol + "\\";  // 多级子目录路径

   if(fileName == "")
      m_logFileName = subDir + "SuperTrend_EA_" + date + ".log";
   else
      m_logFileName = subDir + fileName;

   // 打开文件（注意 MQL5 会自动创建子目录）
   if(m_enableFileLog)
   {
      m_fileHandle = FileOpen(m_logFileName, FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(m_fileHandle == INVALID_HANDLE)
      {
         Print("日志模块初始化失败: 无法创建日志文件 ", m_logFileName);
         return false;
      }
   }

   WriteInfo("SuperTrend EA 日志模块初始化成功");
   WriteInfo("EA版本: SuperTrend 三位一体 v1.0");
   WriteInfo("交易品种: " + symbol);
   WriteInfo("时间框架: " + EnumToString(Period()));

   return true;
}

void CLogModule::Cleanup()
{
   if(m_fileHandle != INVALID_HANDLE)
   {
      WriteInfo("日志模块关闭");
      LogPerformanceReport();
      FileClose(m_fileHandle);
      m_fileHandle = INVALID_HANDLE;
   }
}

string CLogModule::GetLevelString(LOG_EB_LEVEL level)
{
   switch(level)
   {
      case LOG_LEVEL_ERROR: return "ERROR";
      case LOG_LEVEL_WARNING: return "WARN ";
      case LOG_LEVEL_INFO: return "INFO ";
      case LOG_LEVEL_DEBUG: return "DEBUG";
      case LOG_LEVEL_TRACE: return "TRACE";
   }
   return "UNKNW";
}

string CLogModule::GetTypeString(LOG_TYPE type)
{
   switch(type)
   {
      case LOG_TYPE_SYSTEM: return "[系统]";
      case LOG_TYPE_ENTRY: return "[入场]";
      case LOG_TYPE_EXIT: return "[出场]";
      case LOG_TYPE_RISK: return "[风控]";
      case LOG_TYPE_PERFORMANCE: return "[性能]";
   }
   return "[未知]";
}

string CLogModule::GetTimestamp()
{
   return TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
}

bool CLogModule::ShouldLog(LOG_EB_LEVEL level)
{
   return (level <= m_logLevel);
}

void CLogModule::WriteLog(LOG_EB_LEVEL level, LOG_TYPE type, string message)
{
   if(!ShouldLog(level)) return;
   string logLine = StringFormat("%s [%s] %s %s", GetTimestamp(), GetLevelString(level), GetTypeString(type), message);
   if(m_enableConsoleLog) Print(logLine);
   if(m_enableFileLog && m_fileHandle != INVALID_HANDLE)
   {
      FileWrite(m_fileHandle, logLine);
      FileFlush(m_fileHandle);
   }
}

void CLogModule::LogEntrySignal(string signal, double price, double stopLoss, double lotSize)
{
   string message = StringFormat("入场信号: %s | 价格: %.5f | 止损: %.5f | 手数: %.2f", signal, price, stopLoss, lotSize);
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_ENTRY, message);
}

void CLogModule::LogExitSignal(string signal, double price, double profit, int reason)
{
   string reasons[] = {"其他", "SAR反转", "分步止盈", "移动止损", "ADX确认"};
   string message = StringFormat("出场信号: %s | 价格: %.5f | 盈亏: %.2f | 原因: %s", signal, price, profit, reasons[MathMin(reason, 4)]);
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_EXIT, message);
}

void CLogModule::LogRiskManagement(double riskAmount, double lotSize, bool canTrade)
{
   string message = StringFormat("风控检查: 风险金额: %.2f | 手数: %.2f | 可交易: %s", riskAmount, lotSize, canTrade ? "是" : "否");
   WriteLog(LOG_LEVEL_DEBUG, LOG_TYPE_RISK, message);
}

void CLogModule::LogTradeExecution(string action, int ticket, double price, double volume)
{
   string message = StringFormat("交易执行: %s | 单号: %d | 价格: %.5f | 手数: %.2f", action, ticket, price, volume);
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_SYSTEM, message);
}

void CLogModule::LogIndicatorValues(string indicator, double value1, double value2 = 0, double value3 = 0)
{
   string message = StringFormat("%s 值: %.5f", indicator, value1);
   if(value2 != 0.0) message += StringFormat(" | %.5f", value2);
   if(value3 != 0.0) message += StringFormat(" | %.5f", value3);
   WriteLog(LOG_LEVEL_TRACE, LOG_TYPE_SYSTEM, message);
}

void CLogModule::UpdateTradeStats(bool isWin, double profit)
{
   m_totalTrades++;
   if(isWin) m_winTrades++;
   m_totalProfit += profit;
   double winRate = m_totalTrades > 0 ? 100.0 * m_winTrades / m_totalTrades : 0;
   string message = StringFormat("交易统计: 总数: %d | 胜数: %d | 胜率: %.2f%% | 总盈亏: %.2f", m_totalTrades, m_winTrades, winRate, m_totalProfit);
   WriteLog(LOG_LEVEL_DEBUG, LOG_TYPE_PERFORMANCE, message);
}

void CLogModule::UpdateDrawdown(double currentBalance)
{
   if(currentBalance > m_peakBalance) m_peakBalance = currentBalance;
   double dd = (m_peakBalance - currentBalance) / m_peakBalance * 100.0;
   if(dd > m_maxDrawdown)
   {
      m_maxDrawdown = dd;
      WriteLog(LOG_LEVEL_WARNING, LOG_TYPE_PERFORMANCE, StringFormat("新最大回撤: %.2f%%", dd));
   }
}

void CLogModule::LogPerformanceReport()
{
   double winRate = m_totalTrades > 0 ? 100.0 * m_winTrades / m_totalTrades : 0;
   double avgProfit = m_totalTrades > 0 ? m_totalProfit / m_totalTrades : 0;
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_PERFORMANCE, "========== 性能报告 ==========");
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_PERFORMANCE, StringFormat("总交易次数: %d", m_totalTrades));
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_PERFORMANCE, StringFormat("盈利交易: %d", m_winTrades));
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_PERFORMANCE, StringFormat("胜率: %.2f%%", winRate));
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_PERFORMANCE, StringFormat("总盈亏: %.2f", m_totalProfit));
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_PERFORMANCE, StringFormat("平均盈亏: %.2f", avgProfit));
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_PERFORMANCE, StringFormat("最大回撤: %.2f%%", m_maxDrawdown));
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_PERFORMANCE, StringFormat("当前余额: %.2f", AccountInfoDouble(ACCOUNT_BALANCE)));
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_PERFORMANCE, "============================");
}

void CLogModule::LogModuleStart(string moduleName)
{
   WriteLog(LOG_LEVEL_DEBUG, LOG_TYPE_SYSTEM, StringFormat("模块开始: %s", moduleName));
}

void CLogModule::LogModuleEnd(string moduleName, bool success)
{
   string status = success ? "成功" : "失败";
   WriteLog(LOG_LEVEL_DEBUG, LOG_TYPE_SYSTEM, StringFormat("模块结束: %s - %s", moduleName, status));
}

void CLogModule::LogParameterSettings()
{
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_SYSTEM, "========== 参数设置 ==========");
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_SYSTEM, "请在此补充各模块具体参数记录...");
   WriteLog(LOG_LEVEL_INFO, LOG_TYPE_SYSTEM, "============================");
}

bool InitializeLogger(LOG_EB_LEVEL level = LOG_LEVEL_INFO)
{
   if(g_Logger != NULL) delete g_Logger;
   g_Logger = new CLogModule();
   return g_Logger.Initialize("", level);
}

void CleanupLogger()
{
   if(g_Logger != NULL) { delete g_Logger; g_Logger = NULL; }
}

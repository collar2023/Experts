//+------------------------------------------------------------------+
//|                                      Adaptive_Time_Manager.mqh |
//|                                  EA自适应时间控制模块 - MT5版本  |
//|                        支持外汇/期权/加密货币/港美股多资产交易    |
//+------------------------------------------------------------------+

#include "SuperTrend_LogModule.mqh"

// 声明外部日志对象
extern CLogModule* g_Logger;

//--- 资产类型枚举
enum ASSET_TYPE
{
   ASSET_FOREX = 1,        // 外汇
   ASSET_CRYPTO = 2,       // 加密货币
   ASSET_STOCK_US = 3,     // 美股
   ASSET_STOCK_HK = 4,     // 港股
   ASSET_OPTIONS = 5,      // 期权
   ASSET_FUTURES = 6,      // 期货
   ASSET_COMMODITIES = 7   // 商品
};

//--- 交易时段枚举
enum TRADING_SESSION
{
   SESSION_ASIA = 1,       // 亚洲时段
   SESSION_EUROPE = 2,     // 欧洲时段
   SESSION_AMERICA = 3,    // 美洲时段
   SESSION_24H = 4         // 24小时交易
};

//--- 市场状态枚举
enum MARKET_STATUS
{
   MARKET_ACTIVE = 1,      // 活跃交易
   MARKET_CAUTIOUS = 2,    // 谨慎交易
   MARKET_CLOSED = 3,      // 市场关闭
   MARKET_NEWS_AVOID = 4,  // 新闻避开
   MARKET_HOLIDAY = 5,     // 节假日
   MARKET_LOW_LIQUIDITY = 6 // 低流动性
};

//--- 新闻影响级别枚举
enum NEWS_IMPACT_LEVEL
{
   NEWS_LOW = 1,           // 低影响
   NEWS_MEDIUM = 2,        // 中影响  
   NEWS_HIGH = 3,          // 高影响
   NEWS_CRITICAL = 4       // 关键影响（央行会议、非农等）
};

//--- 时间窗口结构
struct TimeWindow
{
   int startHour;          // 开始小时
   int startMinute;        // 开始分钟
   int endHour;            // 结束小时
   int endMinute;          // 结束分钟
   bool enabled;           // 是否启用
   string description;     // 描述
};

//--- 新闻事件结构
struct NewsEvent
{
   datetime eventTime;           // 事件时间
   string eventName;            // 事件名称
   string currency;             // 相关货币
   NEWS_IMPACT_LEVEL impact;    // 影响级别
   datetime avoidStart;         // 避开开始时间
   datetime avoidEnd;           // 避开结束时间
   bool isSpecialEvent;         // 是否特殊事件（非农、FOMC等）
};

//--- 节假日结构
struct Holiday
{
   datetime date;          // 节假日日期
   string name;           // 节假日名称
   string country;        // 国家
   bool affectsTradingPair; // 是否影响当前交易对
};

//+------------------------------------------------------------------+
//| EA自适应时间控制管理类                                            |
//+------------------------------------------------------------------+
class CAdaptiveTimeManager
{
private:
   // 基础配置
   ASSET_TYPE assetType;              // 资产类型
   string symbolName;                 // 交易品种名称
   string baseCurrency;               // 基础货币
   string quoteCurrency;              // 报价货币
   
   // 时间窗口配置
   TimeWindow asiaSession;            // 亚洲时段
   TimeWindow europeSession;          // 欧洲时段
   TimeWindow americaSession;         // 美洲时段
   TimeWindow customSession;          // 自定义时段
   
   // 市场状态
   MARKET_STATUS currentMarketStatus;
   datetime lastStatusUpdate;
   
   // 新闻事件管理
   NewsEvent newsEvents[];
   int eventCount;
   datetime lastNewsUpdate;
   
   // 节假日管理
   Holiday holidays[];
   int holidayCount;
   
   // 配置参数
   bool enableWeekendTrading;         // 周末交易开关
   bool enableHolidayTrading;         // 节假日交易开关
   bool enableNewsAvoid;              // 新闻避开开关
   bool enableMarketOpenCaution;      // 开盘谨慎期开关
   
   // 新闻避开时间设置
   int highNewsAvoidBefore;           // 高影响新闻前避开分钟
   int highNewsAvoidAfter;            // 高影响新闻后避开分钟
   int mediumNewsAvoidBefore;         // 中影响新闻前避开分钟
   int mediumNewsAvoidAfter;          // 中影响新闻后避开分钟
   int criticalNewsAvoidBefore;       // 关键新闻前避开分钟
   int criticalNewsAvoidAfter;        // 关键新闻后避开分钟
   
   // 风险控制参数
   double maxSpreadThreshold;         // 最大点差阈值
   double volatilityThreshold;        // 波动率阈值
   int marketOpenCautionMinutes;      // 开盘谨慎期分钟数
   
   // 智能调整参数
   bool enableSeasonalAdjust;         // 季节性调整
   bool enableVolatilityAdapt;        // 波动性自适应
   bool enableLiquidityMonitor;       // 流动性监控

public:
   //--- 构造函数
   CAdaptiveTimeManager()
   {
      InitializeDefaults();
      DetectAssetType();
      ConfigureTimeWindows();
   }
   
   //--- 析构函数
   ~CAdaptiveTimeManager() {}
   
   //+------------------------------------------------------------------+
   //| 初始化默认参数                                                    |
   //+------------------------------------------------------------------+
   void InitializeDefaults()
   {
      symbolName = Symbol();
      eventCount = 0;
      holidayCount = 0;
      lastNewsUpdate = 0;
      lastStatusUpdate = 0;
      currentMarketStatus = MARKET_ACTIVE;
      
      // 基础开关
      enableWeekendTrading = false;
      enableHolidayTrading = false;
      enableNewsAvoid = true;
      enableMarketOpenCaution = true;
      
      // 新闻避开时间（分钟）
      criticalNewsAvoidBefore = 120;    // 关键新闻前2小时
      criticalNewsAvoidAfter = 120;     // 关键新闻后2小时
      highNewsAvoidBefore = 60;         // 高影响前1小时
      highNewsAvoidAfter = 90;          // 高影响后1.5小时
      mediumNewsAvoidBefore = 30;       // 中影响前30分钟
      mediumNewsAvoidAfter = 30;        // 中影响后30分钟
      
      // 风险控制
      maxSpreadThreshold = 3.0;         // 3倍正常点差
      volatilityThreshold = 2.0;        // 2倍正常波动率
      marketOpenCautionMinutes = 30;    // 开盘后30分钟谨慎期
      
      // 智能功能
      enableSeasonalAdjust = true;
      enableVolatilityAdapt = true;
      enableLiquidityMonitor = true;
      
      g_Logger->WriteInfo("时间管理模块初始化默认参数");
   }
   
   //+------------------------------------------------------------------+
   //| 检测资产类型                                                      |
   //+------------------------------------------------------------------+
   void DetectAssetType()
   {
      string symbol = symbolName;
      
      // 提取货币对信息
      if(StringLen(symbol) >= 6)
      {
         baseCurrency = StringSubstr(symbol, 0, 3);
         quoteCurrency = StringSubstr(symbol, 3, 3);
      }
      
      // 检测资产类型
      if(StringFind(symbol, "BTC") >= 0 || StringFind(symbol, "ETH") >= 0 || 
         StringFind(symbol, "CRYPTO") >= 0 || StringFind(symbol, "USDT") >= 0)
      {
         assetType = ASSET_CRYPTO;
         g_Logger->WriteInfo("检测到加密货币: " + symbol);
      }
      else if(StringFind(symbol, ".HK") >= 0 || StringFind(symbol, "HK") >= 0)
      {
         assetType = ASSET_STOCK_HK;
         g_Logger->WriteInfo("检测到港股: " + symbol);
      }
      else if(StringFind(symbol, ".US") >= 0 || StringFind(symbol, "US") >= 0)
      {
         assetType = ASSET_STOCK_US;
         g_Logger->WriteInfo("检测到美股: " + symbol);
      }
      else if(StringFind(symbol, "OPT") >= 0 || StringFind(symbol, "OPTION") >= 0)
      {
         assetType = ASSET_OPTIONS;
         g_Logger->WriteInfo("检测到期权: " + symbol);
      }
      else if(StringLen(baseCurrency) == 3 && StringLen(quoteCurrency) == 3)
      {
         assetType = ASSET_FOREX;
         g_Logger->WriteInfo("检测到外汇: " + symbol + " (" + baseCurrency + "/" + quoteCurrency + ")");
      }
      else
      {
         assetType = ASSET_FOREX; // 默认为外汇
         g_Logger->WriteWarning("未能确定资产类型，默认为外汇: " + symbol);
      }
   }
   
   //+------------------------------------------------------------------+
   //| 配置交易时间窗口                                                  |
   //+------------------------------------------------------------------+
   void ConfigureTimeWindows()
   {
      // 亚洲时段 (GMT+0: 00:00-09:00)
      asiaSession.startHour = 0;
      asiaSession.startMinute = 0;
      asiaSession.endHour = 9;
      asiaSession.endMinute = 0;
      asiaSession.description = "亚洲时段";
      
      // 欧洲时段 (GMT+0: 08:00-17:00)
      europeSession.startHour = 8;
      europeSession.startMinute = 0;
      europeSession.endHour = 17;
      europeSession.endMinute = 0;
      europeSession.description = "欧洲时段";
      
      // 美洲时段 (GMT+0: 13:00-22:00)
      americaSession.startHour = 13;
      americaSession.startMinute = 0;
      americaSession.endHour = 22;
      americaSession.endMinute = 0;
      americaSession.description = "美洲时段";
      
      // 根据资产类型启用相应时段
      switch(assetType)
      {
         case ASSET_FOREX:
            asiaSession.enabled = true;
            europeSession.enabled = true;
            americaSession.enabled = true;
            enableWeekendTrading = false;
            break;
            
         case ASSET_CRYPTO:
            asiaSession.enabled = true;
            europeSession.enabled = true;
            americaSession.enabled = true;
            enableWeekendTrading = true; // 加密货币24/7交易
            break;
            
         case ASSET_STOCK_US:
            asiaSession.enabled = false;
            europeSession.enabled = false;
            americaSession.enabled = true;
            // 美股时间调整为EST
            americaSession.startHour = 14; // 9:30 EST = 14:30 GMT
            americaSession.startMinute = 30;
            americaSession.endHour = 21;   // 4:00 PM EST = 21:00 GMT
            americaSession.endMinute = 0;
            enableWeekendTrading = false;
            break;
            
         case ASSET_STOCK_HK:
            asiaSession.enabled = true;
            europeSession.enabled = false;
            americaSession.enabled = false;
            // 港股时间调整为HKT
            asiaSession.startHour = 1;     // 9:30 HKT = 01:30 GMT
            asiaSession.startMinute = 30;
            asiaSession.endHour = 8;       // 4:00 PM HKT = 08:00 GMT
            asiaSession.endMinute = 0;
            enableWeekendTrading = false;
            break;
            
         case ASSET_OPTIONS:
            // 期权跟随标的资产时间，但增加特殊处理
            asiaSession.enabled = true;
            europeSession.enabled = true;
            americaSession.enabled = true;
            enableWeekendTrading = false;
            break;
            
         default:
            asiaSession.enabled = true;
            europeSession.enabled = true;
            americaSession.enabled = true;
            enableWeekendTrading = false;
            break;
      }
      
      g_Logger->WriteInfo("时间窗口配置完成 - 亚洲:" + (asiaSession.enabled ? "开启" : "关闭") +
                       " 欧洲:" + (europeSession.enabled ? "开启" : "关闭") +
                       " 美洲:" + (americaSession.enabled ? "开启" : "关闭"));
   }
   
   //+------------------------------------------------------------------+
   //| 主要初始化函数                                                    |
   //+------------------------------------------------------------------+
   bool Initialize()
   {
      g_Logger->WriteInfo("=== 初始化EA自适应时间控制模块 ===");
      g_Logger->WriteInfo("交易品种: " + symbolName);
      g_Logger->WriteInfo("资产类型: " + GetAssetTypeString());
      
      // 加载新闻事件
      if(!UpdateNewsEvents())
      {
         g_Logger->WriteWarning("新闻事件加载失败，继续使用其他时间控制");
      }
      
      // 加载节假日
      LoadHolidays();
      
      // 初始状态检查
      UpdateMarketStatus();
      
      g_Logger->WriteInfo("时间控制模块初始化成功");
      return true;
   }
   
   //+------------------------------------------------------------------+
   //| 更新新闻事件                                                      |
   //+------------------------------------------------------------------+
   bool UpdateNewsEvents()
   {
      datetime currentTime = TimeCurrent();
      
      // 每小时更新一次
      if(currentTime - lastNewsUpdate < 3600 && eventCount > 0)
         return true;
         
      g_Logger->WriteDebug("更新新闻事件数据");
      
      // 清空现有数据
      ArrayResize(newsEvents, 0);
      eventCount = 0;
      
      // 获取未来48小时的新闻事件
      datetime startTime = currentTime;
      datetime endTime = currentTime + 172800; // 48小时后
      
      MqlCalendarValue calendarValues[];
      
      if(CalendarValueHistory(calendarValues, startTime, endTime) > 0)
      {
         int totalEvents = ArraySize(calendarValues);
         
         for(int i = 0; i < totalEvents; i++)
         {
            if(ProcessCalendarEvent(calendarValues[i]))
            {
               eventCount++;
            }
         }
         
         g_Logger->WriteInfo("成功加载 " + IntegerToString(eventCount) + " 个相关新闻事件");
      }
      else
      {
         g_Logger->WriteWarning("无法获取经济日历，加载预设重要事件");
         LoadPresetEvents();
      }
      
      lastNewsUpdate = currentTime;
      return true;
   }
   
   //+------------------------------------------------------------------+
   //| 处理日历事件                                                      |
   //+------------------------------------------------------------------+
   bool ProcessCalendarEvent(const MqlCalendarValue &calendarValue)
   {
      MqlCalendarEvent calendarEvent;
      MqlCalendarCountry calendarCountry;
      
      if(!CalendarEventById(calendarValue.event_id, calendarEvent))
         return false;
         
      if(!CalendarCountryById(calendarEvent.country_id, calendarCountry))
         return false;
      
      // 获取影响级别
      NEWS_IMPACT_LEVEL eventImpact = GetNewsImpactLevel(calendarEvent);
      if(eventImpact < NEWS_MEDIUM) // 只关注中等以上影响
         return false;
      
      // 检查与当前交易对的相关性
      if(!IsEventRelevant(calendarEvent, calendarCountry))
         return false;
      
      // 创建新闻事件
      NewsEvent newsEvent;
      newsEvent.eventTime = calendarValue.time;
      newsEvent.eventName = calendarEvent.name;
      newsEvent.currency = calendarCountry.currency;
      newsEvent.impact = eventImpact;
      newsEvent.isSpecialEvent = IsSpecialEvent(calendarEvent.name);
      
      // 根据影响级别设置避开时间
      SetAvoidTimeForEvent(newsEvent);
      
      // 添加到数组
      int newSize = ArraySize(newsEvents) + 1;
      ArrayResize(newsEvents, newSize);
      newsEvents[newSize - 1] = newsEvent;
      
      return true;
   }
   
   //+------------------------------------------------------------------+
   //| 获取新闻影响级别                                                  |
   //+------------------------------------------------------------------+
   NEWS_IMPACT_LEVEL GetNewsImpactLevel(const MqlCalendarEvent &event)
   {
      // 检查是否为特殊事件
      if(IsSpecialEvent(event.name))
         return NEWS_CRITICAL;
      
      // 根据系统重要性分级
      switch(event.importance)
      {
         case CALENDAR_IMPORTANCE_HIGH:
            return NEWS_HIGH;
         case CALENDAR_IMPORTANCE_MODERATE:
            return NEWS_MEDIUM;
         case CALENDAR_IMPORTANCE_LOW:
            return NEWS_LOW;
         default:
            return NEWS_LOW;
      }
   }
   
   //+------------------------------------------------------------------+
   //| 检查是否为特殊事件                                                |
   //+------------------------------------------------------------------+
   bool IsSpecialEvent(const string eventName)
   {
      string specialEvents[] = {
         "Non-Farm Payrolls", "非农就业人数", "NFP",
         "FOMC", "Federal Reserve", "利率决议",
         "CPI", "消费者物价指数", "通胀率",
         "GDP", "国内生产总值",
         "央行", "Central Bank", "货币政策"
      };
      
      for(int i = 0; i < ArraySize(specialEvents); i++)
      {
         if(StringFind(eventName, specialEvents[i]) >= 0)
            return true;
      }
      
      return false;
   }
   
   //+------------------------------------------------------------------+
   //| 检查事件相关性                                                    |
   //+------------------------------------------------------------------+
   bool IsEventRelevant(const MqlCalendarEvent &event, const MqlCalendarCountry &country)
   {
      // 对于外汇，检查货币相关性
      if(assetType == ASSET_FOREX)
      {
         if(country.currency == baseCurrency || country.currency == quoteCurrency)
            return true;
         
         // 主要货币对美元的影响
         if(country.currency == "USD" && (baseCurrency == "USD" || quoteCurrency == "USD"))
            return true;
      }
      
      // 对于股票，检查国家相关性
      if(assetType == ASSET_STOCK_US && country.currency == "USD")
         return true;
      if(assetType == ASSET_STOCK_HK && country.currency == "CNY")
         return true;
      
      // 对于加密货币，主要关注美国数据
      if(assetType == ASSET_CRYPTO && country.currency == "USD")
         return true;
      
      return false;
   }
   
   //+------------------------------------------------------------------+
   //| 设置事件避开时间                                                  |
   //+------------------------------------------------------------------+
   void SetAvoidTimeForEvent(NewsEvent &event)
   {
      int beforeMinutes, afterMinutes;
      
      if(event.isSpecialEvent)
      {
         beforeMinutes = criticalNewsAvoidBefore;
         afterMinutes = criticalNewsAvoidAfter;
      }
      else if(event.impact == NEWS_HIGH)
      {
         beforeMinutes = highNewsAvoidBefore;
         afterMinutes = highNewsAvoidAfter;
      }
      else
      {
         beforeMinutes = mediumNewsAvoidBefore;
         afterMinutes = mediumNewsAvoidAfter;
      }
      
      event.avoidStart = event.eventTime - beforeMinutes * 60;
      event.avoidEnd = event.eventTime + afterMinutes * 60;
   }
   
   //+------------------------------------------------------------------+
   //| 加载预设事件                                                      |
   //+------------------------------------------------------------------+
   void LoadPresetEvents()
   {
      // 添加每月第一个周五的非农数据
      datetime currentTime = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(currentTime, dt);
      
      // 计算当月第一个周五
      datetime firstDayOfMonth = currentTime - (dt.day - 1) * 86400;
      TimeToStruct(firstDayOfMonth, dt);
      
      int daysToFriday = (5 - dt.day_of_week + 7) % 7;
      if(daysToFriday == 0 && dt.day_of_week != 5) daysToFriday = 7;
      
      datetime firstFriday = firstDayOfMonth + daysToFriday * 86400;
      datetime nfpTime = firstFriday + 13 * 3600 + 30 * 60; // 13:30 GMT
      
      if(nfpTime > currentTime && nfpTime < currentTime + 2592000) // 30天内
      {
         NewsEvent nfpEvent;
         nfpEvent.eventTime = nfpTime;
         nfpEvent.eventName = "非农就业人数 (NFP)";
         nfpEvent.currency = "USD";
         nfpEvent.impact = NEWS_CRITICAL;
         nfpEvent.isSpecialEvent = true;
         SetAvoidTimeForEvent(nfpEvent);
         
         ArrayResize(newsEvents, 1);
         newsEvents[0] = nfpEvent;
         eventCount = 1;
         
         g_Logger->WriteInfo("添加预设NFP事件: " + TimeToString(nfpTime));
      }
   }
   
   //+------------------------------------------------------------------+
   //| 加载节假日                                                        |
   //+------------------------------------------------------------------+
   void LoadHolidays()
   {
      // 这里可以加载主要国家的节假日
      // 简化版本，只添加一些固定节假日
      
      ArrayResize(holidays, 0);
      holidayCount = 0;
      
      datetime currentTime = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(currentTime, dt);
      
      // 添加圣诞节、新年等
      AddHoliday(StringToTime(IntegerToString(dt.year) + ".12.25"), "圣诞节", "USD");
      AddHoliday(StringToTime(IntegerToString(dt.year + 1) + ".01.01"), "新年", "USD");
      
      g_Logger->WriteInfo("加载了 " + IntegerToString(holidayCount) + " 个节假日");
   }
   
   //+------------------------------------------------------------------+
   //| 添加节假日                                                        |
   //+------------------------------------------------------------------+
   void AddHoliday(datetime date, string name, string country)
   {
      Holiday holiday;
      holiday.date = date;
      holiday.name = name;
      holiday.country = country;
      holiday.affectsTradingPair = (country == baseCurrency || country == quoteCurrency);
      
      int newSize = ArraySize(holidays) + 1;
      ArrayResize(holidays, newSize);
      holidays[newSize - 1] = holiday;
      holidayCount++;
   }
   
   //+------------------------------------------------------------------+
   //| 更新市场状态                                                      |
   //+------------------------------------------------------------------+
   void UpdateMarketStatus()
   {
      datetime currentTime = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(currentTime, dt);
      
      // 检查是否为周末
      if(!enableWeekendTrading && (dt.day_of_week == 0 || dt.day_of_week == 6))
      {
         currentMarketStatus = MARKET_CLOSED;
         return;
      }
      
      // 检查节假日
      if(!enableHolidayTrading && IsHoliday(currentTime))
      {
         currentMarketStatus = MARKET_HOLIDAY;
         return;
      }
      
      // 检查新闻避开时间
      if(enableNewsAvoid && IsInNewsAvoidTime(currentTime))
      {
         currentMarketStatus = MARKET_NEWS_AVOID;
         return;
      }
      
      // 检查交易时段
      if(!IsInTradingSession(currentTime))
      {
         currentMarketStatus = MARKET_CLOSED;
         return;
      }
      
      // 检查开盘谨慎期
      if(enableMarketOpenCaution && IsInMarketOpenCaution(currentTime))
      {
         currentMarketStatus = MARKET_CAUTIOUS;
         return;
      }
      
      // 检查流动性
      if(enableLiquidityMonitor && IsLowLiquidity())
      {
         currentMarketStatus = MARKET_LOW_LIQUIDITY;
         return;
      }
      
      currentMarketStatus = MARKET_ACTIVE;
   }
   
   //+------------------------------------------------------------------+
   //| 检查是否在交易时段内                                              |
   //+------------------------------------------------------------------+
   bool IsInTradingSession(datetime checkTime)
   {
      MqlDateTime dt;
      TimeToStruct(checkTime, dt);
      
      int currentHour = dt.hour;
      int currentMinute = dt.min;
      int currentTotalMinutes = currentHour * 60 + currentMinute;
      
      // 检查各个时段
      if(asiaSession.enabled)
      {
         int startMinutes = asiaSession.startHour * 60 + asiaSession.startMinute;
         int endMinutes = asiaSession.endHour * 60 + asiaSession.endMinute;
         if(currentTotalMinutes >= startMinutes && currentTotalMinutes < endMinutes)
            return true;
      }
      
      if(europeSession.enabled)
      {
         int startMinutes = europeSession.startHour * 60 + europeSession.startMinute;
         int endMinutes = europeSession.endHour * 60 + europeSession.endMinute;
         if(currentTotalMinutes >= startMinutes && currentTotalMinutes < endMinutes)
            return true;
      }
      
      if(americaSession.enabled)
      {
         int startMinutes = americaSession.startHour * 60 + americaSession.startMinute;
         int endMinutes = americaSession.endHour * 60 + americaSession.endMinute;
         if(currentTotalMinutes >= startMinutes && currentTotalMinutes < endMinutes)
            return true;
      }
      
      return false;
   }
   
   //+------------------------------------------------------------------+
   //| 检查是否在新闻避开时间                                            |
   //+------------------------------------------------------------------+
   bool IsInNewsAvoidTime(datetime checkTime)
   {
      for(int i = 0; i < eventCount; i++)
      {
         if(checkTime >= newsEvents[i].avoidStart && checkTime <= newsEvents[i].avoidEnd)
         {
            g_Logger->WriteDebug("当前在新闻避开时间: " + newsEvents[i].eventName);
            return true;
         }
      }
      return false;
   }
   
   //+------------------------------------------------------------------+
   //| 检查是否为节假日                                                  |
   //+------------------------------------------------------------------+
   bool IsHoliday(datetime checkTime)
   {
      datetime checkDate = checkTime - (checkTime % 86400); // 只比较日期
      
      for(int i = 0; i < holidayCount; i++)
      {
         datetime holidayDate = holidays[i].date - (holidays[i].date % 86400);
         if(checkDate == holidayDate && holidays[i].affectsTradingPair)
         {
            g_Logger->WriteDebug("今日为节假日: " + holidays[i].name);
            return true;
         }
      }
      return false;
   }
   
   //+------------------------------------------------------------------+
   //| 检查是否在开盘谨慎期                                              |
   //+------------------------------------------------------------------+
   bool IsInMarketOpenCaution(datetime checkTime)
   {
      MqlDateTime dt;
      TimeToStruct(checkTime, dt);
      
      int currentHour = dt.hour;
      int currentMinute = dt.min;
      int currentTotalMinutes = currentHour * 60 + currentMinute;
      
      // 检查各时段开盘后的谨慎期
      if(asiaSession.enabled)
      {
         int sessionStart = asiaSession.startHour * 60 + asiaSession.startMinute;
         int cautionEnd = sessionStart + marketOpenCautionMinutes;
         if(currentTotalMinutes >= sessionStart && currentTotalMinutes < cautionEnd)
            return true;
      }
      
      if(europeSession.enabled)
      {
         int sessionStart = europeSession.startHour * 60 + europeSession.startMinute;
         int cautionEnd = sessionStart + marketOpenCautionMinutes;
         if(currentTotalMinutes >= sessionStart && currentTotalMinutes < cautionEnd)
            return true;
      }
      
      if(americaSession.enabled)
      {
         int sessionStart = americaSession.startHour * 60 + americaSession.startMinute;
         int cautionEnd = sessionStart + marketOpenCautionMinutes;
         if(currentTotalMinutes >= sessionStart && currentTotalMinutes < cautionEnd)
            return true;
      }
      
      return false;
   }
   
   //+------------------------------------------------------------------+
   //| 检查流动性是否过低                                                |
   //+------------------------------------------------------------------+
   bool IsLowLiquidity()
   {
      // 获取当前点差
      double currentSpread = SymbolInfoDouble(symbolName, SYMBOL_SPREAD) * SymbolInfoDouble(symbolName, SYMBOL_POINT);
      double normalSpread = GetNormalSpread();
      
      if(currentSpread > normalSpread * maxSpreadThreshold)
      {
         g_Logger->WriteWarning("点差异常: 当前=" + DoubleToString(currentSpread, 5) + 
                           " 正常=" + DoubleToString(normalSpread, 5));
         return true;
      }
      
      // 检查波动率异常
      if(enableVolatilityAdapt && IsVolatilityAbnormal())
      {
         return true;
      }
      
      return false;
   }
   
   //+------------------------------------------------------------------+
   //| 获取正常点差                                                      |
   //+------------------------------------------------------------------+
   double GetNormalSpread()
   {
      // 这里可以根据历史数据计算平均点差
      // 简化版本返回固定值
      switch(assetType)
      {
         case ASSET_FOREX:
            if(symbolName == "EURUSD") return 0.00008;
            if(symbolName == "GBPUSD") return 0.00012;
            if(symbolName == "USDJPY") return 0.008;
            return 0.0001; // 默认1点
            
         case ASSET_CRYPTO:
            return 0.01; // 加密货币波动较大
            
         case ASSET_STOCK_US:
         case ASSET_STOCK_HK:
            return 0.01;
            
         default:
            return 0.0001;
      }
   }
   
   //+------------------------------------------------------------------+
   //| 检查波动率是否异常                                                |
   //+------------------------------------------------------------------+
   bool IsVolatilityAbnormal()
   {
      // 计算最近1小时的波动率
      datetime currentTime = TimeCurrent();
      datetime oneHourAgo = currentTime - 3600;
      
      double rates[];
      int copied = CopyRates(symbolName, PERIOD_M1, oneHourAgo, currentTime, rates);
      
      if(copied < 30) return false; // 数据不足
      
      // 计算波动率
      double high = rates[0].high;
      double low = rates[0].low;
      
      for(int i = 1; i < copied; i++)
      {
         if(rates[i].high > high) high = rates[i].high;
         if(rates[i].low < low) low = rates[i].low;
      }
      
      double currentVolatility = (high - low) / rates[copied-1].close;
      double normalVolatility = GetNormalVolatility();
      
      if(currentVolatility > normalVolatility * volatilityThreshold)
      {
         g_Logger->WriteWarning("波动率异常: 当前=" + DoubleToString(currentVolatility * 100, 2) + 
                           "% 正常=" + DoubleToString(normalVolatility * 100, 2) + "%");
         return true;
      }
      
      return false;
   }
   
   //+------------------------------------------------------------------+
   //| 获取正常波动率                                                    |
   //+------------------------------------------------------------------+
   double GetNormalVolatility()
   {
      // 根据资产类型返回正常波动率
      switch(assetType)
      {
         case ASSET_FOREX:
            return 0.005; // 0.5%
         case ASSET_CRYPTO:
            return 0.02;  // 2%
         case ASSET_STOCK_US:
         case ASSET_STOCK_HK:
            return 0.01;  // 1%
         default:
            return 0.005;
      }
   }
   
   //+------------------------------------------------------------------+
   //| 主要交易允许检查函数                                              |
   //+------------------------------------------------------------------+
   bool IsTradeAllowed()
   {
      // 更新市场状态
      UpdateMarketStatus();
      
      switch(currentMarketStatus)
      {
         case MARKET_ACTIVE:
            return true;
            
         case MARKET_CAUTIOUS:
            g_Logger->WriteInfo("市场状态: 谨慎交易期");
            return true; // 允许交易但需要谨慎
            
         case MARKET_CLOSED:
            g_Logger->WriteDebug("市场状态: 市场关闭");
            return false;
            
         case MARKET_NEWS_AVOID:
            g_Logger->WriteInfo("市场状态: 新闻避开时间");
            return false;
            
         case MARKET_HOLIDAY:
            g_Logger->WriteInfo("市场状态: 节假日");
            return false;
            
         case MARKET_LOW_LIQUIDITY:
            g_Logger->WriteWarning("市场状态: 低流动性");
            return false;
            
         default:
            return false;
      }
   }
   
   //+------------------------------------------------------------------+
   //| 获取市场状态字符串                                                |
   //+------------------------------------------------------------------+
   string GetMarketStatusString()
   {
      switch(currentMarketStatus)
      {
         case MARKET_ACTIVE: return "活跃交易";
         case MARKET_CAUTIOUS: return "谨慎交易";
         case MARKET_CLOSED: return "市场关闭";
         case MARKET_NEWS_AVOID: return "新闻避开";
         case MARKET_HOLIDAY: return "节假日";
         case MARKET_LOW_LIQUIDITY: return "低流动性";
         default: return "未知状态";
      }
   }
   
   //+------------------------------------------------------------------+
   //| 获取资产类型字符串                                                |
   //+------------------------------------------------------------------+
   string GetAssetTypeString()
   {
      switch(assetType)
      {
         case ASSET_FOREX: return "外汇";
         case ASSET_CRYPTO: return "加密货币";
         case ASSET_STOCK_US: return "美股";
         case ASSET_STOCK_HK: return "港股";
         case ASSET_OPTIONS: return "期权";
         case ASSET_FUTURES: return "期货";
         case ASSET_COMMODITIES: return "商品";
         default: return "未知类型";
      }
   }
   
   //+------------------------------------------------------------------+
   //| 获取下一个重要事件信息                                            |
   //+------------------------------------------------------------------+
   string GetNextImportantEvent()
   {
      datetime currentTime = TimeCurrent();
      datetime nextEventTime = 0;
      string nextEventInfo = "";
      
      // 查找最近的重要新闻
      for(int i = 0; i < eventCount; i++)
      {
         if(newsEvents[i].eventTime > currentTime)
         {
            if(nextEventTime == 0 || newsEvents[i].eventTime < nextEventTime)
            {
               nextEventTime = newsEvents[i].eventTime;
               
               string impactStr = "";
               switch(newsEvents[i].impact)
               {
                  case NEWS_CRITICAL: impactStr = "[关键]"; break;
                  case NEWS_HIGH: impactStr = "[高]"; break;
                  case NEWS_MEDIUM: impactStr = "[中]"; break;
                  default: impactStr = "[低]"; break;
               }
               
               int minutesToEvent = (int)((nextEventTime - currentTime) / 60);
               nextEventInfo = impactStr + " " + newsEvents[i].eventName + 
                             " (" + newsEvents[i].currency + ") - " + 
                             IntegerToString(minutesToEvent) + "分钟后";
            }
         }
      }
      
      if(nextEventTime == 0)
         return "未来24小时内无重要新闻事件";
      
      return "下一个重要事件: " + nextEventInfo;
   }
   
   //+------------------------------------------------------------------+
   //| 获取当前交易建议                                                  |
   //+------------------------------------------------------------------+
   string GetTradingAdvice()
   {
      UpdateMarketStatus();
      
      string advice = "市场状态: " + GetMarketStatusString() + "\n";
      
      switch(currentMarketStatus)
      {
         case MARKET_ACTIVE:
            advice += "建议: 正常交易，监控市场变化";
            break;
            
         case MARKET_CAUTIOUS:
            advice += "建议: 谨慎交易，减小仓位，密切关注";
            break;
            
         case MARKET_CLOSED:
            advice += "建议: 市场关闭，等待开盘";
            break;
            
         case MARKET_NEWS_AVOID:
            advice += "建议: 重要新闻期间，避免新开仓";
            break;
            
         case MARKET_HOLIDAY:
            advice += "建议: 节假日期间，市场活跃度低";
            break;
            
         case MARKET_LOW_LIQUIDITY:
            advice += "建议: 流动性不足，避免大额交易";
            break;
      }
      
      advice += "\n" + GetNextImportantEvent();
      
      return advice;
   }
   
   //+------------------------------------------------------------------+
   //| 配置函数 - 设置交易时段                                           |
   //+------------------------------------------------------------------+
   void EnableTradingSession(TRADING_SESSION session, bool enable)
   {
      switch(session)
      {
         case SESSION_ASIA:
            asiaSession.enabled = enable;
            g_Logger->WriteInfo("亚洲时段: " + (enable ? "开启" : "关闭"));
            break;
         case SESSION_EUROPE:
            europeSession.enabled = enable;
            g_Logger->WriteInfo("欧洲时段: " + (enable ? "开启" : "关闭"));
            break;
         case SESSION_AMERICA:
            americaSession.enabled = enable;
            g_Logger->WriteInfo("美洲时段: " + (enable ? "开启" : "关闭"));
            break;
      }
   }
   
   //+------------------------------------------------------------------+
   //| 设置新闻避开时间                                                  |
   //+------------------------------------------------------------------+
   void SetNewsAvoidTime(NEWS_IMPACT_LEVEL level, int beforeMinutes, int afterMinutes)
   {
      switch(level)
      {
         case NEWS_CRITICAL:
            criticalNewsAvoidBefore = beforeMinutes;
            criticalNewsAvoidAfter = afterMinutes;
            break;
         case NEWS_HIGH:
            highNewsAvoidBefore = beforeMinutes;
            highNewsAvoidAfter = afterMinutes;
            break;
         case NEWS_MEDIUM:
            mediumNewsAvoidBefore = beforeMinutes;
            mediumNewsAvoidAfter = afterMinutes;
            break;
      }
      
      g_Logger->WriteInfo("设置新闻避开时间 - 级别:" + IntegerToString(level) + 
                       " 前:" + IntegerToString(beforeMinutes) + 
                       "分钟 后:" + IntegerToString(afterMinutes) + "分钟");
   }
   
   //+------------------------------------------------------------------+
   //| 设置风险控制参数                                                  |
   //+------------------------------------------------------------------+
   void SetRiskParameters(double spreadThreshold, double volThreshold, int cautionMinutes)
   {
      maxSpreadThreshold = spreadThreshold;
      volatilityThreshold = volThreshold;
      marketOpenCautionMinutes = cautionMinutes;
      
      g_Logger->WriteInfo("更新风险参数 - 点差阈值:" + DoubleToString(spreadThreshold, 1) +
                       " 波动率阈值:" + DoubleToString(volThreshold, 1) +
                       " 谨慎期:" + IntegerToString(cautionMinutes) + "分钟");
   }
   
   //+------------------------------------------------------------------+
   //| 启用/禁用功能开关                                                 |
   //+------------------------------------------------------------------+
   void EnableFeature(string featureName, bool enable)
   {
      if(featureName == "WeekendTrading")
         enableWeekendTrading = enable;
      else if(featureName == "HolidayTrading")
         enableHolidayTrading = enable;
      else if(featureName == "NewsAvoid")
         enableNewsAvoid = enable;
      else if(featureName == "MarketOpenCaution")
         enableMarketOpenCaution = enable;
      else if(featureName == "SeasonalAdjust")
         enableSeasonalAdjust = enable;
      else if(featureName == "VolatilityAdapt")
         enableVolatilityAdapt = enable;
      else if(featureName == "LiquidityMonitor")
         enableLiquidityMonitor = enable;
      
      g_Logger->WriteInfo("功能开关 " + featureName + ": " + (enable ? "开启" : "关闭"));
   }
   
   //+------------------------------------------------------------------+
   //| 打印完整的时间管理状态                                            |
   //+------------------------------------------------------------------+
   void PrintTimeManagerStatus()
   {
      g_Logger->WriteInfo("=== EA自适应时间控制状态 ===");
      g_Logger->WriteInfo("交易品种: " + symbolName + " (" + GetAssetTypeString() + ")");
      g_Logger->WriteInfo("当前状态: " + GetMarketStatusString());
      
      if(assetType == ASSET_FOREX)
         g_Logger->WriteInfo("货币对: " + baseCurrency + "/" + quoteCurrency);
      
      g_Logger->WriteInfo("交易时段配置:");
      g_Logger->WriteInfo("  亚洲时段: " + (asiaSession.enabled ? "开启" : "关闭") + 
                       " (" + IntegerToString(asiaSession.startHour) + ":" + 
                       IntegerToString(asiaSession.startMinute) + "-" +
                       IntegerToString(asiaSession.endHour) + ":" +
                       IntegerToString(asiaSession.endMinute) + ")");
      g_Logger->WriteInfo("  欧洲时段: " + (europeSession.enabled ? "开启" : "关闭") +
                       " (" + IntegerToString(europeSession.startHour) + ":" + 
                       IntegerToString(europeSession.startMinute) + "-" +
                       IntegerToString(europeSession.endHour) + ":" +
                       IntegerToString(europeSession.endMinute) + ")");
      g_Logger->WriteInfo("  美洲时段: " + (americaSession.enabled ? "开启" : "关闭") +
                       " (" + IntegerToString(americaSession.startHour) + ":" + 
                       IntegerToString(americaSession.startMinute) + "-" +
                       IntegerToString(americaSession.endHour) + ":" +
                       IntegerToString(americaSession.endMinute) + ")");
      
      g_Logger->WriteInfo("功能开关:");
      g_Logger->WriteInfo("  周末交易: " + (enableWeekendTrading ? "开启" : "关闭"));
      g_Logger->WriteInfo("  节假日交易: " + (enableHolidayTrading ? "关闭" : "关闭"));
      g_Logger->WriteInfo("  新闻避开: " + (enableNewsAvoid ? "开启" : "关闭"));
      g_Logger->WriteInfo("  开盘谨慎: " + (enableMarketOpenCaution ? "开启" : "关闭"));
      g_Logger->WriteInfo("  流动性监控: " + (enableLiquidityMonitor ? "开启" : "关闭"));
      
      g_Logger->WriteInfo("新闻事件: " + IntegerToString(eventCount) + "个");
      g_Logger->WriteInfo("节假日: " + IntegerToString(holidayCount) + "个");
      
      g_Logger->WriteInfo(GetNextImportantEvent());
      g_Logger->WriteInfo("=============================");
   }
   
   //+------------------------------------------------------------------+
   //| 获取期权到期日特殊处理                                            |
   //+------------------------------------------------------------------+
   bool IsOptionsExpiryDate()
   {
      if(assetType != ASSET_OPTIONS)
         return false;
      
      // 这里需要根据期权合约信息判断
      // 简化版本：假设每月第三个周五为到期日
      datetime currentTime = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(currentTime, dt);
      
      // 计算当月第三个周五
      datetime firstDayOfMonth = currentTime - (dt.day - 1) * 86400;
      TimeToStruct(firstDayOfMonth, dt);
      
      int firstFridayOffset = (5 - dt.day_of_week + 7) % 7;
      if(firstFridayOffset == 0 && dt.day_of_week != 5) firstFridayOffset = 7;
      
      datetime thirdFriday = firstDayOfMonth + (firstFridayOffset + 14) * 86400;
      
      // 检查是否为到期日或前一天
      datetime checkDate = currentTime - (currentTime % 86400);
      datetime expiryDate = thirdFriday - (thirdFriday % 86400);
      
      return (checkDate == expiryDate || checkDate == expiryDate - 86400);
   }
};

// 全局时间管理器实例
extern CAdaptiveTimeManager* g_TimeManager;

//+------------------------------------------------------------------+
//| 模块导出函数                                                      |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| 初始化时间管理模块                                                |
//+------------------------------------------------------------------+
bool InitAdaptiveTimeManager()
{
   return g_TimeManager.Initialize();
}

//+------------------------------------------------------------------+
//| 检查是否允许交易                                                  |
//+------------------------------------------------------------------+
bool IsTradeAllowed()
{
   return g_TimeManager.IsTradeAllowed();
}

//+------------------------------------------------------------------+
//| 获取市场状态                                                      |
//+------------------------------------------------------------------+
string GetMarketStatus()
{
   return g_TimeManager.GetMarketStatusString();
}

//+------------------------------------------------------------------+
//| 获取交易建议                                                      |
//+------------------------------------------------------------------+
string GetTradingAdvice()
{
   return g_TimeManager.GetTradingAdvice();
}

//+------------------------------------------------------------------+
//| 获取下一个重要事件                                                |
//+------------------------------------------------------------------+
string GetNextImportantEvent()
{
   return g_TimeManager.GetNextImportantEvent();
}

//+------------------------------------------------------------------+
//| 启用/禁用交易时段                                                 |
//+------------------------------------------------------------------+
void EnableTradingSession(TRADING_SESSION session, bool enable)
{
   g_TimeManager.EnableTradingSession(session, enable);
}

//+------------------------------------------------------------------+
//| 设置新闻避开时间                                                  |
//+------------------------------------------------------------------+
void SetNewsAvoidTime(NEWS_IMPACT_LEVEL level, int beforeMinutes, int afterMinutes)
{
   g_TimeManager.SetNewsAvoidTime(level, beforeMinutes, afterMinutes);
}

//+------------------------------------------------------------------+
//| 设置风险控制参数                                                  |
//+------------------------------------------------------------------+
void SetRiskParameters(double spreadThreshold, double volThreshold, int cautionMinutes)
{
   g_TimeManager.SetRiskParameters(spreadThreshold, volThreshold, cautionMinutes);
}

//+------------------------------------------------------------------+
//| 启用/禁用功能                                                     |
//+------------------------------------------------------------------+
void EnableTimeManagerFeature(string featureName, bool enable)
{
   g_TimeManager.EnableFeature(featureName, enable);
}

//+------------------------------------------------------------------+
//| 打印时间管理器状态                                                |
//+------------------------------------------------------------------+
void PrintTimeManagerStatus()
{
   g_TimeManager.PrintTimeManagerStatus();
}

//+------------------------------------------------------------------+
//| 快速配置预设方案                                                  |
//+------------------------------------------------------------------+
void ApplyPresetConfiguration(string presetName)
{
   if(presetName == "Conservative") // 保守配置
   {
      g_TimeManager.SetNewsAvoidTime(NEWS_CRITICAL, 180, 180); // 3小时
      g_TimeManager.SetNewsAvoidTime(NEWS_HIGH, 90, 120);      // 1.5-2小时
      g_TimeManager.SetNewsAvoidTime(NEWS_MEDIUM, 60, 60);     // 1小时
      g_TimeManager.SetRiskParameters(2.0, 1.5, 45);          // 严格风险控制
      g_TimeManager.EnableFeature("NewsAvoid", true);
      g_TimeManager.EnableFeature("MarketOpenCaution", true);
      g_TimeManager.EnableFeature("LiquidityMonitor", true);
   }
   else if(presetName == "Aggressive") // 激进配置
   {
      g_TimeManager.SetNewsAvoidTime(NEWS_CRITICAL, 60, 60);   // 1小时
      g_TimeManager.SetNewsAvoidTime(NEWS_HIGH, 30, 45);       // 30-45分钟
      g_TimeManager.SetNewsAvoidTime(NEWS_MEDIUM, 15, 15);     // 15分钟
      g_TimeManager.SetRiskParameters(5.0, 3.0, 15);          // 宽松风险控制
      g_TimeManager.EnableFeature("NewsAvoid", true);
      g_TimeManager.EnableFeature("MarketOpenCaution", false);
      g_TimeManager.EnableFeature("LiquidityMonitor", false);
   }
   else if(presetName == "Crypto24h") // 加密货币24小时配置
   {
      g_TimeManager.EnableTradingSession(SESSION_ASIA, true);
      g_TimeManager.EnableTradingSession(SESSION_EUROPE, true);
      g_TimeManager.EnableTradingSession(SESSION_AMERICA, true);
      g_TimeManager.EnableFeature("WeekendTrading", true);
      g_TimeManager.EnableFeature("HolidayTrading", true);
      g_TimeManager.SetNewsAvoidTime(NEWS_HIGH, 30, 60);       // 关注美国新闻
   }
   
   g_Logger->WriteInfo("应用预设配置: " + presetName);
}
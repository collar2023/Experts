//+------------------------------------------------------------------+
//|               SignalPollerEA_Crypto_Pro_v6.1.mq5                 |
//|          加密货币专用版 - 商业级稳健架构 (含自动回补功能)        |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- ==========================================
//--- 1. 基础连接设置
//--- ==========================================
// [重要] 请确保域名为您的 CF Worker 地址，并填写正确的 Token
input string serverUrl            = "https://btc.640001.xyz/get_signal?token=121218679"; 
input int    timerSeconds         = 1;          // 极速轮询
input ulong  magicNumber          = 640004;     // 加密货币专用魔术号 
input bool   manageManualOrders   = true;       // 是否接管手动开出的订单 (Magic=0)

// [核心] 交易品种白名单 (已过滤非加密货币)
// 作用: 决定当前EA实例只管理哪些品种
input string allowedSymbols       = "BTCUSDm,ETHUSDm,SOLUSDm";

//--- ==========================================
//--- 2. 仓位与风控核心参数 (加密货币高波动适配)
//--- ==========================================
input double lotSize              = 0.01;       // 固定手数
input int    maxPositions         = 2;          // 最大持仓数

input group  "=== 动态止损设置 (Crypto) ==="
input double baseStopLossPercent  = 1.5;        // [M15] 平衡型止损 1.5%
input double heavyPosStopLoss     = 1.0;        // [M15] 重仓止损 1.0%
input double hardStopLossPercent  = 5.0;        // [M15] 灾难硬止损 (放宽以允许动态止损工作)

input group  "=== 移动止盈设置 (Crypto) ==="
input bool   trailingStopEnabled  = true;       // 是否开启移动止盈
input double trailingStartPercent = 1.2;        // [M15] 启动阈值 1.2%

input group  "=== 分级回撤宽容度 (Gap) ==="
input double trailGap_Level1      = 0.4;        // [M15] 初期回撤 0.4%
input double trailGap_Level2      = 0.6;        // [M15] 中期回撤 0.6%
input double trailGap_Level3      = 1.0;        // [M15] 后期回撤 1.0%

input group  "=== 自动回补进场 (Auto Re-Entry) ==="
input bool   enableReEntry        = true;       // 是否开启趋势回调补单
input double reEntryPullbackPct   = 0.3;        // 回调触发阈值% (加密货币建议稍大，如0.3%)
input int    maxReEntryTimes      = 2;          // 单个信号允许补单次数
input int    reEntryCooldown      = 60;         // 补单冷却时间(秒)

//--- ==========================================
//--- 3. 通知与日志
//--- ==========================================
input bool enablePushNotification = true;
input bool enableHeartbeatPush = true;
input int  heartbeatInterval = 3600;
input bool enableDetailedLog = true;
input bool enablePnLSummaryPush = true;
input int  pnLSummaryInterval = 21600;

//--- 持仓追踪结构体
struct PositionTracker
{
   ulong    ticket;
   string   symbol;
   double   highestPnl;
   bool     isActive;
   datetime lastHeartbeatTime;
   bool     startLogSent;
};

//--- 补单追踪结构体
struct ReEntryTask {
   string   symbol;
   long     type;          // 原持仓方向 (POSITION_TYPE_BUY/SELL)
   double   exitPrice;     // 出场价格
   string   signalId;      // 关联的信号ID
   int      count;         // 已补单次数
   datetime lastExitTime;  // 上次出场时间
   bool     active;        // 任务是否激活
};

//--- 全局变量
CTrade trade;
string lastSignalId = "";
int currentSignalReEntryCount = 0; // 全局计数器：当前信号周期的累计补单次数
PositionTracker trackers[];
ReEntryTask reEntries[];

//+------------------------------------------------------------------+
//| 辅助：内存清理                                                   |
//+------------------------------------------------------------------+
void CompactTrackers()
{
   int writeIndex = 0;
   int total = ArraySize(trackers);
   for(int i = 0; i < total; i++)
   {
      if(trackers[i].isActive)
      {
         if(i != writeIndex) trackers[writeIndex] = trackers[i];
         writeIndex++;
      }
   }
   if(writeIndex < total) ArrayResize(trackers, writeIndex);
}

void CompactReEntries()
{
   int writeIndex = 0;
   int total = ArraySize(reEntries);
   for(int i = 0; i < total; i++)
   {
      if(reEntries[i].active)
      {
         if(i != writeIndex) reEntries[writeIndex] = reEntries[i];
         writeIndex++;
      }
   }
   if(writeIndex < total) ArrayResize(reEntries, writeIndex);
}

//+------------------------------------------------------------------+
//| 从文件加载上次的信号ID                                            |
//+------------------------------------------------------------------+
string LoadLastSignalId()
{
   string filename = "LastSignalID_" + IntegerToString(magicNumber) + ".txt";
   int handle = FileOpen(filename, FILE_READ|FILE_TXT);
   if(handle != INVALID_HANDLE)
   {
      string savedId = FileReadString(handle);
      FileClose(handle);
      if(StringLen(savedId) > 0) return savedId;
   }
   return "";
}

//+------------------------------------------------------------------+
//| 保存当前信号ID到文件                                              |
//+------------------------------------------------------------------+
void SaveLastSignalId(string signalId)
{
   string filename = "LastSignalID_" + IntegerToString(magicNumber) + ".txt";
   int handle = FileOpen(filename, FILE_WRITE|FILE_TXT);
   if(handle != INVALID_HANDLE)
   {
      FileWriteString(handle, signalId);
      FileClose(handle);
   }
}

//+------------------------------------------------------------------+
//| 初始化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("========================================");
   Print("EA 初始化 - 加密货币专用版 v6.1 (含回补)"); 
   Print("========================================");
   if(StringFind(serverUrl, "token=") == -1)
      Print("⚠️ 警告: Server URL 似乎未包含 ?token=... 参数！");

   lastSignalId = LoadLastSignalId();
   currentSignalReEntryCount = 0;

   ArrayResize(trackers, 0);
   ArrayResize(reEntries, 0);
   
   // 扫描现有持仓 (带白名单过滤)
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         long magic = PositionGetInteger(POSITION_MAGIC);
         string symbol = PositionGetString(POSITION_SYMBOL);

         // 直接使用 allowedSymbols 常量进行判断
         if( (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             (allowedSymbols=="" || StringFind(allowedSymbols, symbol)!=-1) )
         {
            GetOrCreateTracker(ticket, symbol);
            Print("🔍 识别到现有持仓: ", symbol, " Ticket=", ticket);
         }
      }
   }
   
   EventSetTimer(timerSeconds);
   trade.SetExpertMagicNumber(magicNumber);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); ArrayFree(trackers); ArrayFree(reEntries); }

//+------------------------------------------------------------------+
//| OnTick - 实时风控与回补监控                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   CleanupClosedPositions();
   
   // 1. 现有持仓风控
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         long magic = PositionGetInteger(POSITION_MAGIC);
         string symbol = PositionGetString(POSITION_SYMBOL);

         // 实时风控白名单过滤
         if( (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             (allowedSymbols=="" || StringFind(allowedSymbols, symbol)!=-1) )
         {
            ManageRisk(symbol, ticket);
         }
      }
   }
   
   // 2. 自动回补逻辑
   if(enableReEntry) CheckReEntry();
}

//+------------------------------------------------------------------+
//| OnTimer - 轮询信号                                               |
//+------------------------------------------------------------------+
void OnTimer()
{
   CompactTrackers();
   CompactReEntries();

   uchar post[], result[];
   string response_headers;
   ResetLastError();
   
   int res = WebRequest("GET", serverUrl, "", 2000, post, result, response_headers);
   if(res==200)
   {
      string jsonResponse = CharArrayToString(result);
      if(StringLen(jsonResponse)==0) return;

      string newSignalId = ParseJsonValue(jsonResponse,"signal_id");
      if(newSignalId!="" && newSignalId!=lastSignalId)
      {
         string symbol = ParseJsonValue(jsonResponse,"symbol");
         // 非白名单信号，跳过但必须更新 ID，防止死循环
         if(allowedSymbols!="" && StringFind(allowedSymbols, symbol)==-1)
         {
             lastSignalId = newSignalId;
             SaveLastSignalId(newSignalId);
             currentSignalReEntryCount = 0; // 重置
             return;
         }

         lastSignalId = newSignalId;
         SaveLastSignalId(newSignalId);
         
         // 新信号到来:
         // 1. 清空所有基于旧信号的补单任务
         ArrayResize(reEntries, 0); 
         // 2. 归零补单计数器
         currentSignalReEntryCount = 0;
         
         string side   = ParseJsonValue(jsonResponse,"side");
         double qty    = StringToDouble(ParseJsonValue(jsonResponse, "qty"));
         string msg = ">>> 收到新信号\nID=" + lastSignalId + "\n品种=" + symbol + "\n方向=" + side;
         Print(msg);
         SendPushNotification(msg);

         ExecuteTrade(symbol, side, qty, ""); // 正常信号开单
      }
   }
   else if(res == 401)
   {
      static bool alerted401 = false;
      if(!alerted401) {
         Print("❌ 鉴权失败 (401): 请检查 Token！");
         alerted401 = true;
      }
   }
}

//+------------------------------------------------------------------+
//| 注册回补任务                                                      |
//+------------------------------------------------------------------+
void RegisterReEntryTask(string symbol, long type, double exitPrice)
{
    if(!enableReEntry) return;

    // 严格校验：如果当前信号周期内补单次数已达上限，直接拒绝
    if(currentSignalReEntryCount >= maxReEntryTimes) {
        Print("⛔ [回补拒绝] ", symbol, " 当前信号周期补单已达上限 (", currentSignalReEntryCount, "/", maxReEntryTimes, ")");
        return;
    }

    int index = -1;
    for(int i=0; i<ArraySize(reEntries); i++) {
        if(reEntries[i].symbol == symbol && reEntries[i].active) {
            index = i;
            break;
        }
    }
    
    if(index == -1) {
        index = ArraySize(reEntries);
        ArrayResize(reEntries, index + 1);
        reEntries[index].count = 0; 
    }
    
    reEntries[index].symbol       = symbol;
    reEntries[index].type         = type;
    reEntries[index].exitPrice    = exitPrice;
    reEntries[index].signalId     = lastSignalId;
    reEntries[index].lastExitTime = TimeCurrent();
    reEntries[index].active       = true;

    double targetPrice = 0;
    if(type == POSITION_TYPE_BUY) targetPrice = exitPrice * (1.0 - reEntryPullbackPct/100.0);
    else targetPrice = exitPrice * (1.0 + reEntryPullbackPct/100.0);

    Print("🔄 [回补] 任务已注册: ", symbol, 
          " 方向=", (type==POSITION_TYPE_BUY?"Buy":"Sell"), 
          " 目标价<=", DoubleToString(targetPrice, 2),
          " (Pct:", reEntryPullbackPct, "%, Count:", currentSignalReEntryCount, ")");
}

//+------------------------------------------------------------------+
//| 检查回补条件                                                      |
//+------------------------------------------------------------------+
void CheckReEntry()
{
    for(int i=0; i<ArraySize(reEntries); i++) {
        if(!reEntries[i].active) continue;

        if(reEntries[i].signalId != lastSignalId) {
            reEntries[i].active = false;
            continue;
        }

        if(TimeCurrent() - reEntries[i].lastExitTime < reEntryCooldown) continue;
        
        // 双重校验
        if(currentSignalReEntryCount >= maxReEntryTimes) {
             reEntries[i].active = false;
             return;
        }

        string symbol = reEntries[i].symbol;
        if(!SymbolInfoInteger(symbol, SYMBOL_SELECT)) SymbolSelect(symbol, true);

        double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
        double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
        
        bool triggered = false;
        double targetPrice = 0;

        if(reEntries[i].type == POSITION_TYPE_BUY) {
            targetPrice = reEntries[i].exitPrice * (1.0 - reEntryPullbackPct/100.0);
            if(ask <= targetPrice && ask > 0) triggered = true;
        } 
        else if(reEntries[i].type == POSITION_TYPE_SELL) {
            targetPrice = reEntries[i].exitPrice * (1.0 + reEntryPullbackPct/100.0);
            if(bid >= targetPrice && bid > 0) triggered = true;
        }

        if(triggered) {
            Print("⚡ [回补] 触发进场: ", symbol, " 现价=", (reEntries[i].type==POSITION_TYPE_BUY?DoubleToString(ask,2):DoubleToString(bid,2)), 
                  " 目标价=", DoubleToString(targetPrice, 2));
            
            string side = (reEntries[i].type == POSITION_TYPE_BUY) ? "buy" : "sell";
            
            // ✅ 改动 1: 执行后根据返回值判断是否计数
            ulong dealTicket = 0;
            if(ExecuteTrade(symbol, side, 0, "[ReEntry]", dealTicket)) {
                currentSignalReEntryCount++;
                reEntries[i].active = false; 
                string msg = "🔄 自动回补执行成功: " + symbol + " (累计:" + IntegerToString(currentSignalReEntryCount) + "/" + IntegerToString(maxReEntryTimes) + ")";
                SendPushNotification(msg);
            } else {
                Print("⚠️ [回补] 交易执行失败，等待下一次 tick 重试。");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 执行交易 (改动: 返回 bool + 3次重试)                             |
//+------------------------------------------------------------------+
bool ExecuteTrade(string symbol, string side, double qty, string comment = "", ulong &outDealTicket = 0) 
{
   if(!SymbolInfoInteger(symbol, SYMBOL_SELECT)) {
      if(!SymbolSelect(symbol, true)) {
         Print("❌ 严重错误: 品种 ", symbol, " 不存在或不可交易");
         return false;
      }
   }

   // 执行层二次白名单校验
   if(allowedSymbols != "" && StringFind(allowedSymbols, symbol) == -1) {
      Print("⚠️ [二次拦截] 品种 ", symbol, " 不在白名单内，跳过交易");
      return false;
   }

   string lockName = "TRADE_LOCK_" + symbol + "_" + side;
   if(GlobalVariableCheck(lockName)) {
      if(TimeCurrent() - (datetime)GlobalVariableGet(lockName) < 10) return false;
   }
   GlobalVariableSet(lockName, (double)TimeCurrent());
   
   double tradeQty = qty > 0 ? qty : lotSize;
   bool isBuy = (StringCompare(side, "buy", false) == 0);
   bool isSell = (StringCompare(side, "sell", false) == 0);
   bool result = false;

   if(isBuy)
   {
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_SELL) > 0) {
         if(!CloseAllPositionsByType(symbol, POSITION_TYPE_SELL)) {
             Print("❌ 反手平仓(Sell)失败，为了安全，取消开(Buy)新仓");
             GlobalVariableDel(lockName);
             return false;
         }
      }
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_BUY) < maxPositions) {
         // 硬止损 (1% 或 5% 视参数而定)
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double slPrice = ask * (1.0 - hardStopLossPercent / 100.0);
         
         // ✅ 改动 3: 3次重试机制
         for(int i=0; i<3; i++) {
             if(trade.Buy(tradeQty, symbol, ask, slPrice, 0, comment)) {
                 Print("✅ 买入成功: ", symbol, " 硬止损=", DoubleToString(slPrice, 2), " ", comment, " Deal=", trade.ResultDeal());
                 outDealTicket = trade.ResultDeal();
                 result = true;
                 break;
             } else {
                 Print("⚠️ 买入失败(尝试 ", i+1, "/3): ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
                 Sleep(200);
                 ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
                 slPrice = ask * (1.0 - hardStopLossPercent / 100.0);
             }
         }
      }
   } 
   else if(isSell)
   {
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_BUY) > 0) {
         if(!CloseAllPositionsByType(symbol, POSITION_TYPE_BUY)) {
             Print("❌ 反手平仓(Buy)失败，为了安全，取消开(Sell)新仓");
             GlobalVariableDel(lockName);
             return false;
         }
      }
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_SELL) < maxPositions) {
         // 硬止损
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double slPrice = bid * (1.0 + hardStopLossPercent / 100.0);
         
         // ✅ 改动 3: 3次重试机制
         for(int i=0; i<3; i++) {
             if(trade.Sell(tradeQty, symbol, bid, slPrice, 0, comment)) {
                 Print("✅ 卖出成功: ", symbol, " 硬止损=", DoubleToString(slPrice, 2), " ", comment, " Deal=", trade.ResultDeal());
                 outDealTicket = trade.ResultDeal();
                 result = true;
                 break;
             } else {
                 Print("⚠️ 卖出失败(尝试 ", i+1, "/3): ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
                 Sleep(200);
                 bid = SymbolInfoDouble(symbol, SYMBOL_BID);
                 slPrice = bid * (1.0 + hardStopLossPercent / 100.0);
             }
         }
      }
   }
   
   GlobalVariableDel(lockName);
   return result;
}

//+------------------------------------------------------------------+
//| 风险管理 (核心逻辑)                                               |
//+------------------------------------------------------------------+
void ManageRisk(string symbol, ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;

   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume = PositionGetDouble(POSITION_VOLUME);
   long type = PositionGetInteger(POSITION_TYPE);
   if(entryPrice==0.0) return;

   double currentPrice = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol,SYMBOL_BID) : SymbolInfoDouble(symbol,SYMBOL_ASK);
   double pnlPercent = (currentPrice - entryPrice) * ((type==POSITION_TYPE_BUY)?1:-1) / entryPrice * 100.0;

   int trackerIndex = GetOrCreateTracker(ticket, symbol);
   if(trackerIndex < 0 || trackerIndex >= ArraySize(trackers)) return;

   // 峰值更新
   if(pnlPercent > trackers[trackerIndex].highestPnl)
   {
      double oldHigh = trackers[trackerIndex].highestPnl;
      trackers[trackerIndex].highestPnl = pnlPercent;
      
      string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
      GlobalVariableSet(gvName, trackers[trackerIndex].highestPnl);
      
      if(oldHigh > 0 && pnlPercent - oldHigh > 0.5)
         Print("📈 ", symbol, " 新高:", DoubleToString(pnlPercent, 2), "%");
   }

   // 1. 动态止损 (使用加密货币专用参数)
   double currentStopLoss = baseStopLossPercent;
   if(volume > 0.05) currentStopLoss = heavyPosStopLoss;
   if(pnlPercent < -currentStopLoss)
   {
      if(TryPositionClose(ticket, symbol)) // ✅ 使用带重试的平仓
      {
         string msg = symbol + " 🛑 止损平仓 (Crypto)\n亏损:" + DoubleToString(pnlPercent, 2) + "%";
         SendPushNotification(msg);
         trackers[trackerIndex].isActive = false;
         
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
         GlobalVariableDel(gvName);
         // 注意：止损不触发回补
      }
      return;
   }

   // 2. 保本逻辑
   double breakEvenTrigger = (trailingStartPercent < 0.8) ? 0.8 : trailingStartPercent; // [M15] 动态调整保本触发线 (下调至 0.8%)
   if(pnlPercent >= breakEvenTrigger)
   {
      double breakEvenPrice = entryPrice;
      double currentSL = PositionGetDouble(POSITION_SL);
      bool needBreakEven = false;
      double protectBuffer = SymbolInfoDouble(symbol, SYMBOL_POINT) * 2000; // [M15-BTC] 提高缓冲至 2000 点，覆盖 BTC 高额点差与手续费

      if(type == POSITION_TYPE_BUY)
      {
         if(currentSL == 0 || currentSL < breakEvenPrice - protectBuffer) needBreakEven = true;
      }
      else
      {
         if(currentSL > breakEvenPrice + protectBuffer || currentSL == 0) needBreakEven = true;
      }
      if(needBreakEven)
      {
         if(trade.PositionModify(ticket, breakEvenPrice, 0))
            Print(symbol, " 🔒 保本已设置");
      }
   }

   // 3. 移动止盈 (使用加密货币专用参数)
   if(trailingStopEnabled && trackers[trackerIndex].highestPnl >= trailingStartPercent)
   {
      if(!trackers[trackerIndex].startLogSent)
      {
         SendPushNotification(symbol + " 🚀 移动止盈启动 (Crypto Mode)");
         trackers[trackerIndex].startLogSent = true;
      }
      double drawdown = trackers[trackerIndex].highestPnl - pnlPercent;
      double currentGap = 0.0;
      
      // 加密货币分级回撤
      if(trackers[trackerIndex].highestPnl < 3.5) currentGap = trailGap_Level1; // 0.8
      else if(trackers[trackerIndex].highestPnl < 6.0) currentGap = trailGap_Level2; // 1.2
      else currentGap = trailGap_Level3; // 2.0
      
      if(drawdown >= currentGap)
      {
         // 准备出场前获取信息，用于回补
         double exitPrice = currentPrice;
         
         if(TryPositionClose(ticket, symbol)) // ✅ 使用带重试的平仓
         {
            // ✅ 改动 2: 获取真实成交价
            ulong deal = trade.ResultDeal();
            if(deal > 0) {
                if(HistoryDealSelect(deal)) {
                    double realPrice = HistoryDealGetDouble(deal, DEAL_PRICE);
                    if(realPrice > 0) {
                        exitPrice = realPrice;
                        Print("📉 真实平仓价获取成功: ", exitPrice, " (原参考价: ", currentPrice, ")");
                    }
                }
            } else {
               Print("⚠️ 警告: 无法获取平仓 Deal Ticket, 使用参考价: ", exitPrice);
            }

            string msg = symbol + " 📈 止盈平仓\n获利:" + DoubleToString(pnlPercent, 2) + "%";
            SendPushNotification(msg);
            trackers[trackerIndex].isActive = false;
            
            string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
            GlobalVariableDel(gvName);
            
            // 触发自动回补逻辑
            RegisterReEntryTask(symbol, type, exitPrice);
         }
      }
   }
   
   // 心跳推送
   if(enableHeartbeatPush)
   {
      datetime timeSinceLastHeartbeat = TimeCurrent() - trackers[trackerIndex].lastHeartbeatTime;
      if(timeSinceLastHeartbeat >= heartbeatInterval)
      {
         string trailingStatus = (trackers[trackerIndex].highestPnl >= trailingStartPercent) ?
         "✅ 已启动" : "⏳ 待启动";
         string msg = "💓 Crypto EA心跳 (" + IntegerToString(magicNumber) + ")\n" +
                      symbol + "\n" +
                      "当前: " + DoubleToString(pnlPercent, 2) + "%";
         SendPushNotification(msg);
         trackers[trackerIndex].lastHeartbeatTime = TimeCurrent();
      }
   }
}

// ✅ 封装带重试的平仓函数
bool TryPositionClose(ulong ticket, string symbol) {
   for(int i=0; i<3; i++) {
      if(trade.PositionClose(ticket)) return true;
      Print("⚠️ 平仓失败(尝试 ", i+1, "/3): ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      Sleep(200);
   }
   Print("❌ 平仓彻底失败: Ticket=", ticket);
   return false;
}

// --- 辅助函数 (保持架构稳定性) ---
int GetOrCreateTracker(ulong ticket, string symbol) {
   int total = ArraySize(trackers);
   for(int i=0; i<total; i++) if(trackers[i].ticket == ticket && trackers[i].isActive) return i;
   for(int i=0; i<total; i++) if(!trackers[i].isActive) {
         trackers[i].ticket = ticket; trackers[i].symbol = symbol;
         trackers[i].isActive = true; trackers[i].lastHeartbeatTime = 0; trackers[i].startLogSent = false;
         
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
         trackers[i].highestPnl = GlobalVariableCheck(gvName) ? GlobalVariableGet(gvName) : 0.0;
         return i;
   }
   int size = ArraySize(trackers); ArrayResize(trackers, size+1);
   trackers[size].ticket = ticket; trackers[size].symbol = symbol; trackers[size].isActive = true; trackers[size].lastHeartbeatTime = 0; trackers[size].startLogSent = false; 
   
   string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
   trackers[size].highestPnl = GlobalVariableCheck(gvName) ? GlobalVariableGet(gvName) : 0.0;
   return size;
}

void CleanupClosedPositions() {
   for(int i=ArraySize(trackers)-1; i>=0; i--) {
      if(!trackers[i].isActive) continue;
      if(!PositionSelectByTicket(trackers[i].ticket)) {
         
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(trackers[i].ticket) + "_PNL";
         GlobalVariableDel(gvName);
         trackers[i].isActive = false;
      }
   }
}

int CountPositionsBySymbol(string symbol, ENUM_POSITION_TYPE posType = -1) {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         // 计数下沉白名单
         if( posSymbol == symbol && 
             (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             (allowedSymbols=="" || StringFind(allowedSymbols, posSymbol)!=-1) ) 
         {
            if(posType == -1) count++;
            else if(PositionGetInteger(POSITION_TYPE) == posType) count++;
         }
      }
   }
   return count;
}

bool CloseAllPositionsByType(string symbol, ENUM_POSITION_TYPE posType) {
   bool allClosed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         long posType_actual = PositionGetInteger(POSITION_TYPE);
         
         // 平仓下沉白名单
         if( posSymbol == symbol && 
             (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             posType_actual == posType &&
             (allowedSymbols=="" || StringFind(allowedSymbols, posSymbol)!=-1) ) 
         {
            if(TryPositionClose(ticket, symbol)) { // ✅ 使用带重试的平仓
               Print("✅ 平仓成功: Ticket=", ticket);
               for(int j=0; j<ArraySize(trackers); j++) if(trackers[j].ticket == ticket) {
                  trackers[j].isActive = false; 
                  
                  string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
                  GlobalVariableDel(gvName);
               }
            } else {
               allClosed = false;
            }
            Sleep(100);
         }
      }
   }
   return allClosed;
}

string ParseJsonValue(string json, string key) {
   string sk_string = "\"" + key + "\":\"";
   int p1 = StringFind(json, sk_string);
   if(p1 != -1) {
      int p2 = StringFind(json, "\"", p1 + StringLen(sk_string));
      if(p2 != -1) return StringSubstr(json, p1 + StringLen(sk_string), p2 - (p1 + StringLen(sk_string)));
   }
   string sk_number = "\"" + key + "\":";
   p1 = StringFind(json, sk_number);
   if(p1 != -1) {
      int start = p1 + StringLen(sk_number);
      string remaining = StringSubstr(json, start);
      int idx = 0;
      while(idx < StringLen(remaining) && (StringGetCharacter(remaining, idx) == 32 || StringGetCharacter(remaining, idx) == 91)) idx++;
      int value_start = idx;
      while(idx < StringLen(remaining)) {
         ushort ch = StringGetCharacter(remaining, idx);
         if(ch == 44 || ch == 125 || ch == 93) break;
         idx++;
      }
      if(idx > value_start) return StringSubstr(remaining, value_start, idx - value_start);
   }
   return "";
}

void SendPushNotification(string message) {
   if(!enablePushNotification) return;
   SendNotification(message);
}

//+------------------------------------------------------------------+
//|              SignalPollerEA_Index_Plus_v6.0.mq5                  |
//|              指数通用版 - 商业级稳健架构 (最终定稿)                |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- ==========================================
//--- 1. 基础连接设置
//--- ==========================================
// [重要] 请在 URL 后加上 ?token=您的Token
input string serverUrl            = "https://index.460001.xyz/get_signal?token=121218679";
input int    timerSeconds         = 3;          // ✅ 极速轮询
input ulong  magicNumber          = 640003;     // 指数魔术号
input bool   manageManualOrders   = true;       // ✅ 是否接管手动开出的订单 (Magic=0)

// ✅ [核心] 交易品种白名单 (请严格输入: 区分大小写，不要加空格)
// 作用: 决定当前EA实例只管理哪些品种
input string allowedSymbols       = "USTECm,JP225m,UK100m,DE30m,HK50m";

//--- ==========================================
//--- 2. 仓位与风控核心参数 (指数特调)
//--- ==========================================
input double lotSize              = 0.01;
input int    maxPositions         = 2;

input group  "=== 动态止损 (Index) ==="
input double baseStopLossPercent  = 2.3;        // 纳指波动大，默认 2.3%
input double heavyPosStopLoss     = 2.5;        // 重仓止损 (建议宽松)
input double hardStopLossPercent  = 1.0;        // ✅ [新增] 开仓硬止损 (1%)

input group  "=== 移动止盈 (Index) ==="
input bool   trailingStopEnabled  = true;
input double trailingStartPercent = 1.2;        // 1.2% 才启动，过滤噪音

input group  "=== 分级回撤 (Index) ==="
input double trailGap_Level1      = 1.2;        // 盈利 < 2.5%
input double trailGap_Level2      = 1.5;        // 盈利 2.5% - 5.0%
input double trailGap_Level3      = 2.0;        // 盈利 > 5.0% (大趋势)

//--- ==========================================
//--- 3. 通知与日志
//--- ==========================================
input bool enablePushNotification = true;
input bool enableHeartbeatPush = true;
input int  heartbeatInterval = 3600;
input bool enableDetailedLog = true;
input bool enablePnLSummaryPush = true;
input int  pnLSummaryInterval = 21600;

struct PositionTracker {
   ulong ticket;
   string symbol;
   double highestPnl;
   bool isActive;
   datetime lastHeartbeatTime;
   bool startLogSent;
};

CTrade trade;
string lastSignalId = "";
PositionTracker trackers[];

//+------------------------------------------------------------------+
//| 辅助：内存清理 (修复 #8)                                          |
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
//| 交易时段检查 (指数版独有核心)                                     |
//+------------------------------------------------------------------+
bool IsInTradingSession(string symbol)
{
   long trade_mode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(trade_mode == 0 || trade_mode == 3) return false; // 禁用或只平
   
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return false; // 无报价即休市

   return true;
}

//+------------------------------------------------------------------+
//| 初始化                                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("========================================");
   Print("EA 初始化 - 指数极速版 v6.0 (稳健架构)");
   Print("========================================");
   if(StringFind(serverUrl, "token=") == -1)
      Print("⚠️ 警告: Server URL 似乎未包含 ?token=... 参数！");

   lastSignalId = LoadLastSignalId();
   ArrayResize(trackers, 0);
   
   // 扫描现有持仓
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         long magic = PositionGetInteger(POSITION_MAGIC);
         string symbol = PositionGetString(POSITION_SYMBOL);

         // 🔥 修改点 1: 初始化扫描时，下沉白名单过滤
         if( (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             (allowedSymbols=="" || StringFind(allowedSymbols, symbol)!=-1) )
         {
            GetOrCreateTracker(ticket, symbol);
            Print("🔍 识别到现有持仓: ", symbol, " Ticket=", ticket, (magic==0?" (手动)":" (自动)"));
         }
      }
   }
   
   // 检查时段
   string test_symbols[] = {"USTEC", "USTECm", "NAS100", "HK50", "HSI50"};
   for(int i = 0; i < ArraySize(test_symbols); i++)
   {
      if(SymbolSelect(test_symbols[i], true)) IsInTradingSession(test_symbols[i]);
   }
   
   EventSetTimer(timerSeconds);
   trade.SetExpertMagicNumber(magicNumber);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); ArrayFree(trackers); }

//+------------------------------------------------------------------+
//| OnTick - 实时风控 (无延迟)                                       |
//+------------------------------------------------------------------+
void OnTick()
{
   CleanupClosedPositions();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         long magic = PositionGetInteger(POSITION_MAGIC);
         string symbol = PositionGetString(POSITION_SYMBOL);

         // 🔥 修改点 2: 实时风控时，下沉白名单过滤
         if( (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             (allowedSymbols=="" || StringFind(allowedSymbols, symbol)!=-1) )
         {
            ManageRisk(symbol, ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnTimer - 轮询信号 (修复 #2)                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   // 定期清理内存
   CompactTrackers();

   // 核心轮询
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
         
         // 🔥 修复 #2: 非白名单信号，跳过但必须更新 ID，防止死循环
         if(allowedSymbols!="" && StringFind(allowedSymbols, symbol)==-1) 
         {
             lastSignalId = newSignalId;
             SaveLastSignalId(newSignalId);
             return;
         }

         lastSignalId = newSignalId;
         SaveLastSignalId(newSignalId);
         
         string side   = ParseJsonValue(jsonResponse,"side");
         double qty    = StringToDouble(ParseJsonValue(jsonResponse, "qty"));
         string msg = ">>> 收到新信号\nID=" + lastSignalId + "\n品种=" + symbol + "\n方向=" + side;
         Print(msg);
         SendPushNotification(msg);

         ExecuteTrade(symbol, side, qty);
      }
   }
   else if(res == 401)
   {
      static bool alerted401 = false;
      if(!alerted401) {
         Print("❌ 鉴权失败 (401): 请检查 Token！");
         SendPushNotification("❌ 指数EA鉴权失败: Token无效");
         alerted401 = true;
      }
   }
}

//+------------------------------------------------------------------+
//| 风险管理 (指数参数化版)                                           |
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
      trackers[trackerIndex].highestPnl = pnlPercent;
      // ✅ [新增] 持久化最高点
      string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
      GlobalVariableSet(gvName, trackers[trackerIndex].highestPnl);
   }

   // 1. 动态止损
   double currentStopLoss = baseStopLossPercent;
   if(volume > 0.5) currentStopLoss = heavyPosStopLoss;
   if(pnlPercent < -currentStopLoss)
   {
      if(trade.PositionClose(ticket))
      {
         string msg = symbol + " 🛑 指数止损\n亏损:" + DoubleToString(pnlPercent, 2) + "%";
         SendPushNotification(msg);
         trackers[trackerIndex].isActive = false;
         // ✅ [清理] 删除持久化变量
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
         GlobalVariableDel(gvName);
      }
      return;
   }

   // 2. 保本 (指数建议 1.5% 后保本)
   double breakEvenTrigger = (trailingStartPercent < 1.5) ? 1.5 : trailingStartPercent;
   
   if(pnlPercent >= breakEvenTrigger)
   {
      double breakEvenPrice = entryPrice;
      double currentSL = PositionGetDouble(POSITION_SL);
      bool needBreakEven = false;
      double protectBuffer = SymbolInfoDouble(symbol, SYMBOL_POINT) * 100; // [Exness-Index] 100点缓冲 // 指数20点缓冲

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

   // 3. 移动止盈 (参数化)
   if(trailingStopEnabled && trackers[trackerIndex].highestPnl >= trailingStartPercent)
   {
      if(!trackers[trackerIndex].startLogSent)
      {
         SendPushNotification(symbol + " 🚀 指数追踪启动");
         trackers[trackerIndex].startLogSent = true;
      }
      
      double drawdown = trackers[trackerIndex].highestPnl - pnlPercent;
      double currentGap = 0.0;
      
      if(trackers[trackerIndex].highestPnl < 2.5) 
         currentGap = trailGap_Level1;
      else if(trackers[trackerIndex].highestPnl < 5.0) 
         currentGap = trailGap_Level2;
      else 
         currentGap = trailGap_Level3;
      if(drawdown >= currentGap)
      {
         if(trade.PositionClose(ticket))
         {
            string msg = symbol + " 📈 指数止盈\n获利:" + DoubleToString(pnlPercent, 2) + "%";
            SendPushNotification(msg);
            trackers[trackerIndex].isActive = false;
            // ✅ [清理] 删除持久化变量
            string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
            GlobalVariableDel(gvName);
         }
      }
   }
   
   // 心跳推送
   if(enableHeartbeatPush)
   {
      datetime timeSinceLastHeartbeat = TimeCurrent() - trackers[trackerIndex].lastHeartbeatTime;
      if(timeSinceLastHeartbeat >= heartbeatInterval)
      {
         string trailingStatus = (trackers[trackerIndex].highestPnl >= trailingStartPercent) ? "✅ 已启动" : "⏳ 待启动";
         string msg = "💓 指数EA心跳\n" +
                      symbol + "\n" +
                      "当前: " + DoubleToString(pnlPercent, 2) + "%";
         SendPushNotification(msg);
         trackers[trackerIndex].lastHeartbeatTime = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//| 辅助函数集合 (完整版)                                             |
//+------------------------------------------------------------------+
int GetOrCreateTracker(ulong ticket, string symbol)
{
   int total = ArraySize(trackers);
   for(int i=0; i<total; i++)
   {
      if(trackers[i].ticket == ticket && trackers[i].isActive) return i;
   }
   for(int i=0; i<total; i++)
   {
      if(!trackers[i].isActive)
      {
         trackers[i].ticket = ticket;
         trackers[i].symbol = symbol;
         trackers[i].isActive = true;
         trackers[i].lastHeartbeatTime = 0;
         trackers[i].startLogSent = false;
         
         // ✅ [新增] 恢复持久化最高盈利
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
         trackers[i].highestPnl = GlobalVariableCheck(gvName) ? GlobalVariableGet(gvName) : 0.0;
         return i;
      }
   }
   int size = ArraySize(trackers);
   ArrayResize(trackers, size+1);
   trackers[size].ticket = ticket;
   trackers[size].symbol = symbol;
   trackers[size].isActive = true;
   trackers[size].lastHeartbeatTime = 0;
   trackers[size].startLogSent = false;
   
   // ✅ [新增] 恢复持久化最高盈利
   string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
   trackers[size].highestPnl = GlobalVariableCheck(gvName) ? GlobalVariableGet(gvName) : 0.0;
   return size;
}

void CleanupClosedPositions()
{
   for(int i=ArraySize(trackers)-1; i>=0; i--)
   {
      if(!trackers[i].isActive) continue;
      if(!PositionSelectByTicket(trackers[i].ticket)) { 
         // ✅ [清理] 
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(trackers[i].ticket) + "_PNL";
         GlobalVariableDel(gvName);
         trackers[i].isActive = false;
      }
   }
}

int CountPositionsBySymbol(string symbol, ENUM_POSITION_TYPE posType = -1)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         
         // 🔥 修改点 4: 计数逻辑下沉白名单
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

bool CloseAllPositionsByType(string symbol, ENUM_POSITION_TYPE posType)
{
   bool allClosed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         long posType_actual = PositionGetInteger(POSITION_TYPE);
         
         // 🔥 修改点 5: 反手平仓逻辑下沉白名单
         if( posSymbol == symbol && 
             (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             posType_actual == posType &&
             (allowedSymbols=="" || StringFind(allowedSymbols, posSymbol)!=-1) )
         {
            if(trade.PositionClose(ticket))
            {
               Print("✅ 平仓成功: Ticket=", ticket);
               for(int j=0; j<ArraySize(trackers); j++) {
                  if(trackers[j].ticket == ticket) {
                     trackers[j].isActive = false;
                     // ✅ [清理] 
                     string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
                     GlobalVariableDel(gvName);
                  }
               }
            }
            else
            {
               Print("❌ 平仓失败: ", trade.ResultRetcode());
               allClosed = false;
            }
            Sleep(100);
         }
      }
   }
   return allClosed;
}

void ExecuteTrade(string symbol, string side, double qty)
{
   string lockName = "TRADE_LOCK_" + symbol + "_" + side;
   if(GlobalVariableCheck(lockName))
   {
      // 🔥 修复 #4: 锁时间延长至 10 秒
      if(TimeCurrent() - (datetime)GlobalVariableGet(lockName) < 10) return;
   }
   GlobalVariableSet(lockName, (double)TimeCurrent());
   
   // ✅ 指数版独有: 交易时段强校验
   if(!IsInTradingSession(symbol))
   {
      SendPushNotification("⏳ " + symbol + " 休市/非交易时段，跳过信号");
      GlobalVariableDel(lockName);
      return;
   }
   
   // 🔥 修复 #6: 品种有效性检查
   if(!SymbolInfoInteger(symbol, SYMBOL_SELECT)) { 
      if(!SymbolSelect(symbol, true)) {
         Print("❌ 严重错误: 品种 ", symbol, " 不存在或不可交易");
         return;
      }
   }

   // 🔥 修复 #1: 执行层二次白名单校验
   if(allowedSymbols != "" && StringFind(allowedSymbols, symbol) == -1) {
      Print("⚠️ [二次拦截] 品种 ", symbol, " 不在白名单内，跳过交易");
      return;
   }
   
   double tradeQty = qty > 0 ? qty : lotSize;
   bool isBuy = (StringCompare(side, "buy", false) == 0);
   bool isSell = (StringCompare(side, "sell", false) == 0);
   
   if(isBuy)
   {
      // 🔥 修复 #5: 严格反手逻辑
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_SELL) > 0) {
         if(!CloseAllPositionsByType(symbol, POSITION_TYPE_SELL)) {
             Print("❌ 反手平仓(Sell)失败，为了安全，取消开(Buy)新仓");
             GlobalVariableDel(lockName);
             return; // ⛔️ 平仓失败绝对不开新仓
         }
      }
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_BUY) < maxPositions)
      {
         // ✅ [新增] 硬止损 (1%)
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double slPrice = ask * (1.0 - hardStopLossPercent/100.0);
         if(trade.Buy(tradeQty, symbol, ask, slPrice, 0))
            Print("✅ 买入成功: ", symbol, " 硬止损=", DoubleToString(slPrice, 2));
      }
   }
   else if(isSell)
   {
      // 🔥 修复 #5: 严格反手逻辑
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_BUY) > 0) {
         if(!CloseAllPositionsByType(symbol, POSITION_TYPE_BUY)) {
             Print("❌ 反手平仓(Buy)失败，为了安全，取消开(Sell)新仓");
             GlobalVariableDel(lockName);
             return; // ⛔️ 平仓失败绝对不开新仓
         }
      }
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_SELL) < maxPositions)
      {
         // ✅ [新增] 硬止损 (1%)
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double slPrice = bid * (1.0 + hardStopLossPercent/100.0);
         if(trade.Sell(tradeQty, symbol, bid, slPrice, 0))
            Print("✅ 卖出成功: ", symbol, " 硬止损=", DoubleToString(slPrice, 2));
      }
   }
   
   GlobalVariableDel(lockName);
}

string ParseJsonValue(string json, string key)
{
   string sk_string = "\"" + key + "\":\"";
   int p1 = StringFind(json, sk_string);
   if(p1 != -1)
   {
      int p2 = StringFind(json, "\"", p1 + StringLen(sk_string));
      if(p2 != -1) return StringSubstr(json, p1 + StringLen(sk_string), p2 - (p1 + StringLen(sk_string)));
   }
   string sk_number = "\"" + key + "\":";
   p1 = StringFind(json, sk_number);
   if(p1 != -1)
   {
      int start = p1 + StringLen(sk_number);
      string remaining = StringSubstr(json, start);
      int idx = 0;
      while(idx < StringLen(remaining) && (StringGetCharacter(remaining, idx) == 32 || StringGetCharacter(remaining, idx) == 91)) idx++;
      int value_start = idx;
      while(idx < StringLen(remaining))
      {
         ushort ch = StringGetCharacter(remaining, idx);
         if(ch == 44 || ch == 125 || ch == 93) break;
         idx++;
      }
      if(idx > value_start) return StringSubstr(remaining, value_start, idx - value_start);
   }
   return "";
}

void SendPushNotification(string message)
{
   if(!enablePushNotification) return;
   string msg = StringLen(message) > 255 ?
      StringSubstr(message, 0, 252) + "..." : message;
   SendNotification(msg);
}
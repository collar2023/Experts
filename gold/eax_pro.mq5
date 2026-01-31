//+------------------------------------------------------------------+
//|               SignalPollerEA_Gold_Plus_v6.1.mq5                  |
//|          黄金/石油/通用版 - 商业级稳健架构 (Pro 版)             |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- ==========================================
//--- 1. 基础连接设置
//--- ==========================================
// [重要] 请在 URL 后加上 ?token=您的Token
input string serverUrl            = "https://gold.460001.xyz/get_signal?token=121218679";
input int    timerSeconds         = 1;          // ✅ 极速轮询
input ulong  magicNumber          = 640002;     // ⚠️ 注意: 不同品种挂EA时，请修改此号码
input bool   manageManualOrders   = true;       // ✅ 是否接管手动开出的订单 (Magic=0)

// ✅ [核心] 交易品种白名单 (请严格输入: 区分大小写，不要加空格)
// 作用: 决定当前EA实例只管理哪些品种
input string allowedSymbols       = "XAUUSDm,XAGUSDm,USOILm";

//--- ==========================================
//--- 2. 仓位与风控核心参数
//--- ==========================================
input double lotSize              = 0.01;       // 固定手数
input int    maxPositions         = 2;          // 最大持仓数

input group  "=== 动态止损设置 ==="
input double baseStopLossPercent  = 0.8;        // 基础止损
input double heavyPosStopLoss     = 0.6;        // 重仓止损
input double hardStopLossPercent  = 1.0;        // ✅ 开仓硬止损 (服务器端)

input group  "=== 移动止盈设置 ==="
input bool   trailingStopEnabled  = true;       // 是否开启移动止盈
input double trailingStartPercent = 0.5;        // 启动阈值

input group  "=== 分级回撤宽容度 (Gap) ==="
input double trailGap_Level1      = 0.4;        // 初期回撤
input double trailGap_Level2      = 0.5;        // 中期回撤
input double trailGap_Level3      = 0.6;        // 后期回撤

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
//--- 全局变量
CTrade trade;
string lastSignalId = "";
PositionTracker trackers[];

//+------------------------------------------------------------------+
//| 辅助：内存清理                                                    |
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
//| 初始化                                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("========================================");
   Print("EA 初始化 - 商业级稳健版 v6.1 (持久化增强)");
   Print("========================================");
   
   if(StringFind(serverUrl, "token=") == -1)
      Print("⚠️ 警告: Server URL 似乎未包含 ?token=... 参数！");

   lastSignalId = LoadLastSignalId();
   ArrayResize(trackers, 0);
   
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

void OnDeinit(const int reason) { EventKillTimer(); ArrayFree(trackers); }

//+------------------------------------------------------------------+
//| OnTick - 实时风控                                               |
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

         // 实时风控白名单过滤
         if( (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             (allowedSymbols=="" || StringFind(allowedSymbols, symbol)!=-1) )
         {
            ManageRisk(symbol, ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OnTimer - 轮询信号                                              |
//+------------------------------------------------------------------+
void OnTimer()
{
   // 定期清理内存
   CompactTrackers();

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
         
         // 🔥 非白名单信号，跳过但必须更新 ID，防止死循环
         if(allowedSymbols!="" && StringFind(allowedSymbols, symbol)==-1) 
         {
             // 记录下来但不执行，防止下一次轮询卡死
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
         alerted401 = true;
      }
   }
}

//+------------------------------------------------------------------+
//| 执行交易                                                         |
//+------------------------------------------------------------------+
void ExecuteTrade(string symbol, string side, double qty) 
{
   // 品种有效性检查
   if(!SymbolInfoInteger(symbol, SYMBOL_SELECT)) {
      if(!SymbolSelect(symbol, true)) {
         Print("❌ 严重错误: 品种 ", symbol, " 不存在或不可交易");
         return;
      }
   }

   // 执行层二次白名单校验
   if(allowedSymbols != "" && StringFind(allowedSymbols, symbol) == -1) {
      Print("⚠️ [二次拦截] 品种 ", symbol, " 不在白名单内，跳过交易");
      return;
   }

   string lockName = "TRADE_LOCK_" + symbol + "_" + side;
   if(GlobalVariableCheck(lockName)) {
      if(TimeCurrent() - (datetime)GlobalVariableGet(lockName) < 10) return;
   }
   GlobalVariableSet(lockName, (double)TimeCurrent());
   
   double tradeQty = qty > 0 ? qty : lotSize;
   bool isBuy = (StringCompare(side, "buy", false) == 0);
   bool isSell = (StringCompare(side, "sell", false) == 0);
   
   if(isBuy) 
   {
      // 严格反手逻辑
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_SELL) > 0) {
         if(!CloseAllPositionsByType(symbol, POSITION_TYPE_SELL)) {
             Print("❌ 反手平仓(Sell)失败，为了安全，取消开(Buy)新仓");
             GlobalVariableDel(lockName);
             return;
         }
      }
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_BUY) < maxPositions) {
         // ✅ 计算硬止损价格 (服务器端)
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double slPrice = ask * (1.0 - hardStopLossPercent / 100.0);
         if(trade.Buy(tradeQty, symbol, ask, slPrice, 0)) Print("✅ 买入成功: ", symbol, " 硬止损=", DoubleToString(slPrice, 2));
      }
   } 
   else if(isSell) 
   {
      // 严格反手逻辑
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_BUY) > 0) {
         if(!CloseAllPositionsByType(symbol, POSITION_TYPE_BUY)) {
             Print("❌ 反手平仓(Buy)失败，为了安全，取消开(Sell)新仓");
             GlobalVariableDel(lockName);
             return;
         }
      }
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_SELL) < maxPositions) {
         // ✅ 计算硬止损价格 (服务器端)
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double slPrice = bid * (1.0 + hardStopLossPercent / 100.0);
         if(trade.Sell(tradeQty, symbol, bid, slPrice, 0)) Print("✅ 卖出成功: ", symbol, " 硬止损=", DoubleToString(slPrice, 2));
      }
   }
   
   GlobalVariableDel(lockName);
}

//+------------------------------------------------------------------+
//| 风险管理                                                        |
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
      
      // ✅ [持久化] 同步更新到终端全局变量，防止重载失忆
      string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
      GlobalVariableSet(gvName, trackers[trackerIndex].highestPnl);
      
      if(oldHigh > 0 && pnlPercent - oldHigh > 0.5)
         Print("📈 ", symbol, " 新高:", DoubleToString(pnlPercent, 2), "%");
   }

   // 1. 动态止损
   double currentStopLoss = baseStopLossPercent;
   if(volume > 0.05) currentStopLoss = heavyPosStopLoss;
   if(pnlPercent < -currentStopLoss)
   {
      if(trade.PositionClose(ticket))
      {
         string msg = symbol + " 🛑 止损平仓\n亏损:" + DoubleToString(pnlPercent, 2) + "%";
         SendPushNotification(msg);
         trackers[trackerIndex].isActive = false;
         
         // ✅ [清理] 删除全局变量
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
         GlobalVariableDel(gvName);
      }
      return;
   }

   // 2. 保本
   double breakEvenTrigger = (trailingStartPercent < 0.5) ? 0.5 : trailingStartPercent;
   if(pnlPercent >= breakEvenTrigger)
   {
      double breakEvenPrice = entryPrice;
      double currentSL = PositionGetDouble(POSITION_SL);
      bool needBreakEven = false;
      double protectBuffer = SymbolInfoDouble(symbol, SYMBOL_POINT) * 200; // [Exness-Gold] 200点缓冲
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

   // 3. 移动止盈
   if(trailingStopEnabled && trackers[trackerIndex].highestPnl >= trailingStartPercent)
   {
      if(!trackers[trackerIndex].startLogSent)
      {
         SendPushNotification(symbol + " 🚀 移动止盈启动");
         trackers[trackerIndex].startLogSent = true;
      }
      double drawdown = trackers[trackerIndex].highestPnl - pnlPercent;
      double currentGap = 0.0;
      if(trackers[trackerIndex].highestPnl < 2.5) currentGap = trailGap_Level1;
      else if(trackers[trackerIndex].highestPnl < 4.5) currentGap = trailGap_Level2;
      else currentGap = trailGap_Level3;
      if(drawdown >= currentGap)
      {
         if(trade.PositionClose(ticket))
         {
            string msg = symbol + " 📈 止盈平仓\n获利:" + DoubleToString(pnlPercent, 2) + "%";
            SendPushNotification(msg);
            trackers[trackerIndex].isActive = false;
            
            // ✅ [清理] 删除全局变量
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
         string msg = "💓 EA心跳 (" + IntegerToString(magicNumber) + ")\n" +
                      symbol + "\n" +
                      "当前: " + DoubleToString(pnlPercent, 2) + "%";
         SendPushNotification(msg);
         trackers[trackerIndex].lastHeartbeatTime = TimeCurrent();
      }
   }
}

// --- 辅助函数 ---
int GetOrCreateTracker(ulong ticket, string symbol) {
   int total = ArraySize(trackers);
   for(int i=0; i<total; i++) if(trackers[i].ticket == ticket && trackers[i].isActive) return i;
   
   // 查找空闲槽或扩容
   int targetIndex = -1;
   for(int i=0; i<total; i++) if(!trackers[i].isActive) { targetIndex = i; break; }
   if(targetIndex == -1) { targetIndex = ArraySize(trackers); ArrayResize(trackers, targetIndex+1); }

   trackers[targetIndex].ticket = ticket; 
   trackers[targetIndex].symbol = symbol; 
   trackers[targetIndex].isActive = true; 
   trackers[targetIndex].lastHeartbeatTime = 0; 
   trackers[targetIndex].startLogSent = false;
   
   // ✅ [恢复] 从终端全局变量加载历史最高盈利
   string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
   if(GlobalVariableCheck(gvName)) {
      trackers[targetIndex].highestPnl = GlobalVariableGet(gvName);
      Print("📥 持久化恢复: Ticket=", ticket, " 历史最高盈利=", trackers[targetIndex].highestPnl, "%");
   } else {
      trackers[targetIndex].highestPnl = 0.0;
   }
   
   return targetIndex;
}

void CleanupClosedPositions() {
   for(int i=ArraySize(trackers)-1; i>=0; i--) {
      if(!trackers[i].isActive) continue;
      if(!PositionSelectByTicket(trackers[i].ticket)) {
         // ✅ 平仓后清理残留的全局变量
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
         
         if( posSymbol == symbol && 
             (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             posType_actual == posType &&
             (allowedSymbols=="" || StringFind(allowedSymbols, posSymbol)!=-1) ) 
         {
            if(trade.PositionClose(ticket)) {
               Print("✅ 平仓成功: Ticket=", ticket);
               for(int j=0; j<ArraySize(trackers); j++) {
                  if(trackers[j].ticket == ticket) {
                     trackers[j].isActive = false;
                     string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
                     GlobalVariableDel(gvName);
                  }
               }
            } else {
               Print("❌ 平仓失败: ", trade.ResultRetcode());
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

//+------------------------------------------------------------------+
//|               SignalPollerEA_Crypto_Pro_v6.0.mq5                 |
//|          加密货币专用版 - 商业级稳健架构 (CF Workers适配)          |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

//--- ==========================================
//--- 1. 基础连接设置
//--- ==========================================
// [重要] 请确保域名为您的 CF Worker 地址，并填写正确的 Token
input string serverUrl            = "https://btc.640001.xyz/get_signal?token=121218679"; 
input int    timerSeconds         = 1;          // [cite: 15] 极速轮询
input ulong  magicNumber          = 640004;     // ✅ [已修改] 加密货币专用魔术号 
input bool   manageManualOrders   = true;       // [cite: 17] 是否接管手动开出的订单 (Magic=0)

// ✅ [核心] 交易品种白名单 (已过滤非加密货币)
// 作用: 决定当前EA实例只管理哪些品种
input string allowedSymbols       = "BTCUSDm,ETHUSDm,SOLUSDm"; // 

//--- ==========================================
//--- 2. 仓位与风控核心参数 (加密货币高波动适配)
//--- ==========================================
input double lotSize              = 0.01;       // [cite: 20] 固定手数
input int    maxPositions         = 2;          // [cite: 21] 最大持仓数

input group  "=== 动态止损设置 (Crypto) ==="
input double baseStopLossPercent  = 3.0;        // ✅ [已修改] 轻仓止损 3.0% [cite: 22]
input double heavyPosStopLoss     = 2.0;        // ✅ [已修改] 重仓止损 2.0% [cite: 23]
input double hardStopLossPercent  = 1.0;        // ✅ [新增] 开仓硬止损 (1%)

input group  "=== 移动止盈设置 (Crypto) ==="
input bool   trailingStopEnabled  = true;       // 是否开启移动止盈
input double trailingStartPercent = 2.0;        // ✅ [已修改] 启动阈值 2.0% [cite: 24]

input group  "=== 分级回撤宽容度 (Gap) ==="
input double trailGap_Level1      = 0.8;        // ✅ [已修改] 初期回撤 0.8% [cite: 25]
input double trailGap_Level2      = 1.2;        // ✅ [已修改] 中期回撤 1.2% [cite: 26]
input double trailGap_Level3      = 2.0;        // ✅ [已修改] 后期回撤 2.0% [cite: 27]

//--- ==========================================
//--- 3. 通知与日志
//--- ==========================================
input bool enablePushNotification = true;
input bool enableHeartbeatPush = true;
input int  heartbeatInterval = 3600;            // [cite: 28]
input bool enableDetailedLog = true;
input bool enablePnLSummaryPush = true;
input int  pnLSummaryInterval = 21600;          // [cite: 29]

//--- 持仓追踪结构体
struct PositionTracker
{
   ulong    ticket;
   string   symbol;
   double   highestPnl; // [cite: 30]
   bool     isActive;
   datetime lastHeartbeatTime;
   bool     startLogSent;
};

//--- 全局变量
CTrade trade;
string lastSignalId = "";
PositionTracker trackers[];

//+------------------------------------------------------------------+
//| 辅助：内存清理                                                   |
//+------------------------------------------------------------------+
void CompactTrackers() // [cite: 33]
{
   int writeIndex = 0;
   int total = ArraySize(trackers);
   for(int i = 0; i < total; i++) // [cite: 34]
   {
      if(trackers[i].isActive)
      {
         if(i != writeIndex) trackers[writeIndex] = trackers[i];
         writeIndex++; // [cite: 35]
      }
   }
   if(writeIndex < total) ArrayResize(trackers, writeIndex);
}

//+------------------------------------------------------------------+
//| 从文件加载上次的信号ID                                            |
//+------------------------------------------------------------------+
string LoadLastSignalId() // [cite: 37]
{
   string filename = "LastSignalID_" + IntegerToString(magicNumber) + ".txt";
   int handle = FileOpen(filename, FILE_READ|FILE_TXT);
   if(handle != INVALID_HANDLE) // [cite: 38]
   {
      string savedId = FileReadString(handle);
      FileClose(handle);
      if(StringLen(savedId) > 0) return savedId; // [cite: 39]
   }
   return "";
}

//+------------------------------------------------------------------+
//| 保存当前信号ID到文件                                              |
//+------------------------------------------------------------------+
void SaveLastSignalId(string signalId) // [cite: 41]
{
   string filename = "LastSignalID_" + IntegerToString(magicNumber) + ".txt";
   int handle = FileOpen(filename, FILE_WRITE|FILE_TXT);
   if(handle != INVALID_HANDLE) // [cite: 42]
   {
      FileWriteString(handle, signalId);
      FileClose(handle);
   }
}

//+------------------------------------------------------------------+
//| 初始化                                                           |
//+------------------------------------------------------------------+
int OnInit() // [cite: 44]
{
   Print("========================================");
   Print("EA 初始化 - 加密货币专用版 v6.0 (CF Workers)"); // ✅ 保留 v6.0
   Print("========================================");
   if(StringFind(serverUrl, "token=") == -1) // [cite: 45]
      Print("⚠️ 警告: Server URL 似乎未包含 ?token=... 参数！");

   lastSignalId = LoadLastSignalId();
   ArrayResize(trackers, 0); // [cite: 46]
   
   // 扫描现有持仓 (带白名单过滤)
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) // [cite: 47]
      {
         long magic = PositionGetInteger(POSITION_MAGIC);
         string symbol = PositionGetString(POSITION_SYMBOL); // [cite: 48]

         // 直接使用 allowedSymbols 常量进行判断
         if( (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             (allowedSymbols=="" || StringFind(allowedSymbols, symbol)!=-1) )
         {
            GetOrCreateTracker(ticket, symbol);
            Print("🔍 识别到现有持仓: ", symbol, " Ticket=", ticket); // [cite: 49]
         }
      }
   }
   
   EventSetTimer(timerSeconds);
   trade.SetExpertMagicNumber(magicNumber); // [cite: 50]
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); ArrayFree(trackers); }

//+------------------------------------------------------------------+
//| OnTick - 实时风控                                                |
//+------------------------------------------------------------------+
void OnTick() // [cite: 52]
{
   CleanupClosedPositions();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) // [cite: 53]
      {
         long magic = PositionGetInteger(POSITION_MAGIC);
         string symbol = PositionGetString(POSITION_SYMBOL); // [cite: 54]

         // 实时风控白名单过滤
         if( (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             (allowedSymbols=="" || StringFind(allowedSymbols, symbol)!=-1) )
         {
            ManageRisk(symbol, ticket);
         } // [cite: 55]
      }
   }
}

//+------------------------------------------------------------------+
//| OnTimer - 轮询信号                                               |
//+------------------------------------------------------------------+
void OnTimer() // [cite: 57]
{
   CompactTrackers();

   uchar post[], result[];
   string response_headers;
   ResetLastError();
   // [cite: 58] 发起网络请求
   int res = WebRequest("GET", serverUrl, "", 2000, post, result, response_headers);
   if(res==200) // [cite: 59]
   {
      string jsonResponse = CharArrayToString(result);
      if(StringLen(jsonResponse)==0) return;

      string newSignalId = ParseJsonValue(jsonResponse,"signal_id");
      if(newSignalId!="" && newSignalId!=lastSignalId) // [cite: 60]
      {
         string symbol = ParseJsonValue(jsonResponse,"symbol");
         // 非白名单信号，跳过但必须更新 ID，防止死循环
         if(allowedSymbols!="" && StringFind(allowedSymbols, symbol)==-1) // [cite: 61]
         {
             lastSignalId = newSignalId;
             SaveLastSignalId(newSignalId); // [cite: 62]
             return;
         }

         lastSignalId = newSignalId;
         SaveLastSignalId(newSignalId);
         string side   = ParseJsonValue(jsonResponse,"side"); // [cite: 63]
         double qty    = StringToDouble(ParseJsonValue(jsonResponse, "qty"));
         string msg = ">>> 收到新信号\nID=" + lastSignalId + "\n品种=" + symbol + "\n方向=" + side; // [cite: 64]
         Print(msg);
         SendPushNotification(msg);

         ExecuteTrade(symbol, side, qty);
      } // [cite: 65]
   }
   else if(res == 401)
   {
      static bool alerted401 = false;
      if(!alerted401) { // [cite: 66]
         Print("❌ 鉴权失败 (401): 请检查 Token！");
         alerted401 = true;
      } // [cite: 67]
   }
}

//+------------------------------------------------------------------+
//| 执行交易                                                         |
//+------------------------------------------------------------------+
void ExecuteTrade(string symbol, string side, double qty) // [cite: 68]
{
   if(!SymbolInfoInteger(symbol, SYMBOL_SELECT)) {
      if(!SymbolSelect(symbol, true)) {
         Print("❌ 严重错误: 品种 ", symbol, " 不存在或不可交易");
         return; // [cite: 69]
      }
   }

   // 执行层二次白名单校验
   if(allowedSymbols != "" && StringFind(allowedSymbols, symbol) == -1) {
      Print("⚠️ [二次拦截] 品种 ", symbol, " 不在白名单内，跳过交易");
      return; // [cite: 70]
   }

   string lockName = "TRADE_LOCK_" + symbol + "_" + side;
   if(GlobalVariableCheck(lockName)) { // [cite: 71]
      if(TimeCurrent() - (datetime)GlobalVariableGet(lockName) < 10) return;
   } // [cite: 72]
   GlobalVariableSet(lockName, (double)TimeCurrent());
   
   double tradeQty = qty > 0 ? qty : lotSize;
   bool isBuy = (StringCompare(side, "buy", false) == 0); // [cite: 73]
   bool isSell = (StringCompare(side, "sell", false) == 0);

   if(isBuy) // [cite: 74]
   {
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_SELL) > 0) {
         if(!CloseAllPositionsByType(symbol, POSITION_TYPE_SELL)) {
             Print("❌ 反手平仓(Sell)失败，为了安全，取消开(Buy)新仓");
             GlobalVariableDel(lockName); // [cite: 75]
             return;
         }
      }
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_BUY) < maxPositions) {
         // ✅ [新增] 硬止损 (1%)
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double slPrice = ask * (1.0 - hardStopLossPercent / 100.0);
         if(trade.Buy(tradeQty, symbol, ask, slPrice, 0)) Print("✅ 买入成功: ", symbol, " 硬止损=", DoubleToString(slPrice, 2));
      } // [cite: 76]
   } 
   else if(isSell) // [cite: 77]
   {
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_BUY) > 0) {
         if(!CloseAllPositionsByType(symbol, POSITION_TYPE_BUY)) {
             Print("❌ 反手平仓(Buy)失败，为了安全，取消开(Sell)新仓");
             GlobalVariableDel(lockName); // [cite: 77]
             return;
         }
      }
      if(CountPositionsBySymbol(symbol, POSITION_TYPE_SELL) < maxPositions) {
         // ✅ [新增] 硬止损 (1%)
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double slPrice = bid * (1.0 + hardStopLossPercent / 100.0);
         if(trade.Sell(tradeQty, symbol, bid, slPrice, 0)) Print("✅ 卖出成功: ", symbol, " 硬止损=", DoubleToString(slPrice, 2));
      } // [cite: 78]
   }
   
   GlobalVariableDel(lockName);
}

//+------------------------------------------------------------------+
//| 风险管理 (核心逻辑)                                               |
//+------------------------------------------------------------------+
void ManageRisk(string symbol, ulong ticket) // [cite: 80]
{
   if(!PositionSelectByTicket(ticket)) return;

   double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume = PositionGetDouble(POSITION_VOLUME);
   long type = PositionGetInteger(POSITION_TYPE); // [cite: 81]
   if(entryPrice==0.0) return;

   double currentPrice = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol,SYMBOL_BID) : SymbolInfoDouble(symbol,SYMBOL_ASK);
   double pnlPercent = (currentPrice - entryPrice) * ((type==POSITION_TYPE_BUY)?1:-1) / entryPrice * 100.0; // [cite: 82]

   int trackerIndex = GetOrCreateTracker(ticket, symbol);
   if(trackerIndex < 0 || trackerIndex >= ArraySize(trackers)) return; // [cite: 83]

   // 峰值更新
   if(pnlPercent > trackers[trackerIndex].highestPnl)
   {
      double oldHigh = trackers[trackerIndex].highestPnl; // ✅ 恢复变量声明
      trackers[trackerIndex].highestPnl = pnlPercent; // [cite: 84]
      // ✅ [新增] 持久化
      string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
      GlobalVariableSet(gvName, trackers[trackerIndex].highestPnl);
      
      if(oldHigh > 0 && pnlPercent - oldHigh > 0.5)
         Print("📈 ", symbol, " 新高:", DoubleToString(pnlPercent, 2), "%");
   } // [cite: 85]

   // 1. 动态止损 (使用加密货币专用参数)
   double currentStopLoss = baseStopLossPercent;
   if(volume > 0.05) currentStopLoss = heavyPosStopLoss;
   if(pnlPercent < -currentStopLoss) // [cite: 86]
   {
      if(trade.PositionClose(ticket))
      {
         string msg = symbol + " 🛑 止损平仓 (Crypto)\n亏损:" + DoubleToString(pnlPercent, 2) + "%";
         SendPushNotification(msg); // [cite: 87]
         trackers[trackerIndex].isActive = false;
         // ✅ [清理] 
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
         GlobalVariableDel(gvName);
      }
      return;
   } // [cite: 88]

   // 2. 保本逻辑
   double breakEvenTrigger = (trailingStartPercent < 1.5) ? 1.5 : trailingStartPercent; // 动态调整保本触发线
   if(pnlPercent >= breakEvenTrigger) // [cite: 89]
   {
      double breakEvenPrice = entryPrice;
      double currentSL = PositionGetDouble(POSITION_SL);
      bool needBreakEven = false; // [cite: 90]
      double protectBuffer = SymbolInfoDouble(symbol, SYMBOL_POINT) * 50; // 加密货币点差大，增加保护 buffer

      if(type == POSITION_TYPE_BUY) // [cite: 91]
      {
         if(currentSL == 0 || currentSL < breakEvenPrice - protectBuffer) needBreakEven = true;
      }
      else // [cite: 92]
      {
         if(currentSL > breakEvenPrice + protectBuffer || currentSL == 0) needBreakEven = true;
      }
      if(needBreakEven) // [cite: 93]
      {
         if(trade.PositionModify(ticket, breakEvenPrice, 0))
            Print(symbol, " 🔒 保本已设置");
      } // [cite: 94]
   }

   // 3. 移动止盈 (使用加密货币专用参数)
   if(trailingStopEnabled && trackers[trackerIndex].highestPnl >= trailingStartPercent)
   {
      if(!trackers[trackerIndex].startLogSent)
      {
         SendPushNotification(symbol + " 🚀 移动止盈启动 (Crypto Mode)");
         trackers[trackerIndex].startLogSent = true; // [cite: 95]
      }
      double drawdown = trackers[trackerIndex].highestPnl - pnlPercent;
      double currentGap = 0.0;
      
      // ✅ [已修改] 加密货币分级回撤
      if(trackers[trackerIndex].highestPnl < 3.5) currentGap = trailGap_Level1; // 0.8
      else if(trackers[trackerIndex].highestPnl < 6.0) currentGap = trailGap_Level2; // 1.2
      else currentGap = trailGap_Level3; // 2.0  // [cite: 96]
      
      if(drawdown >= currentGap) // [cite: 97]
      {
         if(trade.PositionClose(ticket))
         {
            string msg = symbol + " 📈 止盈平仓\n获利:" + DoubleToString(pnlPercent, 2) + "%";
            SendPushNotification(msg); // [cite: 98]
            trackers[trackerIndex].isActive = false;
            // ✅ [清理] 
            string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
            GlobalVariableDel(gvName);
         }
      }
   }
   
   // 心跳推送
   if(enableHeartbeatPush)
   {
      datetime timeSinceLastHeartbeat = TimeCurrent() - trackers[trackerIndex].lastHeartbeatTime;
      if(timeSinceLastHeartbeat >= heartbeatInterval) // [cite: 99]
      {
         string trailingStatus = (trackers[trackerIndex].highestPnl >= trailingStartPercent) ?
         "✅ 已启动" : "⏳ 待启动"; // [cite: 100]
         string msg = "💓 Crypto EA心跳 (" + IntegerToString(magicNumber) + ")\n" +
                      symbol + "\n" +
                      "当前: " + DoubleToString(pnlPercent, 2) + "%";
         SendPushNotification(msg); // [cite: 101]
         trackers[trackerIndex].lastHeartbeatTime = TimeCurrent();
      }
   }
}

// --- 辅助函数 (保持架构稳定性) ---
int GetOrCreateTracker(ulong ticket, string symbol) {
   int total = ArraySize(trackers);
   for(int i=0; i<total; i++) if(trackers[i].ticket == ticket && trackers[i].isActive) return i; // [cite: 102]
   for(int i=0; i<total; i++) if(!trackers[i].isActive) {
         trackers[i].ticket = ticket; trackers[i].symbol = symbol;
         trackers[i].isActive = true; trackers[i].lastHeartbeatTime = 0; trackers[i].startLogSent = false;
         // ✅ [新增] 恢复持久化最高盈利
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
         trackers[i].highestPnl = GlobalVariableCheck(gvName) ? GlobalVariableGet(gvName) : 0.0;
         return i;
   } // [cite: 105]
   int size = ArraySize(trackers); ArrayResize(trackers, size+1);
   trackers[size].ticket = ticket; trackers[size].symbol = symbol; trackers[size].isActive = true; trackers[size].lastHeartbeatTime = 0; trackers[size].startLogSent = false; // [cite: 106]
   
   // ✅ [新增] 恢复持久化最高盈利
   string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
   trackers[size].highestPnl = GlobalVariableCheck(gvName) ? GlobalVariableGet(gvName) : 0.0;
   return size; // [cite: 107]
}

void CleanupClosedPositions() {
   for(int i=ArraySize(trackers)-1; i>=0; i--) {
      if(!trackers[i].isActive) continue;
      if(!PositionSelectByTicket(trackers[i].ticket)) {
         // ✅ [清理] 
         string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(trackers[i].ticket) + "_PNL";
         GlobalVariableDel(gvName);
         trackers[i].isActive = false; // [cite: 108]
      }
   }
}

int CountPositionsBySymbol(string symbol, ENUM_POSITION_TYPE posType = -1) {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) { // [cite: 109]
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) { // [cite: 110]
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         // 计数下沉白名单
         if( posSymbol == symbol && 
             (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             (allowedSymbols=="" || StringFind(allowedSymbols, posSymbol)!=-1) ) 
         { // [cite: 111]
            if(posType == -1) count++;
            else if(PositionGetInteger(POSITION_TYPE) == posType) count++; // [cite: 112]
         }
      }
   }
   return count; // [cite: 113]
} // [cite: 113]

bool CloseAllPositionsByType(string symbol, ENUM_POSITION_TYPE posType) {
   bool allClosed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--) { // [cite: 114]
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) { // [cite: 115]
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         long magic = PositionGetInteger(POSITION_MAGIC);
         long posType_actual = PositionGetInteger(POSITION_TYPE); // [cite: 116]
         
         // 平仓下沉白名单
         if( posSymbol == symbol && 
             (magic == magicNumber || (manageManualOrders && magic == 0)) && 
             posType_actual == posType &&
             (allowedSymbols=="" || StringFind(allowedSymbols, posSymbol)!=-1) ) 
         {
            if(trade.PositionClose(ticket)) {
               Print("✅ 平仓成功: Ticket=", ticket); // [cite: 117]
               for(int j=0; j<ArraySize(trackers); j++) if(trackers[j].ticket == ticket) {
                  trackers[j].isActive = false; 
                  // ✅ [清理] 
                  string gvName = "GV_" + IntegerToString(magicNumber) + "_" + IntegerToString(ticket) + "_PNL";
                  GlobalVariableDel(gvName);
               }
            } else {
               Print("❌ 平仓失败: ", trade.ResultRetcode());
               allClosed = false; // [cite: 120]
            }
            Sleep(100);
         } // [cite: 121]
      }
   }
   return allClosed; // [cite: 122]
} // [cite: 122]

string ParseJsonValue(string json, string key) { // [cite: 122]
   string sk_string = "\"" + key + "\":\"";
   int p1 = StringFind(json, sk_string);
   if(p1 != -1) {
      int p2 = StringFind(json, "\"", p1 + StringLen(sk_string));
      if(p2 != -1) return StringSubstr(json, p1 + StringLen(sk_string), p2 - (p1 + StringLen(sk_string))); // [cite: 123]
   }
   string sk_number = "\"" + key + "\":";
   p1 = StringFind(json, sk_number);
   if(p1 != -1) { // [cite: 125]
      int start = p1 + StringLen(sk_number);
      string remaining = StringSubstr(json, start);
      int idx = 0; // [cite: 126]
      while(idx < StringLen(remaining) && (StringGetCharacter(remaining, idx) == 32 || StringGetCharacter(remaining, idx) == 91)) idx++;
      int value_start = idx; // [cite: 127]
      while(idx < StringLen(remaining)) {
         ushort ch = StringGetCharacter(remaining, idx);
         if(ch == 44 || ch == 125 || ch == 93) break; // [cite: 128]
         idx++;
      }
      if(idx > value_start) return StringSubstr(remaining, value_start, idx - value_start); // [cite: 129]
   }
   return "";
}

void SendPushNotification(string message) { // [cite: 130]
   if(!enablePushNotification) return;
   SendNotification(message);
}
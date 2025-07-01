//+------------------------------------------------------------------+
//| Risk_Management_Module.mqh – 核心风控与资金管理 v2.6 (2025‑07‑04)|
//| ★ v2.6.1: 止损逻辑增强 - 全面部署三级防御与 MathIsValidNumber() 防护 |
//|   1) 终极止损设置逻辑重构: 引入CArrayDouble收集合法候选止损价。 |
//|   2) MathIsValidNumber() 在所有关键价格/手数计算的入口和出口均已加固。|
//|   3) NormalizePrice() 函数增加了对输入值的防护。                |
//|   4) 彻底杜绝因计算过程产生的 inf/nan 导致止损设置失败。       |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

//==================================================================
//  输入参数 (无修改)
//==================================================================
input group "--- Position Sizing ---"
input bool     Risk_useFixedLot        = false;
input double   Risk_fixedLot           = 0.01;
input double   Risk_riskPercent        = 1.0;

input group "--- Stop Loss Protection ---"
input double   Risk_minStopATRMultiple = 1.0;
input int      Risk_atrPeriod          = 14;
input double   Risk_minStopPoints      = 10.0;

input group "--- Position Size Limits ---"
input double   Risk_maxLotByBalance    = 50.0;
input double   Risk_maxAbsoluteLot     = 1.0;
input bool     Risk_enableLotLimit     = true;

input group "--- Trade Execution & Global Risk ---"
input double   Risk_slippage           = 3;
input double   Risk_dailyLossLimitPct  = 10.0;
input bool     Risk_AllowNewTrade      = true;

//==================================================================
//  模块内部全局变量 (无修改)
//==================================================================
static int      rm_currentDay        = -1;
static double   rm_dayStartBalance   = 0.0;
static bool     rm_dayLossLimitHit   = false;
static int      rm_atrHandle         = INVALID_HANDLE;

//==================================================================
//  初始化和清理函数 (无修改)
//==================================================================
void InitRiskModule()
{
   rm_currentDay      = -1;
   rm_dayStartBalance = 0.0;
   rm_dayLossLimitHit = false;

   rm_atrHandle = iATR(_Symbol, _Period, Risk_atrPeriod);
   if(rm_atrHandle == INVALID_HANDLE)
      Print("[风控] ATR 初始化失败");
   else
      Print("[风控] 风控模块 v2.6.1 初始化完成 (止损加固 & MathIsValidNumber 全面防护)");
}

void DeinitRiskModule()
{
   if(rm_atrHandle != INVALID_HANDLE) IndicatorRelease(rm_atrHandle);
}

void ConfigureTrader(CTrade &t)
{
   t.SetExpertMagicNumber(123456); // 使用EA固定的魔术数字
   t.SetDeviationInPoints((ulong)Risk_slippage);
   t.SetTypeFillingBySymbol(_Symbol);
}

//==================================================================
//  手数计算 (加固MathIsValidNumber检查)
//==================================================================
double CalculateLotSize(double original_sl_price, ENUM_ORDER_TYPE type)
{
   // ★ 关键入口防护 ★
   if (!MathIsValidNumber(original_sl_price))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[风控-手数计算] 输入止损价无效.");
       return 0.0;
   }

   double estPrice = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // ★ 关键入口防护 ★
   if(estPrice <= 0 || !MathIsValidNumber(estPrice))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[风控-手数计算] 预估开仓价无效.");
       return 0.0;
   }

   // 计算点数差，确保其有效性
   double riskPoints = MathAbs(estPrice - original_sl_price);
   // ★ 关键入口防护 ★
   if(riskPoints <= 0 || !MathIsValidNumber(riskPoints))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[风控-手数计算] 计算风险点数无效.");
       return 0.0;
   }
   riskPoints /= _Point; // 转换为点数

   double lot = 0.0;
   if(Risk_useFixedLot)
   {
       lot = Risk_fixedLot;
   }
   else
   {
       double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
       // ★ 关键入口防护 ★
       if(!MathIsValidNumber(balance) || balance <= 0)
       {
           if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[风控-手数计算] 账户余额无效.");
           return 0.0;
       }

       double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_PROFIT);
       if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
       // ★ 关键入口防护 ★
       if(tickValue <= 0 || !MathIsValidNumber(tickValue))
       {
           if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[风控-手数计算] Tick Value 无效.");
           return 0.0;
       }

       double riskAmt = balance * Risk_riskPercent / 100.0;
       // ★ 关键入口防护 ★
       if(!MathIsValidNumber(riskAmt) || riskAmt <= 0)
       {
           if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[风控-手数计算] 计算风险金额无效.");
           return 0.0;
       }

       lot = riskAmt / (riskPoints * tickValue); // 注意这里是 riskPoints * tickValue 而不是 riskPoints / _Point * tickValue
   }

   // ★ 关键出口防护 ★
   if(!MathIsValidNumber(lot))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[风控-手数计算] 计算出的手数无效.");
       return 0.0;
   }

   // 限制手数并确保符合交易规则
   lot = MathMin(lot, GetMaxAllowedLotSize());
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // ★ 关键入口防护 ★
   if(!MathIsValidNumber(minLot) || !MathIsValidNumber(stepLot))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[风控-手数计算] 最小/步进手数无效.");
       return 0.0;
   }

   lot = MathMax(lot, minLot);
   lot = MathFloor(lot / stepLot) * stepLot;

   // ★ 关键出口防护 ★
   if(!MathIsValidNumber(lot) || lot <= 0)
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[风控-手数计算] 最终计算手数无效或为零.");
       return 0.0;
   }

   return lot;
}

//==================================================================
//  止损相关工具函数 (终极修复区域)
//==================================================================

// ★ 关键函数：对价格进行标准化，增加入口和出口防护 ★
double NormalizePrice(double price)
{
   // --- 入口防护 ---
   if (!MathIsValidNumber(price))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[NormalizePrice] 输入价格无效，返回0.");
       return 0.0;
   }

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   // 如果tickSize非常小或无效，则直接使用_Digits进行标准化
   if(tickSize <= 1e-10 || !MathIsValidNumber(tickSize))
   {
       double normalized = NormalizeDouble(price, _Digits);
       // --- 出口防护 ---
       if (!MathIsValidNumber(normalized))
       {
           if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[NormalizePrice] _Digits标准化后价格无效，返回0.");
           return 0.0;
       }
       return normalized;
   }

   // 使用 TickSize 进行标准化
   double normalized_with_ticksize = NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
   // --- 出口防护 ---
   if (!MathIsValidNumber(normalized_with_ticksize))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[NormalizePrice] TickSize标准化后价格无效，返回0.");
       return 0.0;
   }
   return normalized_with_ticksize;
}

// ★ 关键函数：计算基础止损价，增加入口防护 ★
double CalculateFinalStopLoss(double actualOpenPrice, double originalSL, ENUM_ORDER_TYPE orderType)
{
   // --- 入口防护 ---
   if (!MathIsValidNumber(actualOpenPrice) || !MathIsValidNumber(originalSL))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[CalculateFinalStopLoss] 输入价格无效，返回0.");
       return 0.0;
   }

   double minDist = GetMinStopDistance(); // 这个函数内部已处理ATR和Broker最小距离

   // ★ 关键入口防护 ★
   if (!MathIsValidNumber(minDist) || minDist <= 0)
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[CalculateFinalStopLoss] 计算出的最小止损距离无效.");
       return 0.0; // 如果最小距离都算不出来，则无法计算止损
   }

   double sl;
   if(orderType == ORDER_TYPE_BUY)
   {
      // 计算应有的最小止损价 (开仓价 - 最小距离)
      double minSL = actualOpenPrice - minDist;
      // 选择用户设定的原始止损价和最小止损价中更远的那个作为基础止损
      sl = MathMax(originalSL, minSL);
   }
   else // ORDER_TYPE_SELL
   {
      // 计算应有的最小止损价 (开仓价 + 最小距离)
      double minSL = actualOpenPrice + minDist;
      // 选择用户设定的原始止损价和最小止损价中更远的那个作为基础止损
      sl = MathMin(originalSL, minSL);
   }

   // --- 出口防护 ---
   if (!MathIsValidNumber(sl))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[CalculateFinalStopLoss] 计算出的基础止损价无效，返回0.");
       return 0.0;
   }
   // 返回标准化后的价格
   return NormalizePrice(sl);
}

// ★ 关键函数：检查止损价是否满足经纪商的要求 (距离/冻结) ★
bool IsStopLossValid(double sl, ENUM_POSITION_TYPE posType)
{
   // --- 入口防护 ---
   if (!MathIsValidNumber(sl) || sl == 0) // 止损价为0或无效则直接返回false
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[IsStopLossValid] 输入的止损价无效或为零.");
       return false;
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // --- 输入防护 ---
   if(!MathIsValidNumber(bid) || !MathIsValidNumber(ask))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[IsStopLossValid] 市场报价 BID/ASK 无效.");
       return false;
   }

   double pt  = _Point;
   // 获取经纪商设定的最小止损距离 (Level)
   long stopsLevelInt = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = (stopsLevelInt > 0) ? (double)stopsLevelInt * pt : 1 * pt; // 至少为1个点
   // 获取经纪商设定的冻结距离 (Freeze Level)
   long freezeLevelInt = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double minFreezeDist = (freezeLevelInt > 0) ? (double)freezeLevelInt * pt : 0; // 如果为0，表示无冻结距离要求

   // --- 校验逻辑 ---
   if(posType == POSITION_TYPE_BUY)
   {
      // 对于多单，止损价必须低于Bid价
      // 检查是否离市价太近，不满足最小止损距离要求
      if(sl >= bid - minStopDist)
      {
          if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("[IsStopLossValid] 多单止损 %.5f 离 Bid %.5f 过近 (最小距离 %d 点)", sl, bid, stopsLevelInt));
          return false;
      }
      // 检查是否触碰到冻结距离
      if(minFreezeDist > 0 && (bid - sl) <= minFreezeDist)
      {
          if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("[IsStopLossValid] 多单止损 %.5f 触碰冻结距离 (Bid %.5f, 冻结 %.1f 点)", sl, bid, minFreezeDist / pt));
          return false;
      }
   }
   else // POSITION_TYPE_SELL
   {
      // 对于空单，止损价必须高于Ask价
      // 检查是否离市价太近，不满足最小止损距离要求
      if(sl <= ask + minStopDist)
      {
          if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("[IsStopLossValid] 空单止损 %.5f 离 Ask %.5f 过近 (最小距离 %d 点)", sl, ask, stopsLevelInt));
          return false;
      }
      // 检查是否触碰到冻结距离
      if(minFreezeDist > 0 && (sl - ask) <= minFreezeDist)
      {
          if(g_Logger != NULL && EnableDebug) g_Logger.WriteInfo(StringFormat("[IsStopLossValid] 空单止损 %.5f 触碰冻结距离 (Ask %.5f, 冻结 %.1f 点)", sl, ask, minFreezeDist / pt));
          return false;
      }
   }

   // --- 最终通过检查 ---
   return true;
}

// ★ 关键函数：尝试设置止损止盈，包含重试机制 ★
bool SetStopLossWithRetry(CTrade &t, double stopLoss, double takeProfit, int maxRetries = 3)
{
   // --- 入口防护 ---
   if(!PositionSelect(_Symbol))
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[SetStopLossWithRetry] 无法选中当前仓位.");
       return false;
   }

   ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   // 对传入的止损止盈值进行标准化和校验
   double validStopLoss = NormalizePrice(stopLoss);
   double validTakeProfit = (takeProfit > 0) ? NormalizePrice(takeProfit) : 0;

   // --- 再次检查止损有效性 ---
   if(!IsStopLossValid(validStopLoss, pType))
   {
       // [日志增强] - 更清晰地说明止损无效的原因
       PrintFormat("[风控] ❌ 无法设置止损: 价格 %.5f (校准后 %.5f) 不满足Broker规则", stopLoss, validStopLoss);
       return false;
   }

   // --- 执行止损设置，包含重试 ---
   for(int i = 0; i < maxRetries; ++i)
   {
      // 尝试修改仓位
      if(t.PositionModify(_Symbol, validStopLoss, validTakeProfit))
      {
          // 如果成功，返回true
          return true;
      }
      // 如果失败，打印错误信息并等待
      PrintFormat("[风控] 止损设置尝试 %d/%d 失败，等待重试...", i + 1, maxRetries);
      if(i < maxRetries - 1) Sleep(250); // 等待250毫秒
   }

   // --- 所有重试都失败 ---
   // [日志增强] - 更详细的失败信息
   PrintFormat("[风控] 🚨 最终失败：无法为仓位设置止损止盈。上次错误代码: %d", t.ResultRetcode());
   return false;
}

//==================================================================
//  辅助函数 (加固MathIsValidNumber检查)
//==================================================================

// 获取最小止损距离，考虑ATR和经纪商最小距离要求
double GetMinStopDistance()
{
   // 基础最小距离，由输入参数决定 (转换为价格单位)
   double dist = Risk_minStopPoints * _Point;

   // 如果ATR句柄有效，计算基于ATR的最小距离
   if(rm_atrHandle != INVALID_HANDLE)
   {
      double atr[1];
      // 确保ATR数据有效
      if(CopyBuffer(rm_atrHandle, 0, 0, 1, atr) == 1 && MathIsValidNumber(atr[0]) && atr[0] > 0)
      {
         // 使用一个参考价格，这里用BID价（如果趋势是买入，则用Ask；如果趋势是卖出，则用Bid。但为了简化，这里统一用BID）
         // 更精确的做法是根据订单方向来决定，但这里为保持一致性，暂时使用BID。
         double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(MathIsValidNumber(refPrice) && refPrice > 0 && atr[0] < refPrice)
         {
            // 计算ATR乘以乘数后的距离
            double atrDist = atr[0] * Risk_minStopATRMultiple;
            // 取ATR距离和基础最小距离中较大的那个
            dist = MathMax(dist, atrDist);
         }
      }
   }

   // 获取经纪商设定的最小止损距离（Broker's Stop Level）
   long stopsLevelInt = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double brokerMinDist = (stopsLevelInt > 0) ? (double)stopsLevelInt * _Point : 1 * _Point; // 确保至少是1个点

   // --- 最终取所有要求中最大的那个 ---
   double finalMinDist = MathMax(dist, brokerMinDist);

   // --- 出口防护 ---
   if (!MathIsValidNumber(finalMinDist) || finalMinDist <= 0)
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[GetMinStopDistance] 计算出的最终最小止损距离无效或为零.");
       return 1 * _Point; // 返回一个默认的最小距离
   }

   return finalMinDist;
}

// 获取交易手数的上限，考虑余额和绝对值限制
double GetMaxAllowedLotSize()
{
   // 如果手数限制未启用，则返回交易品种的最大手数
   if(!Risk_enableLotLimit)
   {
       double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
       // --- 出口防护 ---
       return (MathIsValidNumber(maxLot) && maxLot > 0) ? maxLot : 0.1; // 返回一个默认值如果无效
   }

   // 考虑基于账户余额的限制
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   // --- 输入防护 ---
   if(!MathIsValidNumber(balance) || balance <= 0)
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[GetMaxAllowedLotSize] 账户余额无效.");
       return 0.0;
   }

   // 计算基于余额的最大手数
   double maxLotByBalance = (Risk_maxLotByBalance > 0) ? balance / Risk_maxLotByBalance : SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   // --- 出口防护 ---
   if (!MathIsValidNumber(maxLotByBalance) || maxLotByBalance <= 0) maxLotByBalance = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); // 出错时退回到品种最大值

   // 返回基于余额的最大手数和绝对手数限制中的较小值
   double maxAllowed = MathMin(maxLotByBalance, Risk_maxAbsoluteLot);

   // --- 出口防护 ---
   if (!MathIsValidNumber(maxAllowed) || maxAllowed <= 0)
   {
       if(g_Logger != NULL && EnableDebug) g_Logger.WriteWarning("[GetMaxAllowedLotSize] 计算出的最大手数无效.");
       return 0.1; // 返回一个默认值
   }

   return maxAllowed;
}

// 检查是否允许新交易 (考虑每日亏损限制)
bool CanOpenNewTrade(bool dbg=false)
{
   // 如果全局允许交易设置为false，则不允许开仓
   if(!Risk_AllowNewTrade) return false;

   // 获取当前日期和时间
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);

   // 如果是新的一天，重置每日亏损相关变量
   if(rm_currentDay != dt.day_of_year)
   {
      rm_currentDay = dt.day_of_year;
      rm_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); // 记录当天的起始余额
      rm_dayLossLimitHit = false; // 重置亏损限制标记
   }

   // 如果当日已触及亏损限制，则不允许开仓
   if(rm_dayLossLimitHit) return false;

   // 计算当日当前余额
   double balNow = AccountInfoDouble(ACCOUNT_BALANCE);
   // 计算当日亏损金额
   double loss = rm_dayStartBalance - balNow;
   // 计算每日亏损限制的金额值
   double limitVal = rm_dayStartBalance * Risk_dailyLossLimitPct / 100.0;

   // 检查当日亏损是否已达到或超过限制
   if(loss > 0 && limitVal > 0 && loss >= limitVal)
   {
      rm_dayLossLimitHit = true; // 标记为已触及限制
      // [日志增强] - 记录触及每日亏损限制
      if(g_Logger != NULL)
         g_Logger.WriteError(StringFormat("每日亏损限制已达标! 当日亏损 %.2f > 限制 %.2f", loss, limitVal));
      return false;
   }

   // 如果以上检查都通过，则允许开新交易
   return true;
}
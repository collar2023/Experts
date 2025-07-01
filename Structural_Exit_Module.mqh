//+------------------------------------------------------------------+
//| Structural_Exit_Module.mqh v1.7 (2025‑07‑06)                     |
//| ★ v1.7: 最终优雅版 - 引入“失败记录”逻辑                        |
//|   通过静态变量记录因FreezeLevel等原因修改失败的SL，在同一根K线  |
//|   内不再对同一价格进行无效的重复尝试，使日志干净，行为高效。     |
//+------------------------------------------------------------------+
#property strict

//==================================================================
//  输入结构体
//==================================================================
struct SStructuralExitInputs
{
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
};

//==================================================================
//  模块内部句柄与静态变量
//==================================================================
static int se_fractalHandle = INVALID_HANDLE;
static int se_atrHandle     = INVALID_HANDLE;

// ★★★ v1.7 核心新增: 用于避免重复无效尝试的静态变量 ★★★
static double   se_last_failed_sl = 0;
static datetime se_last_failed_bar_time = 0;

//==================================================================
//  模块初始化与清理
//==================================================================
bool InitStructuralExitModule(const SStructuralExitInputs &in)
{
   if(in.EnableStructureStop)
   {
      se_fractalHandle = iFractals(_Symbol, _Period);
      if(se_fractalHandle==INVALID_HANDLE)
      {
         Print("[SE] 模块错误: 分形指标初始化失败!");
         return false;
      }
   }
   if(in.EnableATRFallback)
   {
      se_atrHandle = iATR(_Symbol, _Period, in.ATRTrailPeriod);
      if(se_atrHandle==INVALID_HANDLE)
      {
         Print("[SE] 模块错误: ATR指标初始化失败!");
         return false;
      }
   }
   // 重置失败记录
   se_last_failed_sl = 0;
   se_last_failed_bar_time = 0;
   Print("[SE] 模块 v1.7 初始化完成 (最终优雅版)");
   return true;
}

void DeinitStructuralExitModule()
{
   if(se_fractalHandle!=INVALID_HANDLE) IndicatorRelease(se_fractalHandle);
   if(se_atrHandle!=INVALID_HANDLE) IndicatorRelease(se_atrHandle);
}

//==================================================================
//  核心接口函数 (最终优雅版)
//==================================================================
void ManageStructuralExit(CTrade &trade,const SStructuralExitInputs &in,double initialSL)
{
   if(!in.EnableStructuralExit || !PositionSelect(_Symbol)) return;
   
   // --- 1. 获取当前K线时间，用于重置失败记录 ---
   datetime current_bar_time = (datetime)iTime(_Symbol, _Period, 0);
   if(current_bar_time > se_last_failed_bar_time)
   {
      se_last_failed_sl = 0; // 新K线，重置失败记录
   }
   
   // --- 2. 计算理想的止损价 (The "Should-be" SL) ---
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   if (!MathIsValidNumber(openPrice) || !MathIsValidNumber(initialSL)) return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double finalSL = currentSL; 

   // ... (Breakeven, Structural Stop, ATR Fallback 的计算逻辑保持不变) ...
   // --- Breakeven ---
   if(in.EnableBreakeven)
   {
      double riskPts = MathAbs(openPrice - initialSL);
      if(riskPts>0)
      {
         if(type==POSITION_TYPE_BUY && (MarketBid()-openPrice)/riskPts >= in.BreakevenTriggerRR)
         {
            double beSL = openPrice + in.BreakevenBufferPips*_Point;
            if(beSL>finalSL) finalSL = beSL;
         }
         else if(type==POSITION_TYPE_SELL && (openPrice-MarketAsk())/riskPts >= in.BreakevenTriggerRR)
         {
            double beSL = openPrice - in.BreakevenBufferPips*_Point;
            if(beSL<finalSL || finalSL==0) finalSL = beSL;
         }
      }
   }
   // --- Structural Stop (Fractals) ---
   if(in.EnableStructureStop && se_fractalHandle!=INVALID_HANDLE)
   {
      double upperF[], lowerF[];
      if(CopyBuffer(se_fractalHandle,0,1,in.StructureLookback,upperF) == in.StructureLookback &&
         CopyBuffer(se_fractalHandle,1,1,in.StructureLookback,lowerF) == in.StructureLookback)
      {
          if(type==POSITION_TYPE_BUY)
          {
             for(int i=ArraySize(lowerF)-1;i>=0;i--)
             {
                if(lowerF[i] != EMPTY_VALUE) { double stSL = lowerF[i] - in.StructureBufferPips*_Point; if(stSL > finalSL) finalSL = stSL; break; }
             }
          }
          else { for(int i=ArraySize(upperF)-1;i>=0;i--) { if(upperF[i] != EMPTY_VALUE) { double stSL = upperF[i] + in.StructureBufferPips*_Point; if(stSL < finalSL || finalSL == 0) finalSL = stSL; break; } } }
      }
   }
   // --- ATR Fallback Trailing ---
   if(in.EnableATRFallback && se_atrHandle!=INVALID_HANDLE)
   {
      double atr[1];
      if(CopyBuffer(se_atrHandle,0,0,1,atr)==1 && atr[0]>0)
      {
          double refPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
          if (refPrice > 0 && atr[0] < refPrice)
          {
             double price = (type==POSITION_TYPE_BUY)?MarketBid():MarketAsk();
             double trailDist = atr[0]*in.ATRTrailMultiplier;
             double atrSL = (type==POSITION_TYPE_BUY)? price - trailDist : price + trailDist;
             if(type==POSITION_TYPE_BUY && atrSL>finalSL) finalSL=atrSL;
             if(type==POSITION_TYPE_SELL&& (atrSL<finalSL || finalSL==0)) finalSL=atrSL;
          }
      }
   }

   // --- 3. 最终校验与执行 ---
   if (!MathIsValidNumber(finalSL)) return;
   if(finalSL==0 || finalSL==currentSL) return;

   // ★★★ v1.7 核心逻辑：检查是否正在对同一个失败的价格进行重复尝试 ★★★
   if(finalSL == se_last_failed_sl)
   {
      // 在同一根K线上，如果这个价格上次就修改失败了，这次就暂时放弃，等待更好的时机。
      return;
   }
   
   // 委托给风控模块中那个绝对安全的函数来执行
   bool success = SetStopLossWithRetry(trade, finalSL, currentTP, 3);
   
   // 如果修改失败，就记录下这个失败的价格和时间，以便在本根K线内不再尝试
   if(!success)
   {
      se_last_failed_sl = finalSL;
      se_last_failed_bar_time = current_bar_time;
   }
}
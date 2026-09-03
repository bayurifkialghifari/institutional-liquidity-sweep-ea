#property copyright "Institutional Liquidity Sweep EA"
#property version   "1.00"
#property strict
#property description "Asian session liquidity sweep with MSS confirmation and institutional risk controls."

#include <Trade/Trade.mqh>

enum ENUM_TRADING_SESSION
  {
   ASIA_ONLY=0,
   LONDON_ONLY=1,
   NEWYORK_ONLY=2,
   LONDON_AND_NY=3,
   ALL_DAY=4
  };

enum ENUM_LOT_SIZING_MODE
  {
   LOT_FIXED=0,
   LOT_RISK_PERCENT=1
  };

enum ENUM_SYMBOL_PROFILE
  {
   PROFILE_AUTO=0,
   PROFILE_CUSTOM=1,
   PROFILE_XAUUSD=2,
   PROFILE_EURUSD=3,
   PROFILE_USDJPY=4
  };

enum ENUM_LOCK_REASON
  {
   LOCK_NONE=0,
   LOCK_PROFIT_TARGET=1,
   LOCK_LOSS_LIMIT=2,
   LOCK_MAX_TRADES=3,
   LOCK_CONSECUTIVE_LOSSES=4
  };

input group "General Settings"
input ulong                 InpMagicNumber=1001;          // Unique Chart ID
input ENUM_LOT_SIZING_MODE  InpLotSizingMode=LOT_FIXED;
input double                InpLotSize=0.01;              // Fixed lot size
input double                InpRiskPercent=0.50;          // Equity risk per trade
input int                   InpStopLossPips=20;
input int                   InpTakeProfitPips=40;         // Raised automatically when below 2R
input int                   InpMaxSpreadPips=3;

input group "Pair Profile"
input bool                  InpUseAutoPairProfile=true;
input ENUM_SYMBOL_PROFILE   InpSymbolProfile=PROFILE_AUTO;

input group "Strategy Settings"
input ENUM_TIMEFRAMES       InpSignalTimeframe=PERIOD_M5; // CUSTOM profile: M5 or M15
input double                InpSweepBufferPips=1.0;
input int                   InpSwingStrength=2;
input int                   InpSwingLookback=16;
input int                   InpMSSExpiryBars=6;

input group "Session Filter (UTC)"
input ENUM_TRADING_SESSION  InpTradingSession=LONDON_AND_NY;
input int                   InpBrokerUtcOffsetHours=2;    // Broker server time = UTC + offset
input int                   InpAsiaStartHour=0;
input int                   InpAsiaEndHour=6;
input int                   InpLondonStartHour=7;
input int                   InpLondonEndHour=10;
input int                   InpNewYorkStartHour=13;
input int                   InpNewYorkEndHour=16;

input group "Daily Guardrails & Circuit Breakers"
input int                   InpMaxDailyTrades=2;
input int                   InpMaxConsecutiveLosses=2;
input double                InpDailyProfitTargetUSD=200.0;
input double                InpDailyLossLimitUSD=100.0;
input bool                  InpCloseFloatingOnDailyLimit=true;

input group "Execution Safety"
input double                InpMaxSlippagePips=1.0;
input double                InpMinMarginLevelPercent=200.0;

struct EffectiveConfig
  {
   ENUM_TIMEFRAMES      signal_tf;
   ENUM_TRADING_SESSION trading_session;
   int                  stop_loss_pips;
   int                  take_profit_pips;
   int                  max_spread_pips;
   double               sweep_buffer_pips;
   int                  swing_strength;
   int                  swing_lookback;
   int                  mss_expiry_bars;
   string               profile_name;
  };

struct SignalState
  {
   bool     armed;
   bool     traded;
   datetime sweep_time;
   double   structure_level;
   int      elapsed_bars;
  };

struct ClosedTradeStat
  {
   ulong    position_id;
   datetime close_time;
   double   net_pnl;
  };

struct DailyStats
  {
   datetime day_start;
   double   closed_pnl;
   int      total_trades;
   int      consecutive_losses;
  };

CTrade          g_trade;
EffectiveConfig g_config;
SignalState     g_buy_state;
SignalState     g_sell_state;
DailyStats      g_daily_stats;

datetime g_last_signal_bar=0;
datetime g_asia_start=0;
datetime g_asia_end=0;
double   g_asia_high=0.0;
double   g_asia_low=0.0;
bool     g_asia_ready=false;
bool     g_stats_dirty=true;
datetime g_last_close_attempt=0;
string   g_instance_key="";

// Forward declarations
bool   ValidateInputs();
void   LoadEffectiveConfig();
bool   RefreshAsianRange();
bool   EvaluateRiskGuards(const bool allow_close);
void   ProcessClosedSignalBar();
bool   TryOpenPosition(const bool is_buy,const datetime range_id);
int    MaxInt(const int first,const int second);

int OnInit()
  {
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   LoadEffectiveConfig();
   g_instance_key=StringFormat("ILS.%I64d.%s.%I64u",
                               AccountInfoInteger(ACCOUNT_LOGIN),_Symbol,InpMagicNumber);
   if(StringLen(g_instance_key)>48)
      g_instance_key=StringSubstr(g_instance_key,0,48);

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints((ulong)MathCeil(InpMaxSlippagePips*PipSize()/_Point));
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   ResetSignalState(g_buy_state);
   ResetSignalState(g_sell_state);
   g_last_signal_bar=iTime(_Symbol,g_config.signal_tf,0);
   g_daily_stats.day_start=0;
   g_stats_dirty=true;

   string currency=AccountInfoString(ACCOUNT_CURRENCY);
   if(currency!="USD")
      PrintFormat("WARNING: Daily USD inputs are interpreted in account deposit currency (%s).",currency);

   RefreshAsianRange();
   EvaluateRiskGuards(false);
   PrintFormat("Initialized %s | profile=%s | TF=%s | session=%s | SL=%d | TP=%d | spread=%d",
               _Symbol,g_config.profile_name,EnumToString(g_config.signal_tf),
               EnumToString(g_config.trading_session),g_config.stop_loss_pips,
               g_config.take_profit_pips,g_config.max_spread_pips);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   PrintFormat("Deinitialized %s magic=%I64u reason=%d",_Symbol,InpMagicNumber,reason);
  }

void OnTick()
  {
   RefreshAsianRange();
   if(!EvaluateRiskGuards(true))
     {
      CancelArmedSignals();
      return;
     }

   datetime current_bar=iTime(_Symbol,g_config.signal_tf,0);
   if(current_bar<=0 || current_bar==g_last_signal_bar)
      return;

   g_last_signal_bar=current_bar;
   ProcessClosedSignalBar();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD ||
      trans.type==TRADE_TRANSACTION_HISTORY_ADD ||
      trans.type==TRADE_TRANSACTION_POSITION)
      g_stats_dirty=true;
  }

bool ValidateInputs()
  {
   if(InpMagicNumber==0 || InpLotSize<=0.0 || InpRiskPercent<=0.0 || InpRiskPercent>10.0)
     {
      Print("Invalid magic number, lot size, or risk percentage.");
      return(false);
     }
   if(InpStopLossPips<=0 || InpTakeProfitPips<=0 || InpMaxSpreadPips<=0 ||
      InpMaxSlippagePips<0.0 || InpMinMarginLevelPercent<0.0)
     {
      Print("Invalid stop, target, spread, slippage, or margin settings.");
      return(false);
     }
   if(InpMaxDailyTrades<1 || InpMaxConsecutiveLosses<1 ||
      InpDailyProfitTargetUSD<0.0 || InpDailyLossLimitUSD<0.0)
     {
      Print("Invalid daily guardrail settings.");
      return(false);
     }
   if(InpSignalTimeframe!=PERIOD_M5 && InpSignalTimeframe!=PERIOD_M15)
     {
      Print("Signal timeframe must be M5 or M15.");
      return(false);
     }
   if(InpSweepBufferPips<0.0 || InpSwingStrength<1 || InpSwingLookback<5 ||
      InpMSSExpiryBars<1)
     {
      Print("Invalid strategy settings.");
      return(false);
     }
   if(!ValidHour(InpAsiaStartHour) || !ValidHour(InpAsiaEndHour) ||
      !ValidHour(InpLondonStartHour) || !ValidHour(InpLondonEndHour) ||
      !ValidHour(InpNewYorkStartHour) || !ValidHour(InpNewYorkEndHour) ||
      InpAsiaStartHour==InpAsiaEndHour ||
      InpBrokerUtcOffsetHours<-14 || InpBrokerUtcOffsetHours>14)
     {
      Print("Invalid UTC session hours or broker UTC offset.");
      return(false);
     }
   return(true);
  }

bool ValidHour(const int hour)
  {
   return(hour>=0 && hour<=23);
  }

void LoadEffectiveConfig()
  {
   g_config.signal_tf=InpSignalTimeframe;
   g_config.trading_session=InpTradingSession;
   g_config.stop_loss_pips=InpStopLossPips;
   g_config.take_profit_pips=MaxInt(InpTakeProfitPips,InpStopLossPips*2);
   g_config.max_spread_pips=InpMaxSpreadPips;
   g_config.sweep_buffer_pips=InpSweepBufferPips;
   g_config.swing_strength=InpSwingStrength;
   g_config.swing_lookback=InpSwingLookback;
   g_config.mss_expiry_bars=InpMSSExpiryBars;
   g_config.profile_name="CUSTOM";

   if(!InpUseAutoPairProfile || InpSymbolProfile==PROFILE_CUSTOM)
      return;

   ENUM_SYMBOL_PROFILE profile=InpSymbolProfile;
   if(profile==PROFILE_AUTO)
      profile=DetectSymbolProfile();

   if(profile==PROFILE_XAUUSD)
     {
      g_config.signal_tf=PERIOD_M15;
      g_config.trading_session=LONDON_AND_NY;
      g_config.stop_loss_pips=300;
      g_config.take_profit_pips=600;
      g_config.max_spread_pips=50;
      g_config.sweep_buffer_pips=20.0;
      g_config.swing_strength=2;
      g_config.swing_lookback=16;
      g_config.mss_expiry_bars=4;
      g_config.profile_name="XAUUSD_CONSERVATIVE";
     }
   else if(profile==PROFILE_EURUSD)
     {
      g_config.signal_tf=PERIOD_M5;
      g_config.trading_session=LONDON_AND_NY;
      g_config.stop_loss_pips=20;
      g_config.take_profit_pips=40;
      g_config.max_spread_pips=2;
      g_config.sweep_buffer_pips=1.0;
      g_config.swing_strength=2;
      g_config.swing_lookback=16;
      g_config.mss_expiry_bars=6;
      g_config.profile_name="EURUSD_CONSERVATIVE";
     }
   else if(profile==PROFILE_USDJPY)
     {
      g_config.signal_tf=PERIOD_M15;
      g_config.trading_session=LONDON_ONLY;
      g_config.stop_loss_pips=20;
      g_config.take_profit_pips=40;
      g_config.max_spread_pips=2;
      g_config.sweep_buffer_pips=1.0;
      g_config.swing_strength=2;
      g_config.swing_lookback=16;
      g_config.mss_expiry_bars=4;
      g_config.profile_name="USDJPY_CONSERVATIVE";
     }
   else
      PrintFormat("No automatic profile for %s; CUSTOM inputs will be used.",_Symbol);
  }

ENUM_SYMBOL_PROFILE DetectSymbolProfile()
  {
   string symbol=_Symbol;
   StringToUpper(symbol);
   if(StringFind(symbol,"XAUUSD")>=0) return(PROFILE_XAUUSD);
   if(StringFind(symbol,"EURUSD")>=0) return(PROFILE_EURUSD);
   if(StringFind(symbol,"USDJPY")>=0) return(PROFILE_USDJPY);
   return(PROFILE_CUSTOM);
  }

double PipSize()
  {
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(digits==3 || digits==5)
      return(point*10.0);
   return(point);
  }

datetime UtcNow()
  {
   return(TimeCurrent()-InpBrokerUtcOffsetHours*3600);
  }

datetime UtcMidnight(const datetime utc_time)
  {
   MqlDateTime parts;
   TimeToStruct(utc_time,parts);
   parts.hour=0;
   parts.min=0;
   parts.sec=0;
   return(StructToTime(parts));
  }

void GetLastCompletedAsiaWindow(datetime &server_start,datetime &server_end)
  {
   datetime now_utc=UtcNow();
   datetime midnight=UtcMidnight(now_utc);
   datetime end_today=midnight+InpAsiaEndHour*3600;
   datetime end_utc=(now_utc>=end_today ? end_today : end_today-86400);

   int duration_hours;
   if(InpAsiaEndHour>InpAsiaStartHour)
      duration_hours=InpAsiaEndHour-InpAsiaStartHour;
   else
      duration_hours=24-InpAsiaStartHour+InpAsiaEndHour;

   datetime start_utc=end_utc-duration_hours*3600;
   int offset_seconds=InpBrokerUtcOffsetHours*3600;
   server_start=start_utc+offset_seconds;
   server_end=end_utc+offset_seconds;
  }

bool RefreshAsianRange()
  {
   datetime range_start,range_end;
   GetLastCompletedAsiaWindow(range_start,range_end);
   if(g_asia_ready && range_start==g_asia_start)
      return(true);

   MqlRates rates[];
   int copied=CopyRates(_Symbol,PERIOD_M5,range_start,range_end-1,rates);
   if(copied<=0)
     {
      g_asia_ready=false;
      return(false);
     }

   double high=rates[0].high;
   double low=rates[0].low;
   for(int i=1;i<copied;i++)
     {
      if(rates[i].high>high) high=rates[i].high;
      if(rates[i].low<low) low=rates[i].low;
     }

   g_asia_start=range_start;
   g_asia_end=range_end;
   g_asia_high=high;
   g_asia_low=low;
   g_asia_ready=true;
   ResetSignalState(g_buy_state);
   ResetSignalState(g_sell_state);
   g_buy_state.traded=DirectionAlreadyTraded(true,range_start);
   g_sell_state.traded=DirectionAlreadyTraded(false,range_start);
   PrintFormat("Asian range ready: %s - %s | high=%.*f low=%.*f",
               TimeToString(range_start,TIME_DATE|TIME_MINUTES),
               TimeToString(range_end,TIME_DATE|TIME_MINUTES),
               _Digits,high,_Digits,low);
   return(true);
  }

bool HourInWindow(const int hour,const int start_hour,const int end_hour)
  {
   if(start_hour==end_hour) return(true);
   if(start_hour<end_hour) return(hour>=start_hour && hour<end_hour);
   return(hour>=start_hour || hour<end_hour);
  }

bool IsTradingSessionOpen()
  {
   if(g_config.trading_session==ALL_DAY)
      return(true);

   MqlDateTime utc;
   TimeToStruct(UtcNow(),utc);
   bool asia=HourInWindow(utc.hour,InpAsiaStartHour,InpAsiaEndHour);
   bool london=HourInWindow(utc.hour,InpLondonStartHour,InpLondonEndHour);
   bool new_york=HourInWindow(utc.hour,InpNewYorkStartHour,InpNewYorkEndHour);

   if(g_config.trading_session==ASIA_ONLY) return(asia);
   if(g_config.trading_session==LONDON_ONLY) return(london);
   if(g_config.trading_session==NEWYORK_ONLY) return(new_york);
   return(london || new_york);
  }

void ResetSignalState(SignalState &state)
  {
   state.armed=false;
   state.traded=false;
   state.sweep_time=0;
   state.structure_level=0.0;
   state.elapsed_bars=0;
  }

void CancelArmedSignals()
  {
   g_buy_state.armed=false;
   g_sell_state.armed=false;
   g_buy_state.elapsed_bars=0;
   g_sell_state.elapsed_bars=0;
  }

double FindRecentSwing(const bool find_high)
  {
   int strength=g_config.swing_strength;
   int first_shift=strength+1;
   int last_shift=g_config.swing_lookback+strength;
   int available=Bars(_Symbol,g_config.signal_tf);
   if(available<=last_shift+strength)
      return(0.0);

   for(int shift=first_shift;shift<=last_shift;shift++)
     {
      double pivot=(find_high ? iHigh(_Symbol,g_config.signal_tf,shift)
                              : iLow(_Symbol,g_config.signal_tf,shift));
      if(pivot<=0.0) continue;
      bool confirmed=true;
      for(int side=1;side<=strength;side++)
        {
         double newer=(find_high ? iHigh(_Symbol,g_config.signal_tf,shift-side)
                                 : iLow(_Symbol,g_config.signal_tf,shift-side));
         double older=(find_high ? iHigh(_Symbol,g_config.signal_tf,shift+side)
                                 : iLow(_Symbol,g_config.signal_tf,shift+side));
         if(find_high && (pivot<=newer || pivot<=older)) confirmed=false;
         if(!find_high && (pivot>=newer || pivot>=older)) confirmed=false;
         if(!confirmed) break;
        }
      if(confirmed) return(pivot);
     }
   return(0.0);
  }

void ProcessClosedSignalBar()
  {
   if(!g_asia_ready || !IsTradingSessionOpen())
     {
      CancelArmedSignals();
      return;
     }
   if(HasBlockingPosition())
      return;

   datetime bar_time=iTime(_Symbol,g_config.signal_tf,1);
   double high=iHigh(_Symbol,g_config.signal_tf,1);
   double low=iLow(_Symbol,g_config.signal_tf,1);
   double close=iClose(_Symbol,g_config.signal_tf,1);
   if(bar_time<=0 || high<=0.0 || low<=0.0 || close<=0.0)
      return;

   // Existing setups can only confirm on a candle after the sweep candle.
   ProcessArmedState(g_buy_state,true,bar_time,close);
   ProcessArmedState(g_sell_state,false,bar_time,close);
   if(HasBlockingPosition())
      return;

   double buffer=g_config.sweep_buffer_pips*PipSize();
   bool swept_low=(low<g_asia_low-buffer && close>g_asia_low);
   bool swept_high=(high>g_asia_high+buffer && close<g_asia_high);

   if(swept_low && swept_high)
     {
      Print("Ambiguous candle swept both Asian extremes; setup ignored.");
      return;
     }

   if(swept_low && !g_buy_state.traded && !g_buy_state.armed)
     {
      double swing_high=FindRecentSwing(true);
      if(swing_high>0.0)
        {
         g_buy_state.armed=true;
         g_buy_state.sweep_time=bar_time;
         g_buy_state.structure_level=swing_high;
         g_buy_state.elapsed_bars=0;
         PrintFormat("Bullish sweep armed; MSS close must exceed %.*f",_Digits,swing_high);
        }
     }

   if(swept_high && !g_sell_state.traded && !g_sell_state.armed)
     {
      double swing_low=FindRecentSwing(false);
      if(swing_low>0.0)
        {
         g_sell_state.armed=true;
         g_sell_state.sweep_time=bar_time;
         g_sell_state.structure_level=swing_low;
         g_sell_state.elapsed_bars=0;
         PrintFormat("Bearish sweep armed; MSS close must fall below %.*f",_Digits,swing_low);
        }
     }
  }

void ProcessArmedState(SignalState &state,const bool is_buy,
                       const datetime bar_time,const double close_price)
  {
   if(!state.armed || bar_time<=state.sweep_time)
      return;

   state.elapsed_bars++;
   bool confirmed=(is_buy ? close_price>state.structure_level
                          : close_price<state.structure_level);
   if(confirmed)
     {
      state.armed=false;
      if(TryOpenPosition(is_buy,g_asia_start))
        {
         state.traded=true;
         MarkDirectionTraded(is_buy,g_asia_start);
        }
      return;
     }

   if(state.elapsed_bars>=g_config.mss_expiry_bars)
     {
      state.armed=false;
      PrintFormat("%s MSS setup expired.",is_buy ? "Bullish" : "Bearish");
     }
  }

bool TryOpenPosition(const bool is_buy,const datetime range_id)
  {
   if(!EvaluateRiskGuards(false) || HasBlockingPosition() || !IsTradingSessionOpen())
      return(false);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0.0 || tick.bid<=0.0)
     {
      Print("Entry rejected: invalid market tick.");
      return(false);
     }

   double spread_pips=(tick.ask-tick.bid)/PipSize();
   if(spread_pips>g_config.max_spread_pips)
     {
      PrintFormat("Entry rejected: spread %.2f pips exceeds %d.",
                  spread_pips,g_config.max_spread_pips);
      return(false);
     }

   double entry=(is_buy ? tick.ask : tick.bid);
   double sl_distance=g_config.stop_loss_pips*PipSize();
   int tp_pips=MaxInt(g_config.take_profit_pips,g_config.stop_loss_pips*2);
   double tp_distance=tp_pips*PipSize();
   double sl=NormalizeTradePrice(entry+(is_buy ? -sl_distance : sl_distance),!is_buy);
   double tp=NormalizeTradePrice(entry+(is_buy ? tp_distance : -tp_distance),is_buy);

   if(!StopsAreValid(entry,sl,tp))
     {
      Print("Entry rejected: requested SL/TP violates broker stop distance.");
      return(false);
     }

   ENUM_ORDER_TYPE order_type=(is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double volume=CalculateVolume(order_type,entry,sl);
   if(volume<=0.0)
      return(false);

   MqlTradeRequest request;
   MqlTradeCheckResult check;
   ZeroMemory(request);
   ZeroMemory(check);
   request.action=TRADE_ACTION_DEAL;
   request.magic=InpMagicNumber;
   request.symbol=_Symbol;
   request.volume=volume;
   request.type=order_type;
   request.price=entry;
   request.sl=sl;
   request.tp=tp;
   request.deviation=(ulong)MathCeil(InpMaxSlippagePips*PipSize()/_Point);
   request.type_filling=SupportedFillingMode();
   request.type_time=ORDER_TIME_GTC;
   request.comment=BuildOrderComment(is_buy,range_id);

   double required_margin=0.0;
   if(!OrderCalcMargin(order_type,_Symbol,volume,entry,required_margin))
     {
      PrintFormat("Entry rejected: OrderCalcMargin failed (%d).",GetLastError());
      return(false);
     }
   if(required_margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE))
     {
      PrintFormat("Entry rejected: margin %.2f exceeds free margin %.2f.",
                  required_margin,AccountInfoDouble(ACCOUNT_MARGIN_FREE));
      return(false);
     }
   if(!OrderCheck(request,check))
     {
      PrintFormat("Entry rejected by OrderCheck: %u %s",check.retcode,check.comment);
      return(false);
     }
   if(InpMinMarginLevelPercent>0.0 && check.margin_level>0.0 &&
      check.margin_level<InpMinMarginLevelPercent)
     {
      PrintFormat("Entry rejected: projected margin level %.2f%% is below %.2f%%.",
                  check.margin_level,InpMinMarginLevelPercent);
      return(false);
     }

   g_trade.SetTypeFillingBySymbol(_Symbol);
   bool sent=(is_buy ? g_trade.Buy(volume,_Symbol,entry,sl,tp,request.comment)
                     : g_trade.Sell(volume,_Symbol,entry,sl,tp,request.comment));
   uint retcode=g_trade.ResultRetcode();
   if(!sent || (retcode!=TRADE_RETCODE_DONE && retcode!=TRADE_RETCODE_DONE_PARTIAL &&
                retcode!=TRADE_RETCODE_PLACED))
     {
      PrintFormat("Order failed: retcode=%u %s",retcode,g_trade.ResultRetcodeDescription());
      return(false);
     }

   double fill_price=g_trade.ResultPrice();
   if(fill_price>0.0)
     {
      double slippage=MathAbs(fill_price-entry)/PipSize();
      if(slippage>InpMaxSlippagePips+0.000001)
         PrintFormat("WARNING: reported fill slippage %.2f pips exceeded configured %.2f.",
                     slippage,InpMaxSlippagePips);
     }

   g_stats_dirty=true;
   PrintFormat("%s opened: volume=%.*f entry=%.*f SL=%.*f TP=%.*f deal=%I64u",
               is_buy ? "BUY" : "SELL",VolumeDigits(),volume,_Digits,
               fill_price,_Digits,sl,_Digits,tp,g_trade.ResultDeal());
   return(true);
  }

double NormalizeTradePrice(const double price,const bool round_up)
  {
   double tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick_size<=0.0) tick_size=_Point;
   double units=price/tick_size;
   double normalized=(round_up ? MathCeil(units-1e-10) : MathFloor(units+1e-10))*tick_size;
   return(NormalizeDouble(normalized,_Digits));
  }

bool StopsAreValid(const double entry,const double sl,const double tp)
  {
   long stops_level=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minimum=stops_level*_Point;
   if(MathAbs(entry-sl)+1e-10<minimum || MathAbs(tp-entry)+1e-10<minimum)
      return(false);
   return(true);
  }

double CalculateVolume(const ENUM_ORDER_TYPE order_type,const double entry,const double sl)
  {
   double min_volume=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double max_volume=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double volume;

   if(InpLotSizingMode==LOT_FIXED)
     {
      if(InpLotSize+1e-10<min_volume || InpLotSize-1e-10>max_volume)
        {
         PrintFormat("Entry rejected: fixed volume %.4f outside broker range %.4f-%.4f.",
                     InpLotSize,min_volume,max_volume);
         return(0.0);
        }
      volume=NormalizeVolumeDown(InpLotSize);
     }
   else
     {
      double loss_one_lot=0.0;
      if(!OrderCalcProfit(order_type,_Symbol,1.0,entry,sl,loss_one_lot))
        {
         PrintFormat("Entry rejected: OrderCalcProfit failed (%d).",GetLastError());
         return(0.0);
        }
      loss_one_lot=MathAbs(loss_one_lot);
      if(loss_one_lot<=0.0)
        {
         Print("Entry rejected: invalid one-lot risk calculation.");
         return(0.0);
        }
      double risk_money=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;
      volume=NormalizeVolumeDown(risk_money/loss_one_lot);
      if(volume>max_volume) volume=NormalizeVolumeDown(max_volume);
      if(volume+1e-10<min_volume)
        {
         PrintFormat("Entry rejected: risk-based volume %.4f is below broker minimum %.4f.",
                     volume,min_volume);
         return(0.0);
        }
     }

   return(NormalizeDouble(volume,VolumeDigits()));
  }

double NormalizeVolumeDown(const double requested)
  {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double max_volume=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0.0) return(0.0);
   double bounded=MathMin(requested,max_volume);
   return(MathFloor((bounded+1e-12)/step)*step);
  }

int VolumeDigits()
  {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   int digits=0;
   while(digits<8 && MathAbs(step-NormalizeDouble(step,digits))>1e-10)
      digits++;
   return(digits);
  }

ENUM_ORDER_TYPE_FILLING SupportedFillingMode()
  {
   long modes=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return(ORDER_FILLING_FOK);
   if((modes & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return(ORDER_FILLING_IOC);
   return(ORDER_FILLING_RETURN);
  }

bool HasBlockingPosition()
  {
   ENUM_ACCOUNT_MARGIN_MODE margin_mode=(ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   bool netting=(margin_mode==ACCOUNT_MARGIN_MODE_RETAIL_NETTING ||
                 margin_mode==ACCOUNT_MARGIN_MODE_EXCHANGE);

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      ulong magic=(ulong)PositionGetInteger(POSITION_MAGIC);
      if(magic==InpMagicNumber) return(true);
      if(netting)
        {
         PrintFormat("Trading blocked: netting position on %s belongs to magic %I64u.",_Symbol,magic);
         return(true);
        }
     }
   return(false);
  }

double FloatingPnL()
  {
   double total=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      total+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }
   return(total);
  }

bool EvaluateRiskGuards(const bool allow_close)
  {
   datetime day_start=iTime(_Symbol,PERIOD_D1,0);
   if(day_start<=0) return(false);
   if(g_daily_stats.day_start!=day_start)
     {
      g_stats_dirty=true;
      ClearExpiredLock(day_start);
     }
   if(g_stats_dirty && !RefreshDailyStats(day_start))
      return(false);

   ENUM_LOCK_REASON persisted=PersistedMoneyLock(day_start);
   if(persisted==LOCK_PROFIT_TARGET || persisted==LOCK_LOSS_LIMIT)
     {
      if(allow_close && InpCloseFloatingOnDailyLimit) CloseOwnedPositionsThrottled();
      return(false);
     }

   double daily_net=g_daily_stats.closed_pnl+FloatingPnL();
   if(InpDailyProfitTargetUSD>0.0 && daily_net>=InpDailyProfitTargetUSD)
     {
      PersistMoneyLock(day_start,LOCK_PROFIT_TARGET);
      PrintFormat("Daily profit target reached: %.2f. Trading locked.",daily_net);
      if(allow_close && InpCloseFloatingOnDailyLimit) CloseOwnedPositionsThrottled();
      return(false);
     }
   if(InpDailyLossLimitUSD>0.0 && daily_net<=-InpDailyLossLimitUSD)
     {
      PersistMoneyLock(day_start,LOCK_LOSS_LIMIT);
      PrintFormat("Daily loss limit reached: %.2f. Trading locked.",daily_net);
      if(allow_close && InpCloseFloatingOnDailyLimit) CloseOwnedPositionsThrottled();
      return(false);
     }
   if(g_daily_stats.total_trades>=InpMaxDailyTrades)
      return(false);
   if(g_daily_stats.consecutive_losses>=InpMaxConsecutiveLosses)
      return(false);
   return(true);
  }

bool RefreshDailyStats(const datetime day_start)
  {
   if(!HistorySelect(day_start,TimeCurrent()))
     {
      PrintFormat("HistorySelect failed (%d).",GetLastError());
      return(false);
     }

   ClosedTradeStat closed[];
   ulong trade_ids[];
   int deal_total=HistoryDealsTotal();

   for(int i=0;i<deal_total;i++)
     {
      ulong ticket=HistoryDealGetTicket(i);
      if(!IsOwnedDeal(ticket)) continue;
      ulong position_id=(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);

      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT ||
         entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
         AddUniqueId(trade_ids,position_id);

      if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)
        {
         int index=FindClosedTrade(closed,position_id);
         if(index<0)
           {
            index=ArraySize(closed);
            ArrayResize(closed,index+1);
            closed[index].position_id=position_id;
            closed[index].close_time=0;
            closed[index].net_pnl=0.0;
           }
         datetime deal_time=(datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
         if(deal_time>closed[index].close_time) closed[index].close_time=deal_time;
        }
     }

   // Remove partially open positions from the closed-trade list.
   for(int i=ArraySize(closed)-1;i>=0;i--)
     {
      if(IsPositionIdentifierOpen(closed[i].position_id))
         RemoveClosedTrade(closed,i);
     }

   // Include all same-day charges belonging to positions which closed today.
   for(int i=0;i<deal_total;i++)
     {
      ulong ticket=HistoryDealGetTicket(i);
      if(!IsOwnedDeal(ticket)) continue;
      ulong position_id=(ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      int index=FindClosedTrade(closed,position_id);
      if(index<0) continue;
      closed[index].net_pnl+=HistoryDealGetDouble(ticket,DEAL_PROFIT)
                             +HistoryDealGetDouble(ticket,DEAL_SWAP)
                             +HistoryDealGetDouble(ticket,DEAL_COMMISSION)
                             +HistoryDealGetDouble(ticket,DEAL_FEE);
     }

   SortClosedTradesNewestFirst(closed);
   double closed_pnl=0.0;
   for(int i=0;i<ArraySize(closed);i++) closed_pnl+=closed[i].net_pnl;

   int losses=0;
   for(int i=0;i<ArraySize(closed);i++)
     {
      if(closed[i].net_pnl<0.0) losses++;
      else break;
     }

   g_daily_stats.day_start=day_start;
   g_daily_stats.closed_pnl=closed_pnl;
   g_daily_stats.total_trades=ArraySize(trade_ids);
   g_daily_stats.consecutive_losses=losses;
   g_stats_dirty=false;
   return(true);
  }

bool IsOwnedDeal(const ulong ticket)
  {
   if(ticket==0) return(false);
   if(HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol) return(false);
   return((ulong)HistoryDealGetInteger(ticket,DEAL_MAGIC)==InpMagicNumber);
  }

void AddUniqueId(ulong &ids[],const ulong id)
  {
   if(id==0) return;
   for(int i=0;i<ArraySize(ids);i++) if(ids[i]==id) return;
   int size=ArraySize(ids);
   ArrayResize(ids,size+1);
   ids[size]=id;
  }

int FindClosedTrade(ClosedTradeStat &trades[],const ulong position_id)
  {
   for(int i=0;i<ArraySize(trades);i++)
      if(trades[i].position_id==position_id) return(i);
   return(-1);
  }

void RemoveClosedTrade(ClosedTradeStat &trades[],const int index)
  {
   int size=ArraySize(trades);
   for(int i=index;i<size-1;i++) trades[i]=trades[i+1];
   ArrayResize(trades,size-1);
  }

bool IsPositionIdentifierOpen(const ulong position_id)
  {
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER)==position_id) return(true);
     }
   return(false);
  }

void SortClosedTradesNewestFirst(ClosedTradeStat &trades[])
  {
   int size=ArraySize(trades);
   for(int i=0;i<size-1;i++)
      for(int j=i+1;j<size;j++)
         if(trades[j].close_time>trades[i].close_time)
           {
            ClosedTradeStat temp=trades[i];
            trades[i]=trades[j];
            trades[j]=temp;
           }
  }

void CloseOwnedPositionsThrottled()
  {
   datetime now=TimeCurrent();
   if(now-g_last_close_attempt<5) return;
   g_last_close_attempt=now;

   ulong deviation=(ulong)MathCeil(InpMaxSlippagePips*PipSize()/_Point);
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      if(!g_trade.PositionClose(ticket,deviation))
         PrintFormat("Emergency close failed for ticket %I64u: %u %s",ticket,
                     g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      else
         PrintFormat("Emergency close submitted for ticket %I64u.",ticket);
     }
  }

string LockDayKey()    { return(g_instance_key+".lockday"); }
string LockReasonKey() { return(g_instance_key+".lockwhy"); }
string DirectionKey(const bool is_buy)
  {
   return(g_instance_key+(is_buy ? ".buyrange" : ".sellrange"));
  }

void ClearExpiredLock(const datetime day_start)
  {
   if(GlobalVariableCheck(LockDayKey()) &&
      (datetime)GlobalVariableGet(LockDayKey())!=day_start)
     {
      GlobalVariableDel(LockDayKey());
      GlobalVariableDel(LockReasonKey());
     }
  }

ENUM_LOCK_REASON PersistedMoneyLock(const datetime day_start)
  {
   if(!GlobalVariableCheck(LockDayKey()) || !GlobalVariableCheck(LockReasonKey()))
      return(LOCK_NONE);
   if((datetime)GlobalVariableGet(LockDayKey())!=day_start)
      return(LOCK_NONE);
   return((ENUM_LOCK_REASON)(int)GlobalVariableGet(LockReasonKey()));
  }

void PersistMoneyLock(const datetime day_start,const ENUM_LOCK_REASON reason)
  {
   GlobalVariableSet(LockDayKey(),(double)day_start);
   GlobalVariableSet(LockReasonKey(),(double)reason);
   GlobalVariablesFlush();
  }

bool DirectionAlreadyTraded(const bool is_buy,const datetime range_id)
  {
   string key=DirectionKey(is_buy);
   return(GlobalVariableCheck(key) && (datetime)GlobalVariableGet(key)==range_id);
  }

void MarkDirectionTraded(const bool is_buy,const datetime range_id)
  {
   GlobalVariableSet(DirectionKey(is_buy),(double)range_id);
   GlobalVariablesFlush();
  }

string BuildOrderComment(const bool is_buy,const datetime range_id)
  {
   return(StringFormat("ILS|%I64d|%s",(long)range_id,is_buy ? "B" : "S"));
  }

int MaxInt(const int first,const int second)
  {
   return(first>second ? first : second);
  }

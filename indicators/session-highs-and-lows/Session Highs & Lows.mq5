//+------------------------------------------------------------------+
//| Session Highs & Lows.mq5                                         |
//| Author: Enrique Briceno                                          |
//| Copyright (c) 2026 Enrique Briceno                               |
//| License: MIT (see LICENSE file)                                  |
//| GitHub: https://github.com/enr1quecido/trading-tools             |
//|                                                                  |
//| Displays historical highs and lows for Asia, Europe and USA.     |
//| This indicator does not execute or manage trades.                |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026 Enrique Briceno"
#property link      "https://github.com/enr1quecido/trading-tools"
#property version   "1.50"
#property description "Session Highs & Lows by Enrique Briceno"
#property strict
#property indicator_chart_window
#property indicator_plots 0
#property indicator_buffers 0

// Session times below can use Berlin local time (default) or UTC (GMT+0).
// Europe defaults to the EA's confirmed 07:00-09:00 BERLIN range.
enum ENUM_SESSION_TIME_BASIS
  {
   SESSION_TIME_BERLIN=0,  // Berlin local time, automatic CET/CEST
   SESSION_TIME_UTC=1      // UTC (GMT+0), no daylight-saving shift
  };

input int InpMaxCandles = 1000;                  // Maximum number of candles to be calculated
input bool InpShowBuySellLevels = false;         // Show BUY/SELL breakout lines
input bool InpShowText = false;                  // Show text labels and status

input group "Session times"
input ENUM_SESSION_TIME_BASIS InpSessionTimeBasis = SESSION_TIME_BERLIN; // Time basis for all sessions
input bool   InpShowAsia = true;                // Show Asia
input string InpAsiaStart = "00:10";             // Asia session begin (HH:MM)
input string InpAsiaEnd   = "07:00";             // Asia session end (HH:MM)
input bool   InpShowEurope = false;               // Show Europe (EA range)
input string InpEuropeStart = "07:00";           // Europe session begin (HH:MM)
input string InpEuropeEnd   = "09:00";           // Europe session end (HH:MM)
input bool   InpShowUSA = false;                 // Show USA
input string InpUSAStart = "13:00";              // USA session begin (HH:MM)
input string InpUSAEnd   = "22:00";              // USA session end (HH:MM)

input group "Range / levels"
input double InpBreakoutBufferPips = 1.0;        // +/- 1 pip from session high/low
input double InpMinValidRangePips = 8.0;         // EA validity check for Europe
input double InpMaxValidRangePips = 20.0;        // EA validity check for Europe

input group "Broker server time"
input bool InpUseAutomaticUTCOffset = true;     // Auto-detect from server clock and UTC
input int InpManualServerUTCOffsetMinutes = 120; // UTC+2 = 120 (tester: set manually)
input bool InpBrokerFollowsEuropeanDST = true;  // Historical broker offset assumption

input group "Appearance"
input color InpAsiaColor = clrRed;
input color InpRangeColor = clrDodgerBlue;       // Europe range color
input color InpUSAColor = clrSeaGreen;
input color InpBreakoutColor = clrDarkOrange;
input ENUM_LINE_STYLE InpHighLineStyle = STYLE_DASH; // HIGH line style
input ENUM_LINE_STYLE InpLowLineStyle = STYLE_SOLID;  // LOW line style
input int InpLineWidth = 1;
input string InpObjectTag = "SessionHighsLows";

int g_startMinutes[3];
int g_endMinutes[3];

string   g_prefix="";
int      g_lastOffsetMinutes=100000;
string   g_lastStatus="";
datetime g_lastCalculatedM5=0;
datetime g_lastRecalculation=0;
bool     g_hasCalculated=false;
double   g_pip=0.0;

// Last Sunday of March/October, 01:00 UTC (European daylight saving).
int LastSunday(int year,int month)
  {
   MqlDateTime first={};
   first.year=year; first.mon=(month==12?1:month+1);
   if(month==12)first.year=year+1;
   first.day=1;
   datetime nextMonth=StructToTime(first);
   datetime lastDay=nextMonth-86400;
   MqlDateTime d={};
   TimeToStruct(lastDay,d);
   return d.day-d.day_of_week;
  }

datetime CivilTime(int year,int month,int day,int hour,int minute=0)
  {
   MqlDateTime d={};
   d.year=year; d.mon=month; d.day=day;
   d.hour=hour; d.min=minute;
   return StructToTime(d);
  }

int BerlinUTCOffsetSeconds(datetime utc)
  {
   MqlDateTime d={};
   TimeToStruct(utc,d);
   datetime dstStart=CivilTime(d.year,3,LastSunday(d.year,3),1);
   datetime dstEnd=CivilTime(d.year,10,LastSunday(d.year,10),1);
   return (utc>=dstStart && utc<dstEnd)?7200:3600;
  }

int DayKey(datetime berlin)
  {
   MqlDateTime d={};TimeToStruct(berlin,d);
   return d.year*10000+d.mon*100+d.day;
  }

bool ReadClock(datetime &utcNow,int &serverOffsetSeconds)
  {
   if((bool)MQLInfoInteger(MQL_TESTER))
     {
      // In Strategy Tester TimeGMT() may equal simulated server time.
      // Require a verified fixed server offset to interpret that test day's candles.
      if(InpUseAutomaticUTCOffset)return false;
      serverOffsetSeconds=InpManualServerUTCOffsetMinutes*60;
      utcNow=TimeCurrent()-serverOffsetSeconds;
      return utcNow>0;
     }

   utcNow=TimeGMT();
   if(utcNow<=0)return false;

   if(!InpUseAutomaticUTCOffset)
     {
      serverOffsetSeconds=InpManualServerUTCOffsetMinutes*60;
      return true;
     }

   // NOTE: the live auto mode relies on the PC clock being correctly set.
   // Strategy Tester may emulate GMT differently: use manual mode in tests.
   datetime serverNow=TimeTradeServer();
   if(serverNow<=0)return false;
   int diff=(int)(serverNow-utcNow);
   int rounded=(int)MathRound((double)diff/900.0)*900; // 15-min increments
   if(MathAbs(diff-rounded)>120 || rounded<-12*3600 || rounded>14*3600)
      return false;
   serverOffsetSeconds=rounded;
   return true;
  }

// Draw one finite horizontal line segment per calculated session/day.
void DrawLine(string suffix,datetime startTime,datetime endTime,
              double price,color lineColor,ENUM_LINE_STYLE style,
              string description)
  {
   string name=g_prefix+suffix;
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_TREND,0,startTime,price,endTime,price))
        {
         Print("Session Highs & Lows: failed to create ",name,"; code=",GetLastError());
         return;
        }
     }
   else
     {
      ObjectMove(0,name,0,startTime,price);
      ObjectMove(0,name,1,endTime,price);
     }

   ObjectSetInteger(0,name,OBJPROP_RAY_LEFT,false);
   ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,name,OBJPROP_COLOR,lineColor);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   // MQL5 non-solid object styles render reliably only at 1-pixel width.
   ObjectSetInteger(0,name,OBJPROP_WIDTH,(style!=STYLE_SOLID?1:InpLineWidth));
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,description+" " + DoubleToString(price,_Digits));
  }

void DrawText(string suffix,datetime time,double price,string caption,color textColor)
  {
   string name=g_prefix+"TXT_"+suffix;
   if(!InpShowText)
     {ObjectDelete(0,name);return;}
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_TEXT,0,time,price))return;
     }
   else ObjectMove(0,name,0,time,price);

   ObjectSetString(0,name,OBJPROP_TEXT,caption);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,name,OBJPROP_COLOR,textColor);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

void Status(string message)
  {
   if(!InpShowText)
     {
      ObjectDelete(0,g_prefix+"STATUS");
      return;
     }
   if(g_lastStatus==message && ObjectFind(0,g_prefix+"STATUS")>=0)return;
   g_lastStatus=message;
   string name=g_prefix+"STATUS";
   if(ObjectFind(0,name)<0)ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,12);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,70);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrSilver);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_TEXT,"Session Highs & Lows: "+message);
  }

// Historical broker time conversion uses the currently verified server offset.
// If configured, infer older broker offsets using European DST transitions.
// It must not be used as proof of the broker's historical offset for EA testing.
datetime HistoricalUTC(datetime serverBar,datetime utcNow,int serverOffsetNow)
  {
   int offset=serverOffsetNow;
   if(InpBrokerFollowsEuropeanDST)
     {
      int currentBerlinOffset=BerlinUTCOffsetSeconds(utcNow);
      for(int pass=0;pass<3;pass++)
        {
         datetime tentativeUTC=serverBar-offset;
         int historicalBerlinOffset=BerlinUTCOffsetSeconds(tentativeUTC);
         offset=serverOffsetNow+historicalBerlinOffset-currentBerlinOffset;
        }
     }
   return serverBar-offset;
  }

// Exact HH:MM format, including leading zeroes. No parsing surprises.
bool ParseTimeHHMM(const string value,int &minutes)
  {
   if(StringLen(value)!=5 || StringSubstr(value,2,1)!=":")return false;
   int positions[4]={0,1,3,4};
   for(int i=0;i<4;i++)
     {
      int c=(int)StringGetCharacter(value,positions[i]);
      if(c<48 || c>57)return false;
     }
   int hh=(int)StringToInteger(StringSubstr(value,0,2));
   int mm=(int)StringToInteger(StringSubstr(value,3,2));
   if(hh>23 || mm>59)return false;
   minutes=hh*60+mm;
   // Ranges must align to completed M5 candle boundaries.
   return mm%5==0;
  }

string SessionName(const int index)
  {
   if(index==0)return "ASIA";
   if(index==1)return "EUROPE";
   return "USA";
  }
bool SessionEnabled(const int index)
  {
   if(index==0)return InpShowAsia;
   if(index==1)return InpShowEurope;
   return InpShowUSA;
  }
color SessionColor(const int index)
  {
   if(index==0)return InpAsiaColor;
   if(index==1)return InpRangeColor;
   return InpUSAColor;
  }

// Input clocks represent a civil timestamp, not a broker-server timestamp.
datetime CivilToUTC(datetime localClock)
  {
   if(InpSessionTimeBasis==SESSION_TIME_UTC)return localClock;
   // All default times avoid the DST transition's ambiguous hour.
   // During the transition at 02:00-03:00, incomplete ranges fail validation.
   return localClock-BerlinUTCOffsetSeconds(localClock-3600);
  }

datetime UTCToCivil(datetime utc)
  {
   return InpSessionTimeBasis==SESSION_TIME_UTC?
          utc:utc+BerlinUTCOffsetSeconds(utc);
  }

datetime HistoricalServerTime(datetime utc,datetime utcNow,int offsetNow)
  {
   int offset=offsetNow;
   if(InpBrokerFollowsEuropeanDST)
      offset+=BerlinUTCOffsetSeconds(utc)-BerlinUTCOffsetSeconds(utcNow);
   return utc+offset;
  }

// Per-session, per-day range. Crossing-midnight windows belong to their start day.
struct SSessionDay
  {
   int session;
   int key;
   datetime startUTC;
   datetime endUTC;
   datetime startServer;
   datetime endServer;
   datetime lineStartServer;
   datetime lineEndServer;
   int expectedBars;
   int count;
   bool bad;
   double high;
   double low;
  };

void ClearLevels()
  {
   for(int i=ObjectsTotal(0,0,-1)-1;i>=0;i--)
     {
      string name=ObjectName(0,i,0,-1);
      if(StringFind(name,g_prefix)==0 && name!=g_prefix+"STATUS")
         ObjectDelete(0,name);
     }
  }

void Refresh()
  {
   datetime utcNow=0;
   int serverOffset=0;
   if(!ReadClock(utcNow,serverOffset))
     {
      ClearLevels();
      Status("Cannot verify server/UTC time. Tester requires manual UTC offset.");
      g_hasCalculated=false;
      return;
     }

   datetime serverNow=(bool)MQLInfoInteger(MQL_TESTER)?TimeCurrent():TimeTradeServer();
   if(serverNow<=0)return;

   datetime latestM5=iTime(_Symbol,PERIOD_M5,0);
   if(g_hasCalculated && latestM5==g_lastCalculatedM5 &&
      serverOffset/60==g_lastOffsetMinutes &&
      serverNow-g_lastRecalculation<60)
      return;

   g_lastCalculatedM5=latestM5;
   g_lastOffsetMinutes=serverOffset/60;
   g_lastRecalculation=serverNow;

   // Read exactly the requested number of M5 bars, even on M1, M15, H1, etc.
   MqlRates rates[];
   int copied=CopyRates(_Symbol,PERIOD_M5,0,InpMaxCandles,rates);
   if(copied<=0)
     {
      Status("M5 history unavailable; waiting for data.");
      g_hasCalculated=false;
      return;
     }
   ArraySetAsSeries(rates,false); // Physical order oldest -> newest.

   SSessionDay groups[];
   ArrayResize(groups,0);
   int lastGroup[3]={-1,-1,-1};

   for(int i=0;i<copied;i++)
     {
      // Do not use a forming M5 candle.
      if(rates[i].time+300>serverNow)continue;

      datetime utc=HistoricalUTC(rates[i].time,utcNow,serverOffset);
      if(utc<=0)continue;

      datetime civil=UTCToCivil(utc);
      MqlDateTime d={};
      TimeToStruct(civil,d);
      int minute=d.hour*60+d.min;
      datetime midnight=CivilTime(d.year,d.mon,d.day,0);

      for(int sid=0;sid<3;sid++)
        {
         if(!SessionEnabled(sid))continue;
         int start=g_startMinutes[sid],end=g_endMinutes[sid];
         bool crossesMidnight=(end<start);
         bool inside=crossesMidnight?(minute>=start || minute<end):
                                     (minute>=start && minute<end);
         if(!inside)continue;

         datetime anchorDay=midnight;
         if(crossesMidnight && minute<end)anchorDay-=86400;

         MqlDateTime anchor={};
         TimeToStruct(anchorDay,anchor);
         // Exclude weekend-starting sessions; a complete Forex session
         // is required. This deliberately excludes Sunday evening Asia.
         if(anchor.day_of_week==0 || anchor.day_of_week==6)continue;
         int key=anchor.year*10000+anchor.mon*100+anchor.day;

         int k=lastGroup[sid];
         if(k<0 || groups[k].key!=key)
           {
            datetime startCivil=anchorDay+start*60;
            datetime endCivil=anchorDay+end*60+(crossesMidnight?86400:0);
            datetime startUTC=CivilToUTC(startCivil);
            datetime endUTC=CivilToUTC(endCivil);
            if(endUTC<=startUTC)continue;

            // All ranges require complete M5 bars, with no missing minutes.
            long elapsed=(long)(endUTC-startUTC);
            if(elapsed%300!=0)continue;
            int n=ArraySize(groups);
            ArrayResize(groups,n+1);
            k=n;
            lastGroup[sid]=k;
            groups[k].session=sid;
            groups[k].key=key;
            groups[k].startUTC=startUTC;
            groups[k].endUTC=endUTC;
            groups[k].startServer=HistoricalServerTime(startUTC,utcNow,serverOffset);
            groups[k].endServer=HistoricalServerTime(endUTC,utcNow,serverOffset);

            // MT5 daily chart separators use BROKER-SERVER midnight.
            // Derive the endpoint from the session's SERVER end time,
            // not Berlin/UTC midnight. End exactly at the next 00:00.
            MqlDateTime serverEndDate={};
            TimeToStruct(groups[k].endServer,serverEndDate);
            datetime chartMidnight=CivilTime(serverEndDate.year,
                                              serverEndDate.mon,
                                              serverEndDate.day,0);
            groups[k].lineEndServer=chartMidnight+86400;

            // Overnight sessions may start on the previous broker day.
            // Clip their displayed segments to this chart day so no line
            // crosses the broker's vertical day separator.
            groups[k].lineStartServer=groups[k].startServer;
            if(groups[k].lineStartServer<chartMidnight)
               groups[k].lineStartServer=chartMidnight;
            groups[k].expectedBars=(int)(elapsed/300);
            groups[k].count=0;
            groups[k].bad=false;
            groups[k].high=-DBL_MAX;
            groups[k].low=DBL_MAX;
           }

         // On DST transition days, an unusual UTC/local mapping can cause
         // out-of-range bars. Never silently extend or invent candles.
         if(utc<groups[k].startUTC || utc>=groups[k].endUTC)
           {groups[k].bad=true;continue;}

         datetime expectedUTC=groups[k].startUTC+groups[k].count*300;
         if(utc!=expectedUTC || rates[i].high<rates[i].low ||
            rates[i].high<=0 || rates[i].low<=0)
            groups[k].bad=true;
         groups[k].count++;
         if(rates[i].high>groups[k].high)groups[k].high=rates[i].high;
         if(rates[i].low<groups[k].low)groups[k].low=rates[i].low;
        }
     }

   ClearLevels();
   int drawn[3]={0,0,0};
   string europeLatest="none";

   for(int i=0;i<ArraySize(groups);i++)
     {
      SSessionDay g=groups[i];
      if(g.bad || g.count!=g.expectedBars || utcNow<g.endUTC ||
         g.startServer<=0 || g.endServer<=g.startServer ||
         g.lineStartServer>=g.lineEndServer ||
         g.lineEndServer<g.endServer)
         continue;

      double rangePips=(g.high-g.low)/g_pip;
      bool eaRangeValid=(rangePips>=InpMinValidRangePips-1e-7 &&
                         rangePips<=InpMaxValidRangePips+1e-7);
      color c=SessionColor(g.session);
      string session=SessionName(g.session);
      string tag=session+"_"+IntegerToString(g.key)+"_";
      datetime textAt=g.endServer+300;

      DrawLine(tag+"HIGH",g.lineStartServer,g.lineEndServer,g.high,
               c,InpHighLineStyle,session+" range HIGH");
      DrawLine(tag+"LOW",g.lineStartServer,g.lineEndServer,g.low,
               c,InpLowLineStyle,session+" range LOW");

      DrawText(tag+"HIGH",textAt,g.high,
               session+" HIGH "+DoubleToString(g.high,_Digits),c);
      DrawText(tag+"LOW",textAt,g.low,
               session+" LOW "+DoubleToString(g.low,_Digits),c);

      if(InpShowBuySellLevels)
        {
         double buy=g.high+InpBreakoutBufferPips*g_pip;
         double sell=g.low-InpBreakoutBufferPips*g_pip;
         datetime thresholdStart=g.endServer;
         if(thresholdStart<g.lineStartServer)thresholdStart=g.lineStartServer;
         DrawLine(tag+"BUY",thresholdStart,g.lineEndServer,buy,
                  InpBreakoutColor,STYLE_DASH,session+" BUY threshold");
         DrawLine(tag+"SELL",thresholdStart,g.lineEndServer,sell,
                  InpBreakoutColor,STYLE_DASH,session+" SELL threshold");
         DrawText(tag+"BUY",textAt,buy,
                  session+" BUY +1p "+DoubleToString(buy,_Digits),InpBreakoutColor);
         DrawText(tag+"SELL",textAt,sell,
                  session+" SELL -1p "+DoubleToString(sell,_Digits),InpBreakoutColor);
        }

      drawn[g.session]++;
      if(g.session==1)
         europeLatest=StringFormat("%d: %.1f pips (%s)",g.key,rangePips,
                                   eaRangeValid?"VALID 8-20p":"SKIP 8-20p");
     }

   Status(StringFormat("M5 %d bars | Asia %d | Europe %d | USA %d | Latest Europe %s",
                       copied,drawn[0],drawn[1],drawn[2],europeLatest));
   g_hasCalculated=true;
   ChartRedraw(0);
  }

int OnInit()
  {
   if(InpMaxCandles<24 || InpMaxCandles>50000 ||
      InpBreakoutBufferPips<0.0 || InpMinValidRangePips<=0 ||
      InpMaxValidRangePips<InpMinValidRangePips ||
      InpLineWidth<1 || InpLineWidth>5 ||
      InpManualServerUTCOffsetMinutes< -720 || InpManualServerUTCOffsetMinutes>840 ||
      StringLen(InpObjectTag)==0 || StringLen(InpObjectTag)>24)
     {
      Print("Session Highs & Lows: invalid numeric input.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(!ParseTimeHHMM(InpAsiaStart,g_startMinutes[0]) ||
      !ParseTimeHHMM(InpAsiaEnd,g_endMinutes[0]) ||
      !ParseTimeHHMM(InpEuropeStart,g_startMinutes[1]) ||
      !ParseTimeHHMM(InpEuropeEnd,g_endMinutes[1]) ||
      !ParseTimeHHMM(InpUSAStart,g_startMinutes[2]) ||
      !ParseTimeHHMM(InpUSAEnd,g_endMinutes[2]))
     {
      Print("Session Highs & Lows: times must be HH:MM in 5-minute increments.");
      return INIT_PARAMETERS_INCORRECT;
     }

   for(int i=0;i<3;i++)
      if(g_startMinutes[i]==g_endMinutes[i])
        {
         Print("Session Highs & Lows: ",SessionName(i)," start and end cannot be identical.");
         return INIT_PARAMETERS_INCORRECT;
        }

   g_pip=(_Digits==3 || _Digits==5)?10.0*_Point:_Point;
   g_prefix="SHL_"+InpObjectTag+"_";
   IndicatorSetString(INDICATOR_SHORTNAME,"Session Highs & Lows");
   EventSetTimer(15);
   Refresh();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0,g_prefix,0,-1);
   ChartRedraw(0);
  }

void OnTimer() { Refresh(); }

int OnCalculate(const int rates_total,const int prev_calculated,
                const datetime &time[],const double &open[],
                const double &high[],const double &low[],
                const double &close[],const long &tick_volume[],
                const long &volume[],const int &spread[])
  {
   Refresh();
   return rates_total;
  }
//+------------------------------------------------------------------+
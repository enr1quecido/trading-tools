//+------------------------------------------------------------------+
//| Session Highs & Lows.mq5                                         |
//| Author: Enrique Briceno                                          |
//| Copyright (c) 2026 Enrique Briceno                               |
//| License: MIT (see LICENSE file)                                  |
//| GitHub: https://github.com/enr1quecido/trading-tools             |
//|                                                                  |
//| Displays completed-session highs and lows for Asia, Europe, USA. |
//| This indicator does not execute or manage trades.               |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026 Enrique Briceno"
#property link      "https://github.com/enr1quecido/trading-tools"
#property version   "1.52"
#property description "Session Highs & Lows by Enrique Briceno"
#property strict
#property indicator_chart_window
#property indicator_plots   0
#property indicator_buffers 0

// This selects the clock used by the HH:MM session inputs.
// Chart timestamps always use the broker's server clock.
enum ENUM_SESSION_TIME_BASIS
  {
   SESSION_TIME_BERLIN = 0,  // Berlin time (CET/CEST, automatic European DST)
   SESSION_TIME_UTC    = 1,  // UTC (GMT+0, no daylight saving)
   SESSION_TIME_BROKER = 2   // Broker server time (as shown on MT5 chart)
  };

input int    InpMaxCandles             = 1000;    // Maximum M5 candles to calculate
input bool   InpShowBuySellLevels      = false;   // Show BUY/SELL breakout lines
input bool   InpShowText               = true;    // Show names beside HIGH/LOW lines
input bool   InpShowStatus             = false;   // Show diagnostic status on chart

input group "Timezone for session times"
input ENUM_SESSION_TIME_BASIS InpSessionTimeBasis = SESSION_TIME_BERLIN; // Timezone of all HH:MM values

input group "Session times (in selected timezone)"
input bool   InpShowAsia               = true;    // Show Asia
input string InpAsiaStart              = "00:10"; // Asia session begin (HH:MM)
input string InpAsiaEnd                = "07:00"; // Asia session end (HH:MM)
input bool   InpShowEurope             = false;   // Show Europe (EA range)
input string InpEuropeStart            = "07:00"; // Europe session begin (HH:MM)
input string InpEuropeEnd              = "09:00"; // Europe session end (HH:MM)
input bool   InpShowUSA                = false;   // Show USA
input string InpUSAStart               = "13:00"; // USA session begin (HH:MM)
input string InpUSAEnd                 = "22:00"; // USA session end (HH:MM)

input group "Level names"
input string InpAsiaHighName           = "High Asia";   // Asia high label
input string InpAsiaLowName            = "Low Asia";    // Asia low label
input string InpEuropeHighName         = "High Europe"; // Europe high label
input string InpEuropeLowName          = "Low Europe";  // Europe low label
input string InpUSAHighName            = "High USA";    // USA high label
input string InpUSALowName             = "Low USA";     // USA low label

input group "Range / levels"
input double InpBreakoutBufferPips     = 1.0;     // +/- 1 pip from session high/low
input double InpMinValidRangePips      = 8.0;     // EA validity check for Europe
input double InpMaxValidRangePips      = 20.0;    // EA validity check for Europe

input group "Broker-to-UTC conversion (Berlin / UTC modes)"
input bool InpUseAutomaticUTCOffset     = true;   // Live: estimate server UTC offset
input int  InpManualServerUTCOffsetMinutes = 120; // Manual UTC+2=120 (tester: required)
input bool InpBrokerFollowsEuropeanDST  = true;   // Assumption for historical broker time

input group "Appearance"
input color           InpAsiaColor      = clrDarkOrange;  // Asia lines and names
input color           InpRangeColor     = clrDodgerBlue;  // Europe lines and names
input color           InpUSAColor       = clrSeaGreen;    // USA lines and names
input color           InpBreakoutColor  = clrDarkOrange;
input ENUM_LINE_STYLE InpHighLineStyle  = STYLE_DOT;      // HIGH line style
input ENUM_LINE_STYLE InpLowLineStyle   = STYLE_DOT;      // LOW line style
input int             InpLineWidth      = 1;
input string          InpObjectTag      = "SessionHighsLows";

int      g_startMinutes[3];
int      g_endMinutes[3];
string   g_prefix="";
int      g_lastOffsetMinutes=100000;
string   g_lastStatus="";
datetime g_lastCalculatedM5=0;
datetime g_lastRecalculation=0;
bool     g_hasCalculated=false;
bool     g_clockWarningIssued=false;
double   g_pip=0.0;

// The European DST transition occurs at 01:00 UTC on the last Sunday
// of March and October. This calculation does not use the PC timezone.
int LastSunday(int year,int month)
  {
   MqlDateTime first={};
   first.year=year;
   first.mon=(month==12?1:month+1);
   if(month==12) first.year=year+1;
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

// On live charts TimeGMT() is based on PC settings. In the tester it
// equals simulated server time, so the UTC offset must be supplied.
bool ReadClock(datetime &utcNow,int &serverOffsetSeconds)
  {
   if((bool)MQLInfoInteger(MQL_TESTER))
     {
      if(InpUseAutomaticUTCOffset) return false;
      serverOffsetSeconds=InpManualServerUTCOffsetMinutes*60;
      utcNow=TimeCurrent()-serverOffsetSeconds;
      return utcNow>0;
     }

   utcNow=TimeGMT();
   if(utcNow<=0) return false;
   if(!InpUseAutomaticUTCOffset)
     {
      serverOffsetSeconds=InpManualServerUTCOffsetMinutes*60;
      return true;
     }

   datetime serverNow=TimeTradeServer();
   if(serverNow<=0) return false;
   int diff=(int)(serverNow-utcNow);
   int rounded=(int)MathRound((double)diff/900.0)*900;
   if(MathAbs(diff-rounded)>120 || rounded< -12*3600 || rounded>14*3600)
      return false;
   serverOffsetSeconds=rounded;
   return true;
  }

// Historical broker conversion assumes that broker DST follows Europe
// when the corresponding input is enabled. Verify this for your broker.
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

datetime HistoricalServerTime(datetime utc,datetime utcNow,int offsetNow)
  {
   int offset=offsetNow;
   if(InpBrokerFollowsEuropeanDST)
      offset+=BerlinUTCOffsetSeconds(utc)-BerlinUTCOffsetSeconds(utcNow);
   return utc+offset;
  }

// Resolve a Berlin civil time to UTC. Reject the nonexistent spring
// hour and ambiguous autumn hour instead of choosing a silent guess.
datetime BerlinCivilToUTC(datetime localClock)
  {
   datetime winterCandidate=localClock-3600;
   datetime summerCandidate=localClock-7200;
   bool winterValid=(BerlinUTCOffsetSeconds(winterCandidate)==3600);
   bool summerValid=(BerlinUTCOffsetSeconds(summerCandidate)==7200);
   if(winterValid==summerValid) return 0;
   return winterValid?winterCandidate:summerCandidate;
  }

datetime CivilToUTC(datetime localClock)
  {
   if(InpSessionTimeBasis==SESSION_TIME_UTC) return localClock;
   return BerlinCivilToUTC(localClock);
  }

datetime UTCToCivil(datetime utc)
  {
   return InpSessionTimeBasis==SESSION_TIME_UTC?
          utc:utc+BerlinUTCOffsetSeconds(utc);
  }

// Exact HH:MM; aligned with M5 candles.
bool ParseTimeHHMM(const string value,int &minutes)
  {
   if(StringLen(value)!=5 || StringSubstr(value,2,1)!=":") return false;
   int positions[4]={0,1,3,4};
   for(int i=0;i<4;i++)
     {
      int c=(int)StringGetCharacter(value,positions[i]);
      if(c<48 || c>57) return false;
     }
   int hh=(int)StringToInteger(StringSubstr(value,0,2));
   int mm=(int)StringToInteger(StringSubstr(value,3,2));
   if(hh>23 || mm>59) return false;
   minutes=hh*60+mm;
   return mm%5==0;
  }

string SessionName(const int index)
  {
   if(index==0) return "ASIA";
   if(index==1) return "EUROPE";
   return "USA";
  }

bool SessionEnabled(const int index)
  {
   if(index==0) return InpShowAsia;
   if(index==1) return InpShowEurope;
   return InpShowUSA;
  }

color SessionColor(const int index)
  {
   if(index==0) return InpAsiaColor;
   if(index==1) return InpRangeColor;
   return InpUSAColor;
  }

string LevelName(const int index,const bool isHigh)
  {
   if(index==0) return isHigh?InpAsiaHighName:InpAsiaLowName;
   if(index==1) return isHigh?InpEuropeHighName:InpEuropeLowName;
   return isHigh?InpUSAHighName:InpUSALowName;
  }

void DrawLine(string suffix,datetime startTime,datetime endTime,
              double price,color lineColor,ENUM_LINE_STYLE style,
              string description)
  {
   string name=g_prefix+suffix;
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_TREND,0,startTime,price,endTime,price))
        {
         Print("Session Highs & Lows: failed to create ",name,
               "; code=",GetLastError());
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
   // MT5 non-solid styles reliably display only at width 1.
   ObjectSetInteger(0,name,OBJPROP_WIDTH,(style!=STYLE_SOLID?1:InpLineWidth));
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,
                   description+" " +DoubleToString(price,_Digits));
  }

// Rightmost visible chart time, with a small margin inside the price scale.
datetime VisibleRightTime()
  {
   int width=(int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
   int height=(int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   if(width<=12 || height<=2) return 0;
   int window=0;
   datetime time=0;
   double price=0.0;
   if(!ChartXYToTimePrice(0,width-8,height/2,window,time,price) || window!=0)
      return 0;
   return time;
  }

// Keep historical labels at their own line ends, and clip visible labels
// to the right edge when the end of their line is beyond the viewport.
datetime LabelTime(datetime start,datetime end,datetime right)
  {
   if(right>start && right<end) return right;
   return end;
  }

void RepositionLabels()
  {
   if(!InpShowText || g_prefix=="") return;
   datetime right=VisibleRightTime();
   if(right<=0) return;
   string textPrefix=g_prefix+"TXT_";
   bool changed=false;
   int total=ObjectsTotal(0,0,OBJ_TEXT);
   for(int i=0;i<total;i++)
     {
      string name=ObjectName(0,i,0,OBJ_TEXT);
      if(StringFind(name,textPrefix)!=0) continue;
      string line=g_prefix+StringSubstr(name,StringLen(textPrefix));
      if(ObjectFind(0,line)<0) continue;
      datetime start=(datetime)ObjectGetInteger(0,line,OBJPROP_TIME,0);
      datetime end=(datetime)ObjectGetInteger(0,line,OBJPROP_TIME,1);
      datetime at=LabelTime(start,end,right);
      if((datetime)ObjectGetInteger(0,name,OBJPROP_TIME,0)==at) continue;
      double price=ObjectGetDouble(0,line,OBJPROP_PRICE,0);
      if(ObjectMove(0,name,0,at,price)) changed=true;
     }
   if(changed) ChartRedraw(0);
  }

void DrawText(string suffix,datetime time,double price,string caption,color textColor)
  {
   string name=g_prefix+"TXT_"+suffix;
   if(!InpShowText)
     {
      ObjectDelete(0,name);
      return;
     }
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_TEXT,0,time,price)) return;
     }
   else ObjectMove(0,name,0,time,price);

   ObjectSetString(0,name,OBJPROP_TEXT,caption);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
   ObjectSetInteger(0,name,OBJPROP_COLOR,textColor);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT_LOWER);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

void Status(string message)
  {
   string name=g_prefix+"STATUS";
   if(!InpShowStatus)
     {
      ObjectDelete(0,name);
      return;
     }
   if(g_lastStatus==message && ObjectFind(0,name)>=0) return;
   g_lastStatus=message;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,12);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,70);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrSilver);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_TEXT,"Session Highs & Lows: "+message);
  }

// A session window is assigned to its start day, including overnight
// sessions. 'startComparable/endComparable' use UTC for Berlin/UTC
// inputs and raw broker time when Broker is selected.
struct SSessionDay
  {
   int      session;
   int      key;
   datetime startComparable;
   datetime endComparable;
   datetime startServer;
   datetime endServer;
   datetime lineStartServer;
   datetime lineEndServer;
   int      expectedBars;
   int      count;
   bool     bad;
   double   high;
   double   low;
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
   const bool brokerClock=(InpSessionTimeBasis==SESSION_TIME_BROKER);
   datetime utcNow=0;
   int serverOffset=0;
   // Broker-clock input needs no conversion or offset assumptions.
   if(!brokerClock && !ReadClock(utcNow,serverOffset))
     {
      if(!g_clockWarningIssued)
        {
         Print("Session Highs & Lows: cannot verify broker UTC offset. ",
               "In the Strategy Tester, set automatic UTC offset to false ",
               "and provide the broker offset for the test date, ",
               "or select Broker server time for the HH:MM inputs.");
         g_clockWarningIssued=true;
        }
      ClearLevels();
      Status("Cannot verify server/UTC time. Tester needs manual UTC offset.");
      g_hasCalculated=false;
      return;
     }
   g_clockWarningIssued=false;

   datetime serverNow=(bool)MQLInfoInteger(MQL_TESTER)?
                      TimeCurrent():TimeTradeServer();
   if(serverNow<=0) return;

   datetime latestM5=iTime(_Symbol,PERIOD_M5,0);
   if(g_hasCalculated && latestM5==g_lastCalculatedM5 &&
      serverOffset/60==g_lastOffsetMinutes &&
      serverNow-g_lastRecalculation<60)
      return;

   g_lastCalculatedM5=latestM5;
   g_lastOffsetMinutes=serverOffset/60;
   g_lastRecalculation=serverNow;

   MqlRates rates[];
   int copied=CopyRates(_Symbol,PERIOD_M5,0,InpMaxCandles,rates);
   if(copied<=0)
     {
      Status("M5 history unavailable; waiting for data.");
      g_hasCalculated=false;
      return;
     }
   ArraySetAsSeries(rates,false); // Physical order: oldest to newest.

   SSessionDay groups[];
   ArrayResize(groups,0);
   int lastGroup[3]={-1,-1,-1};

   for(int i=0;i<copied;i++)
     {
      // Never include a forming M5 bar.
      if(rates[i].time+300>serverNow) continue;

      datetime comparableTime=rates[i].time;
      datetime civil=rates[i].time;
      if(!brokerClock)
        {
         comparableTime=HistoricalUTC(rates[i].time,utcNow,serverOffset);
         if(comparableTime<=0) continue;
         civil=UTCToCivil(comparableTime);
        }

      MqlDateTime d={};
      TimeToStruct(civil,d);
      int minute=d.hour*60+d.min;
      datetime midnight=CivilTime(d.year,d.mon,d.day,0);

      for(int sid=0;sid<3;sid++)
        {
         if(!SessionEnabled(sid)) continue;
         int start=g_startMinutes[sid];
         int end=g_endMinutes[sid];
         bool crossesMidnight=(end<start);
         bool inside=crossesMidnight?(minute>=start || minute<end):
                                     (minute>=start && minute<end);
         if(!inside) continue;

         datetime anchorDay=midnight;
         if(crossesMidnight && minute<end) anchorDay-=86400;

         MqlDateTime anchor={};
         TimeToStruct(anchorDay,anchor);
         // Preserve original rule: no weekend-starting sessions.
         if(anchor.day_of_week==0 || anchor.day_of_week==6) continue;
         int key=anchor.year*10000+anchor.mon*100+anchor.day;

         int k=lastGroup[sid];
         if(k<0 || groups[k].key!=key)
           {
            datetime startCivil=anchorDay+start*60;
            datetime endCivil=anchorDay+end*60+
                              (crossesMidnight?86400:0);
            datetime beginComparable;
            datetime finishComparable;
            datetime beginServer;
            datetime finishServer;

            if(brokerClock)
              {
               // Chart bars and these input hours share the same clock.
               beginComparable=startCivil;
               finishComparable=endCivil;
               beginServer=startCivil;
               finishServer=endCivil;
              }
            else
              {
               beginComparable=CivilToUTC(startCivil);
               finishComparable=CivilToUTC(endCivil);
               if(beginComparable<=0 || finishComparable<=0) continue;
               beginServer=HistoricalServerTime(beginComparable,utcNow,serverOffset);
               finishServer=HistoricalServerTime(finishComparable,utcNow,serverOffset);
              }
            if(finishComparable<=beginComparable) continue;

            long elapsed=(long)(finishComparable-beginComparable);
            if(elapsed%300!=0) continue;
            int n=ArraySize(groups);
            ArrayResize(groups,n+1);
            k=n;
            lastGroup[sid]=k;
            groups[k].session=sid;
            groups[k].key=key;
            groups[k].startComparable=beginComparable;
            groups[k].endComparable=finishComparable;
            groups[k].startServer=beginServer;
            groups[k].endServer=finishServer;

            // End at next midnight on MT5's BROKER-server chart.
            MqlDateTime serverEndDate={};
            TimeToStruct(groups[k].endServer,serverEndDate);
            datetime chartMidnight=CivilTime(serverEndDate.year,
                                             serverEndDate.mon,
                                             serverEndDate.day,0);
            groups[k].lineEndServer=chartMidnight+86400;
            groups[k].lineStartServer=groups[k].startServer;
            if(groups[k].lineStartServer<chartMidnight)
               groups[k].lineStartServer=chartMidnight;

            groups[k].expectedBars=(int)(elapsed/300);
            groups[k].count=0;
            groups[k].bad=false;
            groups[k].high=-DBL_MAX;
            groups[k].low=DBL_MAX;
           }

         if(comparableTime<groups[k].startComparable ||
            comparableTime>=groups[k].endComparable)
           {
            groups[k].bad=true;
            continue;
           }

         datetime expected=groups[k].startComparable+groups[k].count*300;
         if(comparableTime!=expected || rates[i].high<rates[i].low ||
            rates[i].high<=0 || rates[i].low<=0)
            groups[k].bad=true;
         groups[k].count++;
         if(rates[i].high>groups[k].high) groups[k].high=rates[i].high;
         if(rates[i].low<groups[k].low) groups[k].low=rates[i].low;
        }
     }

   ClearLevels();
   int drawn[3]={0,0,0};
   string europeLatest="none";
   datetime rightEdge=VisibleRightTime();

   for(int i=0;i<ArraySize(groups);i++)
     {
      SSessionDay g=groups[i];
      datetime comparableNow=brokerClock?serverNow:utcNow;
      if(g.bad || g.count!=g.expectedBars || comparableNow<g.endComparable ||
         g.startServer<=0 || g.endServer<=g.startServer ||
         g.lineStartServer>=g.lineEndServer ||
         g.lineEndServer<g.endServer)
         continue;

      double rangePips=(g.high-g.low)/g_pip;
      bool eaRangeValid=(rangePips>=InpMinValidRangePips-1e-7 &&
                         rangePips<=InpMaxValidRangePips+1e-7);
      color c=SessionColor(g.session);
      string session=SessionName(g.session);
      string highName=LevelName(g.session,true);
      string lowName=LevelName(g.session,false);
      string tag=session+"_"+IntegerToString(g.key)+"_";
      datetime textAt=LabelTime(g.lineStartServer,g.lineEndServer,rightEdge);

      DrawLine(tag+"HIGH",g.lineStartServer,g.lineEndServer,g.high,
               c,InpHighLineStyle,highName);
      DrawLine(tag+"LOW",g.lineStartServer,g.lineEndServer,g.low,
               c,InpLowLineStyle,lowName);
      DrawText(tag+"HIGH",textAt,g.high,highName,c);
      DrawText(tag+"LOW",textAt,g.low,lowName,c);

      if(InpShowBuySellLevels)
        {
         double buy=g.high+InpBreakoutBufferPips*g_pip;
         double sell=g.low-InpBreakoutBufferPips*g_pip;
         datetime thresholdStart=g.endServer;
         if(thresholdStart<g.lineStartServer) thresholdStart=g.lineStartServer;
         DrawLine(tag+"BUY",thresholdStart,g.lineEndServer,buy,
                  InpBreakoutColor,STYLE_DASH,session+" BUY threshold");
         DrawLine(tag+"SELL",thresholdStart,g.lineEndServer,sell,
                  InpBreakoutColor,STYLE_DASH,session+" SELL threshold");
         DrawText(tag+"BUY",LabelTime(thresholdStart,g.lineEndServer,rightEdge),buy,
                  session+" BUY +1p "+DoubleToString(buy,_Digits),InpBreakoutColor);
         DrawText(tag+"SELL",LabelTime(thresholdStart,g.lineEndServer,rightEdge),sell,
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
      InpManualServerUTCOffsetMinutes< -720 ||
      InpManualServerUTCOffsetMinutes>840 ||
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
      Print("Session Highs & Lows: use HH:MM with 5-minute increments.");
      return INIT_PARAMETERS_INCORRECT;
     }

   for(int i=0;i<3;i++)
     {
      if(g_startMinutes[i]==g_endMinutes[i])
        {
         Print("Session Highs & Lows: ",SessionName(i),
               " session start and end cannot be the same.");
         return INIT_PARAMETERS_INCORRECT;
        }
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

void OnTimer()
  {
   Refresh();
   RepositionLabels();
  }

void OnChartEvent(const int id,const long &lparam,const double &dparam,
                  const string &sparam)
  {
   if(id==CHARTEVENT_CHART_CHANGE) RepositionLabels();
  }

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
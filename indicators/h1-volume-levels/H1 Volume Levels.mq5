//+------------------------------------------------------------------+
//| H1 Volume Levels.mq5                                             |
//| Author: Enrique Briceno                                          |
//| Copyright (c) 2026 Enrique Briceno                               |
//| License: MIT (see LICENSE file)                                  |
//| GitHub: https://github.com/enr1quecido/trading-tools             |
//|                                                                  |
//| Three configurable H1 candle levels with editable chart labels. |
//| Bullish H1: HIGH; bearish H1: LOW; doji: no level.               |
//| Can use Berlin local time (CET/CEST) or broker-server time.      |
//| This indicator does not execute or manage trades.               |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026 Enrique Briceno"
#property link      "https://github.com/enr1quecido/trading-tools"
#property version   "1.24"
#property description "H1 Volume Levels by Enrique Briceno"
#property strict
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

enum ENUM_LEVEL_DAY_MODE
  {
   VISIBLE_CHART_DAY = 0,  // Date currently being viewed (recommended)
   BROKER_TODAY      = 1   // Current broker-server calendar day
  };

enum ENUM_LEVEL_CLOCK
  {
   LEVEL_BERLIN_TIME = 0,  // Berlin local time, adjusts CET / CEST
   LEVEL_BROKER_TIME = 1   // Broker-server time, no conversion
  };

enum ENUM_BROKER_OFFSET_MODE
  {
   OFFSET_AUTO_LIVE = 0,   // Live: compare trade server with UTC PC clock
   OFFSET_MANUAL    = 1    // Manual offsets for tester / historical checks
  };

input group "Time settings"
input ENUM_LEVEL_DAY_MODE DayMode = VISIBLE_CHART_DAY;
input ENUM_LEVEL_CLOCK TimeReference = LEVEL_BERLIN_TIME; // Which clock defines 08:00/09:00/10:00?
input ENUM_BROKER_OFFSET_MODE BrokerUTCOffsetMode = OFFSET_AUTO_LIVE;
input int BrokerWinterUTCOffsetHours = 2;       // Used in MANUAL mode (e.g. UTC+2)
input int BrokerSummerUTCOffsetHours = 3;       // Used in MANUAL mode (e.g. UTC+3)
input bool BrokerUsesEuropeanDST = true;        // Historical DST assumption

input group "Level 1"
input int FirstCloseHour = 8;                   // H1 closing hour (selected clock)
input string FirstLevelText = "Vol 8 AM";       // Editable text shown on level 1
input color FirstLineColor = clrMagenta;
input ENUM_LINE_STYLE FirstLineStyle = STYLE_DOT;

input group "Level 2"
input int SecondCloseHour = 9;                  // H1 closing hour (selected clock)
input string SecondLevelText = "Vol 9 AM";      // Editable text shown on level 2
input color SecondLineColor = clrMagenta;
input ENUM_LINE_STYLE SecondLineStyle = STYLE_DOT;

input group "Level 3"
input int ThirdCloseHour = 10;                  // H1 closing hour (selected clock)
input string ThirdLevelText = "Vol 10 AM";      // Editable text shown on level 3
input color ThirdLineColor = clrMagenta;
input ENUM_LINE_STYLE ThirdLineStyle = STYLE_DOT;

input group "Appearance"
input bool ShowLevelText = true;                // Show or hide all three text labels
input int TextFontSize = 9;
input int LineWidth = 1;                       // Non-solid MT5 lines use width 1

string g_levelNames[3];
string g_labelNames[3];
datetime g_activeDay=0;
int g_currentBrokerOffset=0;
datetime g_currentUTC=0;
int g_clockStatus=0;

// Broker/UTC time values are represented as civil timestamps.
datetime CivilTime(int year,int month,int day,int hour=0,int minute=0)
  {
   MqlDateTime t={};
   t.year=year;t.mon=month;t.day=day;t.hour=hour;t.min=minute;
   return StructToTime(t);
  }

datetime DayStart(datetime moment)
  {
   if(moment<=0)return 0;
   MqlDateTime d={};
   if(!TimeToStruct(moment,d))return 0;
   return CivilTime(d.year,d.mon,d.day);
  }

int LastSunday(int year,int month)
  {
   int y=(month==12?year+1:year);
   int m=(month==12?1:month+1);
   datetime last=CivilTime(y,m,1)-86400;
   MqlDateTime d={};TimeToStruct(last,d);
   return d.day-d.day_of_week;
  }

int BerlinOffsetAtUTC(datetime utc)
  {
   MqlDateTime d={};TimeToStruct(utc,d);
   datetime spring=CivilTime(d.year,3,LastSunday(d.year,3),1);
   datetime autumn=CivilTime(d.year,10,LastSunday(d.year,10),1);
   return (utc>=spring && utc<autumn)?7200:3600;
  }

// Session level times are 08-10; none falls in the DST overlap hour.
datetime BerlinCivilToUTC(datetime berlinCivil)
  {
   datetime guess=berlinCivil-3600;
   return berlinCivil-BerlinOffsetAtUTC(guess);
  }

int BrokerOffsetAtUTC(datetime utc)
  {
   if(BrokerUTCOffsetMode==OFFSET_MANUAL)
      return (BrokerUsesEuropeanDST && BerlinOffsetAtUTC(utc)==7200 ?
              BrokerSummerUTCOffsetHours:BrokerWinterUTCOffsetHours)*3600;
   int adjust=0;
   if(BrokerUsesEuropeanDST)
      adjust=BerlinOffsetAtUTC(utc)-BerlinOffsetAtUTC(g_currentUTC);
   return g_currentBrokerOffset+adjust;
  }

bool UpdateBrokerClock()
  {
   g_clockStatus=0;
   if(TimeReference==LEVEL_BROKER_TIME)return true;

   bool tester=(bool)MQLInfoInteger(MQL_TESTER);
   if(BrokerUTCOffsetMode==OFFSET_AUTO_LIVE && tester)
     {
      g_clockStatus=1; // In Strategy Tester, GMT is simulated broker time.
      return false;
     }

   datetime brokerNow=tester?TimeCurrent():TimeTradeServer();
   if(brokerNow<=0)return false;

   if(BrokerUTCOffsetMode==OFFSET_MANUAL)
     {
      // Solve broker-UTC offset using a winter/summer fixed-point estimate.
      datetime utc=brokerNow-BrokerWinterUTCOffsetHours*3600;
      for(int i=0;i<3;i++)
         utc=brokerNow-BrokerOffsetAtUTC(utc);
      g_currentUTC=utc;
      g_currentBrokerOffset=BrokerOffsetAtUTC(g_currentUTC);
      return g_currentUTC>0;
     }

   datetime utcNow=TimeGMT();
   if(utcNow<=0)return false;
   int difference=(int)(brokerNow-utcNow);
   int rounded=(int)MathRound((double)difference/900.0)*900;
   if(MathAbs(difference-rounded)>120 || rounded<(-12*3600) || rounded>(14*3600))
      return false;
   g_currentUTC=utcNow;
   g_currentBrokerOffset=rounded;
   return true;
  }

// Reference date is a *broker* day, so levels end at the MT5 day separator.
// Convert that day's broker noon to Berlin noon to select the intended date.
datetime CloseTimeInBrokerClock(datetime referenceBrokerDay,int closeHour)
  {
   if(TimeReference==LEVEL_BROKER_TIME)
      return referenceBrokerDay+closeHour*3600;

   datetime brokerNoon=referenceBrokerDay+12*3600;
   datetime utcNoon=brokerNoon-g_currentBrokerOffset;
   for(int i=0;i<3;i++)
      utcNoon=brokerNoon-BrokerOffsetAtUTC(utcNoon);

   datetime berlinNoon=utcNoon+BerlinOffsetAtUTC(utcNoon);
   datetime berlinDay=DayStart(berlinNoon);
   datetime closingUTC=BerlinCivilToUTC(berlinDay+closeHour*3600);
   return closingUTC+BrokerOffsetAtUTC(closingUTC);
  }

int ClosingHour(int index)
  {
   if(index==0)return FirstCloseHour;
   if(index==1)return SecondCloseHour;
   return ThirdCloseHour;
  }

string LevelText(int index)
  {
   if(index==0)return FirstLevelText;
   if(index==1)return SecondLevelText;
   return ThirdLevelText;
  }

color LevelColor(int index)
  {
   if(index==0)return FirstLineColor;
   if(index==1)return SecondLineColor;
   return ThirdLineColor;
  }

ENUM_LINE_STYLE LevelStyle(int index)
  {
   if(index==0)return FirstLineStyle;
   if(index==1)return SecondLineStyle;
   return ThirdLineStyle;
  }

bool GetReference(datetime &referenceDay,datetime &asOf)
  {
   referenceDay=0;asOf=0;
   datetime now=TimeTradeServer();
   if(now<=0)now=TimeCurrent();
   if(DayMode==BROKER_TODAY)
     {
      referenceDay=DayStart(now);
      asOf=now;
      return referenceDay>0 && asOf>0;
     }

   long leftmost=ChartGetInteger(0,CHART_FIRST_VISIBLE_BAR,0);
   long visible=ChartGetInteger(0,CHART_VISIBLE_BARS,0);
   int shift=0;
   if(leftmost>=0 && visible>0)
     {
      long rightmost=leftmost-visible+1;
      if(rightmost>0)shift=(int)rightmost;
     }
   int bars=Bars(_Symbol,_Period);
   if(bars<=0)return false;
   if(shift>=bars)shift=bars-1;

   datetime rightTime=iTime(_Symbol,_Period,shift);
   if(rightTime<=0)return false;
   referenceDay=DayStart(rightTime);
   int duration=PeriodSeconds(_Period);
   if(duration<=0)duration=60;
   asOf=rightTime+duration;
   if(shift==0 && now>0 && now<asOf)asOf=now;

   // When scrolling back just after midnight, still show yesterday if
   // its first closing hour is also inside the visible chart area.
   if(shift>0 && rightTime<CloseTimeInBrokerClock(referenceDay,FirstCloseHour))
     {
      int leftShift=(int)leftmost;
      if(leftShift<0)leftShift=0;
      if(leftShift>=bars)leftShift=bars-1;
      datetime leftTime=iTime(_Symbol,_Period,leftShift);
      datetime prevDay=referenceDay-86400;
      datetime firstPrev=CloseTimeInBrokerClock(prevDay,FirstCloseHour);
      if(leftTime>0 && leftTime<=firstPrev)referenceDay=prevDay;
     }
   return referenceDay>0;
  }

void DeleteLevels()
  {
   for(int i=0;i<3;i++)
     {
      if(g_levelNames[i]!="")ObjectDelete(0,g_levelNames[i]);
      if(g_labelNames[i]!="")ObjectDelete(0,g_labelNames[i]);
     }
  }

bool DrawLevel(int index,datetime closingServerTime,double price,string type)
  {
   datetime lineEnd=DayStart(closingServerTime)+86400-1;
   if(closingServerTime<=0 || closingServerTime>=lineEnd)return false;
   string line=g_levelNames[index];
   if(ObjectFind(0,line)<0)
     {
      ResetLastError();
      if(!ObjectCreate(0,line,OBJ_TREND,0,closingServerTime,price,lineEnd,price))
        {
         PrintFormat("H1 Volume Levels: cannot draw line (%d)",GetLastError());
         return false;
        }
     }
   ObjectSetInteger(0,line,OBJPROP_COLOR,LevelColor(index));
   ObjectSetInteger(0,line,OBJPROP_STYLE,LevelStyle(index));
   ObjectSetInteger(0,line,OBJPROP_WIDTH,
                    LevelStyle(index)==STYLE_SOLID?LineWidth:1);
   ObjectSetInteger(0,line,OBJPROP_RAY_LEFT,false);
   ObjectSetInteger(0,line,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,line,OBJPROP_BACK,false);
   ObjectSetInteger(0,line,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,line,OBJPROP_HIDDEN,true);
   ObjectSetString(0,line,OBJPROP_TOOLTIP,
                   StringFormat("H1 %s at %s: %s",type,
                                TimeToString(closingServerTime,TIME_DATE|TIME_MINUTES),
                                DoubleToString(price,_Digits)));

   string label=g_labelNames[index];
   string caption=LevelText(index);
   if(!ShowLevelText || caption=="")
     {
      ObjectDelete(0,label);
      return true;
     }
   datetime labelTime=closingServerTime+300;
   if(labelTime>=lineEnd)labelTime=closingServerTime;
   if(ObjectFind(0,label)<0)
     {
      if(!ObjectCreate(0,label,OBJ_TEXT,0,labelTime,price))return true;
     }
   else ObjectMove(0,label,0,labelTime,price);
   ObjectSetString(0,label,OBJPROP_TEXT,caption);
   ObjectSetString(0,label,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,label,OBJPROP_FONTSIZE,TextFontSize);
   ObjectSetInteger(0,label,OBJPROP_COLOR,LevelColor(index));
   ObjectSetInteger(0,label,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0,label,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,label,OBJPROP_HIDDEN,true);
   return true;
  }

bool DrawH1DirectionalLevel(int index,datetime asOf)
  {
   if(ObjectFind(0,g_levelNames[index])>=0)return false;
   datetime barEnd=CloseTimeInBrokerClock(g_activeDay,ClosingHour(index));
   datetime barOpen=barEnd-PeriodSeconds(PERIOD_H1);
   if(barEnd<=0 || asOf<barEnd)return false;
   MqlRates h1[];
   int copied=CopyRates(_Symbol,PERIOD_H1,barOpen,barOpen,h1);
   if(copied!=1 || h1[0].time!=barOpen)return false;
   if(iBarShift(_Symbol,PERIOD_H1,barOpen,true)<1)return false;
   if(h1[0].close>h1[0].open)
      return DrawLevel(index,barEnd,h1[0].high,"bullish HIGH");
   if(h1[0].close<h1[0].open)
      return DrawLevel(index,barEnd,h1[0].low,"bearish LOW");
   return false; // Doji: no directional line.
  }

void UpdateLevels()
  {
   if(!UpdateBrokerClock())
     {
      if(g_clockStatus==1)Print("H1 Volume Levels: tester requires MANUAL broker UTC offset.");
      return;
     }
   datetime referenceDay=0,asOf=0;
   if(!GetReference(referenceDay,asOf))return;
   bool changed=false;
   if(referenceDay!=g_activeDay)
     {
      DeleteLevels();
      g_activeDay=referenceDay;
      changed=true;
     }
   for(int i=0;i<3;i++)
      if(DrawH1DirectionalLevel(i,asOf))changed=true;
   if(changed)ChartRedraw(0);
  }

int OnInit()
  {
   if(FirstCloseHour<1 || FirstCloseHour>23 ||
      SecondCloseHour<1 || SecondCloseHour>23 ||
      ThirdCloseHour<1 || ThirdCloseHour>23 ||
      FirstCloseHour==SecondCloseHour ||
      FirstCloseHour==ThirdCloseHour ||
      SecondCloseHour==ThirdCloseHour ||
      BrokerWinterUTCOffsetHours< -12 || BrokerWinterUTCOffsetHours>14 ||
      BrokerSummerUTCOffsetHours< -12 || BrokerSummerUTCOffsetHours>14 ||
      LineWidth<1 || LineWidth>5 || TextFontSize<6 || TextFontSize>36)
     {
      Print("H1 Volume Levels: invalid inputs (hours 1-23, distinct, width 1-5).");
      return INIT_PARAMETERS_INCORRECT;
     }
   string prefix="H1VolumeLevels_"+IntegerToString(ChartID())+"_"+
                 IntegerToString((long)GetTickCount())+"_";
   for(int i=0;i<3;i++)
     {
      g_levelNames[i]=prefix+"LINE_"+IntegerToString(i+1);
      g_labelNames[i]=prefix+"TEXT_"+IntegerToString(i+1);
     }
   // No INDICATOR_SHORTNAME: Indicators List displays only H1 Volume Levels.
   EventSetTimer(2);
   UpdateLevels();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeleteLevels();
   ChartRedraw(0);
  }

void OnTimer(){UpdateLevels();}

void OnChartEvent(const int id,const long &lparam,
                  const double &dparam,const string &sparam)
  {
   if(id==CHARTEVENT_CHART_CHANGE)UpdateLevels();
  }

int OnCalculate(const int rates_total,const int prev_calculated,
                const datetime &time[],const double &open[],
                const double &high[],const double &low[],
                const double &close[],const long &tick_volume[],
                const long &volume[],const int &spread[])
  {
   if(rates_total>0)UpdateLevels();
   return rates_total;
  }
//+------------------------------------------------------------------+

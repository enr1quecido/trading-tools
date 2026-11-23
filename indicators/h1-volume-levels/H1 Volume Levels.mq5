//+------------------------------------------------------------------+
//| H1 Volume Levels.mq5                                             |
//| Author: Enrique Briceno                                          |
//| Copyright (c) 2026 Enrique Briceno                               |
//| License: MIT (see LICENSE file)                                   |
//| GitHub: https://github.com/enr1quecido/trading-tools             |
//|                                                                  |
//| Draws bullish H1 highs and bearish H1 lows on the chart.        |
//| Uses H1 data independently of the chart timeframe.               |
//| This indicator does not execute or manage trades.                |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026 Enrique Briceno"
#property link      "https://github.com/enr1quecido/trading-tools"
#property version   "1.22"
#property description "H1 Volume Levels by Enrique Briceno"
#property strict
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

// Select the trading day currently in view when reviewing past charts.
// Alternatively, show only the broker's actual calendar day.
enum ENUM_LEVEL_DAY_MODE
  {
   VISIBLE_CHART_DAY = 0,     // Date currently being viewed (recommended)
   BROKER_TODAY      = 1      // Current broker-server calendar date only
  };

input ENUM_LEVEL_DAY_MODE DayMode        = VISIBLE_CHART_DAY;
input int                 FirstCloseHour = 9;             // First H1 closing time (server time)
input int                 SecondCloseHour= 10;            // Second H1 closing time (server time)
input color               FirstLineColor = clrBlue;      // First H1 high/low line
input color               SecondLineColor= clrBlue;       // Second H1 high/low line
input ENUM_LINE_STYLE     FirstLineStyle = STYLE_SOLID;
input ENUM_LINE_STYLE     SecondLineStyle= STYLE_SOLID;
input int                 LineWidth      = 1;             // Width 1 preserves dashed style

string   g_firstObject  = "";
string   g_secondObject = "";
datetime g_activeDay    = 0;

//+------------------------------------------------------------------+
//| Return midnight for a timestamp on the broker's calendar.       |
//+------------------------------------------------------------------+
datetime DayStart(const datetime when)
  {
   if(when <= 0)
      return 0;

   MqlDateTime parts;
   if(!TimeToStruct(when, parts))
      return 0;
   parts.hour = 0;
   parts.min  = 0;
   parts.sec  = 0;
   return StructToTime(parts);
  }

//+------------------------------------------------------------------+
//| Use server time for live bars; historical view uses bar times.   |
//+------------------------------------------------------------------+
datetime BrokerNow()
  {
   datetime t = TimeTradeServer();
   if(t <= 0)
      t = TimeCurrent();
   return t;
  }

//+------------------------------------------------------------------+
//| Pick a chart-visible trading day and the latest visible time.    |
//| This also works when the chart is scrolled to history.           |
//+------------------------------------------------------------------+
bool GetReference(datetime &referenceDay, datetime &asOf)
  {
   referenceDay = 0;
   asOf = 0;

   datetime now = BrokerNow();
   if(DayMode == BROKER_TODAY)
     {
      referenceDay = DayStart(now);
      asOf = now;
      return (referenceDay > 0 && asOf > 0);
     }

   // The leftmost visible bar has the largest timeseries index.
   // Subtracting the number of visible bars finds the rightmost one.
   long firstVisible = ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR, 0);
   long visibleCount = ChartGetInteger(0, CHART_VISIBLE_BARS, 0);
   int rightShift = 0;
   if(firstVisible >= 0 && visibleCount > 0)
     {
      long shift = firstVisible - visibleCount + 1;
      if(shift > 0)
         rightShift = (int)shift;
     }

   int bars = Bars(_Symbol, _Period);
   if(bars <= 0)
      return false;
   if(rightShift >= bars)
      rightShift = bars - 1;

   datetime rightTime = iTime(_Symbol, _Period, rightShift);
   if(rightTime <= 0)
      return false;

   referenceDay = DayStart(rightTime);
   int barDuration = PeriodSeconds(_Period);
   if(barDuration <= 0)
      barDuration = 60;

   // Historical bars are already closed. The live bar may be forming.
   asOf = rightTime + barDuration;
   if(rightShift == 0 && now > 0 && now < asOf)
      asOf = now;

   // When reviewing history and the right edge crosses just after
   // midnight, keep the previous day if its first level is in view.
   // Do not use this fallback at the live edge: a new day starts clean.
   if(rightShift > 0 && rightTime < referenceDay + FirstCloseHour * 3600)
     {
      int leftShift = (int)firstVisible;
      if(leftShift < 0)
         leftShift = 0;
      if(leftShift >= bars)
         leftShift = bars - 1;
      datetime leftTime = iTime(_Symbol, _Period, leftShift);
      datetime previousDay = referenceDay - 86400;
      datetime previousFirstClose = previousDay + FirstCloseHour * 3600;
      if(leftTime > 0 && leftTime <= previousFirstClose)
         referenceDay = previousDay;
     }

   return (referenceDay > 0);
  }

//+------------------------------------------------------------------+
//| Delete only this indicator instance's chart objects.            |
//+------------------------------------------------------------------+
void DeleteLevels()
  {
   if(g_firstObject != "")
      ObjectDelete(0, g_firstObject);
   if(g_secondObject != "")
      ObjectDelete(0, g_secondObject);
  }

//+------------------------------------------------------------------+
//| Build a finite horizontal segment FROM the closing time onward. |
//+------------------------------------------------------------------+
bool DrawLevel(const string name, const datetime endOfH1,
               const double price, const color lineColor,
               const ENUM_LINE_STYLE lineStyle,
               const string levelType)
  {
   if(ObjectFind(0, name) >= 0)
      return true;

   datetime endOfDay = g_activeDay + 86400 - 1;
   if(endOfH1 >= endOfDay)
      return false;

   ResetLastError();
   if(!ObjectCreate(0, name, OBJ_TREND, 0,
                    endOfH1, price, endOfDay, price))
     {
      PrintFormat("H1 Volume Levels: cannot draw %s (error %d)",
                  name, GetLastError());
      return false;
     }

   ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, lineStyle);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, LineWidth);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ObjectSetString(0, name, OBJPROP_TOOLTIP,
                   StringFormat("H1 %s (%s close): %s",
                                levelType,
                                TimeToString(endOfH1, TIME_DATE | TIME_MINUTES),
                                DoubleToString(price, _Digits)));
   return true;
  }

//+------------------------------------------------------------------+
//| Choose the H1 HIGH if bullish, or LOW if bearish.                |
//+------------------------------------------------------------------+
bool DrawH1DirectionalLevel(const int closeHour, const string objectName,
                        const color lineColor,
                        const ENUM_LINE_STYLE lineStyle,
                        const datetime asOf)
  {
   if(ObjectFind(0, objectName) >= 0)
      return false;

   // For a 09:00 CLOSE, the H1 candle opened at 08:00.
   datetime barEnd = g_activeDay + closeHour * 3600;
   datetime barOpen = barEnd - PeriodSeconds(PERIOD_H1);
   if(asOf < barEnd)
      return false;

   MqlRates h1[];
   int copied = CopyRates(_Symbol, PERIOD_H1, barOpen, barOpen, h1);
   if(copied != 1 || h1[0].time != barOpen)
      return false;

   // Bar must no longer be the still-forming H1 candle.
   if(iBarShift(_Symbol, PERIOD_H1, barOpen, true) < 1)
      return false;

   // Price action is determined by the real H1 open/close, not by
   // the chart's candle colors or by the current chart timeframe.
   // Bullish: line at the highest wick. Bearish: line at lowest wick.
   // Doji: no directional level; leave the chart clear for that candle.
   if(h1[0].close > h1[0].open)
      return DrawLevel(objectName, barEnd, h1[0].high,
                       lineColor, lineStyle, "bullish HIGH");
   if(h1[0].close < h1[0].open)
      return DrawLevel(objectName, barEnd, h1[0].low,
                       lineColor, lineStyle, "bearish LOW");
   return false;
  }

//+------------------------------------------------------------------+
//| Update both levels on price ticks, scrolling, and a timer.       |
//+------------------------------------------------------------------+
void UpdateLevels()
  {
   datetime day, asOf;
   if(!GetReference(day, asOf))
      return;

   bool changed = false;
   if(day != g_activeDay)
     {
      DeleteLevels();
      g_activeDay = day;
      changed = true;
     }

   if(DrawH1DirectionalLevel(FirstCloseHour, g_firstObject,
                         FirstLineColor, FirstLineStyle, asOf))
      changed = true;
   if(DrawH1DirectionalLevel(SecondCloseHour, g_secondObject,
                         SecondLineColor, SecondLineStyle, asOf))
      changed = true;

   if(changed)
      ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| MQL5 indicator event handlers                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(FirstCloseHour < 1 || FirstCloseHour > 23 ||
      SecondCloseHour < 1 || SecondCloseHour > 23 ||
      FirstCloseHour == SecondCloseHour ||
      LineWidth < 1 || LineWidth > 5)
     {
      Print("H1 Volume Levels: hours must be different (1..23); width 1..5.");
      return INIT_PARAMETERS_INCORRECT;
     }

   string prefix = "H1VolumeLevels_" +
                   IntegerToString(ChartID()) + "_" +
                   IntegerToString((long)GetTickCount()) + "_";
   g_firstObject  = prefix + IntegerToString(FirstCloseHour);
   g_secondObject = prefix + IntegerToString(SecondCloseHour);

   // Deliberately do NOT set INDICATOR_SHORTNAME here.
   // MT5 then uses the filename 'H1 Volume Levels' and avoids displaying
   // an additional short-name suffix in parentheses in the Indicators List.

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

void OnTimer()
  {
   UpdateLevels();
  }

void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
      UpdateLevels();
  }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total > 0)
      UpdateLevels();
   return rates_total;
  }
//+------------------------------------------------------------------+
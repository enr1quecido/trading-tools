//+------------------------------------------------------------------+
//| Time to Close.mq5                                                |
//| Author: Enrique Briceno                                          |
//| Copyright (c) 2026 Enrique Briceno                               |
//| License: MIT (see LICENSE file when published)                   |
//| GitHub: https://github.com/enr1quecido/trading-tools             |
//|                                                                  |
//| Displays minutes and seconds until the current candle closes.   |
//| Does not execute or manage trades.                               |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026 Enrique Briceno"
#property link      "https://github.com/enr1quecido/trading-tools"
#property version   "1.04"
#property description "Current-candle countdown; selectable side and legacy-label cleanup."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

enum ENUM_TTC_LOCATION
  {
   TTC_AT_CLOSE   = 0,  // At the current candle's closing price
   TTC_ABOVE_HIGH = 1,  // Just above the current candle's high
   TTC_BELOW_LOW  = 2,  // Just below the current candle's low
   TTC_AT_MIDDLE  = 3   // At the midpoint of the current candle
  };

enum ENUM_TTC_SIDE
  {
   TTC_SIDE_RIGHT = 0,  // Right of current candle
   TTC_SIDE_LEFT  = 1,  // Left of current candle
   TTC_SIDE_AUTO  = 2   // Prefer right, otherwise left
  };

input group "Text appearance"
input string            InpFontName         = "Arial";       // Font
input int               InpFontSize         = 10;            // Font size (points)
input color             InpFontColor        = clrBlack;      // Text color

input group "Location near current candle"
input ENUM_TTC_SIDE     InpSide             = TTC_SIDE_RIGHT; // Horizontal side
input ENUM_TTC_LOCATION InpLocation         = TTC_AT_CLOSE;  // Vertical position
input double            InpRightDistanceMM  = 5.0;           // Gap from candle (approx. mm)
input int               InpVerticalOffsetPx = 0;             // Extra vertical offset (pixels)
input bool              InpEnableRightShift = true;          // Enable right chart space if needed

// Always the SAME name on a chart. Chart objects are already chart-scoped.
// Version 1.00 used names like TimeToClose_<chart_id>_<tick_count>.
// Those unique names were saved into templates and caused ghost labels.
#define TTC_OBJECT_PREFIX "TimeToClose_"
#define TTC_OBJECT_NAME   "TimeToClose_Countdown"

int g_screen_dpi = 96;

//+------------------------------------------------------------------+
//| Closing time: the following month needs calendar arithmetic.    |
//+------------------------------------------------------------------+
datetime CandleEndTime(const datetime opening_time)
  {
   if(_Period == PERIOD_MN1)
     {
      MqlDateTime parts;
      if(!TimeToStruct(opening_time,parts))
         return 0;

      parts.day  = 1;
      parts.hour = 0;
      parts.min  = 0;
      parts.sec  = 0;
      parts.mon++;
      if(parts.mon > 12)
        {
         parts.mon = 1;
         parts.year++;
        }
      return StructToTime(parts);
     }

   const int period_seconds = PeriodSeconds(_Period);
   if(period_seconds <= 0)
      return 0;
   return opening_time + period_seconds;
  }

//+------------------------------------------------------------------+
//| Hide the text, not the object: no text is painted over profits.  |
//+------------------------------------------------------------------+
void HideCountdown()
  {
   if(ObjectFind(0,TTC_OBJECT_NAME) >= 0)
      ObjectSetString(0,TTC_OBJECT_NAME,OBJPROP_TEXT,"");
  }

//+------------------------------------------------------------------+
//| Create our own label, never touching labels from other tools.   |
//+------------------------------------------------------------------+
bool CreateCountdownLabel()
  {
   if(ObjectFind(0,TTC_OBJECT_NAME) < 0)
     {
      ResetLastError();
      if(!ObjectCreate(0,TTC_OBJECT_NAME,OBJ_LABEL,0,0,0))
        {
         PrintFormat("Time to Close: label creation failed (%d).",GetLastError());
         return false;
        }
     }

   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_ANCHOR,ANCHOR_LEFT);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_XDISTANCE,0);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_YDISTANCE,0);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_COLOR,InpFontColor);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_FONTSIZE,InpFontSize);
   ObjectSetString (0,TTC_OBJECT_NAME,OBJPROP_FONT,InpFontName);
   ObjectSetString (0,TTC_OBJECT_NAME,OBJPROP_TEXT,"");
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_BACK,false);
   return true;
  }

//+------------------------------------------------------------------+
//| Estimate a label rectangle; accounts for its corner and anchor.|
//| Only used to protect other OBJ_LABEL text, never to move it.     |
//+------------------------------------------------------------------+
bool OtherLabelBounds(const string name,
                      const int chart_width,
                      const int chart_height,
                      int &left,int &top,int &right,int &bottom)
  {
   if(name == TTC_OBJECT_NAME)
      return false;

   int w = (int)ObjectGetInteger(0,name,OBJPROP_XSIZE);
   int h = (int)ObjectGetInteger(0,name,OBJPROP_YSIZE);
   if(w <= 0 || h <= 0)
     {
      // The template may have been loaded before the text was drawn.
      const string other_text = ObjectGetString(0,name,OBJPROP_TEXT);
      if(other_text == "")
         return false;
      int other_size = (int)ObjectGetInteger(0,name,OBJPROP_FONTSIZE);
      if(other_size <= 0)
         other_size = 12;
      if(w <= 0)
         w = (int)MathCeil(StringLen(other_text) * other_size * g_screen_dpi / 120.0) + 10;
      if(h <= 0)
         h = (int)MathCeil(other_size * g_screen_dpi / 72.0) + 6;
     }

   int x = (int)ObjectGetInteger(0,name,OBJPROP_XDISTANCE);
   int y = (int)ObjectGetInteger(0,name,OBJPROP_YDISTANCE);
   const ENUM_BASE_CORNER corner = (ENUM_BASE_CORNER)ObjectGetInteger(0,name,OBJPROP_CORNER);
   const ENUM_ANCHOR_POINT anchor = (ENUM_ANCHOR_POINT)ObjectGetInteger(0,name,OBJPROP_ANCHOR);

   if(corner == CORNER_RIGHT_UPPER || corner == CORNER_RIGHT_LOWER)
      x = chart_width - x;
   if(corner == CORNER_LEFT_LOWER || corner == CORNER_RIGHT_LOWER)
      y = chart_height - y;

   left = x;
   top  = y;

   switch(anchor)
     {
      case ANCHOR_CENTER:
      case ANCHOR_UPPER:
      case ANCHOR_LOWER:
         left -= w / 2;
         break;
      case ANCHOR_RIGHT_UPPER:
      case ANCHOR_RIGHT:
      case ANCHOR_RIGHT_LOWER:
         left -= w;
         break;
      default:
         break;
     }

   switch(anchor)
     {
      case ANCHOR_CENTER:
      case ANCHOR_LEFT:
      case ANCHOR_RIGHT:
         top -= h / 2;
         break;
      case ANCHOR_LEFT_LOWER:
      case ANCHOR_LOWER:
      case ANCHOR_RIGHT_LOWER:
         top -= h;
         break;
      default:
         break;
     }

   right  = left + w;
   bottom = top + h;
   return true;
  }

//+------------------------------------------------------------------+
//| Check if our text rectangle would cover another chart label.   |
//+------------------------------------------------------------------+
bool OverlapsAnotherLabel(const int left,const int top,
                          const int right,const int bottom,
                          const int chart_width,const int chart_height)
  {
   const int total = ObjectsTotal(0,0,OBJ_LABEL);
   for(int i=0; i<total; i++)
     {
      const string name = ObjectName(0,i,0,OBJ_LABEL);
      if(name == "" || name == TTC_OBJECT_NAME)
         continue;

      int l,t,r,b;
      if(!OtherLabelBounds(name,chart_width,chart_height,l,t,r,b))
         continue;

      // Leave 3 pixels of breathing room around existing labels.
      if(left < r+3 && right > l-3 && top < b+3 && bottom > t-3)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Refresh countdown, or hide rather than overlay existing labels.|
//+------------------------------------------------------------------+
void UpdateCountdown()
  {
   if(ObjectFind(0,TTC_OBJECT_NAME) < 0)
      if(!CreateCountdownLabel())
         return;

   MqlRates latest[1];
   if(CopyRates(_Symbol,_Period,0,1,latest) != 1)
     {
      HideCountdown();
      return;
     }

   const datetime end_time = CandleEndTime(latest[0].time);
   if(end_time == 0)
     {
      HideCountdown();
      return;
     }

   datetime server_now = TimeTradeServer();
   if(server_now <= 0)
      server_now = TimeCurrent();

   long seconds_left = (long)(end_time - server_now);
   if(seconds_left < 0)
      seconds_left = 0;

   const string countdown = StringFormat("%02d:%02d",
                                         (int)(seconds_left / 60),
                                         (int)(seconds_left % 60));

   double anchor_price = latest[0].close;
   switch(InpLocation)
     {
      case TTC_ABOVE_HIGH: anchor_price = latest[0].high; break;
      case TTC_BELOW_LOW:  anchor_price = latest[0].low; break;
      case TTC_AT_MIDDLE: anchor_price = (latest[0].high + latest[0].low) * 0.5; break;
      default: break;
     }

   int candle_x = 0, candle_y = 0;
   if(!ChartTimePriceToXY(0,0,latest[0].time,anchor_price,candle_x,candle_y))
     {
      HideCountdown();
      return;
     }

   const int chart_width  = (int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
   const int chart_height = (int)ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0);
   if(chart_width <= 0 || chart_height <= 0)
     {
      HideCountdown();
      return;
     }

   const int gap = (int)MathRound(InpRightDistanceMM * g_screen_dpi / 25.4);
   const int plot_right = chart_width - 55; // Space reserved for price scale.
   const int safe_left = 120; // Protect profit/stats panels near left edge.

   if(candle_x < 0 || candle_x > plot_right || plot_right <= safe_left)
     {
      HideCountdown();
      return;
     }

   // Use a conservative estimate if MT5 has not drawn this label yet.
   int text_width = (int)ObjectGetInteger(0,TTC_OBJECT_NAME,OBJPROP_XSIZE);
   const int estimated_width = (int)MathCeil(StringLen(countdown) * InpFontSize * g_screen_dpi / 120.0) + 10;
   if(text_width < estimated_width)
      text_width = estimated_width;
   const int text_height = (int)MathCeil(InpFontSize * g_screen_dpi / 72.0) + 6;

   int y = candle_y + InpVerticalOffsetPx;
   if(InpLocation == TTC_ABOVE_HIGH)
      y -= text_height;
   else if(InpLocation == TTC_BELOW_LOW)
      y += text_height;

   // Explicit side preference. Automatic tries the opposite side if needed.
   // Never clamp X to 4: it would put text over left-side profits.
   bool found = false;
   int chosen_x = 0, chosen_y = 0;
   ENUM_ANCHOR_POINT chosen_anchor = ANCHOR_LEFT;

   const int first_side = (InpSide == TTC_SIDE_LEFT) ? 1 : 0;
   const int sides_to_try = (InpSide == TTC_SIDE_AUTO) ? 2 : 1;
   for(int pass=0; pass<sides_to_try && !found; pass++)
     {
      const int side = (pass == 0) ? first_side : 1-first_side;
      const int x = (side == 0) ? candle_x+gap : candle_x-gap;
      const int left  = (side == 0) ? x : x-text_width;
      const int right = left+text_width;
      if(left < safe_left || right > plot_right)
         continue;

      // Try price-aligned text first. Shift no more than one line if needed.
      for(int attempt=0; attempt<3 && !found; attempt++)
        {
         const int shift = (attempt == 0) ? 0 : ((attempt == 1) ? -text_height : text_height);
         const int cy = y + shift;
         const int top = cy - text_height/2;
         const int bottom = top+text_height;
         if(top < 4 || bottom > chart_height-4)
            continue;
         if(OverlapsAnotherLabel(left,top,right,bottom,chart_width,chart_height))
            continue;

         chosen_x = x;
         chosen_y = cy;
         chosen_anchor = (side == 0) ? ANCHOR_LEFT : ANCHOR_RIGHT;
         found = true;
        }
     }

   if(!found)
     {
      HideCountdown();
      return;
     }

   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_ANCHOR,chosen_anchor);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_XDISTANCE,chosen_x);
   ObjectSetInteger(0,TTC_OBJECT_NAME,OBJPROP_YDISTANCE,chosen_y);
   ObjectSetString(0,TTC_OBJECT_NAME,OBJPROP_TEXT,countdown);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Optionally reserve enough right-side room for countdown text.  |
//| Keeps existing room when already sufficient.                     |
//+------------------------------------------------------------------+
void EnsureRightChartSpace()
  {
   if(!InpEnableRightShift || InpSide != TTC_SIDE_RIGHT)
      return;

   const int chart_width = (int)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0);
   if(chart_width <= 0)
      return;

   const int gap = (int)MathRound(InpRightDistanceMM*g_screen_dpi/25.4);
   const int width = (int)MathCeil(5.0*InpFontSize*g_screen_dpi/120.0)+10;
   // Reserve room for the label, the candle gap, and the price axis.
   double required_shift = 100.0*(gap+width+55+10)/chart_width;
   required_shift = MathMax(10.0,MathMin(50.0,required_shift));

   bool changed = false;
   if(!(bool)ChartGetInteger(0,CHART_SHIFT))
     {
      if(ChartSetInteger(0,CHART_SHIFT,true))
         changed = true;
     }

   const double old_shift = ChartGetDouble(0,CHART_SHIFT_SIZE);
   if(old_shift < required_shift)
     {
      if(ChartSetDouble(0,CHART_SHIFT_SIZE,required_shift))
         changed = true;
     }

   if(changed)
      ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Initialize: remove only legacy labels from this indicator.      |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFontSize < 6 || InpFontSize > 150 ||
      StringLen(InpFontName) == 0 ||
      InpRightDistanceMM < 0.0 || InpRightDistanceMM > 100.0)
     {
      Print("Time to Close: invalid font or distance input.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_screen_dpi = (int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   if(g_screen_dpi <= 0)
      g_screen_dpi = 96;

   // Do not set INDICATOR_SHORTNAME here. MT5 recent builds append an
   // explicitly set short name to the indicator filename in parentheses.
   // Keeping the filename only avoids "Time to Close (Time to Close)".

   // This is opt-in via InpEnableRightShift; no chart change for left/auto.
   EnsureRightChartSpace();

   // A template can contain saved graphical objects from earlier runs.
   // This strictly targets labels beginning 'TimeToClose_', not profit
   // labels, trade markers, or any other indicator's objects.
   ObjectsDeleteAll(0,TTC_OBJECT_PREFIX,0,OBJ_LABEL);

   if(!CreateCountdownLabel())
      return INIT_FAILED;

   if(!EventSetTimer(1))
     {
      PrintFormat("Time to Close: timer setup failed (%d).",GetLastError());
      ObjectsDeleteAll(0,TTC_OBJECT_PREFIX,0,OBJ_LABEL);
      return INIT_FAILED;
     }

   UpdateCountdown();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Update once per second, also when the market is between ticks.  |
//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateCountdown();
  }

//+------------------------------------------------------------------+
//| Refresh on new bars; the 1-second timer handles other changes. |
//+------------------------------------------------------------------+
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
   if(prev_calculated == 0 || rates_total != prev_calculated)
      UpdateCountdown();
   return rates_total;
  }

//+------------------------------------------------------------------+
//| Reposition when the chart is resized, zoomed or scrolled.        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      EnsureRightChartSpace();
      UpdateCountdown();
     }
  }

//+------------------------------------------------------------------+
//| Delete current and legacy countdown objects.                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   // Remove the current label AND all old TimeToClose_ labels.
   // Earlier versions used a different name on every attachment.
   ObjectsDeleteAll(0,TTC_OBJECT_PREFIX,0,OBJ_LABEL);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
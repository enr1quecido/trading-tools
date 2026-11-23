//+------------------------------------------------------------------+
//| Profit & Trades.mq5                                              |
//| Author: Enrique Briceno                                          |
//| Copyright (c) 2026 Enrique Briceno                               |
//| License: MIT (see LICENSE file)                                  |
//| GitHub: https://github.com/enr1quecido/trading-tools             |
//|                                                                  |
//| Displays today's realized trading P/L and number of entries.     |
//| Also shows winning and losing closed trades for the day.         |
//| Does not execute or manage trades.                               |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026 Enrique Briceno"
#property link      "https://github.com/enr1quecido/trading-tools"
#property version   "1.09"
#property description "Shows today's realized net P/L, entries, wins and losses."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- Account-wide totals by default. When enabled, use the chart symbol.
input bool InpCurrentSymbolOnly = false; // Count current chart symbol only

enum ENUM_PT_TEXT_POSITION
  {
   PT_BOTTOM_RIGHT = 0, // Bottom right
   PT_BOTTOM_LEFT  = 1  // Bottom left
  };

input group "Display"
input ENUM_PT_TEXT_POSITION InpTextPosition = PT_BOTTOM_RIGHT; // Text position

input group "Font appearance"
input int InpFontSize = 10; // Font size (6-150)

input group "Text colors"
input color InpPositiveProfitColor = clrBlack; // Profit: positive or zero
input color InpNegativeProfitColor = clrOrangeRed;   // Profit: negative
input color InpTotalTradesColor    = clrBlack; // Total entries (parentheses)
input color InpPositiveTradesColor = clrBlack;  // Winning trades
input color InpNegativeTradesColor = clrOrangeRed;   // Losing trades

//--- Display constants (pixel spacing for independent colored labels).
#define PT_SEGMENT_COUNT 5
#define PT_MARGIN_X      16
#define PT_MARGIN_Y      10
// Compact, deliberate gaps between separate colored labels.
#define PT_GAP_PROFIT_ENTRIES  3
#define PT_GAP_ENTRIES_WINS    4
#define PT_GAP_WINS_COMMA      0
#define PT_GAP_COMMA_LOSSES    3

//--- Segment indexes.
enum ENUM_PT_SEGMENT
  {
   SEG_PROFIT = 0,
   SEG_ENTRIES,
   SEG_WINS,
   SEG_SEPARATOR,
   SEG_LOSSES
  };

string g_label_names[PT_SEGMENT_COUNT];
bool   g_error_reported=false;

//+------------------------------------------------------------------+
//| Format a whole monetary amount with comma thousands separators.  |
//+------------------------------------------------------------------+
string FormatWholeNumber(const double amount)
  {
   const double rounded=MathRound(amount);
   string digits=DoubleToString(MathAbs(rounded),0);

   for(int i=StringLen(digits)-3; i>0; i-=3)
      digits=StringSubstr(digits,0,i)+","+StringSubstr(digits,i);

   if(rounded<0.0)
      return "-"+digits;

   return digits;
  }

//+------------------------------------------------------------------+
//| Build unique object names.                                       |
//+------------------------------------------------------------------+
string LabelPrefix()
  {
   return "ProfitTrades_"+IntegerToString((long)ChartID())+"_";
  }

string BuildObjectName(const string suffix)
  {
   return LabelPrefix()+suffix;
  }

//+------------------------------------------------------------------+
//| Remove leftover labels created by earlier indicator versions.   |
//| Only touches this indicator's labels on the main chart.         |
//+------------------------------------------------------------------+
void RemoveLegacyLabels()
  {
   ObjectsDeleteAll(0,LabelPrefix(),0,OBJ_LABEL);
  }

//+------------------------------------------------------------------+
//| Measure text width/height for label placement.                   |
//+------------------------------------------------------------------+
bool MeasureText(const string font_name,
                 const int font_size,
                 const string text,
                 int &width,
                 int &height)
  {
   width=0;
   height=0;

   ResetLastError();
   // TextSetFont uses tenths of a point for negative sizes.
   // -10 * the OBJ_LABEL point size yields matching pixel measurements.
   // Use the same font family as the chart object. Arial Black has
   // reliably heavy strokes for high-contrast black/red trade counts.
   // Weight is provided by the font face itself (Arial Black).
   if(!TextSetFont(font_name,-10*font_size,FW_NORMAL))
      return false;

   uint measured_width=0;
   uint measured_height=0;
   ResetLastError();
   if(!TextGetSize(text,measured_width,measured_height))
      return false;

   width=(int)measured_width+1; // Small safeguard against font rounding.
   height=(int)measured_height;
   return true;
  }

//+------------------------------------------------------------------+
//| Create one chart label.                                          |
//+------------------------------------------------------------------+
bool CreateLabel(const string name)
  {
   ResetLastError();
   if(!ObjectCreate(0,name,OBJ_LABEL,0,0,0))
      return false;

   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,PT_MARGIN_Y);
   ObjectSetString(0,name,OBJPROP_TEXT,"");
   return true;
  }

//+------------------------------------------------------------------+
//| Delete all labels.                                               |
//+------------------------------------------------------------------+
void DeleteLabels()
  {
   for(int i=0; i<PT_SEGMENT_COUNT; i++)
     {
      if(g_label_names[i]!="")
         ObjectDelete(0,g_label_names[i]);
     }
  }

//+------------------------------------------------------------------+
//| Count today's realized results since broker-server midnight.     |
//+------------------------------------------------------------------+
bool CalculateToday(double &profit,int &entries,int &wins,int &losses)
  {
   profit=0.0;
   entries=0;
   wins=0;
   losses=0;

   const datetime now=TimeTradeServer();
   if(now<=0)
      return false;

   MqlDateTime date_parts;
   if(!TimeToStruct(now,date_parts))
      return false;

   date_parts.hour=0;
   date_parts.min=0;
   date_parts.sec=0;
   const datetime day_start=StructToTime(date_parts);

   ResetLastError();
   if(!HistorySelect(day_start,now))
      return false;

   const int deals_total=HistoryDealsTotal();

   ulong entry_orders[];
   if(ArrayResize(entry_orders,deals_total)!=deals_total)
      return false;
   int entry_order_count=0;

   ulong close_orders[];
   if(ArrayResize(close_orders,deals_total)!=deals_total)
      return false;
   double close_results[];
   if(ArrayResize(close_results,deals_total)!=deals_total)
      return false;
   int close_order_count=0;

   for(int i=0; i<deals_total; i++)
     {
      const ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0)
         continue;

      const ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      const bool is_trade=(type==DEAL_TYPE_BUY || type==DEAL_TYPE_SELL);

      if(!is_trade)
        {
         if(!InpCurrentSymbolOnly &&
            (type==DEAL_TYPE_COMMISSION ||
             type==DEAL_TYPE_COMMISSION_DAILY ||
             type==DEAL_TYPE_COMMISSION_MONTHLY))
           {
            profit+=HistoryDealGetDouble(ticket,DEAL_PROFIT);
            profit+=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
            profit+=HistoryDealGetDouble(ticket,DEAL_FEE);
           }
         continue;
        }

      if(InpCurrentSymbolOnly && HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)
         continue;

      const double deal_result = HistoryDealGetDouble(ticket,DEAL_PROFIT)
                               + HistoryDealGetDouble(ticket,DEAL_SWAP)
                               + HistoryDealGetDouble(ticket,DEAL_COMMISSION)
                               + HistoryDealGetDouble(ticket,DEAL_FEE);

      profit += deal_result;

      const ENUM_DEAL_ENTRY entry_type=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      ulong order_ticket=(ulong)HistoryDealGetInteger(ticket,DEAL_ORDER);
      if(order_ticket==0)
         order_ticket=ticket;

      if(entry_type==DEAL_ENTRY_IN || entry_type==DEAL_ENTRY_INOUT)
        {
         bool already_counted=false;
         for(int j=0; j<entry_order_count; j++)
           {
            if(entry_orders[j]==order_ticket)
              {
               already_counted=true;
               break;
              }
           }

         if(!already_counted)
           {
            entry_orders[entry_order_count]=order_ticket;
            entry_order_count++;
            entries++;
           }
        }

      if(entry_type==DEAL_ENTRY_OUT || entry_type==DEAL_ENTRY_OUT_BY || entry_type==DEAL_ENTRY_INOUT)
        {
         int index=-1;
         for(int j=0; j<close_order_count; j++)
           {
            if(close_orders[j]==order_ticket)
              {
               index=j;
               break;
              }
           }

         if(index<0)
           {
            index=close_order_count;
            close_orders[index]=order_ticket;
            close_results[index]=0.0;
            close_order_count++;
           }

         close_results[index]+=deal_result;
        }
     }

   for(int i=0; i<close_order_count; i++)
     {
      if(close_results[i]>0.0)
         wins++;
      else if(close_results[i]<0.0)
         losses++;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Apply the desired corner and anchor for a segment.               |
//+------------------------------------------------------------------+
void ApplyCornerAndAnchor(const string name)
  {
   if(InpTextPosition==PT_BOTTOM_RIGHT)
     {
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_LOWER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_RIGHT_LOWER);
     }
   else
     {
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_LOWER);
      ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
     }
  }

//+------------------------------------------------------------------+
//| Update segment appearance and position.                          |
//+------------------------------------------------------------------+
void UpdateSegment(const string name,
                   const string text,
                   const int x_distance,
                   const color text_color,
                   const string font_name)
  {
   ApplyCornerAndAnchor(name);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x_distance);
   ObjectSetString(0,name,OBJPROP_FONT,font_name);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,InpFontSize);
   ObjectSetInteger(0,name,OBJPROP_COLOR,text_color);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
  }

//+------------------------------------------------------------------+
//| Update the display.                                              |
//+------------------------------------------------------------------+
void RefreshDisplay()
  {
   double profit=0.0;
   int entries=0;
   int wins=0;
   int losses=0;

   string texts[PT_SEGMENT_COUNT];
   color  colors[PT_SEGMENT_COUNT];
   string fonts[PT_SEGMENT_COUNT];
   int    widths[PT_SEGMENT_COUNT];
   int    heights[PT_SEGMENT_COUNT];
   // Pixel gaps after each segment. These are independent of font width.
   int gap_after[PT_SEGMENT_COUNT];
   gap_after[SEG_PROFIT]    = PT_GAP_PROFIT_ENTRIES;
   gap_after[SEG_ENTRIES]   = PT_GAP_ENTRIES_WINS;
   gap_after[SEG_WINS]      = PT_GAP_WINS_COMMA;
   gap_after[SEG_SEPARATOR] = PT_GAP_COMMA_LOSSES;
   gap_after[SEG_LOSSES]    = 0;

   texts[SEG_SEPARATOR] = ",";
   fonts[SEG_PROFIT]    = "Arial";
   fonts[SEG_ENTRIES]   = "Arial";
   fonts[SEG_WINS]      = "Arial Black";
   fonts[SEG_SEPARATOR] = "Arial";
   fonts[SEG_LOSSES]    = "Arial Black";

   if(CalculateToday(profit,entries,wins,losses))
     {
      texts[SEG_PROFIT]  = FormatWholeNumber(profit);
      texts[SEG_ENTRIES] = "("+IntegerToString(entries)+")";
      texts[SEG_WINS]    = IntegerToString(wins);
      texts[SEG_LOSSES]  = IntegerToString(losses);

      // Bold negative profit gives readable contrast even at 10 pt.
      fonts[SEG_PROFIT]     = (profit<0.0 ? "Arial Black" : "Arial");
      colors[SEG_PROFIT]    = (profit<0.0 ? InpNegativeProfitColor : InpPositiveProfitColor);
      colors[SEG_ENTRIES]   = InpTotalTradesColor;
      colors[SEG_WINS]      = InpPositiveTradesColor;
      colors[SEG_SEPARATOR] = InpTotalTradesColor;
      colors[SEG_LOSSES]    = InpNegativeTradesColor;
      g_error_reported=false;
     }
   else
     {
      texts[SEG_PROFIT]  = "N/A";
      texts[SEG_ENTRIES] = "(N/A)";
      texts[SEG_WINS]    = "N/A";
      texts[SEG_LOSSES]  = "N/A";

      fonts[SEG_PROFIT]     = "Arial";
      colors[SEG_PROFIT]    = InpPositiveProfitColor;
      colors[SEG_ENTRIES]   = InpTotalTradesColor;
      colors[SEG_WINS]      = InpPositiveTradesColor;
      colors[SEG_SEPARATOR] = InpTotalTradesColor;
      colors[SEG_LOSSES]    = InpNegativeTradesColor;

      if(!g_error_reported)
        {
         Print("Profit & Trades: Unable to read today's deal history. Error ",GetLastError());
         g_error_reported=true;
        }
     }

   for(int i=0; i<PT_SEGMENT_COUNT; i++)
     {
      if(!MeasureText(fonts[i],InpFontSize,texts[i],widths[i],heights[i]))
        {
         widths[i]=MathMax(StringLen(texts[i])*InpFontSize,1);
         heights[i]=InpFontSize;
        }
     }

   if(InpTextPosition==PT_BOTTOM_RIGHT)
     {
      int running=PT_MARGIN_X;
      for(int i=PT_SEGMENT_COUNT-1; i>=0; i--)
        {
         UpdateSegment(g_label_names[i],texts[i],running,colors[i],fonts[i]);
         running+=widths[i];
         if(i>0)
            running+=gap_after[i-1];
        }
     }
   else
     {
      int running=PT_MARGIN_X;
      for(int i=0; i<PT_SEGMENT_COUNT; i++)
        {
         UpdateSegment(g_label_names[i],texts[i],running,colors[i],fonts[i]);
         running+=widths[i];
         if(i<PT_SEGMENT_COUNT-1)
            running+=gap_after[i];
        }
     }

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Initialization.                                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFontSize<6 || InpFontSize>150)
     {
      Print("Profit & Trades: Font size must be between 6 and 150.");
      return INIT_PARAMETERS_INCORRECT;
     }

   // Version 1.00-1.03 used different object names. Clear orphan labels
   // before creating the current 5-segment display. One copy per chart.
   RemoveLegacyLabels();

   g_label_names[SEG_PROFIT]    = BuildObjectName("Profit");
   g_label_names[SEG_ENTRIES]   = BuildObjectName("Entries");
   g_label_names[SEG_WINS]      = BuildObjectName("Wins");
   g_label_names[SEG_SEPARATOR] = BuildObjectName("Separator");
   g_label_names[SEG_LOSSES]    = BuildObjectName("Losses");

   for(int i=0; i<PT_SEGMENT_COUNT; i++)
     {
      if(!CreateLabel(g_label_names[i]))
        {
         Print("Profit & Trades: Failed to create label ",g_label_names[i],". Error ",GetLastError());
         DeleteLabels();
         return INIT_FAILED;
        }
     }

   if(!EventSetTimer(5))
     {
      Print("Profit & Trades: Failed to start timer. Error ",GetLastError());
      DeleteLabels();
      return INIT_FAILED;
     }

   RefreshDisplay();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Timer.                                                           |
//+------------------------------------------------------------------+
void OnTimer()
  {
   RefreshDisplay();
  }

//+------------------------------------------------------------------+
//| Required custom indicator event handler (no plotted buffers).    |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const int begin,
                const double &price[])
  {
   return rates_total;
  }

//+------------------------------------------------------------------+
//| Cleanup.                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeleteLabels();
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+

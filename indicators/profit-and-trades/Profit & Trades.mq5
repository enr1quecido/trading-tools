//+------------------------------------------------------------------+
//| Profit & Trades.mq5                                              |
//| Author: Enrique Briceno                                          |
//| Copyright (c) 2026 Enrique Briceno                               |
//| License: MIT (see LICENSE file)                                  |
//| GitHub: https://github.com/enr1quecido/trading-tools             |
//|                                                                  |
//| Displays today's realized trading P/L and number of entries.    |
//| Does not execute or manage trades.                               |
//+------------------------------------------------------------------+
#property copyright "Copyright (c) 2026 Enrique Briceno"
#property link      "https://github.com/enr1quecido/trading-tools"
#property version   "1.01"
#property description "Shows today's realized net P/L and number of entries."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- Account-wide totals by default. When enabled, use the chart symbol.
input bool InpCurrentSymbolOnly = false; // Count current chart symbol only

//--- Configurable font. Arial and bottom-left position remain fixed.
input group "Font appearance"
input int   InpFontSize  = 10;       // Font size (6-150)
input color InpFontColor = clrBlack; // Font color

//--- Display state.
string g_label_name     = "";
string g_last_text      = "";
bool   g_error_reported = false;

//+------------------------------------------------------------------+
//| Format a whole monetary amount with comma thousands separators. |
//+------------------------------------------------------------------+
string FormatProfit(const double amount)
  {
   // Round to a whole unit, without displaying negative zero.
   const double rounded = MathRound(amount);
   string digits = DoubleToString(MathAbs(rounded),0);

   for(int i=StringLen(digits)-3; i>0; i-=3)
      digits=StringSubstr(digits,0,i)+","+StringSubstr(digits,i);

   if(rounded<0.0)
      return "-"+digits;

   return digits;
  }

//+------------------------------------------------------------------+
//| Collect trade results since midnight in broker server time.     |
//+------------------------------------------------------------------+
bool CalculateToday(double &profit,int &entries)
  {
   profit=0.0;
   entries=0;

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
   ulong counted_orders[];
   if(ArrayResize(counted_orders,deals_total)!=deals_total)
      return false;
   int counted_total=0;

   for(int i=0; i<deals_total; i++)
     {
      const ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0)
         continue;

      const ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      const bool is_trade=(type==DEAL_TYPE_BUY || type==DEAL_TYPE_SELL);

      if(!is_trade)
        {
         // Some brokers post trading commissions as separate history deals.
         // Include those charges for an account-wide report, but never
         // include deposits, withdrawals, credits or balance adjustments.
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

      if(InpCurrentSymbolOnly &&
         HistoryDealGetString(ticket,DEAL_SYMBOL)!=_Symbol)
         continue;

      // Only booked amounts. No floating P/L from open positions.
      profit+=HistoryDealGetDouble(ticket,DEAL_PROFIT);
      profit+=HistoryDealGetDouble(ticket,DEAL_SWAP);
      profit+=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
      profit+=HistoryDealGetDouble(ticket,DEAL_FEE);

      const ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_IN && entry!=DEAL_ENTRY_INOUT)
         continue;

      // One entry per order, even when one order has several fills.
      ulong order_ticket=(ulong)HistoryDealGetInteger(ticket,DEAL_ORDER);
      if(order_ticket==0)
         order_ticket=ticket;

      bool already_counted=false;
      for(int j=0; j<counted_total; j++)
        {
         if(counted_orders[j]==order_ticket)
           {
            already_counted=true;
            break;
           }
        }

      if(!already_counted)
        {
         counted_orders[counted_total]=order_ticket;
         counted_total++;
         entries++;
        }
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Update the chart label, but only redraw when its text changes.  |
//+------------------------------------------------------------------+
void RefreshDisplay()
  {
   double profit=0.0;
   int entries=0;
   string display_text;

   if(CalculateToday(profit,entries))
     {
      display_text=FormatProfit(profit)+" ("+IntegerToString(entries)+")";
      g_error_reported=false;
     }
   else
     {
      display_text="N/A (N/A)";
      if(!g_error_reported)
        {
         Print("Profit & Trades: Unable to read today's deal history. Error ",GetLastError());
         g_error_reported=true;
        }
     }

   if(display_text!=g_last_text)
     {
      if(ObjectSetString(0,g_label_name,OBJPROP_TEXT,display_text))
        {
         g_last_text=display_text;
         ChartRedraw(0);
        }
     }
  }

//+------------------------------------------------------------------+
//| Initialization.                                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Let MT5 use the exact .mq5 file name as the indicator short name.
   // Setting the same short name explicitly makes some MT5 lists repeat
   // it in parentheses after the file name.
   if(InpFontSize<6 || InpFontSize>150)
     {
      Print("Profit & Trades: Font size must be between 6 and 150.");
      return INIT_PARAMETERS_INCORRECT;
     }

   // Unique object name so multiple copies do not remove each other.
   g_label_name="ProfitTrades_"+IntegerToString(ChartID())+"_"+
                IntegerToString((long)GetTickCount());

   ResetLastError();
   if(!ObjectCreate(0,g_label_name,OBJ_LABEL,0,0,0))
     {
      Print("Profit & Trades: Failed to create label. Error ",GetLastError());
      return INIT_FAILED;
     }

   ObjectSetInteger(0,g_label_name,OBJPROP_CORNER,CORNER_LEFT_LOWER);
   ObjectSetInteger(0,g_label_name,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0,g_label_name,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,g_label_name,OBJPROP_YDISTANCE,10);
   ObjectSetString (0,g_label_name,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,g_label_name,OBJPROP_FONTSIZE,InpFontSize);
   ObjectSetInteger(0,g_label_name,OBJPROP_COLOR,InpFontColor);
   ObjectSetInteger(0,g_label_name,OBJPROP_BACK,false);
   ObjectSetInteger(0,g_label_name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,g_label_name,OBJPROP_HIDDEN,true);
   ObjectSetString (0,g_label_name,OBJPROP_TEXT,"Loading...");

   if(!EventSetTimer(5))
     {
      Print("Profit & Trades: Failed to start timer. Error ",GetLastError());
      ObjectDelete(0,g_label_name);
      return INIT_FAILED;
     }

   RefreshDisplay();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Timer.                                                            |
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
//| Cleanup.                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_label_name!="")
      ObjectDelete(0,g_label_name);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+

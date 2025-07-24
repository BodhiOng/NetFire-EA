//+------------------------------------------------------------------+
//|                                                      NetFire.mq5 |
//|                        Copyright 2025, Bodhidharma Ong          |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Bodhidharma Ong"
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

enum MODE_TL {
    MODE_TL_LIMIT = 0,
    MODE_TL_STOP = 1,
    MODE_TL_MID = 2
};

// Input parameters grouped for better organization
sinput group "=== Trading Settings ==="
input double g_initial_gap = 20.0;                    // Initial gap for trendlines
input int g_magic = 12345;                             // Magic number
input double g_sl_pips = 50;                           // Stop loss in pips
input double g_bep_trigger_pips = 30;                  // Break-even trigger in pips
input int g_max_attempts = 10;                         // Maximum trading attempts
input string g_tp_set = "200, 250, 300, 350, 400, 300, 300, 400, 400, 400"; // Take profit levels
input string g_lot_set = "0.1, 0.1, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8"; // Lot sizes
input bool g_start_in_edit_mode = true;                // Start in edit mode by default

sinput group "=== Mode Settings ==="
input MODE_TL g_tl_mode = MODE_TL_LIMIT;               // Trading mode
input double g_mid_gap = 20;                           // Gap for MID mode

// Global variables
int g_state = 0;
ulong g_recent_ticket = 0;
double g_fix_upper = 0;
double g_fix_lower = 0;

double g_tp[];
double g_lot[];

double g_acc_loss;
ulong g_last_ticket_recorded;
bool g_cycle_done;
bool g_bep_in_place;
bool g_monitor_bep_level;
double g_bep_level;
int g_orders_made_counter = 0;

// Edit mode variables
bool g_edit_mode = true;
string g_edit_button_name = "EditModeButton";
color g_edit_button_color = clrRed;
color g_trading_button_color = clrGreen;

// Variables to track trendline times
datetime g_last_upper_tl_time = 0;
datetime g_last_lower_tl_time = 0;

// Static variable to remember mode across timeframe changes
static bool g_last_mode_was_edit = true;

MODE_TL g_tl_mode_active;

// Trade objects
CTrade g_trade;
CPositionInfo g_position;
COrderInfo g_order;

//+------------------------------------------------------------------+
//| Trendline class for MQL5                                         |
//+------------------------------------------------------------------+
class CTrendline {
public:
    string name;
    color clr;
    int style;
    int width;
    bool extendRight;

    void Draw(int shift, double price, datetime expiration) {
        // Call the ObjectCreate() function to create the trendline object
        ObjectCreate(0, name, OBJ_TREND, 0, 0, 0);

        // Set the trendline's properties
        ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
        ObjectSetInteger(0, name, OBJPROP_STYLE, style);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
        ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, extendRight);
        
        // Get current chart timeframe
        ENUM_TIMEFRAMES currentTimeframe = Period();
        int timeExtension;
        
        // Dynamically adjust trendline length based on timeframe
        switch(currentTimeframe) {
            case PERIOD_M1: timeExtension = 60 * 20; break;
            case PERIOD_M5: timeExtension = 60 * 100; break;
            case PERIOD_M15: timeExtension = 60 * 300; break;
            case PERIOD_M30: timeExtension = 60 * 600; break;
            case PERIOD_H1: timeExtension = 3600 * 20; break;
            case PERIOD_H4: timeExtension = 3600 * 80; break;
            case PERIOD_D1: timeExtension = 86400 * 20; break;
            default: timeExtension = 86400 * 4; break;
        }
        
        // Set the trendline's points based on current timeframe
        ObjectSetInteger(0, name, OBJPROP_TIME, 0, iTime(_Symbol, currentTimeframe, 0));
        ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
        ObjectSetInteger(0, name, OBJPROP_TIME, 1, iTime(_Symbol, currentTimeframe, 0) + timeExtension);
        ObjectSetDouble(0, name, OBJPROP_PRICE, 1, price);
    }
};

// Trendline objects
CTrendline g_tl_upper;
CTrendline g_tl_lower;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    // Set trade parameters
    g_trade.SetExpertMagicNumber(g_magic);
    g_trade.SetDeviationInPoints(30);
    g_trade.SetTypeFilling(ORDER_FILLING_FOK);
    
    // Parse input strings to arrays
    StringToArrayDouble(g_tp_set, g_tp);
    StringToArrayDouble(g_lot_set, g_lot);
   
    if(ObjectFind(0, "Upper Trendline") < 0) {
        CreateLines(g_initial_gap * _Point);
    }
    g_cycle_done = false;
    g_bep_in_place = false;
    g_monitor_bep_level = false;
    g_bep_level = 0;
    
    // Create the edit mode button
    CreateEditButton();
    
    // Set edit mode based on input parameter
    g_edit_mode = g_start_in_edit_mode;
    
    // Update button to reflect current mode
    UpdateEditButton();
    
    // Remember the current mode for timeframe changes
    g_last_mode_was_edit = g_edit_mode;
    
    // Enable keyboard control for chart
    ChartSetInteger(0, CHART_KEYBOARD_CONTROL, true);
   
    g_tl_mode_active = g_tl_mode;

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    // Only delete objects when the EA is being removed, not when switching timeframes
    if(reason != REASON_CHARTCHANGE) {
        // Delete trendlines
        ObjectDelete(0, g_tl_upper.name);
        ObjectDelete(0, g_tl_lower.name);
        
        // Delete level lines
        ObjectDelete(0, "buy_level");
        ObjectDelete(0, "sell_level");
        
        g_last_mode_was_edit = g_edit_mode;
    } else {
        // On timeframe change, update button position
        int chart_width = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
        int chart_height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
    
        // Update button position to stay at bottom left
        ObjectSetInteger(0, g_edit_button_name, OBJPROP_XDISTANCE, 10);
        ObjectSetInteger(0, g_edit_button_name, OBJPROP_YDISTANCE, chart_height - 40);
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    // Always process button clicks, even when cycle is done
    ProcessButtonClicks();
    
    // If in edit mode, don't execute trades
    if(g_edit_mode) {
        Comment("\n\n\nEDIT MODE: Adjust trendlines as needed, then click button to start trading");
        return;
    }
    
    if(g_cycle_done) { 
        Comment("Cycle is done, last order is in profit");
        return;
    }
    
    // Check if we have trendlines
    if(ObjectFind(0, g_tl_upper.name) < 0 || ObjectFind(0, g_tl_lower.name) < 0) {
        Comment("\n\n\nTrendlines not found. Please create trendlines for trading.");
        return;
    }
    
    // Get trendline prices at current bar position
    datetime time1_upper = (datetime)ObjectGetInteger(0, g_tl_upper.name, OBJPROP_TIME, 0);
    double price1_upper = ObjectGetDouble(0, g_tl_upper.name, OBJPROP_PRICE, 0);
    datetime time2_upper = (datetime)ObjectGetInteger(0, g_tl_upper.name, OBJPROP_TIME, 1);
    double price2_upper = ObjectGetDouble(0, g_tl_upper.name, OBJPROP_PRICE, 1);
    
    datetime time1_lower = (datetime)ObjectGetInteger(0, g_tl_lower.name, OBJPROP_TIME, 0);
    double price1_lower = ObjectGetDouble(0, g_tl_lower.name, OBJPROP_PRICE, 0);
    datetime time2_lower = (datetime)ObjectGetInteger(0, g_tl_lower.name, OBJPROP_TIME, 1);
    double price2_lower = ObjectGetDouble(0, g_tl_lower.name, OBJPROP_PRICE, 1);
    
    double upper_price, lower_price;
    
    // Calculate current price on trendlines
    if(price1_upper == price2_upper) {
        upper_price = price1_upper;
    } else {
        double slope_upper = (price2_upper - price1_upper) / (time2_upper - time1_upper);
        double intercept_upper = price1_upper - slope_upper * time1_upper;
        upper_price = slope_upper * TimeCurrent() + intercept_upper;
    }
    
    if(price1_lower == price2_lower) {
        lower_price = price1_lower;
    } else {
        double slope_lower = (price2_lower - price1_lower) / (time2_lower - time1_lower);
        double intercept_lower = price1_lower - slope_lower * time1_lower;
        lower_price = slope_lower * TimeCurrent() + intercept_lower;
    }
        
    // Trading logic based on active mode
    if(g_state == 0) {
        switch(g_tl_mode_active) {
            case MODE_TL_LIMIT:
                if(SymbolInfoDouble(_Symbol, SYMBOL_BID) > upper_price) {
                    OpenSell();
                } else if(SymbolInfoDouble(_Symbol, SYMBOL_ASK) < lower_price) {
                    OpenBuy();
                }
                break;
                
            case MODE_TL_STOP:
                if(SymbolInfoDouble(_Symbol, SYMBOL_ASK) > upper_price) {
                    OpenBuy();
                } else if(SymbolInfoDouble(_Symbol, SYMBOL_BID) < lower_price) {
                    OpenSell();
                }
                break;
                
            case MODE_TL_MID:
                if(SymbolInfoDouble(_Symbol, SYMBOL_ASK) > upper_price) {
                    CreateLines(g_mid_gap * _Point);
                    g_tl_mode_active = MODE_TL_STOP;
                    return;
                } else if(SymbolInfoDouble(_Symbol, SYMBOL_BID) < lower_price) {
                    CreateLines(g_mid_gap * _Point);
                    g_tl_mode_active = MODE_TL_STOP;
                    return;
                }
                break;
        }
    }
    
    // Monitor for ping-pong trades
    PingPong();
    
    // Monitor for trailing stop
    TrailMonitor();
    
    // Check if recent position is closed
    if(g_recent_ticket > 0) {
        if(IsPositionClosed(g_recent_ticket)) {
            double pnl = GetPositionProfit(g_recent_ticket);
            if(pnl > 0) {
                g_cycle_done = true;
            } else {
                g_acc_loss += pnl;
                g_last_ticket_recorded = g_recent_ticket;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| OnChartEvent function                                            |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {
    if(id == CHARTEVENT_CHART_CHANGE) {
        int chart_height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
        ObjectSetInteger(0, g_edit_button_name, OBJPROP_XDISTANCE, 10);
        ObjectSetInteger(0, g_edit_button_name, OBJPROP_YDISTANCE, chart_height - 40);
    }
}

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+
bool IsPositionClosed(ulong ticket) {
    return !g_position.SelectByTicket(ticket);
}

double GetPositionProfit(ulong ticket) {
    if(g_position.SelectByTicket(ticket)) {
        return g_position.Profit();
    }
    
    // Check in history if position is closed
    if(HistorySelectByPosition(ticket)) {
        double profit = 0;
        for(int i = 0; i < HistoryDealsTotal(); i++) {
            ulong deal_ticket = HistoryDealGetTicket(i);
            if(deal_ticket > 0) {
                profit += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
            }
        }
        return profit;
    }
    return 0;
}

ENUM_POSITION_TYPE GetPositionType(ulong ticket) {
    if(g_position.SelectByTicket(ticket)) {
        return g_position.PositionType();
    }
    return POSITION_TYPE_BUY;
}

int CountPositions(ENUM_POSITION_TYPE type) {
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++) {
        if(g_position.SelectByIndex(i)) {
            if(g_position.Symbol() == _Symbol && 
               g_position.Magic() == g_magic && 
               g_position.PositionType() == type) {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Trail Monitor function                                           |
//+------------------------------------------------------------------+
void TrailMonitor() {
    if(g_state >= 4) {
        if(g_monitor_bep_level && IsPositionClosed(g_recent_ticket)) {
            g_monitor_bep_level = false;
            g_bep_level = 0;
        }
      
        if(g_state >= 4 && !g_bep_in_place && !g_monitor_bep_level) {
            double current_profit = GetPositionProfit(g_recent_ticket);
            if(current_profit > MathAbs(g_acc_loss)) {
                g_bep_in_place = false;
                g_monitor_bep_level = true;
                if(GetPositionType(g_recent_ticket) == POSITION_TYPE_BUY) {
                    g_bep_level = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                } else {
                    g_bep_level = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                }
            }
        }
        
        if(g_monitor_bep_level && GetPositionType(g_recent_ticket) == POSITION_TYPE_BUY && g_bep_in_place == false) {
            if(SymbolInfoDouble(_Symbol, SYMBOL_BID) >= g_bep_level + g_bep_trigger_pips * _Point) {
                if(g_position.SelectByTicket(g_recent_ticket)) {
                    bool result = g_trade.PositionModify(g_recent_ticket, g_bep_level, g_position.TakeProfit());
                    if(result) {
                        g_bep_in_place = true;
                    }
                }
            }
        }
        
        if(g_monitor_bep_level && GetPositionType(g_recent_ticket) == POSITION_TYPE_SELL && g_bep_in_place == false) {
            if(SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= g_bep_level - g_bep_trigger_pips * _Point) {
                if(g_position.SelectByTicket(g_recent_ticket)) {
                    bool result = g_trade.PositionModify(g_recent_ticket, g_bep_level, g_position.TakeProfit());
                    if(result) {
                        g_bep_in_place = true;
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| PingPong function                                                |
//+------------------------------------------------------------------+
void PingPong() {
    if(g_state > 0 && g_state < g_max_attempts) {
        if(g_fix_upper > 0 && SymbolInfoDouble(_Symbol, SYMBOL_ASK) > g_fix_upper) {
            if(CountPositions(POSITION_TYPE_BUY) == 0 && g_recent_ticket > 0 && 
               GetPositionProfit(g_recent_ticket) < 0 && IsPositionClosed(g_recent_ticket)) {
                
                double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                double stoploss = ask - g_sl_pips * _Point;
                double takeprofit = ask + g_tp[g_state] * _Point;
            
                if(g_trade.Buy(g_lot[g_state], _Symbol, ask, stoploss, takeprofit, "Buy order")) {
                    g_recent_ticket = g_trade.ResultOrder();
                    g_state++;
                    g_orders_made_counter++;
                }
            }
        } else if(g_fix_lower > 0 && SymbolInfoDouble(_Symbol, SYMBOL_BID) < g_fix_lower) {
            if(CountPositions(POSITION_TYPE_SELL) == 0 && g_recent_ticket > 0 && 
               GetPositionProfit(g_recent_ticket) < 0 && IsPositionClosed(g_recent_ticket)) {
                
                double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                double stoploss = bid + g_sl_pips * _Point;
                double takeprofit = bid - g_tp[g_state] * _Point;
                
                if(g_trade.Sell(g_lot[g_state], _Symbol, bid, stoploss, takeprofit, "Sell order")) {
                    g_recent_ticket = g_trade.ResultOrder();
                    g_state++;
                    g_orders_made_counter++;
                }
            }
        }  
    }
}

//+------------------------------------------------------------------+
//| Open Sell Position                                               |
//+------------------------------------------------------------------+
void OpenSell() {
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double stoploss = bid + g_sl_pips * _Point;
    double takeprofit = bid - g_tp[g_state] * _Point;
    
    if(g_trade.Sell(g_lot[g_state], _Symbol, bid, stoploss, takeprofit, "Sell order")) {
        Print("SELL order executed successfully, ticket #", g_trade.ResultOrder());
        g_recent_ticket = g_trade.ResultOrder();
        g_state = 1;
        g_orders_made_counter++;
        
        double price = bid;
        
        // Set fix levels based on mode
        switch(g_tl_mode_active) {
            case MODE_TL_LIMIT:
                g_fix_lower = price;
                g_fix_upper = price + g_sl_pips * 2 * _Point;
                break;
            case MODE_TL_STOP:
                g_fix_upper = price;
                g_fix_lower = price - g_sl_pips * 2 * _Point;
                break;
            case MODE_TL_MID:
                g_fix_lower = price - g_mid_gap * _Point;
                g_fix_upper = price + g_mid_gap * _Point;
                break;
        }
        
        // Delete existing trendlines and create level lines
        ObjectDelete(0, g_tl_upper.name);
        ObjectDelete(0, g_tl_lower.name);
        
        ObjectCreate(0, "sell_level", OBJ_HLINE, 0, 0, 0);
        ObjectSetDouble(0, "sell_level", OBJPROP_PRICE, price);
        
        ObjectCreate(0, "buy_level", OBJ_HLINE, 0, 0, 0);
        ObjectSetDouble(0, "buy_level", OBJPROP_PRICE, g_fix_upper);
    }
}

//+------------------------------------------------------------------+
//| Open Buy Position                                                |
//+------------------------------------------------------------------+
void OpenBuy() {
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double stoploss = ask - g_sl_pips * _Point;
    double takeprofit = ask + g_tp[g_state] * _Point;
    
    if(g_trade.Buy(g_lot[g_state], _Symbol, ask, stoploss, takeprofit, "Buy order")) {
        Print("BUY order executed successfully, ticket #", g_trade.ResultOrder());
        g_recent_ticket = g_trade.ResultOrder();
        g_state = 1;
        g_orders_made_counter++;
        
        double price = ask;
        
        // Set fix levels based on mode
        switch(g_tl_mode_active) {
            case MODE_TL_LIMIT:
                g_fix_upper = price;
                g_fix_lower = price - g_sl_pips * 2 * _Point;
                break;
            case MODE_TL_STOP:
                g_fix_lower = price;
                g_fix_upper = price + g_sl_pips * 2 * _Point;
                break;
            case MODE_TL_MID:
                g_fix_lower = price - g_mid_gap * _Point;
                g_fix_upper = price + g_mid_gap * _Point;
                break;
        }
        
        // Delete existing trendlines and create level lines
        ObjectDelete(0, g_tl_upper.name);
        ObjectDelete(0, g_tl_lower.name);
        
        ObjectCreate(0, "buy_level", OBJ_HLINE, 0, 0, 0);
        ObjectSetDouble(0, "buy_level", OBJPROP_PRICE, price);
        
        ObjectCreate(0, "sell_level", OBJ_HLINE, 0, 0, 0);
        ObjectSetDouble(0, "sell_level", OBJPROP_PRICE, g_fix_lower);
    }
}

//+------------------------------------------------------------------+
//| Create Lines function                                            |
//+------------------------------------------------------------------+
void CreateLines(double gap_pt) {
    double mid_price = (SymbolInfoDouble(_Symbol, SYMBOL_BID) + SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / 2;
    
    ENUM_TIMEFRAMES currentTimeframe = Period();
    double timeframe_gap_multiplier = 1.0;
    
    switch(currentTimeframe) {
        case PERIOD_M1: timeframe_gap_multiplier = 4.0; break;
        case PERIOD_M5: timeframe_gap_multiplier = 8.0; break;
        case PERIOD_M15: timeframe_gap_multiplier = 12.0; break;
        case PERIOD_M30: timeframe_gap_multiplier = 16.0; break;
        case PERIOD_H1: timeframe_gap_multiplier = 24.0; break;
        case PERIOD_H4: timeframe_gap_multiplier = 32.0; break;
        case PERIOD_D1: timeframe_gap_multiplier = 64.0; break;
        default: timeframe_gap_multiplier = 10.0; break;
    }
    
    double adjusted_gap = gap_pt * timeframe_gap_multiplier;
    double upper_level = mid_price + adjusted_gap;
    double lower_level = mid_price - adjusted_gap;

    g_tl_upper.name = "Upper Trendline";
    g_tl_upper.clr = clrGreen;
    g_tl_upper.style = STYLE_DASH;
    g_tl_upper.width = 2;
    g_tl_upper.extendRight = false;

    g_tl_lower.name = "Lower Trendline";
    g_tl_lower.clr = clrRed;
    g_tl_lower.style = STYLE_DASH;
    g_tl_lower.width = 2;
    g_tl_lower.extendRight = false;

    g_tl_upper.Draw(0, upper_level, TimeCurrent());
    g_tl_lower.Draw(0, lower_level, TimeCurrent());
    
    g_last_upper_tl_time = 0;
    g_last_lower_tl_time = 0;
}

//+------------------------------------------------------------------+
//| String to Array Double function                                  |
//+------------------------------------------------------------------+
void StringToArrayDouble(string input_string, double &output_array[]) {
    string clean_string = StringTrimRight(StringTrimLeft(input_string));
    
    int comma_count = 0;
    for(int i = 0; i < StringLen(clean_string); i++) {
        if(StringGetCharacter(clean_string, i) == ',') {
            comma_count++;
        }
    }
    
    ArrayResize(output_array, comma_count + 1);
    
    string current_value = "";
    int array_index = 0;
    
    for(int i = 0; i < StringLen(clean_string); i++) {
        int char_code = StringGetCharacter(clean_string, i);
        
        if(char_code == ',') {
            output_array[array_index] = StringToDouble(current_value);
            array_index++;
            current_value = "";
        } else {
            current_value = current_value + StringSubstr(clean_string, i, 1);
        }
    }
    
    if(StringLen(current_value) > 0) {
        output_array[array_index] = StringToDouble(current_value);
    }
}

//+------------------------------------------------------------------+
//| Edit Button Functions                                            |
//+------------------------------------------------------------------+
void CreateEditButton() {
    int chart_height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
    
    ObjectCreate(0, g_edit_button_name, OBJ_BUTTON, 0, 0, 0);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_YDISTANCE, chart_height - 40);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_XSIZE, 100);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_YSIZE, 30);
    ObjectSetString(0, g_edit_button_name, OBJPROP_TEXT, "EDIT MODE");
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_BGCOLOR, g_edit_button_color);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_BORDER_COLOR, clrBlack);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_BACK, false);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_STATE, false);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_SELECTED, false);
    ObjectSetInteger(0, g_edit_button_name, OBJPROP_HIDDEN, true);
}

void UpdateEditButton() {
    if(g_edit_mode) {
        ObjectSetString(0, g_edit_button_name, OBJPROP_TEXT, "EDIT MODE");
        ObjectSetInteger(0, g_edit_button_name, OBJPROP_BGCOLOR, g_edit_button_color);
    } else {
        ObjectSetString(0, g_edit_button_name, OBJPROP_TEXT, "TRADING");
        ObjectSetInteger(0, g_edit_button_name, OBJPROP_BGCOLOR, g_trading_button_color);
    }
    ChartRedraw();
}

void ProcessButtonClicks() {
    if(ObjectGetInteger(0, g_edit_button_name, OBJPROP_STATE)) {
        ObjectSetInteger(0, g_edit_button_name, OBJPROP_STATE, false);
        
        g_edit_mode = !g_edit_mode;
        
        if(!g_edit_mode) {
            // Reset cycle state
            g_cycle_done = false;
            g_state = 0;
            g_recent_ticket = 0;
            g_acc_loss = 0;
            
            ChartRedraw();
            
            Comment("\n\n\nTRADING MODE: EA is now actively trading");
        } else {
            Comment("\n\n\nEDIT MODE: Adjust trendlines as needed, then click button to start trading");
        }
        
        UpdateEditButton();
    }
}

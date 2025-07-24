#property copyright "Copyright 2025, Bodhidharma Ong"
#property strict

enum MODE_TL {
    MODE_TL_LIMIT = 0,
    MODE_TL_STOP = 1,
    MODE_TL_MID = 2
};

input double initial_gap = 20.0;
input int magic = 12345;
input double sl_pips = 50;
input double bep_trigger_pips = 30;
input int max_attempts = 10;
input string tp_set = "200, 250, 300, 350, 400, 300, 300, 400, 400, 400";
input string lot_set = "0.1, 0.1, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8";
input bool start_in_edit_mode = true; // Start in edit mode by default

input MODE_TL tl_mode = MODE_TL_LIMIT;
input double mid_gap = 20;

int state = 0;
int recent_tk = 0;
double fix_upper = 0;
double fix_lower = 0;

//double tp[] = {200,250,300,350,400,300,300,400,400,400};
//double lot[] = {0.1,0.1,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8};
double tp[];
double lot[];

double acc_loss;
int last_tk_recorded;
bool cycle_done;
bool bep_in_place;
bool monitor_bep_level;
double bep_level;
int orders_made_counter = 0; // Counter for orders made during trading mode

// Edit mode variables
bool edit_mode = true; // Start in edit mode by default
string edit_button_name = "EditModeButton";
color edit_button_color = clrRed;
color trading_button_color = clrGreen;

// Variables to track trendline times
datetime last_upper_tl_time = 0;
datetime last_lower_tl_time = 0;

// Static variable to remember mode across timeframe changes
static bool last_mode_was_edit = true;

MODE_TL tl_mode_active;

struct Trendline {  
    string name;
    color clr;
    int style;
    int width;
    bool extendRight;

    void Draw(int shift, double price, datetime expiration)
    {
        // Call the ObjectCreate() function to create the trendline object
        ObjectCreate(name, OBJ_TREND, 0, 0, 0);

        // Set the trendline's properties
        ObjectSet(name, OBJPROP_COLOR, clr);
        ObjectSet(name, OBJPROP_STYLE, style);
        ObjectSet(name, OBJPROP_WIDTH, width);
        ObjectSet(name, OBJPROP_RAY, extendRight);
        
        // Get current chart timeframe
        int currentTimeframe = Period();
        int timeExtension;
        
        // Dynamically adjust trendline length based on timeframe
        switch(currentTimeframe)
        {
            case PERIOD_M1: // 1 minute 
            timeExtension = 60 * 20; // 20 minutes
            break;
            case PERIOD_M5: // 5 minutes
            timeExtension = 60 * 100; // 100 minutes
            break;
            case PERIOD_M15: // 15 minutes
            timeExtension = 60 * 300; // 300 minutes
            break;
            case PERIOD_M30: // 30 minutes
            timeExtension = 60 * 600; // 600 minutes
            break;
            case PERIOD_H1: // 1 hour
            timeExtension = 3600 * 20; // 20 hours
            break;
            case PERIOD_H4: // 4 hours
            timeExtension = 3600 * 80; // 80 hours
            break;
            case PERIOD_D1: // 1 day
            timeExtension = 86400 * 20; // 20 days
            break;
            default: // For any other timeframe
            timeExtension = 86400 * 4; // 4 days
            break;
        }
        
        // Set the trendline's points based on current timeframe
        ObjectSet(name, OBJPROP_TIME1, iTime(Symbol(), currentTimeframe, 0));
        ObjectSet(name, OBJPROP_PRICE1, price);
        ObjectSet(name, OBJPROP_TIME2, iTime(Symbol(), currentTimeframe, 0) + timeExtension);
        ObjectSet(name, OBJPROP_PRICE2, price);
    }
};

// Expert initialization function
int OnInit() {
    string_to_array_double(tp_set, tp);
    string_to_array_double(lot_set, lot);
   
    if(ObjectFind("Upper Trendline") < 0) {
        createLines(initial_gap * Point);
    }
    cycle_done = false;
    bep_in_place = false;
    monitor_bep_level = false;
    bep_level = 0;
    
    // Create the edit mode button
    createEditButton();
    
    // Set edit mode based on input parameter
    edit_mode = start_in_edit_mode;
    
    // Update button to reflect current mode
    updateEditButton();
    
    // Remember the current mode for timeframe changes
    last_mode_was_edit = edit_mode;
    
    // Enable keyboard control for chart
    ChartSetInteger(0, CHART_KEYBOARD_CONTROL, true); // Specifically enable keyboard control
   
    tl_mode_active = tl_mode;

    return(INIT_SUCCEEDED);
}

// Expert deinitialization function
void OnDeinit(const int reason) {
    // Only delete objects when the EA is being removed, not when switching timeframes
    // Timeframe change is reason code 3 (REASON_CHARTCHANGE)
    if(reason != REASON_CHARTCHANGE) {
        // Delete trendlines
        ObjectDelete(tl_upper.name);
        ObjectDelete(tl_lower.name);
        
        // Delete edit mode button
        ObjectDelete(edit_button_name);
        
        // Delete horizontal lines
        ObjectDelete("buy_level");
        ObjectDelete("sell_level");
    } else {
        // If we're just changing timeframes, remember the current mode
        last_mode_was_edit = edit_mode;
    }
}

// Function to handle chart resize events
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {
    // Check if this is a chart resize event
    if(id == CHARTEVENT_CHART_CHANGE) {
        // Get new chart dimensions
        int chart_width = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
        int chart_height = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
    
        // Update button position to stay at bottom left
        ObjectSet(edit_button_name, OBJPROP_XDISTANCE, 10);
        ObjectSet(edit_button_name, OBJPROP_YDISTANCE, chart_height - 40); // 40px from bottom
    }
}

// Expert tick function
void OnTick() {
    // Always process button clicks, even when cycle is done
    ProcessButtonClicks();
    
    // If in edit mode, don't execute trades
    if(edit_mode) {
        Comment("\n\n\nEDIT MODE: Adjust trendlines as needed, then click button to start trading");
        return;
    }
    
    // Get the trading mode text
    string modeText = "";
    switch(tl_mode_active) {
        case MODE_TL_LIMIT: modeText = "LIMIT"; break;
        case MODE_TL_STOP: modeText = "STOP"; break;
        case MODE_TL_MID: modeText = "MID"; break;
    }
    
    // Display orders made counter and trading mode info
    if(cycle_done) {
        Comment("\n\n\nCycle is done, last order is in profit.\n\nClick EDIT MODE button to reset and start a new cycle.\n\nTrading Mode: " + modeText + ", Orders made: " + IntegerToString(orders_made_counter));
    } else {
        Comment("\n\n\nTRADING MODE: " + modeText + "\n\nEA will execute trades based on trendlines.\n\nOrders made: " + IntegerToString(orders_made_counter));
    }

    if(orders_made_counter >= max_attempts) {
        Comment("\n\n\nMaximum number of order attempts had been reached. \n\nClick EDIT MODE button to reset and start a new cycle. \n\nOrders made: " + IntegerToString(orders_made_counter));
        return;
    }
    
    // Check if we have trendlines
    if(ObjectFind(tl_upper.name) < 0 || ObjectFind(tl_lower.name) < 0) {
        Comment("\n\n\nTrendlines not found. Please create trendlines for trading.");
        return;
    }
    
    // Get trendline prices at current bar position (accounts for diagonal trendlines)
    // Get the coordinates of the trendline points
    datetime time1_upper = (datetime)ObjectGet(tl_upper.name, OBJPROP_TIME1);
    double price1_upper = ObjectGet(tl_upper.name, OBJPROP_PRICE1);
    datetime time2_upper = (datetime)ObjectGet(tl_upper.name, OBJPROP_TIME2);
    double price2_upper = ObjectGet(tl_upper.name, OBJPROP_PRICE2);
    
    datetime time1_lower = (datetime)ObjectGet(tl_lower.name, OBJPROP_TIME1);
    double price1_lower = ObjectGet(tl_lower.name, OBJPROP_PRICE1);
    datetime time2_lower = (datetime)ObjectGet(tl_lower.name, OBJPROP_TIME2);
    double price2_lower = ObjectGet(tl_lower.name, OBJPROP_PRICE2);
    
    // Calculate the current price on each trendline
    double upper_price, lower_price;
    
    // If the trendline is horizontal, just use the price
    if(price1_upper == price2_upper) {
        upper_price = price1_upper;
    } else {
        // Calculate the slope and intercept for the upper trendline
        double slope_upper = (price2_upper - price1_upper) / (time2_upper - time1_upper);
        double intercept_upper = price1_upper - slope_upper * time1_upper;
        
        // Calculate the current price on the upper trendline
        upper_price = slope_upper * TimeCurrent() + intercept_upper;
    }
    
    // If the trendline is horizontal, just use the price
    if(price1_lower == price2_lower) {
        lower_price = price1_lower;
    } else {
        // Calculate the slope and intercept for the lower trendline
        double slope_lower = (price2_lower - price1_lower) / (time2_lower - time1_lower);
        double intercept_lower = price1_lower - slope_lower * time1_lower;
        
        // Calculate the current price on the lower trendline
        lower_price = slope_lower * TimeCurrent() + intercept_lower;
    }
        
    // Trading logic based on active mode
    if(state == 0) {
        switch(tl_mode_active) {
            case MODE_TL_LIMIT:
                // LIMIT mode: Buy when price touches lower line from above, Sell when price touches upper line from below
                if(Bid > upper_price) {
                    OpenSell();
                } else if(Ask < lower_price) {
                    OpenBuy();
                }
                break;
                
            case MODE_TL_STOP:
                // STOP mode: Buy when price breaks above upper line, Sell when price breaks below lower line
                if(Ask > upper_price) {
                    OpenBuy();
                } else if(Bid < lower_price) {
                    OpenSell();
                }
                break;
                
            case MODE_TL_MID:
            {
                // MID mode: Switch to STOP mode after breakout and recreate trendlines with mid_gap
                if(Ask > upper_price) {
                    createLines(mid_gap * Point);
                    tl_mode_active = MODE_TL_STOP;
                    return;
                } else if(Bid < lower_price) {
                    createLines(mid_gap * Point);
                    tl_mode_active = MODE_TL_STOP;
                    return;
                }
                break;
            }
        }
    }
    
    // Monitor for ping-pong trades
    PingPong();
    
    // Monitor for trailing stop
    TrailMonitor();
    
    // Check if recent order is closed
    if(recent_tk > 0) {
        if(IsOrderClosed(recent_tk)) {
            double pnl = GetOrderProfit(recent_tk);
            if(pnl > 0) {
                cycle_done = true;
            } else {
                acc_loss += pnl;
                last_tk_recorded = recent_tk;
            }
        }
    }
   
}

void TrailMonitor() {
    if(state >= 4) {
   
        if(monitor_bep_level && IsOrderClosed(recent_tk)) {
            monitor_bep_level = false;
            bep_level = 0;
        }
      
        if(state >= 4 && !bep_in_place && !monitor_bep_level) {
            if(GetOrderType(recent_tk) == OP_BUY) {
                if(Bid - Ask >= bep_trigger_pips * Point) {
                    bep_in_place = true;
                    double sl = Ask;
                    if(ModifyOrder(recent_tk, 0, sl, 0)) {
                        Print("Break-even SL set for order #", recent_tk);
                    }
                }
            } else {
                if(Ask - Bid >= bep_trigger_pips * Point) {
                    bep_in_place = true;
                    double sl = Bid;
                    if(ModifyOrder(recent_tk, 0, sl, 0)) {
                        Print("Break-even SL set for order #", recent_tk);
                    }
                }
            }
        }
        
        if(bep_in_place && IsOrderClosed(recent_tk)) {
            bep_in_place = false;
            monitor_bep_level = true;
            if(GetOrderType(recent_tk) == OP_BUY) {
                bep_level = Bid;
            } else {
                bep_level = Ask;
            }
        }
    }
}

void PingPong() {
    if(state > 0 && state < max_attempts) {
        switch(tl_mode_active) {
            case MODE_TL_LIMIT:
                // LIMIT mode: Buy when price crosses above fix_upper, Sell when price crosses below fix_lower
                if(fix_upper > 0 && Ask > fix_upper) {
                    if(CountOrders(OP_BUY) == 0 && recent_tk > 0 && GetOrderProfit(recent_tk) < 0 && IsOrderClosed(recent_tk)) {
                        // Get broker's minimum stop level
                        int min_stop_level = MarketInfo(Symbol(), MODE_STOPLEVEL);
                        
                        // Calculate stop loss and take profit with respect to minimum stop level
                        double stoploss = Ask - MathMax(sl_pips, min_stop_level + 5) * Point;
                        double takeprofit = Ask + MathMax(tp[state], min_stop_level + 5) * Point;
                       
                        int result = OrderSend(Symbol(), OP_BUY, lot[state], Ask, 3, stoploss, takeprofit, "Buy order", magic, 0, clrGreen);
                       
                        if(result > 0) {
                            recent_tk = result;
                            state++;
                            orders_made_counter++; // Increment orders counter
                        }
                    }
                }
                
                if(fix_lower > 0 && Bid < fix_lower) {
                    if(CountOrders(OP_SELL) == 0 && recent_tk > 0 && GetOrderProfit(recent_tk) < 0 && IsOrderClosed(recent_tk)) {
                        // Get broker's minimum stop level
                        int min_stop_level = MarketInfo(Symbol(), MODE_STOPLEVEL);
                        
                        // Calculate stop loss and take profit with respect to minimum stop level
                        double stoploss = Bid + MathMax(sl_pips, min_stop_level + 5) * Point;
                        double takeprofit = Bid - MathMax(tp[state], min_stop_level + 5) * Point;
                       
                        int result = OrderSend(Symbol(), OP_SELL, lot[state], Bid, 3, stoploss, takeprofit, "Sell order", magic, 0, clrGreen);
                       
                        if(result > 0) {
                            recent_tk = result;
                            state++;
                            orders_made_counter++; // Increment orders counter
                        }
                    }
                }
                break;
                
            case MODE_TL_STOP:
                // STOP mode: Buy when price crosses above fix_upper, Sell when price crosses below fix_lower
                // In STOP mode, the fix levels are reversed compared to LIMIT mode
                if(fix_lower > 0 && Ask > fix_lower) {
                    if(CountOrders(OP_BUY) == 0 && recent_tk > 0 && GetOrderProfit(recent_tk) < 0 && IsOrderClosed(recent_tk)) {
                        // Get broker's minimum stop level
                        int min_stop_level = MarketInfo(Symbol(), MODE_STOPLEVEL);
                        
                        // Calculate stop loss and take profit with respect to minimum stop level
                        double stoploss = Ask - MathMax(sl_pips, min_stop_level + 5) * Point;
                        double takeprofit = Ask + MathMax(tp[state], min_stop_level + 5) * Point;
                       
                        int result = OrderSend(Symbol(), OP_BUY, lot[state], Ask, 3, stoploss, takeprofit, "Buy order", magic, 0, clrGreen);
                       
                        if(result > 0) {
                            recent_tk = result;
                            state++;
                            orders_made_counter++; // Increment orders counter
                        }
                    }
                }
                
                if(fix_upper > 0 && Bid < fix_upper) {
                    if(CountOrders(OP_SELL) == 0 && recent_tk > 0 && GetOrderProfit(recent_tk) < 0 && IsOrderClosed(recent_tk)) {
                        // Get broker's minimum stop level
                        int min_stop_level = MarketInfo(Symbol(), MODE_STOPLEVEL);
                        
                        // Calculate stop loss and take profit with respect to minimum stop level
                        double stoploss = Bid + MathMax(sl_pips, min_stop_level + 5) * Point;
                        double takeprofit = Bid - MathMax(tp[state], min_stop_level + 5) * Point;
                       
                        int result = OrderSend(Symbol(), OP_SELL, lot[state], Bid, 3, stoploss, takeprofit, "Sell order", magic, 0, clrGreen);
                       
                        if(result > 0) {
                            recent_tk = result;
                            state++;
                            orders_made_counter++; // Increment orders counter
                        }
                    }
                }
                break;
                
            case MODE_TL_MID:
            {
                // MID mode: Buy and Sell orders are placed based on mid price
                double mid_price = (fix_upper + fix_lower) / 2;
                
                // Buy when price crosses above mid_price + mid_gap
                if(fix_upper > 0 && fix_lower > 0 && Ask > (mid_price + mid_gap * Point)) {
                    if(CountOrders(OP_BUY) == 0 && recent_tk > 0 && GetOrderProfit(recent_tk) < 0 && IsOrderClosed(recent_tk)) {
                        // Get broker's minimum stop level
                        int min_stop_level = MarketInfo(Symbol(), MODE_STOPLEVEL);
                        
                        // Calculate stop loss and take profit with respect to minimum stop level
                        double stoploss = Ask - MathMax(sl_pips, min_stop_level + 5) * Point;
                        double takeprofit = Ask + MathMax(tp[state], min_stop_level + 5) * Point;
                       
                        int result = OrderSend(Symbol(), OP_BUY, lot[state], Ask, 3, stoploss, takeprofit, "Buy order", magic, 0, clrGreen);
                       
                        if(result > 0) {
                            recent_tk = result;
                            state++;
                            orders_made_counter++; // Increment orders counter
                        }
                    }
                }
                
                // Sell when price crosses below mid_price - mid_gap
                if(fix_upper > 0 && fix_lower > 0 && Bid < (mid_price - mid_gap * Point)) {
                    if(CountOrders(OP_SELL) == 0 && recent_tk > 0 && GetOrderProfit(recent_tk) < 0 && IsOrderClosed(recent_tk)) {
                        // Get broker's minimum stop level
                        int min_stop_level = MarketInfo(Symbol(), MODE_STOPLEVEL);
                        
                        // Calculate stop loss and take profit with respect to minimum stop level
                        double stoploss = Bid + MathMax(sl_pips, min_stop_level + 5) * Point;
                        double takeprofit = Bid - MathMax(tp[state], min_stop_level + 5) * Point;
                       
                        int result = OrderSend(Symbol(), OP_SELL, lot[state], Bid, 3, stoploss, takeprofit, "Sell order", magic, 0, clrGreen);
                       
                        if(result > 0) {
                            recent_tk = result;
                            state++;
                            orders_made_counter++; // Increment orders counter
                        }
                    }
                }
                break;
            }
        }
    }
}

void OpenSell() {
    // Get broker's minimum stop level in points
    int min_stop_level = MarketInfo(Symbol(), MODE_STOPLEVEL);
    
    // Calculate stop loss and take profit with respect to minimum stop level
    double stoploss = Bid + MathMax(sl_pips, min_stop_level + 5) * Point;
    double takeprofit = Bid - MathMax(tp[state], min_stop_level + 5) * Point;
    
    int result = OrderSend(Symbol(), OP_SELL, lot[state], Bid, 3, stoploss, takeprofit, "Sell order", magic, 0, clrGreen);
        
    if(result > 0) {
        Print("SELL order executed successfully, ticket #", result);
        recent_tk = result;
        state = 1; // Order opened successfully
        orders_made_counter++; // Increment orders made counter
        
        double price = Bid;
        string name = "sell_level";
        double offset;
        
        // Set fix levels based on mode
        switch(tl_mode_active) {
            case MODE_TL_LIMIT:
                // In LIMIT mode, fix_lower is at the sell price, fix_upper is above
                fix_lower = price;
                offset = sl_pips * 2;
                fix_upper = price + offset * Point;
                break;
                
            case MODE_TL_STOP:
                // In STOP mode, fix_upper is at the sell price, fix_lower is below
                fix_upper = price;
                offset = -sl_pips * 2;
                fix_lower = price + offset * Point;
                break;
                
            case MODE_TL_MID:
            {
                // In MID mode, calculate mid price and set levels with gap
                double mid_price = price;
                fix_lower = mid_price - mid_gap * Point;
                fix_upper = mid_price + mid_gap * Point;
                break;
            }
        }
        
        // Create horizontal lines to visualize levels
        ObjectCreate(name, OBJ_HLINE, 0, 0, 0);
        ObjectSet(name, OBJPROP_PRICE, price);
        
        string opposite_name = "buy_level";
        ObjectCreate(opposite_name, OBJ_HLINE, 0, 0, 0);
        
        // Set the opposite line based on mode
        ObjectSet(opposite_name, OBJPROP_PRICE, fix_upper);
    } else {
        Print("Order's not allowed to be made");
    }
}

void OpenBuy() {
    // Get broker's minimum stop level in points
    int min_stop_level = MarketInfo(Symbol(), MODE_STOPLEVEL);
    
    // Calculate stop loss and take profit with respect to minimum stop level
    double stoploss = Ask - MathMax(sl_pips, min_stop_level + 5) * Point;
    double takeprofit = Ask + MathMax(tp[state], min_stop_level + 5) * Point;
    
    int result = OrderSend(Symbol(), OP_BUY, lot[state], Ask, 3, stoploss, takeprofit, "Buy order", magic, 0, clrGreen);
    
    if(result > 0) {
        Print("BUY order executed successfully, ticket #", result);
        recent_tk = result;
        state = 1; // Order opened successfully
        orders_made_counter++; // Increment orders made counter
        
        double price = Ask;
        string name = "buy_level";
        double offset;
        
        // Set fix levels based on mode
        switch(tl_mode_active) {
            case MODE_TL_LIMIT:
                // In LIMIT mode, fix_upper is at the buy price, fix_lower is below
                fix_upper = price;
                offset = -sl_pips * 2;
                fix_lower = price + offset * Point;
                break;
                
            case MODE_TL_STOP:
                // In STOP mode, fix_lower is at the buy price, fix_upper is above
                fix_lower = price;
                offset = sl_pips * 2;
                fix_upper = price + offset * Point;
                break;
                
            case MODE_TL_MID:
            {
                // In MID mode, calculate mid price and set levels with gap
                double mid_price = price;
                fix_lower = mid_price - mid_gap * Point;
                fix_upper = mid_price + mid_gap * Point;
                break;
            }
        }
        
        // Create horizontal lines to visualize levels
        ObjectCreate(name, OBJ_HLINE, 0, 0, 0);
        ObjectSet(name, OBJPROP_PRICE, price);
        
        string opposite_name = "sell_level";
        ObjectCreate(opposite_name, OBJ_HLINE, 0, 0, 0);
        
        // Set the opposite line based on mode
        ObjectSet(opposite_name, OBJPROP_PRICE, fix_lower);
    }
}

bool IsOrderClosed(int ticket_number) {
    if(OrderSelect(ticket_number, SELECT_BY_TICKET)) {
        if(OrderCloseTime() > 0) {
            return true;
        }
    }
    return false;
}

double GetOrderProfit(int ticket_number) {
    double profit = 0;
    if(OrderSelect(ticket_number, SELECT_BY_TICKET)) {
        profit = OrderProfit() + OrderCommission() + OrderSwap();
    }
    return profit;
}

bool ModifyOrder(int ticket_number, double price, double sl, double tp) {
    bool result = false;
    if(OrderSelect(ticket_number, SELECT_BY_TICKET)) {
        result = OrderModify(ticket_number, price, sl, tp, 0, clrGreen);
    }
    return result;
}

int GetOrderType(int ticket_number) {
    int type = OP_BUY;
    if(OrderSelect(ticket_number, SELECT_BY_TICKET)) {
        type = OrderType();
    }
    return type;
}

int CountOrders(int operation_type) {
    int count = 0;
    for(int i = 0; i < OrdersTotal(); i++)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderType() == operation_type && OrderSymbol() == Symbol() && OrderMagicNumber() == magic)
            {
                count++;
            }
        }
    }
    return count;
}

// Create the edit mode button
void createEditButton() {
    // Delete button if it already exists
    ObjectDelete(edit_button_name);
    
    // Create button object
    ObjectCreate(edit_button_name, OBJ_BUTTON, 0, 0, 0);
    
    // Position at bottom left of the chart
    int chart_width = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
    int chart_height = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
    
    // Set button position and size
    ObjectSet(edit_button_name, OBJPROP_XDISTANCE, 10);
    ObjectSet(edit_button_name, OBJPROP_YDISTANCE, chart_height - 40); // 40px from bottom
    ObjectSet(edit_button_name, OBJPROP_XSIZE, 250);
    ObjectSet(edit_button_name, OBJPROP_YSIZE, 40);
    
    // Set text color to white
    ObjectSet(edit_button_name, OBJPROP_COLOR, clrWhite);
    
    // Update button text and color based on current mode
    updateEditButton();
}

// Update the edit button text and color based on current mode
void updateEditButton() {
    if(edit_mode) {
        // Edit mode - Red button
        ObjectSetText(edit_button_name, "EDIT MODE", 9, "Arial Bold", clrWhite);
        ObjectSet(edit_button_name, OBJPROP_BGCOLOR, edit_button_color);
        ObjectSet(edit_button_name, OBJPROP_COLOR, clrWhite);
    } else {
        // Trading mode - Green button
        ObjectSetText(edit_button_name, "TRADING MODE", 9, "Arial Bold", clrWhite);
        ObjectSet(edit_button_name, OBJPROP_BGCOLOR, trading_button_color);
        ObjectSet(edit_button_name, OBJPROP_COLOR, clrWhite);
    }
}

// Process button clicks
void ProcessButtonClicks() {
    // Check if button was clicked
    if(ObjectGet(edit_button_name, OBJPROP_STATE)) {
        // Toggle edit mode
        edit_mode = !edit_mode;
        
        // Reset button state
        ObjectSet(edit_button_name, OBJPROP_STATE, false);
        
        if(!edit_mode) {
            // Switching to trading mode
            orders_made_counter = 0; // Reset orders counter when entering trading mode
            Comment("\n\n\nTRADING MODE: EA will now execute trades based on trendlines");
        } else {
            // When switching to edit mode, always create new trendlines
            // Delete existing trendlines
            ObjectDelete(tl_upper.name);
            ObjectDelete(tl_lower.name);
            
            // Create new trendlines with a wider gap for better visibility
            createLines(initial_gap * Point);
            
            // Reset cycle state
            cycle_done = false;
            state = 0;
            recent_tk = 0;
            acc_loss = 0;
            
            // Force chart redraw to ensure trendlines appear
            WindowRedraw();
            ChartRedraw();
            
            Comment("\n\n\nEDIT MODE: Adjust trendlines as needed, then click button to start trading");
        }
        
        // Update button appearance
        updateEditButton();
    }
}

void createLines(double gap_pt) {
    // Calculate the middle price to avoid issues with spread
    double mid_price = (Bid + Ask) / 2;
    
    // Get current chart timeframe and adjust gap based on timeframe
    int currentTimeframe = Period();
    double timeframe_gap_multiplier = 1.0;
    
    // Dynamically adjust gap based on timeframe
    switch(currentTimeframe)
    {
        case PERIOD_M1: // 1 minute
            timeframe_gap_multiplier = 4.0;
            break;
        case PERIOD_M5: // 5 minutes
            timeframe_gap_multiplier = 8.0;
            break;
        case PERIOD_M15: // 15 minutes
            timeframe_gap_multiplier = 12.0;
            break;
        case PERIOD_M30: // 30 minutes
            timeframe_gap_multiplier = 16.0;
            break;
        case PERIOD_H1: // 1 hour
            timeframe_gap_multiplier = 24.0;
            break;
        case PERIOD_H4: // 4 hours
            timeframe_gap_multiplier = 32.0;
            break;
        case PERIOD_D1: // 1 day
            timeframe_gap_multiplier = 64.0;
            break;
        default: // For any other timeframe
            timeframe_gap_multiplier = 10.0;
            break;
    }
    
    // Apply the timeframe multiplier to the gap
    double adjusted_gap = gap_pt * timeframe_gap_multiplier;
    
    // Calculate the upper and lower price levels from the middle price
    double upper_level = mid_price + adjusted_gap;
    double lower_level = mid_price - adjusted_gap;

    // Set the parameters for the upper trendline object
    tl_upper.name = "Upper Trendline";
    tl_upper.clr = clrGreen;
    tl_upper.style = STYLE_DASH;
    tl_upper.width = 2;
    tl_upper.extendRight = false;

    // Set the parameters for the lower trendline object
    tl_lower.name = "Lower Trendline";
    tl_lower.clr = clrRed;
    tl_lower.style = STYLE_DASH;
    tl_lower.width = 2;
    tl_lower.extendRight = false;

    // Draw the upper trendline
    tl_upper.Draw(0, upper_level, TimeCurrent());

    // Draw the lower trendline
    tl_lower.Draw(0, lower_level, TimeCurrent());
    
    // Reset the trendline times
    last_upper_tl_time = 0;
    last_lower_tl_time = 0;
}

// Function to convert a comma-separated string to an array of doubles
void string_to_array_double(string input_string, double &output_array[]) {
    // Remove spaces from the input string
    string clean_string = StringTrimRight(StringTrimLeft(input_string));
    
    // Count the number of commas to determine array size
    int comma_count = 0;
    for(int i = 0; i < StringLen(clean_string); i++) {
        if(StringGetCharacter(clean_string, i) == ',') {
            comma_count++;
        }
    }
    
    // Resize the output array
    ArrayResize(output_array, comma_count + 1);
    
    // Parse the string and fill the array
    string current_value = "";
    int array_index = 0;
    
    for(int i = 0; i < StringLen(clean_string); i++) {
        int char_code = StringGetCharacter(clean_string, i);
        
        if(char_code == ',') {
            // Convert the current value to double and add to array
            output_array[array_index] = StringToDouble(current_value);
            array_index++;
            current_value = "";
        } else {
            // Add character to current value
            current_value = current_value + StringSubstr(clean_string, i, 1);
        }
    }
    
    // Add the last value
    if(StringLen(current_value) > 0) {
        output_array[array_index] = StringToDouble(current_value);
    }
}

// Trendline objects
Trendline tl_upper;
Trendline tl_lower;
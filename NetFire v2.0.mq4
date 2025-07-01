//+------------------------------------------------------------------+
//|                                                      NetFire.mq4 |
//|                        Copyright 2022, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2022, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

enum MODE_TL {
    MODE_TL_LIMIT = 0,
    MODE_TL_STOP = 1,
    MODE_TL_MID = 2
};

input double initial_gap = 100.0;
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

// Edit mode variables
bool edit_mode = true; // Start in edit mode by default
string edit_button_name = "EditModeButton";
color edit_button_color = clrRed;
color trading_button_color = clrGreen;

// Flag to track if trendlines have been manually modified
bool trendlines_modified = false;
datetime last_upper_tl_time = 0;
datetime last_lower_tl_time = 0;

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
            timeExtension = 60 * 5; // 5 minutes
            break;
            case PERIOD_M5: // 5 minutes
            timeExtension = 60 * 25; // 25 minutes
            break;
            case PERIOD_M15: // 15 minutes
            timeExtension = 60 * 75; // 75 minutes
            break;
            case PERIOD_M30: // 30 minutes
            timeExtension = 60 * 150; // 150 minutes
            break;
            case PERIOD_H1: // 1 hour
            timeExtension = 3600 * 5; // 5 hours
            break;
            case PERIOD_H4: // 4 hours
            timeExtension = 3600 * 20; // 20 hours
            break;
            case PERIOD_D1: // 1 day
            timeExtension = 86400 * 5; // 5 days
            break;
            default: // For any other timeframe
            timeExtension = 86400; // 1 day
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
    trendlines_modified = false;
    last_upper_tl_time = 0;
    last_lower_tl_time = 0;
    
    // Set initial edit mode from input parameter
    edit_mode = start_in_edit_mode;
    
    // Create edit mode button
    createEditButton();
   
    tl_mode_active = tl_mode;

    return(INIT_SUCCEEDED);
}

// Expert deinitialization function
void OnDeinit(const int reason) {
    ObjectDelete("Upper Trendline");
    ObjectDelete("Lower Trendline");
    ObjectDelete(edit_button_name);
}

// Chart event handler function
void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam) {
    // Check if chart was resized
    if(id == CHARTEVENT_CHART_CHANGE) {
        // Update button position
        updateButtonPosition();
    }
}

// Function to update button position based on current chart size
void updateButtonPosition() {
    // Get current chart dimensions
    int chart_width = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
    int chart_height = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
    
    // Update button position to stay at bottom left
    ObjectSet(edit_button_name, OBJPROP_XDISTANCE, 10);
    ObjectSet(edit_button_name, OBJPROP_YDISTANCE, chart_height - 40); // 40px from bottom
}

// Expert tick function
void OnTick() {
   //---
    if(cycle_done) {
        Comment("\n\n\nCycle is done, last order is in profit");
        return;
    }
    
    // Process button clicks
    ProcessButtonClicks();
   
    // Check if trendlines have been modified
    CheckTrendlineModification();
    
    // If in edit mode, don't execute trades
    if(edit_mode) {
        Comment("\n\n\nEDIT MODE: Adjust trendlines as needed, then click button to start trading");
        return;
    }
   
    LossAccumulator();
   
    TrailMonitor(); // trailing module
   
    // Only allow trading if trendlines have been manually modified and are not marked as dead
    if(!trendlines_modified || (upper_tl_dead && lower_tl_dead)) {
        if(!trendlines_modified) {
            Comment("\n\n\nWaiting for trendlines to be manually adjusted before trading");
        } else {
            Comment("\n\n\nTrendlines are marked as used. Please create new trendlines for trading.");
        }
        return;
    }
   
    PingPong(); // state > 0
   
    if(tl_mode_active == MODE_TL_LIMIT) {
        CycleStarterLimit(); // state - > 0
    } else if (tl_mode_active == MODE_TL_STOP) {
        CycleStarterStop();
    } else if (tl_mode_active == MODE_TL_MID) {
        CycleStarterMiddle();
    }
}

void LossAccumulator() {
    if(recent_tk > 0 && last_tk_recorded != recent_tk) {
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
      
        if(monitor_bep_level && GetOrderType(recent_tk) == OP_BUY && bep_in_place == false) {
            if(Bid >= bep_level + bep_trigger_pips * Point) {
                if(OrderSelect(recent_tk, SELECT_BY_TICKET)) {
               
                    bool result = OrderModify(OrderTicket(), OrderOpenPrice(), bep_level, OrderTakeProfit(), 0, clrGreen);
               
                    if(result) {
                        bep_in_place = true;
                    }
                }
            }
        }
      
        if(monitor_bep_level && GetOrderType(recent_tk) == OP_SELL && bep_in_place == false) {
            if(Ask <= bep_level - bep_trigger_pips * Point) {
                if(OrderSelect(recent_tk, SELECT_BY_TICKET)) {
               
                    bool result = OrderModify(OrderTicket(), OrderOpenPrice(), bep_level, OrderTakeProfit(), 0, clrGreen);
               
                    if(result) {
                        bep_in_place = true;
                    }
                }
            }
        }
   
        if(monitor_bep_level == false && GetOrderProfit(recent_tk) > acc_loss) {
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
        if(fix_upper > 0 && Ask > fix_upper) {
         
            if(CountOrders(OP_BUY) == 0 && recent_tk > 0 && GetOrderProfit(recent_tk) < 0 && IsOrderClosed(recent_tk)) {
                double stoploss = Ask - sl_pips * Point;
                double takeprofit = Ask + tp[state] * Point;
         
                int result = OrderSend(Symbol(), OP_BUY, lot[state], Ask, 3, stoploss, takeprofit, "Buy order", magic, 0, clrGreen);
            
                if(result > 0)
                {
                    recent_tk = result;
                    state++;
                }
            }
        } else if (fix_lower > 0 && Bid < fix_lower) {
      
            if(CountOrders(OP_SELL) == 0 && recent_tk > 0 && GetOrderProfit(recent_tk) < 0 && IsOrderClosed(recent_tk)) {
      
                double stoploss = Bid + sl_pips * Point;
                double takeprofit = Bid - tp[state] * Point;
            
                int result = OrderSend(Symbol(), OP_SELL, lot[state], Ask, 3, stoploss, takeprofit, "Sell order", magic, 0, clrGreen);
               
                if(result > 0)
                {
                    recent_tk = result;
                    state++;
                }
         
            }
        }
    }
}

void OpenSell() {
   // Bid touches the upper trendline from below
    double stoploss = Bid + sl_pips * Point;
    double takeprofit = Bid - tp[state] * Point;
   
    int result = OrderSend(Symbol(), OP_SELL, lot[state], Bid, 3, stoploss, takeprofit, "Sell order", magic, 0, clrGreen);
   
    if(result > 0)
    {
        recent_tk = result;
        fix_lower = Bid;
       // Order opened successfully
        state = 1;
        // Mark trendlines as dead instead of deleting them
        upper_tl_dead = true;
        lower_tl_dead = true;
        
        // Change trendline color to indicate they're dead (gray)
        if(ObjectFind(tl_upper.name) >= 0) ObjectSet(tl_upper.name, OBJPROP_COLOR, clrDarkGray);
        if(ObjectFind(tl_lower.name) >= 0) ObjectSet(tl_lower.name, OBJPROP_COLOR, clrDarkGray);
       
        double price = Bid;
        string name = "sell_level";
        double offset = sl_pips * 2;
       
       // create replacement Hline
        ObjectCreate(name, OBJ_HLINE, 0, 0, 0);
        ObjectSet(name, OBJPROP_PRICE, price);
       
        string opposite_name = "buy_level";
        double opposite_price = price + offset * Point;
       
        fix_upper = opposite_price;
       
        ObjectCreate(opposite_name, OBJ_HLINE, 0, 0, 0);
        ObjectSet(opposite_name, OBJPROP_PRICE, opposite_price);
    }
    else
    {
       // Order failed to open
    }
}

void OpenBuy() {
   // Ask touches the lower trendline from above
    double stoploss = Ask - sl_pips * Point;
    double takeprofit = Ask + tp[state] * Point;
   
    int result = OrderSend(Symbol(), OP_BUY, lot[state], Ask, 3, stoploss, takeprofit, "Buy order", magic, 0, clrGreen);
   
    if(result > 0)
    {
        recent_tk = result;
        fix_upper = Ask;
       // Order opened successfully
        state = 1;
        // Mark trendlines as dead instead of deleting them
        upper_tl_dead = true;
        lower_tl_dead = true;
        
        // Change trendline color to indicate they're dead (gray)
        if(ObjectFind(tl_upper.name) >= 0) ObjectSet(tl_upper.name, OBJPROP_COLOR, clrDarkGray);
        if(ObjectFind(tl_lower.name) >= 0) ObjectSet(tl_lower.name, OBJPROP_COLOR, clrDarkGray);
       
        double price = Ask;
        string name = "buy_level";
        double offset = - sl_pips * 2;
       
       // create replacement Hline
        ObjectCreate(name, OBJ_HLINE, 0, 0, 0);
        ObjectSet(name, OBJPROP_PRICE, price);
       
        string opposite_name = "sell_level";
        double opposite_price = price + offset * Point;
       
        fix_lower = opposite_price;
       
        ObjectCreate(opposite_name, OBJ_HLINE, 0, 0, 0);
        ObjectSet(opposite_name, OBJPROP_PRICE, opposite_price);
    }
    else
    {
        // Order failed to open
    }
}

void CycleStarterLimit() {
    if(state == 0) {
        double tl_upper_price = ObjectGetValueByShift(tl_upper.name, 0);
        if(Bid > tl_upper_price)
        {
            OpenSell();
            return;
        } // upper TL
      
        double tl_lower_price = ObjectGetValueByShift(tl_lower.name, 0);
        if(Ask < tl_lower_price)
        {
            OpenBuy();
        }
    } // if state == 0
}

void CycleStarterStop() {
    if(state == 0) {
        double tl_upper_price = ObjectGetValueByShift(tl_upper.name, 0);
        if(Ask > tl_upper_price)
        {
            OpenBuy();
            return;
        } // upper TL
      
        double tl_lower_price = ObjectGetValueByShift(tl_lower.name, 0);
        if(Bid < tl_lower_price)
        {
            OpenSell();
        }
    } // if state == 0
}

void CycleStarterMiddle() {
    if(state == 0) {
        double tl_upper_price = ObjectGetValueByShift(tl_upper.name, 0);
        if(Ask > tl_upper_price)
        {
            createLines(mid_gap * Point);
            tl_mode_active = MODE_TL_STOP;
            return;
        } // upper TL
      
        double tl_lower_price = ObjectGetValueByShift(tl_lower.name, 0);
        if(Bid < tl_lower_price)
        {
            createLines(mid_gap * Point);
            tl_mode_active = MODE_TL_STOP;
            return;
        }
    } // if state == 0
}

#property strict

int item_count(string someString) {
    string stringCopy = someString;
    int counter = 0; // count number of commas
    while( StringFind(stringCopy, ", ", 0) >= 0 )
    {
        counter++;
        int commaIndex = StringFind(stringCopy, ", ", 0);
        int len = StringLen(stringCopy);
        stringCopy = StringSubstr(stringCopy, commaIndex + 1, len - (commaIndex + 1));
    }
   
    return(counter + 1);
}

void string_to_array_double(string someString, double &someArray[]) {
    int arraySize = item_count(someString);
   
    ArrayResize(someArray, arraySize); // RESIZE ARRAY TO FIT N MEMBERS
   
    int counter = arraySize - 1;
   
   // EXTRACT STRING INTO ARRAY
    for( int i = 0; i < counter; i++ ) // 1 - 3
    {
        int commaIndex = StringFind(someString, ", ", 0);
      
        someArray[i] = StrToDouble(StringSubstr(someString, 0, commaIndex));
      
        int len = StringLen(someString);
      
        someString = StringSubstr(someString, commaIndex + 1, len - (commaIndex + 1));
    }
   
   // LAST MEMBER OF THE ARRAY -> THE REMAINDER OF STRING
    someArray[counter] = StrToDouble(someString);
}

// Declare global variables for the two trendline objects
Trendline tl_upper;
Trendline tl_lower;

// Variables to track if trendlines are "dead" (already used for trading)
bool upper_tl_dead = false;
bool lower_tl_dead = false;

bool IsOrderClosed(int ticket_number) {
    bool is_closed = false;
    if(OrderSelect(ticket_number, SELECT_BY_TICKET))
    {
        is_closed = OrderCloseTime() > 0;
    }
    return is_closed;
}

double GetOrderProfit(int ticket_number) {
    double profit = 0;
    if(OrderSelect(ticket_number, SELECT_BY_TICKET))
    {
        profit = OrderProfit();
    }
    return profit;
}

double GetOrderType(int ticket_number) {
    int type = OP_BUY;
    if(OrderSelect(ticket_number, SELECT_BY_TICKET)) {
        type = OrderType();
    }
    return type;
}

// Function to check if trendlines have been manually modified
void CheckTrendlineModification() {
    // Get the current modification times of the trendlines
    datetime upper_tl_time = (datetime)ObjectGet(tl_upper.name, OBJPROP_TIME1);
    datetime lower_tl_time = (datetime)ObjectGet(tl_lower.name, OBJPROP_TIME1);
    
    // Check if this is the first time we're recording the times
    if(last_upper_tl_time == 0 && last_lower_tl_time == 0)
    {
        last_upper_tl_time = upper_tl_time;
        last_lower_tl_time = lower_tl_time;
        return;
    }
    
    // Check if either trendline has been modified
    if(upper_tl_time != last_upper_tl_time || lower_tl_time != last_lower_tl_time)
    {
        trendlines_modified = true;
        if(!edit_mode) {
            Comment("\n\n\nTrendlines modified - Trading enabled");
        }
    }
    
    // Update the last known times
    last_upper_tl_time = upper_tl_time;
    last_lower_tl_time = lower_tl_time;
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
        
        // When switching from edit mode to trading mode, reset the trendline dead flags
        if(!edit_mode) {
            // Reset trendline dead flags to allow trading with existing trendlines
            upper_tl_dead = false;
            lower_tl_dead = false;
        }
        
        // Update button appearance
        updateEditButton();
        
        // Show appropriate message
        if(edit_mode) {
            Comment("\n\n\nEDIT MODE: Adjust trendlines as needed, then click button to start trading");
        } else if(trendlines_modified) {
            Comment("\n\n\nTRADING MODE: EA will now execute trades based on trendlines");
        } else {
            Comment("\n\n\nTRADING MODE: Waiting for trendlines to be manually adjusted before trading");
        }
    }
}

void createLines(double gap_pt) {
    // Calculate the upper and lower price levels for the trendlines
    double upper_level = Bid + gap_pt;
    double lower_level = Ask - gap_pt;

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
    
    // Reset the modification flag when creating new lines
    trendlines_modified = false;
    last_upper_tl_time = 0;
    last_lower_tl_time = 0;
    
    // Switch to edit mode when new lines are created
    edit_mode = true;
    updateEditButton();
}
# NetFire EA

NetFire is an advanced MetaTrader 4 Expert Advisor implementing a dynamic ping-pong trading strategy using customizable upper and lower trendlines. The EA supports multiple order entry modes, adaptive lot sizing, trailing break-even, and loss recovery mechanisms to optimize trade cycles.

## Features

- **Dual Mode Operation**: Switch between Edit Mode and Trading Mode with a single click
- **Multiple Trading Modes**:
  - **LIMIT Mode**: Buy when price touches lower line from above, Sell when price touches upper line from below
  - **STOP Mode**: Buy when price touches lower line from below, Sell when price touches upper line from above
  - **MID Mode**: Calculate mid-price between trendlines and place orders based on price movements around this level
- **Visual Trendline Management**: Easily adjust upper and lower trendlines in Edit Mode
- **Dynamic Lot Sizing**: Configure progressive lot sizes for recovery trades
- **Multiple Take Profit Targets**: Set different take profit levels for each trade in a cycle
- **Break-Even Protection**: Automatic trailing stop to break-even after reaching a specified profit level
- **Loss Recovery System**: Implements a martingale-style recovery strategy with controlled risk
- **Cycle Management**: Tracks trade cycles and resets after profitable trades

## Installation

1. Copy the `NetFire v2.0.mq4` file to your MetaTrader 4 `Experts` folder
2. Restart MetaTrader 4 or refresh the Navigator panel
3. Drag and drop the EA onto your desired chart

## Usage

1. **Edit Mode**:
   - The EA starts in Edit Mode by default (red button)
   - Adjust the upper (green) and lower (red) trendlines to your desired levels
   - Click the "EDIT MODE" button to switch to Trading Mode

2. **Trading Mode**:
   - The button turns green and displays "TRADING MODE"
   - The EA will execute trades based on price interactions with the trendlines
   - Trading follows the selected mode (LIMIT, STOP, or MID)
   - Orders are placed with the configured lot sizes and take profit levels

3. **Recovery System**:
   - If a trade closes with a loss, the EA will place a recovery trade with the next lot size
   - This continues until either a profitable trade occurs or max_attempts is reached
   - A profitable trade resets the cycle

## Risk Management

The EA implements several risk management features:

- **Stop Loss**: Every trade has a defined stop loss
- **Break-Even**: Moves stop loss to entry price once trade reaches bep_trigger_pips in profit
- **Controlled Recovery**: Limited number of recovery attempts (max_attempts)
- **Visual Feedback**: Horizontal lines show entry levels and potential recovery levels

## Best Practices

1. Test thoroughly on a demo account before using with real money
2. Start with small lot sizes and increase gradually as you gain confidence
3. Adjust trendlines to match the current market conditions and volatility
4. Consider the spread of your broker when setting take profit and stop loss levels
5. Monitor the EA regularly, especially during high-impact news events

## Compatibility

- MetaTrader 4 (build 600 or higher)
- Compatible with all timeframes (adjusts trendline length automatically)
- Works with all forex pairs, though performance may vary based on volatility

## Disclaimer

Trading involves significant risk of loss and may not be suitable for all investors. Past performance is not indicative of future results. Use this EA at your own risk.
import json
import random
from datetime import datetime, timedelta, timezone

def generate_candles(symbol, timeframe_mins=1, count=500, start_price=1.08500):
    candles = []
    current_time = datetime.now(timezone.utc).replace(second=0, microsecond=0) - timedelta(minutes=count * timeframe_mins)

    last_close = start_price
    volatility = 0.0002 # Adjust for more/less movement

    for i in range(count):
        # Random walk for prices
        open_price = last_close
        change = random.normalvariate(0, volatility)
        close_price = open_price + change

        # High and Low
        high_price = max(open_price, close_price) + abs(random.normalvariate(0, volatility * 0.5))
        low_price = min(open_price, close_price) - abs(random.normalvariate(0, volatility * 0.5))

        candles.append({
            "time": current_time.isoformat().replace("+00:00", "Z"),
            "open": round(open_price, 6),
            "high": round(high_price, 6),
            "low": round(low_price, 6),
            "close": round(close_price, 6)
        })

        last_close = close_price
        current_time += timedelta(minutes=timeframe_mins)

    return candles

def main():
    # symbols to generate for
    targets = [
        {"symbol": "EURUSD_otc", "price": 1.08450},
        {"symbol": "GBPUSD_otc", "price": 1.27200},
        {"symbol": "USDBRL_otc", "price": 5.42100},
    ]

    for target in targets:
        symbol = target["symbol"]
        print(f"Generating 500 candles for {symbol}...")
        data = generate_candles(symbol, start_price=target["price"], count=500)

        filename = f"{symbol.lower()}_history.json"
        with open(filename, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        print(f"Saved to {filename}")

if __name__ == "__main__":
    main()

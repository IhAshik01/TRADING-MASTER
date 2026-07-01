import argparse
import csv
import json
import os
import requests

DEFAULT_URL = "http://127.0.0.1:8010"


def load_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_csv_rows(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        return list(reader)


def import_pair_stats(base_url, token, path):
    ext = os.path.splitext(path)[1].lower()

    if ext == ".json":
        rows = load_json(path)
    else:
        rows = load_csv_rows(path)

    items = []
    for r in rows:
        items.append({
            "symbol": str(r.get("symbol", "")).strip(),
            "label": str(r.get("label", "")).strip(),
            "profit_1m": int(float(r.get("profit_1m", 0) or 0)),
            "profit_5m": int(float(r.get("profit_5m", 0) or 0)),
            "change": float(r.get("change", 0) or 0),
            "price": float(r.get("price", 0) or 0),
        })

    payload = {"items": items}
    r = requests.post(
        f"{base_url}/otc/push-pairs",
        json=payload,
        headers={"X-Admin-Token": token},
        timeout=30,
    )
    print(r.status_code)
    print(r.text)


def import_candles(base_url, token, path, symbol, timeframe):
    ext = os.path.splitext(path)[1].lower()

    if ext == ".json":
        candles = load_json(path)
    else:
        rows = load_csv_rows(path)
        candles = []
        for r in rows:
            candles.append({
                "time": str(r["time"]).strip(),
                "open": float(r["open"]),
                "high": float(r["high"]),
                "low": float(r["low"]),
                "close": float(r["close"]),
            })

    payload = {
        "symbol": symbol,
        "timeframe": timeframe,
        "candles": candles,
    }

    r = requests.post(
        f"{base_url}/otc/push-candles",
        json=payload,
        headers={"X-Admin-Token": token},
        timeout=60,
    )
    print(r.status_code)
    print(r.text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--token", required=True)
    parser.add_argument("--mode", choices=["pairs", "candles"], required=True)
    parser.add_argument("--file", required=True)
    parser.add_argument("--symbol")
    parser.add_argument("--timeframe", default="1m")
    args = parser.parse_args()

    if args.mode == "pairs":
        import_pair_stats(args.url, args.token, args.file)
    else:
        if not args.symbol:
            raise SystemExit("--symbol is required for candles mode")
        import_candles(args.url, args.token, args.file, args.symbol, args.timeframe)


if __name__ == "__main__":
    main()

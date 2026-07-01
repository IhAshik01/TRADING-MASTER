import asyncio
import re
from collections import defaultdict, deque
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional

import httpx
from playwright.async_api import async_playwright


# ============================================================
# CONFIG
# ============================================================

BACKEND_URL = "http://127.0.0.1:8010"
TRADE_URL = "https://qxbroker.com/en/demo-trade"
USER_DATA_DIR = "./collector_profile"

POLL_SECONDS = 1.0
SCRAPE_PAIRS_EVERY = 60
PUSH_STATS_EVERY = 15
HEADLESS = False
DEBUG = True

# If the auto-click to open pair panel fails, inspect the page and set this.
# Example:
# PAIR_BUTTON_SELECTOR = "[class*='asset']"
PAIR_BUTTON_SELECTOR = None

# If auto price extraction fails, inspect page and set a direct selector here.
# Example:
# PRICE_SELECTOR = "[class*='price']"
PRICE_SELECTOR = None


# ============================================================
# LABEL -> SYMBOL MAP
# ============================================================

PAIR_MAP = {
    # common forex otc
    "EUR/USD (OTC)": "EURUSD_otc",
    "GBP/USD (OTC)": "GBPUSD_otc",
    "USD/JPY (OTC)": "USDJPY_otc",
    "AUD/USD (OTC)": "AUDUSD_otc",
    "USD/CAD (OTC)": "USDCAD_otc",
    "USD/CHF (OTC)": "USDCHF_otc",
    "EUR/JPY (OTC)": "EURJPY_otc",
    "GBP/JPY (OTC)": "GBPJPY_otc",
    "EUR/GBP (OTC)": "EURGBP_otc",
    "EUR/CHF (OTC)": "EURCHF_otc",
    "AUD/CAD (OTC)": "AUDCAD_otc",
    "AUD/CHF (OTC)": "AUDCHF_otc",
    "GBP/CAD (OTC)": "GBPCAD_otc",
    "GBP/CHF (OTC)": "GBPCHF_otc",

    # other currencies
    "USD/BRL (OTC)": "USDBRL_otc",
    "USD/MXN (OTC)": "USDMXN_otc",
    "USD/INR (OTC)": "USDINR_otc",
    "CAD/CHF (OTC)": "CADCHF_otc",
    "USD/PKR (OTC)": "USDPKR_otc",
    "AUD/NZD (OTC)": "AUDNZD_otc",
    "USD/COP (OTC)": "USDCOP_otc",
    "USD/BDT (OTC)": "USDBDT_otc",
    "USD/NGN (OTC)": "USDNGN_otc",
    "USD/DZD (OTC)": "USDDZD_otc",
    "USD/ARS (OTC)": "USDARS_otc",
    "USD/ZAR (OTC)": "USDZAR_otc",
    "NZD/CAD (OTC)": "NZDCAD_otc",
    "NZD/CHF (OTC)": "NZDCHF_otc",
    "NZD/JPY (OTC)": "NZDJPY_otc",
    "USD/EGP (OTC)": "USDEGP_otc",
    "USD/IDR (OTC)": "USDIDR_otc",
    "USD/PHP (OTC)": "USDPHP_otc",
    "GBP/NZD (OTC)": "GBPNZD_otc",
    "EUR/NZD (OTC)": "EURNZD_otc",
    "NZD/USD (OTC)": "NZDUSD_otc",

    # crypto
    "Trump (OTC)": "TRUMPUSD_otc",
    "Dash (OTC)": "DASHUSD_otc",
    "Ethereum Classic (OTC)": "ETCUSD_otc",
    "Litecoin (OTC)": "LTCUSD_otc",
    "Toncoin (OTC)": "TONUSD_otc",
    "Solana (OTC)": "SOLUSD_otc",
    "Chainlink (OTC)": "LINKUSD_otc",
    "Ethereum (OTC)": "ETHUSD_otc",
    "Polkadot (OTC)": "DOTUSD_otc",
    "Zcash (OTC)": "ZECUSD_otc",
    "Ripple (OTC)": "XRPUSD_otc",
    "Cosmos (OTC)": "ATOMUSD_otc",
    "Bitcoin (OTC)": "BTCUSD_otc",
    "Bitcoin Cash (OTC)": "BCHUSD_otc",
    "Avalanche (OTC)": "AVAXUSD_otc",
    "Axie Infinity (OTC)": "AXSUSD_otc",

    # commodities
    "UKBrent (OTC)": "UKBrent_otc",
    "Silver (OTC)": "XAGUSD_otc",
    "USCrude (OTC)": "USCrude_otc",
    "Gold (OTC)": "XAUUSD_otc",

    # stocks/indices
    "CAC 40": "CAC40",
    "FTSE 100": "FTSE100",
    "S&P/ASX 200": "ASX200",
    "Nikkei 225": "Nikkei225",
    "EURO STOXX 50": "EuroStoxx50",
    "FTSE China A50 Index": "ChinaA50",
    "Hong Kong 50": "HK50",
    "IBEX 35": "IBEX35",
}


# ============================================================
# HELPERS
# ============================================================

def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def label_to_symbol(label: str) -> str:
    label = " ".join(label.split()).strip()
    if label in PAIR_MAP:
        return PAIR_MAP[label]

    cleaned = re.sub(r"[^A-Za-z0-9]", "", label).upper()
    for k, v in PAIR_MAP.items():
        if re.sub(r"[^A-Za-z0-9]", "", k).upper() == cleaned:
            return v

    # fallback
    if "(OTC)" in label:
        base = re.sub(r"[^A-Za-z0-9]", "", label.replace("(OTC)", "")).upper()
        return f"{base}_otc"
    return label


def parse_payout_int(value: str) -> int:
    m = re.search(r"(\d{1,3})\s*%", value)
    if not m:
        return 0
    return int(m.group(1))


def parse_float_text(text: str) -> Optional[float]:
    try:
        return float(text.replace(",", ""))
    except Exception:
        return None


def calc_change_percent_from_candles(candles: List[Dict[str, Any]]) -> float:
    if len(candles) < 2:
        return 0.0
    first = float(candles[0]["close"])
    last = float(candles[-1]["close"])
    if first == 0:
        return 0.0
    return round(((last - first) / first) * 100.0, 2)


# ============================================================
# CANDLE BUILDER
# ============================================================

class CandleBuilder:
    def __init__(self):
        self.current: Dict[str, Dict[str, Any]] = {}
        self.history: Dict[str, deque] = defaultdict(lambda: deque(maxlen=500))

    def update_tick(self, symbol: str, price: float, ts: datetime) -> Optional[Dict[str, Any]]:
        bucket = ts.replace(second=0, microsecond=0)
        key = symbol

        if key not in self.current:
            self.current[key] = {
                "bucket": bucket,
                "candle": {
                    "time": iso_z(bucket),
                    "open": price,
                    "high": price,
                    "low": price,
                    "close": price,
                }
            }
            return None

        current_bucket = self.current[key]["bucket"]
        candle = self.current[key]["candle"]

        if bucket != current_bucket:
            closed = dict(candle)
            self.history[key].append(closed)

            self.current[key] = {
                "bucket": bucket,
                "candle": {
                    "time": iso_z(bucket),
                    "open": price,
                    "high": price,
                    "low": price,
                    "close": price,
                }
            }
            return closed

        candle["high"] = max(float(candle["high"]), price)
        candle["low"] = min(float(candle["low"]), price)
        candle["close"] = price
        return None

    def get_recent(self, symbol: str, limit: int = 120) -> List[Dict[str, Any]]:
        return list(self.history[symbol])[-limit:]


# ============================================================
# BACKEND PUSHER
# ============================================================

class BackendPusher:
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")
        self.client = httpx.AsyncClient(timeout=20)

    async def push_pairs(self, items: List[Dict[str, Any]]):
        payload = {"items": items}
        r = await self.client.post(f"{self.base_url}/otc/push-pairs", json=payload)
        r.raise_for_status()
        return r.json()

    async def push_candles(self, symbol: str, timeframe: str, candles: List[Dict[str, Any]]):
        payload = {
            "symbol": symbol,
            "timeframe": timeframe,
            "candles": candles,
        }
        r = await self.client.post(f"{self.base_url}/otc/push-candles", json=payload)
        r.raise_for_status()
        return r.json()

    async def close(self):
        await self.client.aclose()


# ============================================================
# DOM SCRAPING
# ============================================================

async def visible_blocks(page):
    return await page.evaluate("""
    () => {
      const els = Array.from(document.querySelectorAll('body *'));
      const out = [];
      for (const el of els) {
        const style = window.getComputedStyle(el);
        const rect = el.getBoundingClientRect();
        const text = (el.innerText || '').trim();
        if (!text) continue;
        if (style.visibility === 'hidden' || style.display === 'none') continue;
        if (rect.width < 5 || rect.height < 5) continue;
        if (rect.bottom < 0 || rect.right < 0) continue;
        out.push({
          text,
          x: rect.x,
          y: rect.y,
          w: rect.width,
          h: rect.height
        });
      }
      return out;
    }
    """)


async def find_active_pair_and_payout(page) -> Optional[Dict[str, Any]]:
    blocks = await visible_blocks(page)

    candidates = []
    pair_regex = re.compile(r"(.+?(\(OTC\)|CAC 40|FTSE 100|Nikkei 225|IBEX 35|Hong Kong 50|EURO STOXX 50|S\u0026P/ASX 200|FTSE China A50 Index))\s+(\d{1,3})%")

    for b in blocks:
        text = " ".join(b["text"].split())
        m = pair_regex.search(text)
        if m:
            label = m.group(1).strip()
            payout = int(m.group(3))
            candidates.append({
                "label": label,
                "symbol": label_to_symbol(label),
                "profit_1m": payout,
                "profit_5m": payout,
                "x": b["x"],
                "y": b["y"],
            })

    if not candidates:
        return None

    # usually active pair widget is lower on page than chart labels
    candidates.sort(key=lambda x: x["y"], reverse=True)
    return candidates[0]


async def open_pair_panel(page, active_label: Optional[str]):
    if PAIR_BUTTON_SELECTOR:
        try:
            await page.locator(PAIR_BUTTON_SELECTOR).first.click(timeout=2000)
            await page.wait_for_timeout(800)
            return
        except Exception:
            pass

    if active_label:
        try:
            await page.get_by_text(active_label, exact=False).first.click(timeout=2000)
            await page.wait_for_timeout(800)
            return
        except Exception:
            pass


async def close_panel(page):
    try:
        await page.keyboard.press("Escape")
    except Exception:
        pass


async def scrape_pair_stats(page, active_label: Optional[str]) -> Dict[str, Dict[str, Any]]:
    await open_pair_panel(page, active_label)
    await page.wait_for_timeout(1000)

    blocks = await visible_blocks(page)
    out: Dict[str, Dict[str, Any]] = {}

    pair_regex = re.compile(r"(.+?(\(OTC\)|CAC 40|FTSE 100|Nikkei 225|IBEX 35|Hong Kong 50|EURO STOXX 50|S\u0026P/ASX 200|FTSE China A50 Index))\s+(\d{1,3})%")

    for b in blocks:
        text = " ".join(b["text"].split())
        m = pair_regex.search(text)
        if not m:
            continue

        label = m.group(1).strip()
        payout = int(m.group(3))
        symbol = label_to_symbol(label)

        out[symbol] = {
            "symbol": symbol,
            "label": label,
            "profit_1m": payout,
            "profit_5m": payout,
            "change": 0.0,
            "price": None,
        }

    await close_panel(page)
    return out


async def find_current_price(page) -> Optional[float]:
    if PRICE_SELECTOR:
        try:
            txt = await page.locator(PRICE_SELECTOR).first.inner_text(timeout=1000)
            txt = txt.strip()
            m = re.search(r"\d+\.\d{3,6}", txt)
            if m:
                return float(m.group(0))
        except Exception:
            pass

    blocks = await visible_blocks(page)
    num_candidates = []

    for b in blocks:
        # skip huge text blobs
        if len(b["text"]) > 40:
            continue

        text = b["text"].strip()
        if "%" in text or ":" in text:
            continue

        m = re.fullmatch(r"\d+\.\d{3,6}", text.replace(",", ""))
        if not m:
            continue

        val = parse_float_text(text)
        if val is None:
            continue

        num_candidates.append({
            "value": val,
            "x": b["x"],
            "y": b["y"],
            "h": b["h"],
            "w": b["w"],
            "text": text,
        })

    if DEBUG and num_candidates:
        pass

    if not num_candidates:
        return None

    # heuristic: chart/current quote is often reasonably large and on left/mid of page
    num_candidates.sort(key=lambda x: (x["h"], -x["y"]), reverse=True)
    return float(num_candidates[0]["value"])


# ============================================================
# MAIN LOOP
# ============================================================

async def main():
    candle_builder = CandleBuilder()
    pusher = BackendPusher(BACKEND_URL)

    pair_stats: Dict[str, Dict[str, Any]] = {}

    async with async_playwright() as p:
        context = await p.chromium.launch_persistent_context(
            USER_DATA_DIR,
            headless=HEADLESS,
            viewport={"width": 1440, "height": 900},
        )

        page = context.pages[0] if context.pages else await context.new_page()
        await page.goto(TRADE_URL, wait_until="domcontentloaded")

        print("\n=== OTC COLLECTOR ===")
        print("1) Log in manually if needed")
        print("2) Switch to an OTC pair")
        print("3) Keep the chart page open")
        print("4) Press Enter here when ready\n")
        await asyncio.to_thread(input, "Press Enter when chart is live... ")

        # initial pair scrape
        active = await find_active_pair_and_payout(page)
        if active:
            print(f"[active] {active['label']} -> {active['symbol']}")
            pair_stats[active["symbol"]] = {
                "symbol": active["symbol"],
                "label": active["label"],
                "profit_1m": active["profit_1m"],
                "profit_5m": active["profit_5m"],
                "change": 0.0,
                "price": None,
            }

        try:
            fresh_pairs = await scrape_pair_stats(page, active["label"] if active else None)
            if fresh_pairs:
                pair_stats.update(fresh_pairs)
                await pusher.push_pairs(list(pair_stats.values()))
                print(f"[pairs] pushed {len(pair_stats)} pair stats")
        except Exception as e:
            print(f"[warn] initial pair scrape failed: {e}")

        last_pair_scrape = 0.0
        last_stats_push = 0.0

        while True:
            loop_now = asyncio.get_running_loop().time()

            try:
                active = await find_active_pair_and_payout(page)
                price = await find_current_price(page)

                if active and price is not None:
                    symbol = active["symbol"]
                    label = active["label"]

                    if symbol not in pair_stats:
                        pair_stats[symbol] = {
                            "symbol": symbol,
                            "label": label,
                            "profit_1m": active["profit_1m"],
                            "profit_5m": active["profit_5m"],
                            "change": 0.0,
                            "price": None,
                        }

                    pair_stats[symbol]["label"] = label
                    pair_stats[symbol]["profit_1m"] = active["profit_1m"]
                    pair_stats[symbol]["profit_5m"] = active["profit_5m"]
                    pair_stats[symbol]["price"] = round(float(price), 6)

                    closed = candle_builder.update_tick(symbol, float(price), now_utc())

                    recent = candle_builder.get_recent(symbol, limit=30)
                    pair_stats[symbol]["change"] = calc_change_percent_from_candles(recent)

                    if DEBUG:
                        print(f"[tick] {label} {price}")

                    if closed:
                        if DEBUG:
                            print(f"[candle] closed {symbol} {closed}")

                        to_send = candle_builder.get_recent(symbol, limit=120)
                        await pusher.push_candles(symbol, "1m", to_send)
                        if DEBUG:
                            print(f"[push] candles -> {symbol} ({len(to_send)})")

                # refresh pair payouts from pair list
                if loop_now - last_pair_scrape >= SCRAPE_PAIRS_EVERY:
                    try:
                        fresh_pairs = await scrape_pair_stats(page, active["label"] if active else None)
                        if fresh_pairs:
                            for sym, row in fresh_pairs.items():
                                old = pair_stats.get(sym, {})
                                pair_stats[sym] = {
                                    "symbol": sym,
                                    "label": row["label"],
                                    "profit_1m": row["profit_1m"],
                                    "profit_5m": row["profit_5m"],
                                    "change": old.get("change", 0.0),
                                    "price": old.get("price"),
                                }
                            if DEBUG:
                                print(f"[pairs] scraped {len(fresh_pairs)} rows")
                    except Exception as e:
                        print(f"[warn] pair scrape failed: {e}")

                    last_pair_scrape = loop_now

                # push pair stats to backend
                if loop_now - last_stats_push >= PUSH_STATS_EVERY:
                    try:
                        await pusher.push_pairs(list(pair_stats.values()))
                        if DEBUG:
                            print(f"[push] pair stats -> {len(pair_stats)}")
                    except Exception as e:
                        print(f"[warn] push pair stats failed: {e}")

                    last_stats_push = loop_now

            except Exception as e:
                print(f"[loop error] {e}")

            await asyncio.sleep(POLL_SECONDS)

        # never reached
        await pusher.close()
        await context.close()


if __name__ == "__main__":
    asyncio.run(main())

import asyncio
import json
import os
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
TRADE_URL = "https://market-qx.trade/en/demo-trade"
USER_DATA_DIR = "./rotating_collector_profile"
STATE_FILE = "./rotating_otc_state.json"

HEADLESS = False
DEBUG = True

# Keep this SMALL for better candles
WATCHLIST_LABELS = [
    "EUR/USD (OTC)",
    "GBP/USD (OTC)",
    "USD/BRL (OTC)",
]

# stay on each pair this long
DWELL_SECONDS = 20

# tick poll interval while sitting on one pair
TICK_POLL_SECONDS = 1.0

# scrape payouts / stats every N seconds
SCRAPE_STATS_EVERY = 90

# push pair stats every N seconds
PUSH_STATS_EVERY = 20

# save local state every N seconds
SAVE_STATE_EVERY = 20

# Optional manual selectors if heuristics fail
PAIR_BUTTON_SELECTOR = None
PRICE_SELECTOR = None


# ============================================================
# LABEL -> SYMBOL MAP
# ============================================================

PAIR_MAP = {
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

    "UKBrent (OTC)": "UKBrent_otc",
    "Silver (OTC)": "XAGUSD_otc",
    "USCrude (OTC)": "USCrude_otc",
    "Gold (OTC)": "XAUUSD_otc",

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


def parse_iso(value: str) -> datetime:
    try:
        if value.endswith("Z"):
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            return dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        return now_utc()


def label_to_symbol(label: str) -> str:
    label = " ".join(label.split()).strip()
    if label in PAIR_MAP:
        return PAIR_MAP[label]

    cleaned = re.sub(r"[^A-Za-z0-9]", "", label).upper()
    for k, v in PAIR_MAP.items():
        if re.sub(r"[^A-Za-z0-9]", "", k).upper() == cleaned:
            return v

    if "(OTC)" in label:
        base = re.sub(r"[^A-Za-z0-9]", "", label.replace("(OTC)", "")).upper()
        return f"{base}_otc"

    return label


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
# STATE
# ============================================================

class CollectorState:
    def __init__(self):
        self.pair_stats: Dict[str, Dict[str, Any]] = {}
        self.closed_candles: Dict[str, deque] = defaultdict(lambda: deque(maxlen=500))

    def save(self):
        data = {
            "pair_stats": self.pair_stats,
            "closed_candles": {
                symbol: list(candles)
                for symbol, candles in self.closed_candles.items()
            },
            "saved_at": iso_z(now_utc()),
        }
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)

    def load(self):
        if not os.path.exists(STATE_FILE):
            return

        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)

            self.pair_stats = data.get("pair_stats", {})
            raw_closed = data.get("closed_candles", {})

            self.closed_candles = defaultdict(lambda: deque(maxlen=500))
            for symbol, arr in raw_closed.items():
                dq = deque(maxlen=500)
                for item in arr:
                    dq.append(item)
                self.closed_candles[symbol] = dq
        except Exception as e:
            print(f"[warn] failed to load state: {e}")


# ============================================================
# CANDLE BUILDER
# ============================================================

class CandleBuilder:
    def __init__(self, state: CollectorState):
        self.state = state
        self.current: Dict[str, Dict[str, Any]] = {}

    def update_tick(self, symbol: str, price: float, ts: datetime) -> Optional[Dict[str, Any]]:
        bucket = ts.replace(second=0, microsecond=0)

        if symbol not in self.current:
            self.current[symbol] = {
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

        current_bucket = self.current[symbol]["bucket"]
        candle = self.current[symbol]["candle"]

        if bucket != current_bucket:
            closed = dict(candle)
            self.state.closed_candles[symbol].append(closed)

            self.current[symbol] = {
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

    def get_recent_closed(self, symbol: str, limit: int = 120) -> List[Dict[str, Any]]:
        return list(self.state.closed_candles[symbol])[-limit:]


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

    async def warmup(self):
        try:
            r = await self.client.get(f"{self.base_url}/quotex-warmup")
            return r.json()
        except Exception:
            return None

    async def close(self):
        await self.client.aclose()


# ============================================================
# DOM / SCRAPING
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

    pair_regex = re.compile(
        r"(.+?(\(OTC\)|CAC 40|FTSE 100|Nikkei 225|IBEX 35|Hong Kong 50|EURO STOXX 50|S&P/ASX 200|FTSE China A50 Index))\s+(\d{1,3})%"
    )

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

    candidates.sort(key=lambda x: x["y"], reverse=True)
    return candidates[0]


async def open_pair_panel(page, active_label: Optional[str]):
    if PAIR_BUTTON_SELECTOR:
        try:
            await page.locator(PAIR_BUTTON_SELECTOR).first.click(timeout=2000)
            await page.wait_for_timeout(800)
            return True
        except Exception:
            pass

    if active_label:
        try:
            await page.get_by_text(active_label, exact=False).first.click(timeout=2000)
            await page.wait_for_timeout(800)
            return True
        except Exception:
            pass

    return False


async def close_panel(page):
    try:
        await page.keyboard.press("Escape")
    except Exception:
        pass


async def click_text_fallback(page, label: str) -> bool:
    try:
        ok = await page.evaluate(
            """(label) => {
                const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim();
                const target = norm(label);
                const els = Array.from(document.querySelectorAll('body *'));
                for (const el of els) {
                    const txt = norm(el.innerText || '');
                    if (!txt) continue;
                    if (txt.includes(target)) {
                        const rect = el.getBoundingClientRect();
                        if (rect.width > 5 && rect.height > 5) {
                            el.click();
                            return true;
                        }
                    }
                }
                return false;
            }""",
            label,
        )
        return bool(ok)
    except Exception:
        return False


async def select_pair(page, label: str) -> bool:
    active = await find_active_pair_and_payout(page)
    await open_pair_panel(page, active["label"] if active else None)
    await page.wait_for_timeout(800)

    clicked = False

    try:
        await page.get_by_text(label, exact=False).first.click(timeout=2500)
        clicked = True
    except Exception:
        clicked = await click_text_fallback(page, label)

    if not clicked:
        await close_panel(page)
        return False

    await page.wait_for_timeout(1500)
    await close_panel(page)
    await page.wait_for_timeout(500)

    new_active = await find_active_pair_and_payout(page)
    if not new_active:
        return False

    return new_active["label"] == label or label in new_active["label"]


async def scrape_pair_stats(page, active_label: Optional[str]) -> Dict[str, Dict[str, Any]]:
    opened = await open_pair_panel(page, active_label)
    if not opened:
        return {}

    await page.wait_for_timeout(1000)
    blocks = await visible_blocks(page)
    out: Dict[str, Dict[str, Any]] = {}

    pair_regex = re.compile(
        r"(.+?(\(OTC\)|CAC 40|FTSE 100|Nikkei 225|IBEX 35|Hong Kong 50|EURO STOXX 50|S&P/ASX 200|FTSE China A50 Index))\s+(\d{1,3})%"
    )

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
        })

    if not num_candidates:
        return None

    num_candidates.sort(key=lambda x: (x["h"], -x["y"]), reverse=True)
    return float(num_candidates[0]["value"])


# ============================================================
# BACKEND RESTORE
# ============================================================

async def restore_cached_data_to_backend(state: CollectorState, pusher: BackendPusher):
    if state.pair_stats:
        try:
            await pusher.push_pairs(list(state.pair_stats.values()))
            print(f"[restore] pushed {len(state.pair_stats)} pair stats")
        except Exception as e:
            print(f"[restore warn] pair stats push failed: {e}")

    for symbol, dq in state.closed_candles.items():
        candles = list(dq)[-120:]
        if not candles:
            continue
        try:
            await pusher.push_candles(symbol, "1m", candles)
            print(f"[restore] pushed {len(candles)} candles for {symbol}")
        except Exception as e:
            print(f"[restore warn] candles push failed for {symbol}: {e}")


# ============================================================
# MAIN ROTATION LOOP
# ============================================================

async def main():
    state = CollectorState()
    state.load()

    candle_builder = CandleBuilder(state)
    pusher = BackendPusher(BACKEND_URL)

    async with async_playwright() as p:
        context = await p.chromium.launch_persistent_context(
            USER_DATA_DIR,
            headless=HEADLESS,
            viewport={"width": 1440, "height": 900},
        )

        page = context.pages[0] if context.pages else await context.new_page()
        await page.goto(TRADE_URL, wait_until="domcontentloaded")

        print("\n=== ROTATING OTC COLLECTOR ===")
        print("1) Log in manually if needed")
        print("2) Open any OTC pair first")
        print("3) Press Enter here when ready")
        await asyncio.to_thread(input, "\nPress Enter when ready... ")

        await pusher.warmup()
        await restore_cached_data_to_backend(state, pusher)

        active = await find_active_pair_and_payout(page)
        if active:
            state.pair_stats[active["symbol"]] = {
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
                state.pair_stats.update(fresh_pairs)
                await pusher.push_pairs(list(state.pair_stats.values()))
                print(f"[pairs] initial scrape: {len(fresh_pairs)}")
        except Exception as e:
            print(f"[warn] initial pair scrape failed: {e}")

        watchlist = WATCHLIST_LABELS[:]
        watch_index = 0

        last_stats_scrape = 0.0
        last_stats_push = 0.0
        last_state_save = 0.0

        while True:
            target_label = watchlist[watch_index % len(watchlist)]
            target_symbol = label_to_symbol(target_label)

            print(f"\n[rotate] switching to {target_label}")
            switched = await select_pair(page, target_label)

            if not switched:
                print(f"[warn] could not switch to {target_label}")
                watch_index += 1
                await asyncio.sleep(2)
                continue

            # refresh active after switch
            active = await find_active_pair_and_payout(page)
            if active:
                target_symbol = active["symbol"]
                target_label = active["label"]

                if target_symbol not in state.pair_stats:
                    state.pair_stats[target_symbol] = {
                        "symbol": target_symbol,
                        "label": target_label,
                        "profit_1m": active["profit_1m"],
                        "profit_5m": active["profit_5m"],
                        "change": 0.0,
                        "price": None,
                    }

            dwell_start = asyncio.get_running_loop().time()

            while True:
                loop_now = asyncio.get_running_loop().time()
                elapsed = loop_now - dwell_start
                if elapsed >= DWELL_SECONDS:
                    break

                try:
                    active = await find_active_pair_and_payout(page)
                    price = await find_current_price(page)

                    if active and price is not None:
                        symbol = active["symbol"]
                        label = active["label"]

                        if symbol not in state.pair_stats:
                            state.pair_stats[symbol] = {
                                "symbol": symbol,
                                "label": label,
                                "profit_1m": active["profit_1m"],
                                "profit_5m": active["profit_5m"],
                                "change": 0.0,
                                "price": None,
                            }

                        state.pair_stats[symbol]["label"] = label
                        state.pair_stats[symbol]["profit_1m"] = active["profit_1m"]
                        state.pair_stats[symbol]["profit_5m"] = active["profit_5m"]
                        state.pair_stats[symbol]["price"] = round(float(price), 6)

                        closed = candle_builder.update_tick(symbol, float(price), now_utc())
                        recent = candle_builder.get_recent_closed(symbol, limit=30)
                        state.pair_stats[symbol]["change"] = calc_change_percent_from_candles(recent)

                        if DEBUG:
                            print(f"[tick] {label} {price}")

                        if closed:
                            to_send = candle_builder.get_recent_closed(symbol, limit=120)
                            await pusher.push_candles(symbol, "1m", to_send)
                            if DEBUG:
                                print(f"[push] candles -> {symbol} ({len(to_send)})")

                except Exception as e:
                    print(f"[tick warn] {e}")

                # periodic stats scrape
                if loop_now - last_stats_scrape >= SCRAPE_STATS_EVERY:
                    try:
                        fresh_pairs = await scrape_pair_stats(page, active["label"] if active else None)
                        if fresh_pairs:
                            for sym, row in fresh_pairs.items():
                                old = state.pair_stats.get(sym, {})
                                state.pair_stats[sym] = {
                                    "symbol": sym,
                                    "label": row["label"],
                                    "profit_1m": row["profit_1m"],
                                    "profit_5m": row["profit_5m"],
                                    "change": old.get("change", 0.0),
                                    "price": old.get("price"),
                                }
                            if DEBUG:
                                print(f"[stats] scraped {len(fresh_pairs)} pairs")
                    except Exception as e:
                        print(f"[stats warn] {e}")

                    last_stats_scrape = loop_now

                # periodic stats push
                if loop_now - last_stats_push >= PUSH_STATS_EVERY:
                    try:
                        await pusher.push_pairs(list(state.pair_stats.values()))
                        if DEBUG:
                            print(f"[push] pair stats -> {len(state.pair_stats)}")
                    except Exception as e:
                        print(f"[push warn] pair stats failed: {e}")

                    last_stats_push = loop_now

                # periodic state save
                if loop_now - last_state_save >= SAVE_STATE_EVERY:
                    try:
                        state.save()
                        if DEBUG:
                            print("[state] saved")
                    except Exception as e:
                        print(f"[state warn] {e}")

                    last_state_save = loop_now

                await asyncio.sleep(TICK_POLL_SECONDS)

            watch_index += 1

        await pusher.close()
        await context.close()


if __name__ == "__main__":
    asyncio.run(main())

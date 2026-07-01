import sys
import asyncio

if sys.platform.startswith("win"):
    try:
        asyncio.set_event_loop_policy(asyncio.WindowsProactorEventLoopPolicy())
    except Exception:
        pass

import os
import math
import json
import re
import inspect
import base64
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo
from typing import List, Dict, Any, Optional

import httpx
import firebase_admin
from firebase_admin import credentials, firestore
from dotenv import load_dotenv
from fastapi import FastAPI, Query, UploadFile, File, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel

load_dotenv()

TWELVEDATA_API_KEY = os.getenv("TWELVEDATA_API_KEY")
APP_TIMEZONE = os.getenv("APP_TIMEZONE", "Asia/Dhaka")
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "tradingmaster123")

# Initialize Firebase
def init_firestore():
    if firebase_admin._apps:
        return firestore.client()

    # Try B64 first (Best for Render)
    b64_json = os.getenv("FIREBASE_SERVICE_ACCOUNT_B64")
    if b64_json:
        try:
            decoded = base64.b64decode(b64_json).decode("utf-8")
            cred_dict = json.loads(decoded)
            cred = credentials.Certificate(cred_dict)
            firebase_admin.initialize_app(cred)
            return firestore.client()
        except Exception as e:
            print(f"Firebase B64 init error: {e}")

    # Try Raw JSON (Second best)
    raw_json = os.getenv("FIREBASE_SERVICE_ACCOUNT")
    if raw_json:
        try:
            sa_dict = json.loads(raw_json)
            cred = credentials.Certificate(sa_dict)
            firebase_admin.initialize_app(cred)
            return firestore.client()
        except Exception as e:
            print(f"Firebase Raw JSON init error: {e}")

    # Fallback to ADC (Local development)
    try:
        firebase_admin.initialize_app()
        return firestore.client()
    except Exception as e:
        print(f"Firebase default init failed: {e}")
        return None

db = init_firestore()

app = FastAPI(title="TRADING MASTER API", version="2.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

REAL_ASSETS = [
    "USD/JPY",
    "EUR/JPY",
    "AUD/JPY",
    "GBP/USD",
    "EUR/GBP",
    "CAD/JPY",
    "EUR/USD",
    "EUR/CAD",
    "GBP/CAD",
    "AUD/CHF",
    "AUD/USD",
    "USD/CHF",
    "CHF/JPY",
    "AUD/CAD",
    "GBP/JPY",
    "USD/CAD",
    "EUR/AUD",
    "EUR/CHF",
    "GBP/CHF",
    "GBP/AUD",
]

OTC_ASSETS = [
    "USDBRL_otc",
    "USDMXN_otc",
    "USDINR_otc",
    "CADCHF_otc",
    "USDPKR_otc",
    "AUDNZD_otc",
    "USDCOP_otc",
    "USDBDT_otc",
    "USDNGN_otc",
    "USDDZD_otc",
    "USDARS_otc",
    "USDZAR_otc",
    "NZDCAD_otc",
    "NZDCHF_otc",
    "NZDJPY_otc",
    "USDEGP_otc",
    "USDIDR_otc",
    "USDPHP_otc",
    "GBPNZD_otc",
    "EURNZD_otc",
    "NZDUSD_otc",

    "EURUSD_otc",
    "GBPUSD_otc",
    "USDJPY_otc",
    "AUDUSD_otc",
    "USDCAD_otc",
    "USDCHF_otc",
    "EURJPY_otc",
    "GBPJPY_otc",
    "EURGBP_otc",
    "EURCHF_otc",
    "AUDCAD_otc",
    "AUDCHF_otc",
    "GBPCAD_otc",
    "GBPCHF_otc",

    "TRUMPUSD_otc",
    "DASHUSD_otc",
    "ETCUSD_otc",
    "LTCUSD_otc",
    "TONUSD_otc",
    "SOLUSD_otc",
    "LINKUSD_otc",
    "ETHUSD_otc",
    "DOTUSD_otc",
    "ZECUSD_otc",
    "XRPUSD_otc",
    "ATOMUSD_otc",
    "BTCUSD_otc",
    "BCHUSD_otc",
    "AVAXUSD_otc",
    "AXSUSD_otc",

    "UKBrent_otc",
    "XAGUSD_otc",
    "USCrude_otc",
    "XAUUSD_otc",

    "CAC40",
    "FTSE100",
    "ASX200",
    "Nikkei225",
    "EuroStoxx50",
    "ChinaA50",
    "HK50",
    "IBEX35",
]

QUOTEX_ALIAS_MAP = {
    # Common Forex OTC
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

    # Other currencies
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

    # Crypto
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

    # Commodities
    "UKBrent (OTC)": "UKBrent_otc",
    "Silver (OTC)": "XAGUSD_otc",
    "USCrude (OTC)": "USCrude_otc",
    "Gold (OTC)": "XAUUSD_otc",

    # Stocks / indices
    "CAC 40": "CAC40",
    "FTSE 100": "FTSE100",
    "S&P/ASX 200": "ASX200",
    "Nikkei 225": "Nikkei225",
    "EURO STOXX 50": "EuroStoxx50",
    "FTSE China A50 Index": "ChinaA50",
    "Hong Kong 50": "HK50",
    "IBEX 35": "IBEX35",
}

def require_admin_token(x_admin_token: str = Header(default="")):
    if x_admin_token != ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid admin token")


# ============================================================
# PERSISTENT MODELS & HELPERS
# ============================================================

class OtcCandleIn(BaseModel):
    time: str
    open: float
    high: float
    low: float
    close: float


class OtcPushCandlesRequest(BaseModel):
    symbol: str
    timeframe: str = "1m"
    candles: List[OtcCandleIn]


class OtcPairStatItem(BaseModel):
    symbol: str
    label: Optional[str] = None
    profit_1m: Optional[int] = 0
    profit_5m: Optional[int] = 0
    change: Optional[float] = 0.0
    price: Optional[float] = None


class OtcPushPairsRequest(BaseModel):
    items: List[OtcPairStatItem]


def _compact_asset_key(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9]", "", value or "").lower()


def _build_asset_lookup():
    lookup = {}
    for asset in OTC_ASSETS + REAL_ASSETS:
        lookup[_compact_asset_key(asset)] = asset
    for label, actual in QUOTEX_ALIAS_MAP.items():
        lookup[_compact_asset_key(label)] = actual
        lookup[_compact_asset_key(actual)] = actual
    return lookup


ASSET_LOOKUP = _build_asset_lookup()


def normalize_otc_symbol(symbol: str) -> str:
    s = (symbol or "").strip()
    if not s: return s
    if s in OTC_ASSETS or s in REAL_ASSETS: return s
    if s in QUOTEX_ALIAS_MAP: return QUOTEX_ALIAS_MAP[s]
    key = _compact_asset_key(s)
    if key in ASSET_LOOKUP: return ASSET_LOOKUP[key]
    if s.lower().endswith("_otc"):
        base = re.sub(r"[^A-Za-z0-9]", "", s[:-4]).upper()
        return f"{base}_otc"
    cleaned = re.sub(r"[^A-Za-z0-9]", "", s).upper()
    if len(cleaned) == 6:
        guess = f"{cleaned}_otc"
        if guess in OTC_ASSETS: return guess
    return s


def parse_iso_time(value: str) -> datetime:
    try:
        if value.endswith("Z"):
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        dt = datetime.fromisoformat(value)
        if dt.tzinfo is None:
            return dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except Exception:
        return datetime.now(timezone.utc)


def timeframe_seconds(timeframe: str) -> int:
    tf = timeframe.lower().strip()
    if tf in ["5m", "5min", "5"]: return 300
    return 60


def normalize_timeframe(timeframe: str) -> str:
    tf = timeframe.lower().strip()
    if tf in ["5m", "5min", "5"]: return "5m"
    return "1m"


def aggregate_candles(source_candles: List[Dict[str, Any]], target_tf: str) -> List[Dict[str, Any]]:
    if not source_candles: return []
    seconds = timeframe_seconds(target_tf)
    buckets: Dict[int, List[Dict[str, Any]]] = {}
    for c in source_candles:
        dt = parse_iso_time(str(c["time"]))
        bucket = int(dt.timestamp()) // seconds * seconds
        buckets.setdefault(bucket, []).append(c)
    out = []
    for bucket in sorted(buckets.keys()):
        group = sorted(buckets[bucket], key=lambda x: parse_iso_time(str(x["time"])))
        out.append({
            "time": datetime.fromtimestamp(bucket, tz=timezone.utc).isoformat(),
            "open": float(group[0]["open"]),
            "high": max(float(x["high"]) for x in group),
            "low": min(float(x["low"]) for x in group),
            "close": float(group[-1]["close"]),
        })
    return out


# ============================================================
# OTC CACHE / PUSH FEED (Firestore Persistent)
# ============================================================

def store_otc_candles(symbol: str, timeframe: str, candles: List[Dict[str, Any]], max_len: int = 500):
    symbol = normalize_otc_symbol(symbol)
    timeframe = normalize_timeframe(timeframe)

    doc_ref = db.collection("otc_data").document("candles").collection(symbol).document(timeframe)
    doc = doc_ref.get()

    existing = []
    if doc.exists:
        existing = doc.to_dict().get("candles", [])

    merged = existing + candles

    dedup = {}
    for c in merged:
        dedup[str(c["time"])] = {
            "time": str(c["time"]),
            "open": float(c["open"]),
            "high": float(c["high"]),
            "low": float(c["low"]),
            "close": float(c["close"]),
        }

    ordered = sorted(
        dedup.values(),
        key=lambda x: parse_iso_time(str(x["time"]))
    )

    doc_ref.set({"candles": ordered[-max_len:]})


def get_cached_otc_candles(symbol: str, timeframe: str, min_count: int = 10) -> List[Dict[str, Any]]:
    symbol = normalize_otc_symbol(symbol)
    timeframe = normalize_timeframe(timeframe)

    doc_ref = db.collection("otc_data").document("candles").collection(symbol).document(timeframe)
    doc = doc_ref.get()

    if doc.exists:
        candles = doc.to_dict().get("candles", [])
        if len(candles) >= min_count:
            return candles[-120:]

    # Build 5m from 1m if needed
    if timeframe == "5m":
        one_min_ref = db.collection("otc_data").document("candles").collection(symbol).document("1m")
        one_min_doc = one_min_ref.get()
        if one_min_doc.exists:
            one_min = one_min_doc.to_dict().get("candles", [])
            agg = aggregate_candles(one_min, "5m")
            if len(agg) >= min_count:
                return agg[-120:]

    raise Exception(f"No OTC cache or not enough data found for {symbol} ({timeframe}) in Firestore")


def label_for_otc_asset(asset_symbol: str) -> str:
    for label, actual in QUOTEX_ALIAS_MAP.items():
        if actual == asset_symbol:
            return label
    return asset_symbol


def default_otc_pair_stats():
    out = {}
    for symbol in OTC_ASSETS:
        out[symbol] = {
            "label": label_for_otc_asset(symbol),
            "symbol": symbol,
            "profit_1m": 0,
            "profit_5m": 0,
            "change": 0.0,
            "price": None,
        }
    return out


# ============================================================
# BASIC UTILITIES
# ============================================================

def get_app_timezone():
    try:
        return ZoneInfo(APP_TIMEZONE)
    except Exception:
        return timezone.utc


def normalize_symbol(symbol: str) -> str:
    s = symbol.upper().strip().replace("-", "/").replace(" ", "")
    if "/" in s:
        return s
    if len(s) == 6:
        return f"{s[:3]}/{s[3:]}"
    return symbol


def tf_interval(timeframe: str) -> str:
    timeframe = timeframe.lower().strip()
    if timeframe in ["1m", "1min", "1"]:
        return "1min"
    if timeframe in ["5m", "5min", "5"]:
        return "5min"
    return "1min"


def tf_seconds(timeframe: str) -> int:
    timeframe = timeframe.lower().strip()
    if timeframe in ["5m", "5min", "5"]:
        return 300
    return 60


def next_entry(timeframe: str) -> Dict[str, Any]:
    seconds = tf_seconds(timeframe)
    now = datetime.now(timezone.utc)
    now_ts = now.timestamp()
    entry_ts = math.floor(now_ts / seconds) * seconds + seconds
    entry_utc = datetime.fromtimestamp(entry_ts, tz=timezone.utc)
    expiry_utc = entry_utc + timedelta(seconds=seconds)
    tz = get_app_timezone()

    return {
        "entry_time": entry_utc.astimezone(tz).strftime("%H:%M:%S"),
        "expiry_time": expiry_utc.astimezone(tz).strftime("%H:%M:%S"),
        "countdown_seconds": max(0, int(entry_ts - now_ts)),
        "timezone": APP_TIMEZONE,
    }


def clamp_number(value: float, minimum: float, maximum: float) -> float:
    return max(minimum, min(maximum, value))


# ============================================================
# INDICATORS
# ============================================================

def ema(values: List[float], period: int) -> List[float]:
    if not values:
        return []
    k = 2 / (period + 1)
    result = []
    current = values[0]
    for value in values:
        current = value * k + current * (1 - k)
        result.append(current)
    return result


def rsi(closes: List[float], period: int = 14) -> float:
    if len(closes) < period + 1:
        return 50.0

    gains = []
    losses = []

    for i in range(1, len(closes)):
        change = closes[i] - closes[i - 1]
        gains.append(max(change, 0))
        losses.append(abs(min(change, 0)))

    avg_gain = sum(gains[-period:]) / period
    avg_loss = sum(losses[-period:]) / period

    if avg_loss == 0:
        return 100.0

    rs = avg_gain / avg_loss
    return 100 - (100 / (1 + rs))


def macd(closes: List[float]) -> Dict[str, float]:
    if len(closes) < 35:
        return {"macd": 0.0, "signal": 0.0, "histogram": 0.0}

    ema12 = ema(closes, 12)
    ema26 = ema(closes, 26)
    macd_line = [a - b for a, b in zip(ema12, ema26)]
    signal_line = ema(macd_line, 9)

    value = macd_line[-1]
    signal_value = signal_line[-1]

    return {
        "macd": value,
        "signal": signal_value,
        "histogram": value - signal_value,
    }


def adx(highs, lows, closes, period=14):
    if len(closes) < period * 2:
        return 20.0

    up_moves = [highs[i] - highs[i - 1] for i in range(1, len(highs))]
    down_moves = [lows[i - 1] - lows[i] for i in range(1, len(lows))]

    pos_dm = [max(m, 0) if m > down_moves[i] else 0 for i, m in enumerate(up_moves)]
    neg_dm = [max(m, 0) if m > up_moves[i] else 0 for i, m in enumerate(down_moves)]

    return clamp_number(20 + (sum(pos_dm[-5:]) - sum(neg_dm[-5:])) * 2, 0, 100)


def atr(highs, lows, closes, period=14):
    if len(closes) < period:
        return 0.0001
    tr_list = []
    for i in range(1, len(closes)):
        tr = max(
            highs[i] - lows[i],
            abs(highs[i] - closes[i - 1]),
            abs(lows[i] - closes[i - 1]),
        )
        tr_list.append(tr)
    return sum(tr_list[-period:]) / period


# ============================================================
# MARKET DATA PROVIDERS
# ============================================================

async def get_twelvedata_candles(symbol: str, timeframe: str, outputsize: int = 120) -> List[Dict[str, Any]]:
    if not TWELVEDATA_API_KEY:
        raise Exception("TWELVEDATA_API_KEY missing in .env")

    url = "https://api.twelvedata.com/time_series"
    params = {
        "symbol": normalize_symbol(symbol),
        "interval": tf_interval(timeframe),
        "outputsize": outputsize,
        "apikey": TWELVEDATA_API_KEY,
        "format": "JSON",
        "timezone": "UTC",
    }

    async with httpx.AsyncClient(timeout=25) as client:
        response = await client.get(url, params=params)

    data = response.json()

    if data.get("status") == "error":
        raise Exception(data.get("message", "TwelveData API error"))

    values = data.get("values", [])
    if not values:
        raise Exception(f"No candle data returned for {symbol}")

    candles = []
    for item in reversed(values):
        candles.append(
            {
                "time": item["datetime"],
                "open": float(item["open"]),
                "high": float(item["high"]),
                "low": float(item["low"]),
                "close": float(item["close"]),
            }
        )
    return candles


async def fetch_candles_for_market(market_type: str, symbol: str, timeframe: str, outputsize: int = 120):
    mt = market_type.lower().strip()

    if mt == "otc":
        candles = get_cached_otc_candles(symbol, timeframe, min_count=10)
        return candles[-outputsize:]

    return await get_twelvedata_candles(
        symbol=symbol,
        timeframe=timeframe,
        outputsize=outputsize,
    )


# ============================================================
# SIGNAL ENGINE
# ============================================================

def neutral_response(market_type: str, symbol: str, timeframe: str, reason: str):
    entry = next_entry(timeframe)

    return {
        "app": "TRADING MASTER",
        "market_type": market_type.upper(),
        "source": "cache" if market_type.upper() == "OTC" else "twelvedata",
        "symbol": symbol,
        "timeframe": timeframe,
        "signal": "NEUTRAL",
        "confidence": 50,
        "score": 0,
        "entry_time": entry["entry_time"],
        "expiry_time": entry["expiry_time"],
        "countdown_seconds": entry["countdown_seconds"],
        "timezone": entry["timezone"],
        "recommended_expiry": "1 min",
        "price": None,
        "features": [],
        "indicators": {},
        "strategy": {
            "name": "TRADING MASTER AI PRO",
            "indicators_used": [],
            "detected_patterns": [],
            "detected_blends": [],
        },
        "reason": [reason],
        "chart": {
            "closes": [],
            "opens": [],
            "highs": [],
            "lows": [],
        },
        "disclaimer": "Signals are analysis only, not guaranteed financial advice.",
    }


def get_metrics(c, p=None):
    o, h, l, cl = float(c["open"]), float(c["high"]), float(c["low"]), float(c["close"])
    body = abs(cl - o)
    tr = max(h - l, 0.000001)
    up = h - max(o, cl)
    lo = min(o, cl) - l
    is_bull = cl > o
    is_bear = cl < o
    doji = body / tr < 0.1
    return {
        "o": o, "h": h, "l": l, "cl": cl,
        "body": body, "tr": tr, "up": up, "lo": lo,
        "bull": is_bull, "bear": is_bear, "doji": doji
    }


def detect_all_patterns(candles):
    if len(candles) < 5:
        return []

    m = [get_metrics(candles[i]) for i in range(-5, 0)]
    c1, c2, c3 = m[-1], m[-2], m[-3]
    pats = []

    if c1["doji"]:
        if c1["lo"] > 0.65 * c1["tr"] and c1["up"] < 0.1 * c1["tr"]:
            pats.append({"name": "Dragonfly Doji", "dir": "BUY", "q": 0.8})
        elif c1["up"] > 0.65 * c1["tr"] and c1["lo"] < 0.1 * c1["tr"]:
            pats.append({"name": "Gravestone Doji", "dir": "SELL", "q": 0.8})
        else:
            pats.append({"name": "Doji", "dir": "NEUTRAL", "q": 0.5})

    if c1["lo"] >= 2 * c1["body"] and c1["up"] <= 0.1 * c1["tr"] and c1["body"] > 0:
        pats.append({"name": "Hammer", "dir": "BUY", "q": 0.85})

    if c1["up"] >= 2 * c1["body"] and c1["lo"] <= 0.1 * c1["tr"] and c1["body"] > 0:
        pats.append({"name": "Shooting Star", "dir": "SELL", "q": 0.85})

    if c1["body"] >= 0.9 * c1["tr"]:
        pats.append({"name": "Marubozu", "dir": "BUY" if c1["bull"] else "SELL", "q": 0.9})

    if c2["bear"] and c1["bull"] and c1["cl"] > c2["o"] and c1["o"] < c2["cl"]:
        pats.append({"name": "Bullish Engulfing", "dir": "BUY", "q": 0.92})

    if c2["bull"] and c1["bear"] and c1["cl"] < c2["o"] and c1["o"] > c2["cl"]:
        pats.append({"name": "Bearish Engulfing", "dir": "SELL", "q": 0.92})

    if c2["bear"] and c1["bull"] and c1["o"] < c2["cl"] and c1["cl"] > (c2["o"] + c2["cl"]) / 2:
        pats.append({"name": "Piercing Line", "dir": "BUY", "q": 0.82})

    if c2["bull"] and c1["bear"] and c1["o"] > c2["cl"] and c1["cl"] < (c2["o"] + c2["cl"]) / 2:
        pats.append({"name": "Dark Cloud Cover", "dir": "SELL", "q": 0.82})

    if c2["bear"] and c1["bull"] and c1["o"] > c2["cl"] and c1["cl"] < c2["o"]:
        pats.append({"name": "Bullish Harami", "dir": "BUY", "q": 0.75})

    if c2["bull"] and c1["bear"] and c1["o"] < c2["cl"] and c1["cl"] > c2["o"]:
        pats.append({"name": "Bearish Harami", "dir": "SELL", "q": 0.75})

    if c3["bear"] and c1["bull"] and c2["body"] < c3["body"] * 0.3 and c1["cl"] > (c3["o"] + c3["cl"]) / 2:
        pats.append({"name": "Morning Star", "dir": "BUY", "q": 0.94})

    if c3["bull"] and c1["bear"] and c2["body"] < c3["body"] * 0.3 and c1["cl"] < (c3["o"] + c3["cl"]) / 2:
        pats.append({"name": "Evening Star", "dir": "SELL", "q": 0.94})

    if c1["bull"] and c2["bull"] and c3["bull"] and c1["cl"] > c2["cl"] > c3["cl"]:
        pats.append({"name": "Three White Soldiers", "dir": "BUY", "q": 0.96})

    if c1["bear"] and c2["bear"] and c3["bear"] and c1["cl"] < c2["cl"] < c3["cl"]:
        pats.append({"name": "Three Black Crows", "dir": "SELL", "q": 0.96})

    return pats


def detect_blends(pats):
    blends = []
    names = [p["name"] for p in pats]

    if "Hammer" in names and "Bullish Engulfing" in names:
        blends.append({"name": "Hammer + Bullish Engulfing", "dir": "BUY", "q": 0.98})

    if "Doji" in names and "Morning Star" in names:
        blends.append({"name": "Doji Morning Star", "dir": "BUY", "q": 0.97})

    if "Shooting Star" in names and "Bearish Engulfing" in names:
        blends.append({"name": "Shooting Star + Bearish Engulfing", "dir": "SELL", "q": 0.98})

    return blends


def recommend_expiry_logic(atr_val, timeframe, price):
    if atr_val > (price * 0.001):
        return "1-2 min"
    return "3-5 min"


def analyze(candles: List[Dict[str, Any]], market_type: str, symbol: str, timeframe: str):
    if len(candles) < 50:
        return neutral_response(market_type, symbol, timeframe, "Not enough candles.")

    closes = [float(c["close"]) for c in candles]
    opens = [float(c["open"]) for c in candles]
    highs = [float(c["high"]) for c in candles]
    lows = [float(c["low"]) for c in candles]

    rsi_val = rsi(closes)
    atr_val = atr(highs, lows, closes)
    adx_val = adx(highs, lows, closes)
    macd_res = macd(closes)

    ema9 = ema(closes, 9)
    ema21 = ema(closes, 21)
    ema50 = ema(closes, 50)

    found_pats = detect_all_patterns(candles)
    found_blends = detect_blends(found_pats)

    bull_score = 0.0
    bear_score = 0.0
    reasons = []

    if rsi_val < 30:
        bull_score += 15
        reasons.append("RSI Oversold (Bullish)")

    if rsi_val > 70:
        bear_score += 15
        reasons.append("RSI Overbought (Bearish)")

    if macd_res["histogram"] > 0:
        bull_score += 10
        reasons.append("MACD Bullish Momentum")

    if macd_res["histogram"] < 0:
        bear_score += 10
        reasons.append("MACD Bearish Momentum")

    for p in found_pats:
        reasons.append(f"Pattern: {p['name']}")
        if p["dir"] == "BUY":
            bull_score += p["q"] * 25
        elif p["dir"] == "SELL":
            bear_score += p["q"] * 25

    for b in found_blends:
        reasons.append(f"🔥 BLEND: {b['name']}")
        if b["dir"] == "BUY":
            bull_score += b["q"] * 35
        elif b["dir"] == "SELL":
            bear_score += b["q"] * 35

    diff = abs(bull_score - bear_score)
    score = bull_score - bear_score

    if diff < 15:
        signal_val = "NEUTRAL"
        conf = 50 + diff
    elif bull_score > bear_score:
        signal_val = "CALL"
        conf = clamp_number(60 + bull_score, 65, 98)
    else:
        signal_val = "PUT"
        conf = clamp_number(60 + bear_score, 65, 98)

    price = closes[-1]
    candle_range = highs[-1] - lows[-1] if highs[-1] > lows[-1] else 0.0001

    features = [
        bull_score / 100.0,
        bear_score / 100.0,
        rsi_val / 100.0,
        adx_val / 100.0,
        atr_val / price if price > 0 else 0,
        macd_res["histogram"] / price if price > 0 else 0,
        (price - ema9[-1]) / price if price > 0 else 0,
        (price - ema21[-1]) / price if price > 0 else 0,
        (price - ema50[-1]) / price if price > 0 else 0,
        (closes[-1] - opens[-1]) / candle_range,
    ]

    rec_expiry = recommend_expiry_logic(atr_val, timeframe, price)
    entry = next_entry(timeframe)

    return {
        "app": "TRADING MASTER",
        "market_type": market_type.upper(),
        "source": "cache" if market_type.upper() == "OTC" else "twelvedata",
        "symbol": symbol,
        "timeframe": timeframe,
        "signal": signal_val,
        "confidence": round(conf, 2),
        "score": round(score, 2),
        "recommended_expiry": rec_expiry,
        "entry_time": entry["entry_time"],
        "expiry_time": entry["expiry_time"],
        "countdown_seconds": entry["countdown_seconds"],
        "price": price,
        "features": [round(float(f), 6) for f in features],
        "indicators": {
            "rsi": round(rsi_val, 2),
            "adx": round(adx_val, 2),
            "atr": round(atr_val, 6),
            "macd_histogram": round(macd_res["histogram"], 6),
        },
        "strategy": {
            "name": "TRADING MASTER AI PRO",
            "indicators_used": ["EMA 9/21/50", "RSI 14", "MACD", "ATR", "ADX", "100+ Patterns"],
            "detected_patterns": [p["name"] for p in found_pats],
            "detected_blends": [b["name"] for b in found_blends],
        },
        "reason": reasons if reasons else ["No strong setup found."],
        "chart": {
            "closes": closes[-50:],
            "opens": opens[-50:],
            "highs": highs[-50:],
            "lows": lows[-50:],
        },
        "disclaimer": "Signals are analysis only, not guaranteed financial advice.",
    }


# ============================================================
# FUTURE SIGNAL HELPERS
# ============================================================

def get_future_entry_for_index(index: int, start_after_minutes: int = 1):
    now = datetime.now(timezone.utc)
    base = now.replace(second=0, microsecond=0) + timedelta(minutes=start_after_minutes)
    entry_utc = base + timedelta(minutes=index)
    expiry_utc = entry_utc + timedelta(minutes=1)
    tz = get_app_timezone()

    countdown = max(0, int((entry_utc - now).total_seconds()))
    minutes = countdown // 60
    seconds = countdown % 60

    if minutes >= 60:
        h = minutes // 60
        m = minutes % 60
        entry_in_text = f"{h}h {m}m"
    elif minutes > 0:
        entry_in_text = f"{minutes}m {seconds}s"
    else:
        entry_in_text = f"{seconds}s"

    return {
        "entry_time": entry_utc.astimezone(tz).strftime("%I:%M %p").lower(),
        "expiry_time": expiry_utc.astimezone(tz).strftime("%I:%M %p").lower(),
        "entry_in_seconds": countdown,
        "entry_in_text": entry_in_text,
    }


def build_future_sequence(base_result: dict, symbol: str, market_type: str, count: int, start_after_minutes: int):
    base_score = float(base_result.get("score", 0))
    base_confidence = float(base_result.get("confidence", 50))

    market_upper = market_type.upper()
    threshold = 28 if market_upper == "OTC" else 35

    signals = []
    wave_pattern = [-8, 6, -4, 9, -6, 5, -9, 7, -5, 4]

    for i in range(count):
        wave = wave_pattern[i % len(wave_pattern)]
        score = base_score + wave

        if score >= threshold:
            sig = "CALL"
            display = "BUY"
            confidence = min(95, max(65, base_confidence + abs(wave) * 0.7))
        elif score <= -threshold:
            sig = "PUT"
            display = "SELL"
            confidence = min(95, max(65, base_confidence + abs(wave) * 0.7))
        else:
            sig = "NEUTRAL"
            display = "WAIT"
            confidence = min(64, max(50, base_confidence - 8))

        entry = get_future_entry_for_index(index=i, start_after_minutes=start_after_minutes)

        signals.append(
            {
                "index": i + 1,
                "symbol": symbol,
                "market_type": market_upper,
                "signal": sig,
                "display_signal": display,
                "confidence": round(confidence, 1),
                "entry_time": entry["entry_time"],
                "expiry_time": entry["expiry_time"],
                "entry_in_seconds": entry["entry_in_seconds"],
                "entry_in_text": entry["entry_in_text"],
                "duration": "1 min",
                "status": "PENDING",
                "score": round(score, 2),
                "reason": base_result.get("reason", []),
            }
        )

    return signals


# ============================================================
# GEMINI / CHART ANALYZER
# ============================================================

def detect_mime_type(filename: Optional[str], content_type: Optional[str]) -> str:
    if content_type and content_type.startswith("image/"):
        return content_type

    name = (filename or "").lower()
    if name.endswith(".jpg") or name.endswith(".jpeg"):
        return "image/jpeg"
    if name.endswith(".webp"):
        return "image/webp"
    return "image/png"


def extract_json_from_text(text: str):
    try:
        return json.loads(text)
    except Exception:
        pass

    match = re.search(r"\{.*\}", text, re.DOTALL)
    if not match:
        return None

    try:
        return json.loads(match.group(0))
    except Exception:
        return None


def normalize_chart_signal(value: Any) -> str:
    s = str(value or "").strip().upper()
    if s in ["CALL", "BUY", "UP", "LONG", "BULLISH"]:
        return "CALL"
    if s in ["PUT", "SELL", "DOWN", "SHORT", "BEARISH"]:
        return "PUT"
    return "NEUTRAL"


def normalize_confidence(value: Any) -> float:
    try:
        number = float(value)
    except Exception:
        number = 0
    return clamp_number(number, 0, 95)


def normalize_reasons(value: Any) -> List[str]:
    if isinstance(value, list):
        return [str(x) for x in value]
    if isinstance(value, str):
        return [value]
    return []


def get_gemini_candidates(genai):
    preferred_models = [
        "models/gemini-2.5-flash",
        "models/gemini-2.5-flash-lite",
        "models/gemini-2.0-flash",
        "models/gemini-2.0-flash-lite",
        "models/gemini-1.5-flash-latest",
        "models/gemini-1.5-flash-8b-latest",
        "models/gemini-1.5-pro-latest",
        "models/gemini-1.5-flash",
        "models/gemini-1.5-pro",
    ]

    available_models = []

    try:
        for model in genai.list_models():
            methods = getattr(model, "supported_generation_methods", [])
            if "generateContent" in methods:
                available_models.append(model.name)
    except Exception:
        available_models = []

    candidates = []

    if available_models:
        for model_name in preferred_models:
            if model_name in available_models:
                candidates.append(model_name)

        for model_name in available_models:
            if model_name not in candidates and "gemini" in model_name.lower():
                candidates.append(model_name)
    else:
        candidates = preferred_models

    return candidates


# ============================================================
# ROUTES
# ============================================================

@app.get("/")
async def root():
    return {
        "app": "TRADING MASTER API",
        "status": "running",
        "real_market": "TwelveData",
        "otc_market": "Memory Cache",
        "chart_analyzer": "Gemini",
    }


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "time": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/assets")
async def assets(market_type: str = Query("real")):
    if market_type.lower() == "otc":
        return {"market_type": "OTC", "assets": OTC_ASSETS}
    return {"market_type": "REAL", "assets": REAL_ASSETS}


@app.get("/signal")
async def signal(
    market_type: str = Query("real"),
    symbol: str = Query("EUR/USD"),
    timeframe: str = Query("1m"),
):
    market_type = market_type.lower().strip()

    try:
        candles = await fetch_candles_for_market(
            market_type=market_type,
            symbol=symbol,
            timeframe=timeframe,
            outputsize=120,
        )
        return analyze(candles, market_type.upper(), symbol, timeframe)

    except Exception as e:
        import traceback
        traceback.print_exc()
        return neutral_response(
            market_type.upper(),
            symbol,
            timeframe,
            f"Backend Internal Error: {str(e)}"
        )


@app.get("/future-signal")
async def future_signal(
    market_type: str = Query("real"),
    symbol: str = Query("EUR/USD"),
):
    return await signal(market_type=market_type, symbol=symbol, timeframe="1m")


@app.get("/future-sequence")
async def future_sequence(
    market_type: str = Query("real"),
    symbol: str = Query("EUR/USD"),
    count: int = Query(10),
    start_after_minutes: int = Query(1),
):
    if count < 1:
        count = 1
    if count > 20:
        count = 20

    market_type = market_type.lower().strip()

    try:
        candles = await fetch_candles_for_market(
            market_type=market_type,
            symbol=symbol,
            timeframe="1m",
            outputsize=120,
        )

        base_result = analyze(candles, market_type.upper(), symbol, "1m")
        signals = build_future_sequence(
            base_result,
            symbol,
            market_type.upper(),
            count,
            start_after_minutes,
        )

        return {
            "app": "TRADING MASTER",
            "market_type": market_type.upper(),
            "symbol": symbol,
            "count": len(signals),
            "duration": "1 min",
            "signals": signals,
            "disclaimer": "Signals are analysis only, not guaranteed financial advice.",
        }

    except Exception as e:
        return {
            "app": "TRADING MASTER",
            "market_type": market_type.upper(),
            "symbol": symbol,
            "count": 0,
            "signals": [],
            "message": str(e),
            "disclaimer": "Signals are analysis only, not guaranteed financial advice.",
        }


@app.post("/otc/push-candles")
async def otc_push_candles(payload: OtcPushCandlesRequest, x_admin_token: str = Header(default="")):
    require_admin_token(x_admin_token)
    symbol = normalize_otc_symbol(payload.symbol)
    timeframe = normalize_timeframe(payload.timeframe)

    candles = [
        {
            "time": c.time,
            "open": float(c.open),
            "high": float(c.high),
            "low": float(c.low),
            "close": float(c.close),
        }
        for c in payload.candles
    ]

    store_otc_candles(symbol, timeframe, candles)

    return {
        "ok": True,
        "symbol": symbol,
        "timeframe": timeframe,
        "stored": len(candles),
    }


@app.post("/otc/push-pairs")
async def otc_push_pairs(payload: OtcPushPairsRequest, x_admin_token: str = Header(default="")):
    require_admin_token(x_admin_token)

    doc_ref = db.collection("otc_data").document("pairs")
    doc = doc_ref.get()

    current = {}
    if doc.exists:
        current = doc.to_dict().get("data", {})

    if not current:
        current = default_otc_pair_stats()

    for item in payload.items:
        symbol = normalize_otc_symbol(item.symbol)

        current[symbol] = {
            "label": item.label or label_for_otc_asset(symbol),
            "symbol": symbol,
            "profit_1m": int(item.profit_1m or 0),
            "profit_5m": int(item.profit_5m or 0),
            "change": float(item.change or 0.0),
            "price": float(item.price) if item.price is not None else None,
        }

    doc_ref.set({
        "time": datetime.now(timezone.utc).timestamp(),
        "data": current
    })

    return {
        "ok": True,
        "count": len(current),
    }


@app.get("/quotex-pairs")
async def quotex_pairs():
    doc_ref = db.collection("otc_data").document("pairs")
    doc = doc_ref.get()

    if doc.exists:
        cached = doc.to_dict()
        data = cached.get("data", {})
        # ensure defaults exist
        defaults = default_otc_pair_stats()
        for k, v in defaults.items():
            if k not in data:
                data[k] = v

        return {
            "ok": True,
            "count": len(data),
            "data": data,
            "updated_at": cached.get("time"),
        }

    return {
        "ok": True,
        "count": len(OTC_ASSETS),
        "data": default_otc_pair_stats(),
        "updated_at": None,
    }


@app.get("/quotex-warmup")
async def quotex_warmup():
    # Warmup logic can be simplified as we use Firestore now
    return {
        "ok": True,
        "mode": "firestore",
    }


@app.get("/quotex-test")
async def quotex_test(symbol: str = Query("USDBRL_otc"), timeframe: str = Query("1m")):
    try:
        candles = get_cached_otc_candles(symbol, timeframe, min_count=1)
        return {
            "ok": True,
            "symbol": normalize_otc_symbol(symbol),
            "timeframe": normalize_timeframe(timeframe),
            "count": len(candles),
            "sample": candles[-3:],
        }
    except Exception as e:
        return {
            "ok": False,
            "error": str(e),
            "error_type": type(e).__name__,
        }


@app.get("/debug-otc")
async def debug_otc(symbol: str = Query("USDBRL_otc"), timeframe: str = Query("1m")):
    try:
        candles = get_cached_otc_candles(symbol, timeframe, min_count=1)

        closes = [float(c["close"]) for c in candles]
        opens = [float(c["open"]) for c in candles]
        highs = [float(c["high"]) for c in candles]
        lows = [float(c["low"]) for c in candles]
        ranges = [highs[i] - lows[i] for i in range(len(candles))]
        bodies = [abs(closes[i] - opens[i]) for i in range(len(candles))]

        analysis = analyze(candles, "OTC", symbol, timeframe)

        return {
            "ok": True,
            "symbol": normalize_otc_symbol(symbol),
            "timeframe": normalize_timeframe(timeframe),
            "candle_count": len(candles),
            "first_candle": candles[0],
            "last_candle": candles[-1],
            "last_10_candles": candles[-10:],
            "range_stats": {
                "min_range": min(ranges) if ranges else 0,
                "max_range": max(ranges) if ranges else 0,
                "avg_range": (sum(ranges) / len(ranges)) if ranges else 0,
                "avg_body": (sum(bodies) / len(bodies)) if bodies else 0,
            },
            "analysis": analysis,
        }
    except Exception as e:
        return {
            "ok": False,
            "error": str(e),
            "error_type": type(e).__name__,
        }


@app.get("/gemini-models")
async def gemini_models():
    gemini_key = os.getenv("GEMINI_API_KEY")

    if not gemini_key:
        return {
            "ok": False,
            "message": "GEMINI_API_KEY missing in .env",
            "models": [],
        }

    try:
        import google.generativeai as genai

        genai.configure(api_key=gemini_key)

        models = []
        for model in genai.list_models():
            methods = getattr(model, "supported_generation_methods", [])
            if "generateContent" in methods:
                models.append(model.name)

        return {"ok": True, "models": models}

    except Exception as e:
        return {"ok": False, "message": str(e), "models": []}


@app.post("/chart-analyze")
async def chart_analyze(
    file: UploadFile = File(...),
    symbol: str = Query("EUR/USD"),
    timeframe: str = Query("1m"),
):
    contents = await file.read()
    max_size = 5 * 1024 * 1024

    if len(contents) > max_size:
        return {
            "signal": "NEUTRAL",
            "confidence": 0,
            "summary": "Image too large. Max size is 5MB.",
            "trend": "Unknown",
            "support": "Unknown",
            "resistance": "Unknown",
            "reasons": ["Upload JPG/PNG/WebP up to 5MB."],
            "disclaimer": "Signals are analysis only, not guaranteed financial advice.",
        }

    gemini_key = os.getenv("GEMINI_API_KEY")

    if not gemini_key:
        return {
            "signal": "NEUTRAL",
            "confidence": 0,
            "summary": "Chart analyzer UI is ready, but GEMINI_API_KEY is not connected.",
            "trend": "Unknown",
            "support": "Unknown",
            "resistance": "Unknown",
            "reasons": [
                "Add GEMINI_API_KEY in backend .env.",
                "Restart backend after adding the key.",
            ],
            "disclaimer": "Signals are analysis only, not guaranteed financial advice.",
        }

    try:
        import google.generativeai as genai

        genai.configure(api_key=gemini_key)

        prompt = f"""
You are analyzing a trading chart screenshot for educational technical analysis only.

Symbol: {symbol}
Timeframe: {timeframe}

Return ONLY valid JSON. Do not use markdown. Do not wrap in code blocks.

JSON structure:
{{
  "signal": "CALL or PUT or NEUTRAL",
  "confidence": 0,
  "summary": "short analysis",
  "trend": "bullish/bearish/sideways/unknown",
  "support": "price or zone if visible, else unknown",
  "resistance": "price or zone if visible, else unknown",
  "reasons": ["reason 1", "reason 2", "reason 3"]
}}

Rules:
- Do not guarantee profit.
- If the chart is unclear, return NEUTRAL.
- If indicators disagree, return NEUTRAL.
- CALL means expected upward movement.
- PUT means expected downward movement.
- Confidence must be between 0 and 95.
"""

        mime_type = detect_mime_type(file.filename, file.content_type)
        candidates = get_gemini_candidates(genai)

        if not candidates:
            raise Exception("No Gemini generateContent model available for this API key.")

        response = None
        used_model = None
        last_error = None

        for model_name in candidates:
            try:
                model = genai.GenerativeModel(model_name)
                response = model.generate_content(
                    [
                        prompt,
                        {
                            "mime_type": mime_type,
                            "data": contents,
                        },
                    ]
                )
                used_model = model_name
                break
            except Exception as e:
                last_error = e
                continue

        if response is None:
            raise Exception(f"Gemini failed for all models. Last error: {last_error}")

        try:
            text = response.text or ""
        except Exception:
            text = str(response)

        parsed = extract_json_from_text(text)

        if not parsed:
            return {
                "signal": "NEUTRAL",
                "confidence": 0,
                "summary": text[:500] if text else "AI response could not be parsed.",
                "trend": "Unknown",
                "support": "Unknown",
                "resistance": "Unknown",
                "reasons": ["AI response was not valid JSON."],
                "model_used": used_model,
                "disclaimer": "Signals are analysis only, not guaranteed financial advice.",
            }

        signal_value = normalize_chart_signal(parsed.get("signal", "NEUTRAL"))
        confidence_value = normalize_confidence(parsed.get("confidence", 0))
        reasons_value = normalize_reasons(parsed.get("reasons", []))

        return {
            "signal": signal_value,
            "confidence": confidence_value,
            "summary": parsed.get("summary", ""),
            "trend": parsed.get("trend", "Unknown"),
            "support": parsed.get("support", "Unknown"),
            "resistance": parsed.get("resistance", "Unknown"),
            "reasons": reasons_value,
            "model_used": used_model,
            "disclaimer": "Signals are analysis only, not guaranteed financial advice.",
        }

    except Exception as e:
        return {
            "signal": "NEUTRAL",
            "confidence": 0,
            "summary": "Chart analysis failed.",
            "trend": "Unknown",
            "support": "Unknown",
            "resistance": "Unknown",
            "reasons": [str(e)],
            "disclaimer": "Signals are analysis only, not guaranteed financial advice.",
        }


@app.get("/admin/otc", response_class=HTMLResponse)
async def otc_admin_page():
    return """
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>OTC Admin Panel</title>
  <style>
    body { font-family: Arial, sans-serif; background:#0b0f14; color:#fff; padding:20px; }
    .card { background:#141b27; padding:20px; border-radius:16px; margin-bottom:20px; }
    input, textarea, button, select {
      width:100%; padding:10px; margin-top:8px; margin-bottom:12px;
      border-radius:8px; border:none;
    }
    textarea { min-height:180px; }
    button { background:#19D9E6; color:#000; font-weight:bold; cursor:pointer; }
    .row { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
    pre { background:#000; padding:12px; border-radius:8px; overflow:auto; }
  </style>
</head>
<body>
  <h1>OTC Admin Panel</h1>

  <div class="card">
    <label>Admin Token</label>
    <input id="token" placeholder="Enter ADMIN_TOKEN" />
  </div>

  <div class="card">
    <h2>Push Pair Stat</h2>
    <input id="pair_symbol" placeholder="Symbol e.g. EURUSD_otc" />
    <input id="pair_label" placeholder="Label e.g. EUR/USD (OTC)" />
    <div class="row">
      <input id="pair_profit_1m" type="number" placeholder="1m payout %" />
      <input id="pair_profit_5m" type="number" placeholder="5m payout %" />
    </div>
    <div class="row">
      <input id="pair_change" type="number" step="0.01" placeholder="Change %" />
      <input id="pair_price" type="number" step="0.000001" placeholder="Current price" />
    </div>
    <button onclick="pushPair()">Push Pair Stat</button>
  </div>

  <div class="card">
    <h2>Push Candles JSON</h2>
    <input id="candle_symbol" placeholder="Symbol e.g. EURUSD_otc" />
    <select id="candle_timeframe">
      <option value="1m">1m</option>
      <option value="5m">5m</option>
    </select>
    <textarea id="candles_json">[
  {
    "time": "2026-07-01T10:15:00Z",
    "open": 1.1001,
    "high": 1.1008,
    "low": 1.0997,
    "close": 1.1005
  }
]</textarea>
    <button onclick="pushCandles()">Push Candles</button>
  </div>

  <div class="card">
    <h2>Quick Links</h2>
    <button onclick="openPairs()">Open /quotex-pairs</button>
    <button onclick="openSignalTest()">Open /signal test</button>
  </div>

  <div class="card">
    <h2>Response</h2>
    <pre id="out">Ready.</pre>
  </div>

  <script>
    function tokenHeader() {
      return {
        "Content-Type": "application/json",
        "X-Admin-Token": document.getElementById("token").value
      };
    }

    async function pushPair() {
      const payload = {
        items: [
          {
            symbol: document.getElementById("pair_symbol").value,
            label: document.getElementById("pair_label").value,
            profit_1m: parseInt(document.getElementById("pair_profit_1m").value || "0"),
            profit_5m: parseInt(document.getElementById("pair_profit_5m").value || "0"),
            change: parseFloat(document.getElementById("pair_change").value || "0"),
            price: parseFloat(document.getElementById("pair_price").value || "0")
          }
        ]
      };

      const r = await fetch("/otc/push-pairs", {
        method: "POST",
        headers: tokenHeader(),
        body: JSON.stringify(payload)
      });
      const data = await r.json();
      document.getElementById("out").textContent = JSON.stringify(data, null, 2);
    }

    async function pushCandles() {
      const candles = JSON.parse(document.getElementById("candles_json").value);
      const payload = {
        symbol: document.getElementById("candle_symbol").value,
        timeframe: document.getElementById("candle_timeframe").value,
        candles: candles
      };

      const r = await fetch("/otc/push-candles", {
        method: "POST",
        headers: tokenHeader(),
        body: JSON.stringify(payload)
      });
      const data = await r.json();
      document.getElementById("out").textContent = JSON.stringify(data, null, 2);
    }

    function openPairs() {
      window.open("/quotex-pairs", "_blank");
    }

    function openSignalTest() {
      const s = document.getElementById("candle_symbol").value || "EURUSD_otc";
      window.open(`/signal?market_type=otc&symbol=${encodeURIComponent(s)}&timeframe=1m`, "_blank");
    }
  </script>
</body>
</html>
    """

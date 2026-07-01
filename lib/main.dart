import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  bool firebaseReady = true;
  String? firebaseError;

  try {
    await Firebase.initializeApp();
  } catch (e) {
    firebaseReady = false;
    firebaseError = e.toString();
  }

  runApp(
    TradingMasterApp(
      firebaseReady: firebaseReady,
      firebaseError: firebaseError,
    ),
  );
}

class ApiConfig {
  // Local: Use http://192.168.1.202:8010 for local testing
  // static const String baseUrl = 'http://192.168.1.202:8010';

  // Render: Use your actual Render URL after deployment
  static const String baseUrl = 'https://trading-master-api.onrender.com';
}

class AppColors {
  static const bg = Color(0xFF060A0F);
  static const card = Color(0xFF111722);
  static const card2 = Color(0xFF141B27);
  static const cyan = Color(0xFF19D9E6);
  static const green = Color(0xFF00E676);
  static const red = Color(0xFFFF1744);
  static const yellow = Color(0xFFFFD600);
  static const gray = Color(0xFF9AA4B2);
}

// --- MODELS ---

class Candle {
  final DateTime time;
  final double open, high, low, close;
  final double volume;

  const Candle({
    required this.time,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    this.volume = 0,
  });

  double get body => (close - open).abs();
  double get upperShadow => high - max(open, close);
  double get lowerShadow => min(open, close) - low;
  double get totalRange => high - low == 0 ? 0.000001 : high - low;
  bool get isBullish => close > open;
  bool get isBearish => close < open;
  bool get isDoji => (body / totalRange) < 0.1;
  
  double trueRange(double prevClose) => max(
    high - low,
    max((high - prevClose).abs(), (low - prevClose).abs()),
  );
}

class PatternResult {
  final bool detected;
  final double quality; 
  final String name;
  final bool isBullish;

  const PatternResult(this.name, this.detected, this.quality, this.isBullish);
}

class TradingPair {
  final String label;
  final String symbol;
  final String category;
  final int profit1m;
  final int profit5m;
  final double change;

  const TradingPair({
    required this.label,
    required this.symbol,
    required this.category,
    required this.profit1m,
    required this.profit5m,
    required this.change,
  });
}

class SignalData {
  final String signal;
  final double confidence;
  final String entryTime;
  final String expiryTime;
  final String recommendedExpiry;
  final int countdown;
  final String price;
  final List<String> reasons;
  final List<double> chartCloses;
  final List<double> chartOpens;
  final List<double> chartHighs;
  final List<double> chartLows;
  final List<double> features;
  final Map<String, dynamic> indicators;
  final List<String> strategyIndicators;
  final String? errorText;

  const SignalData({
    required this.signal,
    required this.confidence,
    required this.entryTime,
    required this.expiryTime,
    required this.recommendedExpiry,
    required this.countdown,
    required this.price,
    required this.reasons,
    required this.chartCloses,
    required this.chartOpens,
    required this.chartHighs,
    required this.chartLows,
    required this.features,
    required this.indicators,
    required this.strategyIndicators,
    required this.errorText,
  });

  factory SignalData.empty() {
    return const SignalData(
      signal: 'NEUTRAL',
      confidence: 0,
      entryTime: '--:--:--',
      expiryTime: '--:--:--',
      recommendedExpiry: '1 min',
      countdown: 0,
      price: '--',
      reasons: [],
      chartCloses: [],
      chartOpens: [],
      chartHighs: [],
      chartLows: [],
      features: [],
      indicators: {},
      strategyIndicators: [],
      errorText: null,
    );
  }

  factory SignalData.error(String message) {
    return SignalData(
      signal: 'NEUTRAL',
      confidence: 0,
      entryTime: '--:--:--',
      expiryTime: '--:--:--',
      recommendedExpiry: '1 min',
      countdown: 0,
      price: '--',
      reasons: const ['Could not connect to backend API.'],
      chartCloses: [],
      chartOpens: [],
      chartHighs: [],
      chartLows: [],
      features: [],
      indicators: {},
      strategyIndicators: [],
      errorText: message,
    );
  }

  factory SignalData.fromJson(Map<String, dynamic> json) {
    final rawReasons = json['reason'];
    final parsedReasons = rawReasons is List
        ? rawReasons.map((e) => e.toString()).toList()
        : <String>[];

    final chartObj = json['chart'];
    List<double> closes = [];
    List<double> opens = [];
    List<double> highs = [];
    List<double> lows = [];
    if (chartObj is Map) {
      closes = (chartObj['closes'] as List?)?.map((e) => _toDouble(e)).toList() ?? [];
      opens = (chartObj['opens'] as List?)?.map((e) => _toDouble(e)).toList() ?? [];
      highs = (chartObj['highs'] as List?)?.map((e) => _toDouble(e)).toList() ?? [];
      lows = (chartObj['lows'] as List?)?.map((e) => _toDouble(e)).toList() ?? [];
    }

    final strategyObj = json['strategy'];
    List<String> strategyIndicators = [];
    if (strategyObj is Map) {
      final rawIndicators = strategyObj['indicators_used'];
      if (rawIndicators is List) {
        strategyIndicators = rawIndicators.map((e) => e.toString()).toList();
      }
    }

    final rawFeatures = json['features'];
    final List<double> features = rawFeatures is List 
        ? rawFeatures.map((e) => _toDouble(e)).toList()
        : [];

    return SignalData(
      signal: json['signal']?.toString() ?? 'NEUTRAL',
      confidence: _toDouble(json['confidence']),
      entryTime: json['entry_time']?.toString() ?? '--:--:--',
      expiryTime: json['expiry_time']?.toString() ?? '--:--:--',
      recommendedExpiry: json['recommended_expiry']?.toString() ?? '1 min',
      countdown: _toInt(json['countdown_seconds']),
      price: json['price'] == null ? '--' : json['price'].toString(),
      reasons: parsedReasons,
      chartCloses: closes,
      chartOpens: opens,
      chartHighs: highs,
      chartLows: lows,
      features: features,
      indicators: json['indicators'] is Map ? json['indicators'] : {},
      strategyIndicators: strategyIndicators,
      errorText: null,
    );
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? 0;
  }

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  SignalData copyWithCountdown(int value) {
    return SignalData(
      signal: signal,
      confidence: confidence,
      entryTime: entryTime,
      expiryTime: expiryTime,
      recommendedExpiry: recommendedExpiry,
      countdown: value,
      price: price,
      reasons: reasons,
      chartCloses: chartCloses,
      chartOpens: chartOpens,
      chartHighs: chartHighs,
      chartLows: chartLows,
      features: features,
      indicators: indicators,
      strategyIndicators: strategyIndicators,
      errorText: errorText,
    );
  }
}

class UserProfile {
  final String uid;
  final String email;
  final String displayName;
  final int dailyTradeLimit;
  final int tradesUsedToday;
  final DateTime? subscriptionExpiry;
  final DateTime? lastUsageDate;

  UserProfile({
    required this.uid,
    required this.email,
    required this.displayName,
    this.dailyTradeLimit = 5,
    this.tradesUsedToday = 0,
    this.subscriptionExpiry,
    this.lastUsageDate,
  });

  factory UserProfile.fromFirestore(DocumentSnapshot doc) {
    Map data = doc.data() as Map;
    return UserProfile(
      uid: doc.id,
      email: data['email'] ?? '',
      displayName: data['displayName'] ?? '',
      dailyTradeLimit: data['dailyTradeLimit'] ?? 5,
      tradesUsedToday: data['tradesUsedToday'] ?? 0,
      subscriptionExpiry: (data['subscriptionExpiry'] as Timestamp?)?.toDate(),
      lastUsageDate: (data['lastUsageDate'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'email': email,
      'displayName': displayName,
      'dailyTradeLimit': dailyTradeLimit,
      'tradesUsedToday': tradesUsedToday,
      'subscriptionExpiry': subscriptionExpiry,
      'lastUsageDate': lastUsageDate,
    };
  }
}

class TradeRecord {
  final String id;
  final DateTime openedAt;
  final DateTime? closedAt;
  final double entryPrice;
  final String signal;
  final String asset;
  final String marketType;
  final String timeframe;
  final String entryTimeStr;
  final bool? isWin;
  final List<double> features;

  TradeRecord({
    required this.id,
    required this.openedAt,
    this.closedAt,
    required this.entryPrice,
    required this.signal,
    required this.asset,
    required this.marketType,
    required this.timeframe,
    required this.entryTimeStr,
    this.isWin,
    required this.features,
  });

  TradeRecord close(bool win) {
    return TradeRecord(
      id: id,
      openedAt: openedAt,
      closedAt: DateTime.now(),
      entryPrice: entryPrice,
      signal: signal,
      asset: asset,
      marketType: marketType,
      timeframe: timeframe,
      entryTimeStr: entryTimeStr,
      isWin: win,
      features: features,
    );
  }
}

class BenchmarkResultItem {
  final String preset;
  final String presetLabel;
  final String symbol;
  final String? signal;
  final double? confidence;
  final String? price;
  final String? recommendedExpiry;
  final List<String> topReasons;
  final List<String> patterns;
  final List<String> blends;
  final String? error;

  BenchmarkResultItem({
    required this.preset,
    required this.presetLabel,
    required this.symbol,
    this.signal,
    this.confidence,
    this.price,
    this.recommendedExpiry,
    this.topReasons = const [],
    this.patterns = const [],
    this.blends = const [],
    this.error,
  });

  factory BenchmarkResultItem.fromJson(Map<String, dynamic> json) {
    List<String> toStringList(dynamic value) {
      if (value is List) {
        return value.map((e) => e.toString()).toList();
      }
      return [];
    }

    return BenchmarkResultItem(
      preset: json['preset']?.toString() ?? '',
      presetLabel: json['preset_label']?.toString() ?? '',
      symbol: json['symbol']?.toString() ?? '',
      signal: json['signal']?.toString(),
      confidence: json['confidence'] is num
          ? (json['confidence'] as num).toDouble()
          : double.tryParse(json['confidence']?.toString() ?? ''),
      price: json['price']?.toString(),
      recommendedExpiry: json['recommended_expiry']?.toString(),
      topReasons: toStringList(json['top_reasons']),
      patterns: toStringList(json['patterns']),
      blends: toStringList(json['blends']),
      error: json['error']?.toString(),
    );
  }
}

// --- CONSTANTS ---

const String pairCurrencies = 'CURRENCIES';
const String pairCrypto = 'CRYPTO';
const String pairCommodities = 'COMMODITIES';
const String pairStocks = 'STOCKS';

const List<TradingPair> kRealPairs = [
  TradingPair(label: 'EUR/USD', symbol: 'EUR/USD', category: pairCurrencies, profit1m: 89, profit5m: 85, change: 0.42),
  TradingPair(label: 'GBP/USD', symbol: 'GBP/USD', category: pairCurrencies, profit1m: 87, profit5m: 88, change: -0.12),
  TradingPair(label: 'USD/JPY', symbol: 'USD/JPY', category: pairCurrencies, profit1m: 85, profit5m: 82, change: 0.28),
  TradingPair(label: 'AUD/USD', symbol: 'AUD/USD', category: pairCurrencies, profit1m: 82, profit5m: 80, change: -0.34),
  TradingPair(label: 'EUR/JPY', symbol: 'EUR/JPY', category: pairCurrencies, profit1m: 80, profit5m: 84, change: 0.15),
  TradingPair(label: 'USD/CAD', symbol: 'USD/CAD', category: pairCurrencies, profit1m: 78, profit5m: 75, change: 0.09),
  TradingPair(label: 'USD/CHF', symbol: 'USD/CHF', category: pairCurrencies, profit1m: 75, profit5m: 78, change: -0.04),
  TradingPair(label: 'EUR/GBP', symbol: 'EUR/GBP', category: pairCurrencies, profit1m: 72, profit5m: 70, change: 0.11),
  TradingPair(label: 'AUD/JPY', symbol: 'AUD/JPY', category: pairCurrencies, profit1m: 70, profit5m: 72, change: 0.05),
  TradingPair(label: 'CAD/JPY', symbol: 'CAD/JPY', category: pairCurrencies, profit1m: 68, profit5m: 65, change: -0.18),
  TradingPair(label: 'EUR/CAD', symbol: 'EUR/CAD', category: pairCurrencies, profit1m: 65, profit5m: 68, change: 0.24),
  TradingPair(label: 'GBP/CAD', symbol: 'GBP/CAD', category: pairCurrencies, profit1m: 62, profit5m: 60, change: 0.31),
  TradingPair(label: 'AUD/CHF', symbol: 'AUD/CHF', category: pairCurrencies, profit1m: 60, profit5m: 58, change: -0.22),
  TradingPair(label: 'CHF/JPY', symbol: 'CHF/JPY', category: pairCurrencies, profit1m: 58, profit5m: 60, change: 0.17),
  TradingPair(label: 'AUD/CAD', symbol: 'AUD/CAD', category: pairCurrencies, profit1m: 55, profit5m: 52, change: -0.08),
  TradingPair(label: 'GBP/JPY', symbol: 'GBP/JPY', category: pairCurrencies, profit1m: 52, profit5m: 55, change: 0.45),
  TradingPair(label: 'EUR/AUD', symbol: 'EUR/AUD', category: pairCurrencies, profit1m: 50, profit5m: 48, change: 0.19),
  TradingPair(label: 'EUR/CHF', symbol: 'EUR/CHF', category: pairCurrencies, profit1m: 48, profit5m: 50, change: 0.03),
  TradingPair(label: 'GBP/CHF', symbol: 'GBP/CHF', category: pairCurrencies, profit1m: 45, profit5m: 42, change: -0.14),
  TradingPair(label: 'GBP/AUD', symbol: 'GBP/AUD', category: pairCurrencies, profit1m: 42, profit5m: 45, change: 0.26),
];

const List<TradingPair> kOtcPairs = [
  TradingPair(label: 'EUR/USD (OTC)', symbol: 'EURUSD_otc', category: pairCurrencies, profit1m: 98, profit5m: 98, change: 0.12),
  TradingPair(label: 'GBP/USD (OTC)', symbol: 'GBPUSD_otc', category: pairCurrencies, profit1m: 96, profit5m: 95, change: -0.05),
  TradingPair(label: 'USD/JPY (OTC)', symbol: 'USDJPY_otc', category: pairCurrencies, profit1m: 94, profit5m: 92, change: 0.08),
  TradingPair(label: 'USD/BRL (OTC)', symbol: 'USDBRL_otc', category: pairCurrencies, profit1m: 92, profit5m: 93, change: 4.29),
  TradingPair(label: 'USD/MXN (OTC)', symbol: 'USDMXN_otc', category: pairCurrencies, profit1m: 91, profit5m: 95, change: -0.04),
  TradingPair(label: 'USD/INR (OTC)', symbol: 'USDINR_otc', category: pairCurrencies, profit1m: 90, profit5m: 92, change: 0.34),
  TradingPair(label: 'CAD/CHF (OTC)', symbol: 'CADCHF_otc', category: pairCurrencies, profit1m: 89, profit5m: 92, change: 2.31),
  TradingPair(label: 'USD/PKR (OTC)', symbol: 'USDPKR_otc', category: pairCurrencies, profit1m: 88, profit5m: 92, change: 0.68),
  TradingPair(label: 'AUD/NZD (OTC)', symbol: 'AUDNZD_otc', category: pairCurrencies, profit1m: 87, profit5m: 87, change: 0.17),
  TradingPair(label: 'USD/COP (OTC)', symbol: 'USDCOP_otc', category: pairCurrencies, profit1m: 86, profit5m: 89, change: 0.15),
  TradingPair(label: 'USD/BDT (OTC)', symbol: 'USDBDT_otc', category: pairCurrencies, profit1m: 85, profit5m: 85, change: 1.43),
  TradingPair(label: 'USD/NGN (OTC)', symbol: 'USDNGN_otc', category: pairCurrencies, profit1m: 84, profit5m: 90, change: 0.00),
  TradingPair(label: 'USD/DZD (OTC)', symbol: 'USDDZD_otc', category: pairCurrencies, profit1m: 83, profit5m: 88, change: 0.00),
  TradingPair(label: 'USD/ARS (OTC)', symbol: 'USDARS_otc', category: pairCurrencies, profit1m: 82, profit5m: 79, change: 2.23),
  TradingPair(label: 'USD/ZAR (OTC)', symbol: 'USDZAR_otc', category: pairCurrencies, profit1m: 81, profit5m: 82, change: 0.02),
  TradingPair(label: 'NZD/CAD (OTC)', symbol: 'NZDCAD_otc', category: pairCurrencies, profit1m: 80, profit5m: 77, change: -1.66),
  TradingPair(label: 'NZD/CHF (OTC)', symbol: 'NZDCHF_otc', category: pairCurrencies, profit1m: 79, profit5m: 77, change: -0.56),
  TradingPair(label: 'NZD/JPY (OTC)', symbol: 'NZDJPY_otc', category: pairCurrencies, profit1m: 78, profit5m: 77, change: 1.16),
  TradingPair(label: 'USD/EGP (OTC)', symbol: 'USDEGP_otc', category: pairCurrencies, profit1m: 77, profit5m: 80, change: 0.14),
  TradingPair(label: 'USD/IDR (OTC)', symbol: 'USDIDR_otc', category: pairCurrencies, profit1m: 76, profit5m: 77, change: 0.04),
  TradingPair(label: 'USD/PHP (OTC)', symbol: 'USDPHP_otc', category: pairCurrencies, profit1m: 75, profit5m: 77, change: 0.00),
  TradingPair(label: 'GBP/NZD (OTC)', symbol: 'GBPNZD_otc', category: pairCurrencies, profit1m: 74, profit5m: 74, change: 0.88),
  TradingPair(label: 'EUR/NZD (OTC)', symbol: 'EURNZD_otc', category: pairCurrencies, profit1m: 73, profit5m: 73, change: -0.70),
  TradingPair(label: 'NZD/USD (OTC)', symbol: 'NZDUSD_otc', category: pairCurrencies, profit1m: 72, profit5m: 60, change: 1.84),
  TradingPair(label: 'Trump (OTC)', symbol: 'TRUMPUSD_otc', category: pairCrypto, profit1m: 92, profit5m: 92, change: -6.17),
  TradingPair(label: 'Dash (OTC)', symbol: 'DASHUSD_otc', category: pairCrypto, profit1m: 89, profit5m: 64, change: -2.81),
  TradingPair(label: 'Ethereum Classic (OTC)', symbol: 'ETCUSD_otc', category: pairCrypto, profit1m: 88, profit5m: 76, change: -10.17),
  TradingPair(label: 'Litecoin (OTC)', symbol: 'LTCUSD_otc', category: pairCrypto, profit1m: 88, profit5m: 86, change: 2.49),
  TradingPair(label: 'Toncoin (OTC)', symbol: 'TONUSD_otc', category: pairCrypto, profit1m: 87, profit5m: 92, change: -3.84),
  TradingPair(label: 'Solana (OTC)', symbol: 'SOLUSD_otc', category: pairCrypto, profit1m: 70, profit5m: 74, change: 0.40),
  TradingPair(label: 'Bitcoin (OTC)', symbol: 'BTCUSD_otc', category: pairCrypto, profit1m: 60, profit5m: 60, change: 0.00),
  TradingPair(label: 'Chainlink (OTC)', symbol: 'LINKUSD_otc', category: pairCrypto, profit1m: 53, profit5m: 41, change: 0.92),
  TradingPair(label: 'Ethereum (OTC)', symbol: 'ETHUSD_otc', category: pairCrypto, profit1m: 51, profit5m: 33, change: 1.82),
  TradingPair(label: 'Polkadot (OTC)', symbol: 'DOTUSD_otc', category: pairCrypto, profit1m: 47, profit5m: 42, change: 23.85),
  TradingPair(label: 'Zcash (OTC)', symbol: 'ZECUSD_otc', category: pairCrypto, profit1m: 47, profit5m: 68, change: -3.54),
  TradingPair(label: 'Ripple (OTC)', symbol: 'XRPUSD_otc', category: pairCrypto, profit1m: 36, profit5m: 33, change: 15.48),
  TradingPair(label: 'Cosmos (OTC)', symbol: 'ATOMUSD_otc', category: pairCrypto, profit1m: 35, profit5m: 17, change: 0.00),
  TradingPair(label: 'UKBrent (OTC)', symbol: 'UKBrent_otc', category: pairCommodities, profit1m: 92, profit5m: 92, change: -5.74),
  TradingPair(label: 'Silver (OTC)', symbol: 'XAGUSD_otc', category: pairCommodities, profit1m: 90, profit5m: 88, change: -0.16),
  TradingPair(label: 'USCrude (OTC)', symbol: 'USCrude_otc', category: pairCommodities, profit1m: 77, profit5m: 77, change: -1.63),
  TradingPair(label: 'Gold (OTC)', symbol: 'XAUUSD_otc', category: pairCommodities, profit1m: 77, profit5m: 77, change: 0.40),
  TradingPair(label: 'CAC 40', symbol: 'CAC40', category: pairStocks, profit1m: 40, profit5m: 33, change: 0.32),
  TradingPair(label: 'FTSE 100', symbol: 'FTSE100', category: pairStocks, profit1m: 40, profit5m: 40, change: 0.22),
  TradingPair(label: 'S&P/ASX 200', symbol: 'ASX200', category: pairStocks, profit1m: 20, profit5m: 20, change: 0.48),
  TradingPair(label: 'Nikkei 225', symbol: 'Nikkei225', category: pairStocks, profit1m: 20, profit5m: 20, change: 1.31),
  TradingPair(label: 'EURO STOXX 50', symbol: 'EuroStoxx50', category: pairStocks, profit1m: 20, profit5m: 20, change: 0.61),
  TradingPair(label: 'FTSE China A50 Index', symbol: 'ChinaA50', category: pairStocks, profit1m: 20, profit5m: 20, change: 0.00),
  TradingPair(label: 'Hong Kong 50', symbol: 'HK50', category: pairStocks, profit1m: 20, profit5m: 20, change: 0.57),
  TradingPair(label: 'IBEX 35', symbol: 'IBEX35', category: pairStocks, profit1m: 20, profit5m: 20, change: 0.00),
];

String pairLabelFromSymbol(String symbol) {
  for (final p in [...kRealPairs, ...kOtcPairs]) {
    if (p.symbol == symbol) return p.label;
  }
  return symbol;
}

TradingPair? pairFromSymbol(String symbol) {
  for (final p in [...kRealPairs, ...kOtcPairs]) {
    if (p.symbol == symbol) return p;
  }
  return null;
}

String pairLabelResolved(String symbol, {Map<String, String>? liveLabels}) {
  if (liveLabels != null && liveLabels.containsKey(symbol)) {
    return liveLabels[symbol]!;
  }
  return pairLabelFromSymbol(symbol);
}

String otcChangeText(double? value) {
  final v = value ?? 0.0;
  final sign = v > 0 ? '+' : '';
  return '$sign${v.toStringAsFixed(2)}%';
}

List<String> get kRealAssets => kRealPairs.map((p) => p.symbol).toList();
List<String> get kOtcAssets => kOtcPairs.map((p) => p.symbol).toList();

// --- SERVICES ---

class SignalEngine {
  static Map<String, dynamic> analyze(List<Candle> candles, String marketType, String symbol, String timeframe) {
    if (candles.length < 50) {
      return {'signal': 'NEUTRAL', 'confidence': 50, 'reasons': ['Not enough data']};
    }

    final closes = candles.map((c) => c.close).toList();
    final highs = candles.map((c) => c.high).toList();
    final lows = candles.map((c) => c.low).toList();
    final opens = candles.map((c) => c.open).toList();

    final rsiVal = _calculateRSI(closes);
    final ema9 = _calculateEMA(closes, 9).last;
    final ema21 = _calculateEMA(closes, 21).last;
    final ema50 = _calculateEMA(closes, 50).last;
    final macdData = _calculateMACD(closes);
    final atrVal = _calculateATR(candles, 14);

    final List<PatternResult> patterns = _detectAllPatterns(candles);
    
    double bullScore = 0;
    double bearScore = 0;
    List<String> reasons = [];

    if (closes.last > ema9 && ema9 > ema21) {
      bullScore += 15;
      reasons.add("EMA Trend: Bullish");
    } else if (closes.last < ema9 && ema9 < ema21) {
      bearScore += 15;
      reasons.add("EMA Trend: Bearish");
    }

    if (rsiVal < 30) {
      bullScore += 15;
      reasons.add("RSI Oversold");
    } else if (rsiVal > 70) {
      bearScore += 15;
      reasons.add("RSI Overbought");
    }

    if (macdData['hist']! > 0) {
      bullScore += 10;
      reasons.add("MACD Momentum: Bullish");
    } else if (macdData['hist']! < 0) {
      bearScore += 10;
      reasons.add("MACD Momentum: Bearish");
    }

    for (final p in patterns) {
      if (p.detected) {
        reasons.add("Pattern: ${p.name}");
        if (p.isBullish) bullScore += p.quality * 25;
        else bearScore += p.quality * 25;
      }
    }

    String signalVal;
    double confidence;
    final diff = (bullScore - bearScore).abs();

    if (diff < 15) {
      signalVal = "NEUTRAL";
      confidence = 50 + diff;
    } else if (bullScore > bearScore) {
      signalVal = "CALL";
      confidence = (60 + bullScore).clamp(65, 98);
    } else {
      signalVal = "PUT";
      confidence = (60 + bearScore).clamp(65, 98);
    }

    String recExpiry = "1 min";
    if (atrVal > (closes.last * 0.001)) {
      recExpiry = "1-2 min";
    } else {
      recExpiry = "3-5 min";
    }

    return {
      'signal': signalVal,
      'confidence': confidence,
      'reasons': reasons,
      'price': closes.last,
      'rec_expiry': recExpiry,
      'features': [
        bullScore/100, 
        bearScore/100, 
        rsiVal/100, 
        (closes.last-ema9)/closes.last,
        atrVal/closes.last,
        macdData['hist']!/closes.last,
        (closes.last-ema21)/closes.last,
        (closes.last-ema50)/closes.last,
        patterns.length / 100,
        diff / 100,
      ],
      'chart': {
        'closes': closes.sublist(closes.length - 50),
        'opens': opens.sublist(opens.length - 50),
        'highs': highs.sublist(highs.length - 50),
        'lows': lows.sublist(lows.length - 50),
      }
    };
  }

  static List<PatternResult> _detectAllPatterns(List<Candle> candles) {
    List<PatternResult> results = [];
    if (candles.length < 5) return results;
    final c = candles.last;
    final p = candles[candles.length - 2];
    results.add(PatternResult('Doji', c.isDoji, 1.0 - (c.body / c.totalRange), true));
    bool isHammer = c.lowerShadow >= 2 * c.body && c.upperShadow <= 0.1 * c.totalRange && c.body > 0;
    results.add(PatternResult('Hammer', isHammer, isHammer ? (c.lowerShadow / (c.body + 0.0001)).clamp(0, 1) : 0, true));
    bool isShootingStar = c.upperShadow >= 2 * c.body && c.lowerShadow <= 0.1 * c.totalRange && c.body > 0;
    results.add(PatternResult('Shooting Star', isShootingStar, isShootingStar ? (c.upperShadow / (c.body + 0.0001)).clamp(0, 1) : 0, false));
    bool isBullEngulf = p.isBearish && c.isBullish && c.close > p.open && c.open < p.close;
    results.add(PatternResult('Bullish Engulfing', isBullEngulf, isBullEngulf ? (c.body / p.body).clamp(0, 1) : 0, true));
    bool isBearEngulf = p.isBullish && c.isBearish && c.close < p.open && c.open > p.close;
    results.add(PatternResult('Bearish Engulfing', isBearEngulf, isBearEngulf ? (c.body / p.body).clamp(0, 1) : 0, false));
    return results;
  }

  static double _calculateRSI(List<double> closes, [int period = 14]) {
    if (closes.length < period + 1) return 50.0;
    double gain = 0;
    double loss = 0;
    for (int i = closes.length - period; i < closes.length; i++) {
      double diff = closes[i] - closes[i - 1];
      if (diff > 0) gain += diff; else loss -= diff;
    }
    double rs = (gain / period) / (loss / period == 0 ? 0.00001 : loss / period);
    return 100 - (100 / (1 + rs));
  }

  static List<double> _calculateEMA(List<double> data, int period) {
    if (data.isEmpty) return [];
    List<double> ema = [];
    double k = 2 / (period + 1);
    ema.add(data[0]);
    for (int i = 1; i < data.length; i++) {
      ema.add(data[i] * k + ema.last * (1 - k));
    }
    return ema;
  }

  static Map<String, double> _calculateMACD(List<double> closes) {
    final ema12 = _calculateEMA(closes, 12);
    final ema26 = _calculateEMA(closes, 26);
    if (ema12.length < 26 || ema26.length < 26) return {'hist': 0};
    final macdLine = ema12.last - ema26.last;
    final signalLine = _calculateEMA(ema12.map((e) => e).toList(), 9).last; 
    return {'hist': macdLine - signalLine};
  }

  static double _calculateATR(List<Candle> candles, int period) {
    if (candles.length < period + 1) return 0.0001;
    double trSum = 0;
    for (int i = candles.length - period; i < candles.length; i++) {
      trSum += candles[i].trueRange(candles[i - 1].close);
    }
    return trSum / period;
  }
}

class AuthService {
  static Future<UserCredential?> signInWithGoogle() async {
    final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) return null;
    final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    return FirebaseAuth.instance.signInWithCredential(credential);
  }

  static Future<void> signOut() async {
    await GoogleSignIn().signOut();
    await FirebaseAuth.instance.signOut();
  }
}

class TradingApi {
  static Future<Map<String, dynamic>> warmupOtc() async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/quotex-warmup');
    final response = await http.get(uri).timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw Exception('Backend error ${response.statusCode}: ${response.body}');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getSignal({
    required String marketType,
    required String symbol,
    required String timeframe,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/signal?market_type=${marketType.toLowerCase()}&symbol=${Uri.encodeComponent(symbol)}&timeframe=$timeframe',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw Exception('Backend error ${response.statusCode}: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getFutureSequence({
    required String marketType,
    required String symbol,
    int count = 10,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/future-sequence?market_type=${marketType.toLowerCase()}&symbol=${Uri.encodeComponent(symbol)}&count=$count',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw Exception('Backend error ${response.statusCode}: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> analyzeChart({
    required File imageFile,
    required String symbol,
    required String timeframe,
  }) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}/chart-analyze?symbol=${Uri.encodeComponent(symbol)}&timeframe=$timeframe',
    );
    final request = http.MultipartRequest('POST', uri);
    request.files.add(await http.MultipartFile.fromPath('file', imageFile.path));
    final streamed = await request.send().timeout(const Duration(seconds: 60));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200) {
      throw Exception('Backend error ${response.statusCode}: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getQuotexPairs() async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/quotex-pairs');
    final response = await http.get(uri).timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw Exception('Backend error ${response.statusCode}: ${response.body}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> pushOtcPairStat({
    required String adminToken,
    required String symbol,
    required String label,
    required int profit1m,
    required int profit5m,
    required double change,
    required double price,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/otc/push-pairs');

    final payload = {
      "items": [
        {
          "symbol": symbol,
          "label": label,
          "profit_1m": profit1m,
          "profit_5m": profit5m,
          "change": change,
          "price": price,
        }
      ]
    };

    final response = await http
        .post(
          uri,
          headers: {
            "Content-Type": "application/json",
            "X-Admin-Token": adminToken,
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('Backend error ${response.statusCode}: ${response.body}');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> pushOtcCandles({
    required String adminToken,
    required String symbol,
    required String timeframe,
    required List<Map<String, dynamic>> candles,
  }) async {
    final uri = Uri.parse('${ApiConfig.baseUrl}/otc/push-candles');

    final payload = {
      "symbol": symbol,
      "timeframe": timeframe,
      "candles": candles,
    };

    final response = await http
        .post(
          uri,
          headers: {
            "Content-Type": "application/json",
            "X-Admin-Token": adminToken,
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('Backend error ${response.statusCode}: ${response.body}');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<UserProfile> getOrCreateProfile(User user) async {
    DocumentSnapshot doc = await _db.collection('users').doc(user.uid).get();
    if (doc.exists) {
      UserProfile profile = UserProfile.fromFirestore(doc);
      DateTime now = DateTime.now();
      if (profile.lastUsageDate == null || 
          profile.lastUsageDate!.day != now.day || 
          profile.lastUsageDate!.month != now.month || 
          profile.lastUsageDate!.year != now.year) {
        await _db.collection('users').doc(user.uid).update({
          'tradesUsedToday': 0,
          'lastUsageDate': now,
        });
        return UserProfile(
          uid: profile.uid,
          email: profile.email,
          displayName: profile.displayName,
          dailyTradeLimit: profile.dailyTradeLimit,
          tradesUsedToday: 0,
          subscriptionExpiry: profile.subscriptionExpiry,
          lastUsageDate: now,
        );
      }
      return profile;
    } else {
      UserProfile newProfile = UserProfile(
        uid: user.uid,
        email: user.email ?? '',
        displayName: user.displayName ?? '',
        lastUsageDate: DateTime.now(),
      );
      await _db.collection('users').doc(user.uid).set(newProfile.toMap());
      return newProfile;
    }
  }

  Future<void> incrementUsage(String uid) async {
    await _db.collection('users').doc(uid).update({
      'tradesUsedToday': FieldValue.increment(1),
      'lastUsageDate': DateTime.now(),
    });
  }
}

class AdaptiveAIScorer {
  List<double> weights;
  double intercept;
  double learningRate;

  AdaptiveAIScorer({required this.weights, required this.intercept, this.learningRate = 0.005});

  factory AdaptiveAIScorer.initial(int featureCount) {
    return AdaptiveAIScorer(weights: List.filled(featureCount, 0.0), intercept: 0.0);
  }

  double predict(List<double> features) {
    if (features.length != weights.length) return 0.5;
    double z = intercept;
    for (int i = 0; i < features.length; i++) {
      z += weights[i] * features[i];
    }
    return 1.0 / (1.0 + exp(-z));
  }

  void learn(List<double> features, bool win) {
    if (features.length != weights.length) return;
    double prediction = predict(features);
    double actual = win ? 1.0 : 0.0;
    double error = prediction - actual;
    intercept -= learningRate * error;
    for (int i = 0; i < weights.length; i++) {
      weights[i] -= learningRate * error * features[i];
    }
  }
}

// --- GLOBAL STATE ---

final List<TradeRecord> globalTrades = [];
AdaptiveAIScorer globalScorer = AdaptiveAIScorer.initial(10);

// --- APP UI ---

class TradingMasterApp extends StatelessWidget {
  final bool firebaseReady;
  final String? firebaseError;

  const TradingMasterApp({super.key, required this.firebaseReady, required this.firebaseError});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TRADING MASTER',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.bg,
        primaryColor: AppColors.cyan,
      ),
      home: firebaseReady ? const AuthGate() : FirebaseSetupErrorScreen(error: firebaseError),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const LoadingScreen();
        final user = snapshot.data;
        if (user == null) return const LoginScreen();
        return DashboardScreen(user: user);
      },
    );
  }
}

class FirebaseSetupErrorScreen extends StatelessWidget {
  final String? error;
  const FirebaseSetupErrorScreen({super.key, required this.error});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: NeonCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error, color: AppColors.red, size: 48),
              const SizedBox(height: 16),
              const Text('Firebase Setup Error', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              const Text('Check google-services.json and Gradle configuration.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.gray)),
              const SizedBox(height: 12),
              Text(error ?? 'Unknown error', textAlign: TextAlign.center, style: const TextStyle(color: AppColors.red, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class LoadingScreen extends StatelessWidget {
  const LoadingScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const Scaffold(backgroundColor: AppColors.bg, body: Center(child: CircularProgressIndicator(color: AppColors.cyan)));
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool loading = false;
  String? errorText;
  Future<void> login() async {
    setState(() { loading = true; errorText = null; });
    try { await AuthService.signInWithGoogle(); } catch (e) { setState(() { errorText = e.toString(); }); }
    finally { if (mounted) setState(() { loading = false; }); }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment.topCenter, radius: 1.2, colors: [Color(0xFF063B38), AppColors.bg])),
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(28), border: Border.all(color: Colors.white10), boxShadow: [BoxShadow(color: AppColors.cyan.withOpacity(0.18), blurRadius: 30)]),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(height: 78, width: 78, decoration: BoxDecoration(color: const Color(0xFF080D14), borderRadius: BorderRadius.circular(22), boxShadow: [BoxShadow(color: AppColors.cyan.withOpacity(0.35), blurRadius: 24)]), child: Padding(padding: const EdgeInsets.all(12), child: Image.asset('assets/logo/logo.png'))),
                const SizedBox(height: 24),
                const Text('TRADING MASTER', textAlign: TextAlign.center, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                const SizedBox(height: 8),
                const Text('AI Signal Analysis', style: TextStyle(color: AppColors.gray)),
                const SizedBox(height: 34),
                SizedBox(width: double.infinity, height: 56, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: AppColors.cyan, foregroundColor: Colors.black, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), onPressed: loading ? null : login, icon: loading ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black)) : const Icon(Icons.login), label: Text(loading ? 'SIGNING IN...' : 'CONTINUE WITH GOOGLE', style: const TextStyle(fontWeight: FontWeight.w900)))),
                if (errorText != null) ...[const SizedBox(height: 16), Text(errorText!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.red, fontSize: 12))],
                const SizedBox(height: 16),
                const Text('Signals are analysis only and not guaranteed financial advice.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.gray, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DashboardScreen extends StatelessWidget {
  final User user;
  const DashboardScreen({super.key, required this.user});
  void openSignal(BuildContext context, String marketType) { Navigator.push(context, MaterialPageRoute(builder: (_) => SignalGeneratorScreen(initialMarket: marketType, user: user))); }
  void openFuture(BuildContext context) { Navigator.push(context, MaterialPageRoute(builder: (_) => const FutureSignalScreen())); }
  void openChartAnalyzer(BuildContext context) { Navigator.push(context, MaterialPageRoute(builder: (_) => const ChartAnalyzerScreen())); }
  void openProfile(BuildContext context) { Navigator.push(context, MaterialPageRoute(builder: (_) => ProfileScreen(user: user))); }
  void openJournal(BuildContext context) { Navigator.push(context, MaterialPageRoute(builder: (_) => const TradeJournalScreen())); }
  void openAdmin(BuildContext context) { Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminDashboard())); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: AppDrawer(user: user, onDashboard: () => Navigator.pop(context), onReal: () => openSignal(context, 'REAL'), onOtc: () => openSignal(context, 'OTC'), onFuture: () => openFuture(context), onChart: () => openChartAnalyzer(context), onJournal: () => openJournal(context), onProfile: () => openProfile(context), onAdmin: () => openAdmin(context)),
      appBar: AppBar(
        backgroundColor: AppColors.card,
        title: Row(children: [Image.asset('assets/logo/logo.png', height: 28), const SizedBox(width: 12), const Text('TRADING MASTER', style: TextStyle(fontWeight: FontWeight.w900))]),
        actions: [IconButton(onPressed: () => openProfile(context), icon: user.photoURL == null ? const Icon(Icons.account_circle, color: AppColors.gray) : CircleAvatar(radius: 15, backgroundImage: NetworkImage(user.photoURL!)))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          NeonCard(child: Row(children: [const Expanded(child: Text('Precision\nAlgo Trading', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, height: 1.15))), Container(height: 115, width: 115, decoration: BoxDecoration(color: const Color(0xFF090D14), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white10)), child: const Icon(Icons.candlestick_chart, color: AppColors.green, size: 60))])),
          const SizedBox(height: 18),
          Row(children: [Expanded(child: InfoCard(icon: Icons.shield, iconColor: AppColors.cyan, title: 'Risk Manage', subtitle: 'Protect capital. Max risk 1-2%')), const SizedBox(width: 12), Expanded(child: InfoCard(icon: Icons.rule, iconColor: Colors.purpleAccent, title: 'Trading Rules', subtitle: 'Wait for exact confirmation.'))]),
          const SizedBox(height: 12),
          Row(children: [Expanded(child: InfoCard(icon: Icons.psychology, iconColor: AppColors.green, title: 'Mindset', subtitle: 'Discipline is everything.')), const SizedBox(width: 12), Expanded(child: InfoCard(icon: Icons.lightbulb, iconColor: AppColors.yellow, title: 'Pro Tips', subtitle: 'Avoid high impact news.'))]),
          const SizedBox(height: 24),
          NeonButton(title: 'REAL MARKET SIGNALS', icon: Icons.public, color: AppColors.cyan, onTap: () => openSignal(context, 'REAL')),
          const SizedBox(height: 14),
          NeonButton(title: 'OTC SIGNALS', icon: Icons.timeline, color: AppColors.yellow, onTap: () => openSignal(context, 'OTC')),
          const SizedBox(height: 14),
          NeonButton(title: 'FUTURE SIGNALS', icon: Icons.flash_on, color: AppColors.green, onTap: () => openFuture(context)),
          const SizedBox(height: 14),
          NeonButton(title: 'CHART ANALYZER', icon: Icons.image_search, color: Colors.purpleAccent, onTap: () => openChartAnalyzer(context)),
          const SizedBox(height: 28),
          const Text('Disclaimer: Signals are analysis only and not guaranteed financial advice.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.gray, fontSize: 12)),
        ],
      ),
    );
  }
}

class AppDrawer extends StatelessWidget {
  final User user;
  final VoidCallback onDashboard;
  final VoidCallback onReal;
  final VoidCallback onOtc;
  final VoidCallback onFuture;
  final VoidCallback onChart;
  final VoidCallback onJournal;
  final VoidCallback onProfile;
  final VoidCallback onAdmin;

  const AppDrawer({super.key, required this.user, required this.onDashboard, required this.onReal, required this.onOtc, required this.onFuture, required this.onChart, required this.onJournal, required this.onProfile, required this.onAdmin});
  bool get isAdmin => user.email == 'ihashik820@gmail.com';

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: AppColors.card,
      child: SafeArea(
        child: Column(children: [
          ListTile(leading: Image.asset('assets/logo/logo.png', height: 32), title: const Text('TRADING MASTER', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 20))),
          const Divider(color: Colors.white10),
          ListTile(leading: const Icon(Icons.dashboard, color: Colors.white), title: const Text('Dashboard Overview'), onTap: onDashboard),
          ListTile(leading: const Icon(Icons.public, color: AppColors.gray), title: const Text('Real Analyzer'), onTap: () { Navigator.pop(context); onReal(); }),
          ListTile(leading: const Icon(Icons.timeline, color: AppColors.gray), title: const Text('OTC Analyzer'), onTap: () { Navigator.pop(context); onOtc(); }),
          ListTile(leading: const Icon(Icons.flash_on, color: AppColors.gray), title: const Text('Future Signals'), onTap: () { Navigator.pop(context); onFuture(); }),
          ListTile(leading: const Icon(Icons.image_search, color: AppColors.gray), title: const Text('Chart Analyzer'), onTap: () { Navigator.pop(context); onChart(); }),
          ListTile(leading: const Icon(Icons.book, color: AppColors.gray), title: const Text('Trade Journal'), onTap: () { Navigator.pop(context); onJournal(); }),
          ListTile(leading: const Icon(Icons.account_circle, color: AppColors.gray), title: const Text('Profile'), onTap: () { Navigator.pop(context); onProfile(); }),
          if (isAdmin) ListTile(leading: const Icon(Icons.admin_panel_settings, color: Colors.amber), title: const Text('Admin Panel', style: TextStyle(color: Colors.amber)), onTap: () { Navigator.pop(context); onAdmin(); }),
          const Spacer(),
          const Padding(padding: EdgeInsets.all(18), child: Text('Signals are analysis only.', style: TextStyle(color: AppColors.gray, fontSize: 12))),
        ]),
      ),
    );
  }
}

class SignalGeneratorScreen extends StatefulWidget {
  final String initialMarket;
  final User user;
  const SignalGeneratorScreen({super.key, required this.initialMarket, required this.user});
  @override
  State<SignalGeneratorScreen> createState() => _SignalGeneratorScreenState();
}

class _SignalGeneratorScreenState extends State<SignalGeneratorScreen> {
  late String marketType;
  late String selectedAsset;
  String timeframe = '1m';
  bool loading = false;
  SignalData result = SignalData.empty();
  Timer? countdownTimer;

  List<String> otcAssets = List<String>.from(kOtcAssets);
  Map<String, String> otcLabels = {};
  Map<String, Map<String, dynamic>> otcStats = {};
  bool otcPreparing = false;
  String? otcPrepareError;

  @override
  void initState() {
    super.initState();
    marketType = widget.initialMarket;
    selectedAsset = marketType == 'REAL'
        ? kRealPairs.first.symbol
        : otcAssets.first;

    if (marketType == 'OTC') {
      Future.microtask(_prepareOtc);
    }
  }

  @override
  void dispose() {
    countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _prepareOtc() async {
    if (otcPreparing) return;

    setState(() {
      otcPreparing = true;
      otcPrepareError = null;
    });

    try {
      await TradingApi.warmupOtc();

      final response = await TradingApi.getQuotexPairs();
      final rawData = response['data'];

      if (rawData is Map) {
        final symbols = <String>[];
        final labels = <String, String>{};
        final stats = <String, Map<String, dynamic>>{};

        for (final entry in rawData.entries) {
          final symbol = entry.key.toString();
          symbols.add(symbol);

          if (entry.value is Map) {
            final row = Map<String, dynamic>.from(entry.value as Map);
            stats[symbol] = row;

            final label = row['label']?.toString();
            if (label != null && label.isNotEmpty) {
              labels[symbol] = label;
            }
          }
        }

        symbols.sort();

        if (!mounted) return;

        setState(() {
          otcAssets = symbols.isNotEmpty ? symbols : List<String>.from(kOtcAssets);
          otcLabels = labels;
          otcStats = stats;

          if (marketType == 'OTC' && !otcAssets.contains(selectedAsset)) {
            selectedAsset = otcAssets.first;
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        otcPrepareError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          otcPreparing = false;
        });
      }
    }
  }

  void changeMarket(String value) {
    countdownTimer?.cancel();

    setState(() {
      marketType = value;
      selectedAsset = value == 'REAL'
          ? kRealPairs.first.symbol
          : (otcAssets.isNotEmpty ? otcAssets.first : kOtcPairs.first.symbol);
      result = SignalData.empty();
    });

    if (value == 'OTC') {
      _prepareOtc();
    }
  }

  void startCountdown(int seconds) {
    countdownTimer?.cancel();
    setState(() {
      result = result.copyWithCountdown(seconds);
    });

    countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (result.countdown <= 0) {
        timer.cancel();
      } else {
        setState(() {
          result = result.copyWithCountdown(result.countdown - 1);
        });
      }
    });
  }

  Future<void> generateSignal() async {
    setState(() {
      loading = true;
      result = SignalData.empty();
    });

    try {
      if (marketType == 'OTC') {
        await _prepareOtc();
      }

      final data = await TradingApi.getSignal(
        marketType: marketType,
        symbol: selectedAsset,
        timeframe: timeframe,
      );

      setState(() {
        result = SignalData.fromJson(data);
      });

      startCountdown(result.countdown);

      globalTrades.insert(
        0,
        TradeRecord(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          openedAt: DateTime.now(),
          entryPrice: double.tryParse(result.price) ?? 0,
          signal: result.signal,
          asset: selectedAsset,
          marketType: marketType,
          timeframe: timeframe,
          entryTimeStr: result.entryTime,
          features: result.features,
        ),
      );
    } catch (e) {
      setState(() {
        result = SignalData.error(e.toString());
      });
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<String> assets =
        marketType == 'REAL' ? kRealPairs.map((p) => p.symbol).toList() : otcAssets;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.card,
        title: const Text('Signal Generator', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          NeonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '⚡ Signal Generator',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Select target for prediction',
                  style: TextStyle(color: AppColors.gray, fontSize: 12),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: ToggleButton(
                        title: 'REAL',
                        selected: marketType == 'REAL',
                        onTap: () => changeMarket('REAL'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ToggleButton(
                        title: 'OTC',
                        selected: marketType == 'OTC',
                        onTap: () => changeMarket('OTC'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                if (marketType == 'OTC') ...[
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Live OTC feed',
                          style: TextStyle(
                            color: AppColors.yellow,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: otcPreparing ? null : _prepareOtc,
                        icon: otcPreparing
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh, color: AppColors.yellow),
                      ),
                    ],
                  ),
                  if (otcPrepareError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        otcPrepareError!,
                        style: const TextStyle(color: AppColors.red, fontSize: 12),
                      ),
                    ),
                ],

                AssetDropdown(
                  selectedAsset: selectedAsset,
                  assets: assets,
                  labels: marketType == 'OTC' ? otcLabels : null,
                  stats: marketType == 'OTC' ? otcStats : null,
                  onChanged: loading ? null : (v) => setState(() => selectedAsset = v!),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: ToggleButton(
                        title: '1M',
                        selected: timeframe == '1m',
                        onTap: () => setState(() => timeframe = '1m'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ToggleButton(
                        title: '5M',
                        selected: timeframe == '5m',
                        onTap: () => setState(() => timeframe = '5m'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                NeonButton(
                  title: loading ? 'ANALYZING...' : 'GENERATE SIGNAL',
                  icon: loading ? Icons.hourglass_top : Icons.auto_fix_high,
                  color: AppColors.cyan,
                  onTap: loading ? () {} : generateSignal,
                ),
                if (loading) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(color: AppColors.cyan),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          SignalResultCard(
            data: result,
            asset: selectedAsset,
            timeframe: timeframe,
            marketType: marketType,
          ),
          const SizedBox(height: 18),
          StrategyPanel(
            data: result,
            asset: selectedAsset,
            timeframe: timeframe,
            marketType: marketType,
          ),
        ],
      ),
    );
  }
}

class SignalResultCard extends StatelessWidget {
  final SignalData data;
  final String asset;
  final String timeframe;
  final String marketType;
  const SignalResultCard({super.key, required this.data, required this.asset, required this.timeframe, required this.marketType});
  Color get signalColor => data.signal == 'CALL' ? AppColors.green : (data.signal == 'PUT' ? AppColors.red : AppColors.yellow);
  @override
  Widget build(BuildContext context) {
    return NeonCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: Text(data.signal, style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900, color: signalColor, letterSpacing: 2))),
      const SizedBox(height: 8),
      Center(child: Text('$marketType • $asset • ${timeframe.toUpperCase()}', style: const TextStyle(color: AppColors.gray))),
      const SizedBox(height: 20),
      RowInfo(title: 'Confidence', value: '${data.confidence.toStringAsFixed(1)}%'),
      RowInfo(title: 'Entry Time', value: data.entryTime),
      RowInfo(title: 'Expiry Time', value: data.expiryTime),
      RowInfo(title: 'Countdown', value: '${data.countdown}s'),
      RowInfo(title: 'Price', value: data.price),
      const SizedBox(height: 16),
      if (data.errorText != null) ...[Text(data.errorText!, style: const TextStyle(color: AppColors.red, fontSize: 12)), const SizedBox(height: 12)],
      const Text('Reasons', style: TextStyle(fontWeight: FontWeight.w900)),
      const SizedBox(height: 8),
      if (data.reasons.isEmpty) const Text('Press Generate Signal to analyze.', style: TextStyle(color: AppColors.gray))
      else ...data.reasons.map((r) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('• $r', style: const TextStyle(color: AppColors.gray)))),
    ]));
  }
}

class FutureSignalScreen extends StatefulWidget {
  const FutureSignalScreen({super.key});
  @override
  State<FutureSignalScreen> createState() => _FutureSignalScreenState();
}

class _FutureSignalScreenState extends State<FutureSignalScreen> {
  String marketType = 'REAL';
  String selectedAsset = kRealPairs.first.symbol;
  bool loading = false;
  List<FutureSignalItem> signals = [];
  Timer? listTimer;

  List<String> otcAssets = List<String>.from(kOtcAssets);
  Map<String, String> otcLabels = {};
  Map<String, Map<String, dynamic>> otcStats = {};
  bool otcPreparing = false;
  String? otcPrepareError;

  @override
  void dispose() {
    listTimer?.cancel();
    super.dispose();
  }

  Future<void> _prepareOtc() async {
    if (otcPreparing) return;

    setState(() {
      otcPreparing = true;
      otcPrepareError = null;
    });

    try {
      await TradingApi.warmupOtc();

      final response = await TradingApi.getQuotexPairs();
      final rawData = response['data'];

      if (rawData is Map) {
        final symbols = <String>[];
        final labels = <String, String>{};
        final stats = <String, Map<String, dynamic>>{};

        for (final entry in rawData.entries) {
          final symbol = entry.key.toString();
          symbols.add(symbol);

          if (entry.value is Map) {
            final row = Map<String, dynamic>.from(entry.value as Map);
            stats[symbol] = row;

            final label = row['label']?.toString();
            if (label != null && label.isNotEmpty) {
              labels[symbol] = label;
            }
          }
        }

        symbols.sort();

        if (!mounted) return;

        setState(() {
          otcAssets = symbols.isNotEmpty ? symbols : List<String>.from(kOtcAssets);
          otcLabels = labels;
          otcStats = stats;

          if (marketType == 'OTC' && !otcAssets.contains(selectedAsset)) {
            selectedAsset = otcAssets.first;
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        otcPrepareError = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          otcPreparing = false;
        });
      }
    }
  }

  void changeMarket(String v) {
    listTimer?.cancel();

    setState(() {
      marketType = v;
      selectedAsset = v == 'REAL'
          ? kRealPairs.first.symbol
          : (otcAssets.isNotEmpty ? otcAssets.first : kOtcPairs.first.symbol);
      signals = [];
    });

    if (v == 'OTC') {
      _prepareOtc();
    }
  }

  Future<void> generateNewSignals() async {
    setState(() {
      loading = true;
      signals = [];
    });

    try {
      if (marketType == 'OTC') {
        await _prepareOtc();
      }

      final data = await TradingApi.getFutureSequence(
        marketType: marketType,
        symbol: selectedAsset,
        count: 10,
      );

      final raw = data['signals'] as List;

      setState(() {
        signals = raw
            .map((e) => FutureSignalItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      });

      listTimer?.cancel();
      listTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || signals.isEmpty) {
          timer.cancel();
          return;
        }
        setState(() {
          signals = signals
              .map((i) => i.copyWithSeconds(max(0, i.entryInSeconds - 1)))
              .toList();
        });
      });
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final assets = marketType == 'REAL' ? kRealPairs.map((p) => p.symbol).toList() : otcAssets;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.card,
        title: const Text('Future Signal', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          NeonCard(
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ToggleButton(
                        title: 'REAL',
                        selected: marketType == 'REAL',
                        onTap: () => changeMarket('REAL'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ToggleButton(
                        title: 'OTC',
                        selected: marketType == 'OTC',
                        onTap: () => changeMarket('OTC'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                if (marketType == 'OTC') ...[
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Live OTC feed',
                          style: TextStyle(
                            color: AppColors.yellow,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: otcPreparing ? null : _prepareOtc,
                        icon: otcPreparing
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh, color: AppColors.yellow),
                      ),
                    ],
                  ),
                  if (otcPrepareError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        otcPrepareError!,
                        style: const TextStyle(color: AppColors.red, fontSize: 12),
                      ),
                    ),
                ],

                AssetDropdown(
                  selectedAsset: selectedAsset,
                  assets: assets,
                  labels: marketType == 'OTC' ? otcLabels : null,
                  stats: marketType == 'OTC' ? otcStats : null,
                  onChanged: loading ? null : (v) => setState(() => selectedAsset = v!),
                ),
                const SizedBox(height: 18),
                NeonButton(
                  title: loading ? 'LOADING...' : 'GENERATE NEW SIGNALS',
                  icon: Icons.refresh,
                  color: AppColors.green,
                  onTap: loading ? () {} : generateNewSignals,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          ...signals.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: FutureSignalCard(item: s),
            ),
          ),
        ],
      ),
    );
  }
}

class FutureSignalItem {
  final int index;
  final String symbol;
  final String signal;
  final String displaySignal;
  final double confidence;
  final String entryTime;
  final int entryInSeconds;
  final String duration;
  final String status;
  FutureSignalItem({required this.index, required this.symbol, required this.signal, required this.displaySignal, required this.confidence, required this.entryTime, required this.entryInSeconds, required this.duration, required this.status});
  factory FutureSignalItem.fromJson(Map<String, dynamic> json) {
    return FutureSignalItem(index: _toInt(json['index']), symbol: json['symbol'] ?? '', signal: json['signal'] ?? 'NEUTRAL', displaySignal: json['display_signal'] ?? 'WAIT', confidence: _toDouble(json['confidence']), entryTime: json['entry_time'] ?? '--:--', entryInSeconds: _toInt(json['entry_in_seconds']), duration: json['duration'] ?? '1 min', status: json['status'] ?? 'PENDING');
  }
  static double _toDouble(dynamic v) => (v is num) ? v.toDouble() : 0.0;
  static int _toInt(dynamic v) => (v is num) ? v.toInt() : 0;
  FutureSignalItem copyWithSeconds(int s) => FutureSignalItem(index: index, symbol: symbol, signal: signal, displaySignal: displaySignal, confidence: confidence, entryTime: entryTime, entryInSeconds: s, duration: duration, status: status);
  String get entryInText {
    final h = entryInSeconds ~/ 3600; final m = (entryInSeconds % 3600) ~/ 60; final s = entryInSeconds % 60;
    return h > 0 ? '${h}h ${m}m' : (m > 0 ? '${m}m ${s}s' : '${s}s');
  }
}

class FutureSignalCard extends StatelessWidget {
  final FutureSignalItem item;
  const FutureSignalCard({super.key, required this.item});
  @override
  Widget build(BuildContext context) {
    Color c = item.signal == 'CALL' ? AppColors.green : (item.signal == 'PUT' ? AppColors.red : AppColors.yellow);
    return Container(
      decoration: BoxDecoration(color: c.withOpacity(0.07), borderRadius: BorderRadius.circular(24), border: Border.all(color: c.withOpacity(0.45))),
      child: Column(children: [
        Padding(padding: const EdgeInsets.all(18), child: Row(children: [CircleAvatar(radius: 28, backgroundColor: c.withOpacity(0.18), child: Icon(Icons.currency_exchange, color: c)), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(pairLabelFromSymbol(item.symbol), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20)), Text('Signal #${item.index}', style: const TextStyle(color: AppColors.gray))])), Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12), decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(18), border: Border.all(color: c.withOpacity(0.5))), child: Text(item.displaySignal, style: TextStyle(color: c, fontWeight: FontWeight.w900)))]))
      ]),
    );
  }
}

class ChartAnalyzerScreen extends StatefulWidget {
  const ChartAnalyzerScreen({super.key});
  @override
  State<ChartAnalyzerScreen> createState() => _ChartAnalyzerScreenState();
}

class _ChartAnalyzerScreenState extends State<ChartAnalyzerScreen> {
  File? selectedImage; bool loading = false; String signal = 'NEUTRAL'; double confidence = 0; String summary = 'Upload a chart screenshot to analyze.'; List<String> reasons = [];
  final picker = ImagePicker();
  Future<void> pickImage() async { final p = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85); if (p != null) setState(() { selectedImage = File(p.path); }); }
  Future<void> analyzeChart() async {
    if (selectedImage == null) return;
    setState(() { loading = true; });
    try {
      final data = await TradingApi.analyzeChart(imageFile: selectedImage!, symbol: 'EUR/USD', timeframe: '1m');
      setState(() { signal = data['signal'] ?? 'NEUTRAL'; confidence = (data['confidence'] as num).toDouble(); summary = data['summary'] ?? ''; reasons = List<String>.from(data['reasons'] ?? []); });
    } catch (e) { setState(() { summary = e.toString(); }); }
    finally { if (mounted) setState(() { loading = false; }); }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.card, title: const Text('Chart Analysis', style: TextStyle(fontWeight: FontWeight.w900))),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        NeonCard(child: Column(children: [
          GestureDetector(onTap: pickImage, child: Container(height: 260, width: double.infinity, decoration: BoxDecoration(color: const Color(0xFF020806), borderRadius: BorderRadius.circular(22), border: Border.all(color: AppColors.green.withOpacity(0.35))), child: selectedImage == null ? const Icon(Icons.add_photo_alternate_outlined, color: AppColors.green, size: 48) : ClipRRect(borderRadius: BorderRadius.circular(22), child: Image.file(selectedImage!, fit: BoxFit.cover)))),
          const SizedBox(height: 20),
          NeonButton(title: loading ? 'ANALYZING...' : 'ANALYZE CHART', icon: Icons.center_focus_strong, color: AppColors.green, onTap: loading ? () {} : analyzeChart),
        ])),
        const SizedBox(height: 18),
        NeonCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Text(signal, style: TextStyle(color: signal == 'CALL' ? AppColors.green : AppColors.red, fontSize: 40, fontWeight: FontWeight.w900))),
          const SizedBox(height: 18),
          Text(summary, style: const TextStyle(color: AppColors.gray)),
        ])),
      ]),
    );
  }
}

class TradeJournalScreen extends StatefulWidget {
  const TradeJournalScreen({super.key});
  @override
  State<TradeJournalScreen> createState() => _TradeJournalScreenState();
}

class _TradeJournalScreenState extends State<TradeJournalScreen> {
  bool isSyncing = false;
  void recordOutcome(TradeRecord trade, bool win) { setState(() { int idx = globalTrades.indexWhere((t) => t.id == trade.id); if (idx != -1) { globalTrades[idx] = globalTrades[idx].close(win); globalScorer.learn(trade.features, win); } }); }
  @override
  Widget build(BuildContext context) {
    int wins = globalTrades.where((t) => t.isWin == true).length;
    int losses = globalTrades.where((t) => t.isWin == false).length;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.card, title: const Text('Trade Journal', style: TextStyle(fontWeight: FontWeight.w900))),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        NeonCard(child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [Text('WINS: $wins'), Text('LOSSES: $losses')])),
        const SizedBox(height: 20),
        ...globalTrades.map((t) => Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(16)), child: Column(children: [Row(children: [Text(t.asset), const Spacer(), Text(t.signal)]), if (t.isWin == null) Row(children: [ElevatedButton(onPressed: () => recordOutcome(t, true), child: const Text('WIN')), ElevatedButton(onPressed: () => recordOutcome(t, false), child: const Text('LOSS'))])]))),
      ]),
    );
  }
}

class ProfileScreen extends StatelessWidget {
  final User user;
  const ProfileScreen({super.key, required this.user});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(backgroundColor: AppColors.card, title: const Text('Profile', style: TextStyle(fontWeight: FontWeight.w900))),
      body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(user.displayName ?? 'Trader'), const SizedBox(height: 24), NeonButton(title: 'LOGOUT', icon: Icons.logout, color: AppColors.red, onTap: () => AuthService.signOut())])),
    );
  }
}

// --- WIDGETS ---

class AssetDropdown extends StatelessWidget {
  final String selectedAsset;
  final List<String> assets;
  final Map<String, String>? labels;
  final Map<String, Map<String, dynamic>>? stats;
  final ValueChanged<String?>? onChanged;

  const AssetDropdown({
    super.key,
    required this.selectedAsset,
    required this.assets,
    required this.onChanged,
    this.labels,
    this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final row = stats?[selectedAsset];
    final payout1m = row?['profit_1m'];
    final change = row?['change'] is num ? (row!['change'] as num).toDouble() : null;

    return GestureDetector(
      onTap: () async {
        final selected = await showModalBottomSheet<String>(
          context: context,
          builder: (_) => PairPickerSheet(
            selectedAsset: selectedAsset,
            assets: assets,
            labels: labels,
            stats: stats,
          ),
        );
        if (selected != null && onChanged != null) {
          onChanged!(selected);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF090D14),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(Icons.search),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pairLabelResolved(selectedAsset, liveLabels: labels),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (row != null)
                    Text(
                      '1M: ${payout1m ?? 0}%  •  ${otcChangeText(change)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: (change ?? 0) >= 0 ? AppColors.green : AppColors.red,
                      ),
                    ),
                ],
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

class PairPickerSheet extends StatefulWidget {
  final String selectedAsset;
  final List<String> assets;
  final Map<String, String>? labels;
  final Map<String, Map<String, dynamic>>? stats;

  const PairPickerSheet({
    super.key,
    required this.selectedAsset,
    required this.assets,
    this.labels,
    this.stats,
  });

  @override
  State<PairPickerSheet> createState() => _PairPickerSheetState();
}

class _PairPickerSheetState extends State<PairPickerSheet> {
  String search = '';

  @override
  Widget build(BuildContext context) {
    final filteredAssets = widget.assets.where((symbol) {
      final label =
          pairLabelResolved(symbol, liveLabels: widget.labels).toLowerCase();
      final raw = symbol.toLowerCase();
      final q = search.toLowerCase();
      return label.contains(q) || raw.contains(q);
    }).toList();

    return Container(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => search = v),
            decoration: const InputDecoration(hintText: 'Search'),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: filteredAssets.length,
              itemBuilder: (context, i) {
                final symbol = filteredAssets[i];
                final label = pairLabelResolved(symbol, liveLabels: widget.labels);
                final row = widget.stats?[symbol];

                final payout1m = row?['profit_1m'];
                final payout5m = row?['profit_5m'];
                final change = row?['change'] is num
                    ? (row!['change'] as num).toDouble()
                    : null;

                return ListTile(
                  title: Text(label),
                  subtitle: row == null
                      ? Text(symbol)
                      : Text(
                          '1M: ${payout1m ?? 0}%   5M: ${payout5m ?? 0}%   Δ ${otcChangeText(change)}',
                          style: TextStyle(
                            color: (change ?? 0) >= 0 ? AppColors.green : AppColors.red,
                            fontSize: 12,
                          ),
                        ),
                  trailing: symbol == widget.selectedAsset
                      ? const Icon(Icons.check, color: AppColors.cyan)
                      : null,
                  onTap: () => Navigator.pop(context, symbol),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class BenchmarkResultsTable extends StatelessWidget {
  final String? baseSymbol;
  final String? timeframe;
  final List<BenchmarkResultItem> results;

  const BenchmarkResultsTable({
    super.key,
    required this.baseSymbol,
    required this.timeframe,
    required this.results,
  });

  Color _signalColor(String? signal) {
    switch ((signal ?? '').toUpperCase()) {
      case 'CALL':
        return AppColors.green;
      case 'PUT':
        return AppColors.red;
      case 'NEUTRAL':
        return AppColors.yellow;
      default:
        return AppColors.gray;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) return const SizedBox.shrink();

    return NeonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Benchmark Results',
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            'Base Symbol: ${baseSymbol ?? "--"}   •   Timeframe: ${timeframe ?? "--"}',
            style: const TextStyle(color: AppColors.gray, fontSize: 12),
          ),
          const SizedBox(height: 16),

          ...results.map((item) {
            final color = _signalColor(item.signal);
            final topReason =
                item.topReasons.isNotEmpty ? item.topReasons.first : '-';

            return Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0B0F14),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: item.error != null
                      ? AppColors.red.withOpacity(0.35)
                      : color.withOpacity(0.35),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.presetLabel,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      if (item.error == null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: color.withOpacity(0.4)),
                          ),
                          child: Text(
                            item.signal ?? 'UNKNOWN',
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.symbol,
                    style: const TextStyle(color: AppColors.gray, fontSize: 12),
                  ),
                  const SizedBox(height: 10),

                  if (item.error != null) ...[
                    Text(
                      'Error: ${item.error}',
                      style: const TextStyle(color: AppColors.red),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: _miniInfo(
                            'Confidence',
                            item.confidence?.toStringAsFixed(1) ?? '--',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _miniInfo(
                            'Price',
                            item.price ?? '--',
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _miniInfo(
                            'Expiry',
                            item.recommendedExpiry ?? '--',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _miniInfo('Top Reason', topReason),

                    if (item.patterns.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Patterns: ${item.patterns.take(3).join(", ")}',
                        style: const TextStyle(
                          color: AppColors.cyan,
                          fontSize: 12,
                        ),
                      ),
                    ],

                    if (item.blends.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Blends: ${item.blends.take(2).join(", ")}',
                        style: const TextStyle(
                          color: AppColors.yellow,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            );
          }).toList(),
        ],
      ),
    );
  }

  Widget _miniInfo(String title, String value) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: AppColors.gray, fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w800),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class StrategyPanel extends StatelessWidget {
  final SignalData data; final String asset; final String timeframe; final String marketType;
  const StrategyPanel({super.key, required this.data, required this.asset, required this.timeframe, required this.marketType});
  @override
  Widget build(BuildContext context) {
    return Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: const Color(0xFF0B0F14), borderRadius: BorderRadius.circular(22)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('STRATEGY: ${data.signal}', style: const TextStyle(fontWeight: FontWeight.w900)),
      const SizedBox(height: 12),
      if (data.chartCloses.isNotEmpty) AdvancedCandleChart(data: data),
    ]));
  }
}

class AdvancedCandleChart extends StatelessWidget {
  final SignalData data;
  const AdvancedCandleChart({super.key, required this.data});
  @override
  Widget build(BuildContext context) { return SizedBox(height: 200, child: CustomPaint(size: Size.infinite, painter: _AdvancedCandlePainter(data))); }
}

class _AdvancedCandlePainter extends CustomPainter {
  final SignalData data; _AdvancedCandlePainter(this.data);
  @override
  void paint(Canvas canvas, Size size) {
    if (data.chartCloses.isEmpty) return;
    final minV = data.chartLows.reduce((a, b) => a < b ? a : b);
    final maxV = data.chartHighs.reduce((a, b) => a > b ? a : b);
    final range = maxV - minV; final candleWidth = size.width / data.chartCloses.length;
    for (int i = 0; i < data.chartCloses.length; i++) {
      final x = i * candleWidth; final isUp = data.chartCloses[i] >= data.chartOpens[i];
      final paint = Paint()..color = isUp ? AppColors.green : AppColors.red;
      final openY = size.height - ((data.chartOpens[i] - minV) / range * size.height);
      final closeY = size.height - ((data.chartCloses[i] - minV) / range * size.height);
      canvas.drawRect(Rect.fromLTRB(x + 2, openY, x + candleWidth - 2, closeY), paint);
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class InfoCard extends StatelessWidget {
  final IconData icon; final Color iconColor; final String title; final String subtitle;
  const InfoCard({super.key, required this.icon, required this.iconColor, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) { return NeonCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, color: iconColor, size: 34), const SizedBox(height: 18), Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)), const SizedBox(height: 8), Text(subtitle, style: const TextStyle(color: AppColors.gray, fontSize: 13))])); }
}

class SmallMetricCard extends StatelessWidget {
  final IconData icon; final String title; final String value; final Color color; final bool fullWidth;
  const SmallMetricCard({super.key, required this.icon, required this.title, required this.value, required this.color, this.fullWidth = false});
  @override
  Widget build(BuildContext context) {
    return Container(width: fullWidth ? double.infinity : null, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF0B0F12), borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white10)), child: Row(children: [CircleAvatar(backgroundColor: color.withOpacity(0.15), child: Icon(icon, color: color)), const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(color: AppColors.gray, letterSpacing: 1.8, fontSize: 11)), const SizedBox(height: 8), Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 22))]))]));
  }
}

class StrategyChip extends StatelessWidget {
  final String label; const StrategyChip({super.key, required this.label});
  @override
  Widget build(BuildContext context) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: AppColors.cyan.withOpacity(0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.cyan.withOpacity(0.3))), child: Text(label, style: const TextStyle(color: AppColors.cyan, fontWeight: FontWeight.w900, fontSize: 11)));
  }
}

class MiniLineChart extends StatelessWidget {
  final List<double> values; final Color color; const MiniLineChart({super.key, required this.values, required this.color});
  @override
  Widget build(BuildContext context) { return CustomPaint(size: Size.infinite, painter: _MiniLineChartPainter(values, color)); }
}

class _MiniLineChartPainter extends CustomPainter {
  final List<double> values; final Color color; _MiniLineChartPainter(this.values, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    double minV = values.reduce((a, b) => a < b ? a : b); double maxV = values.reduce((a, b) => a > b ? a : b);
    if (minV == maxV) { minV -= 0.0001; maxV += 0.0001; }
    final paintLine = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.2;
    final path = Path();
    for (int i = 0; i < values.length; i++) {
      final x = (i / (values.length - 1)) * size.width;
      final y = size.height - ((values[i] - minV) / (maxV - minV) * size.height * 0.9 + size.height * 0.05);
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, paintLine);
  }
  @override
  bool shouldRepaint(covariant _MiniLineChartPainter oldDelegate) => true;
}

class NeonCard extends StatelessWidget {
  final Widget child; const NeonCard({super.key, required this.child});
  @override
  Widget build(BuildContext context) { return Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white10)), child: child); }
}

class NeonButton extends StatelessWidget {
  final String title; final IconData icon; final Color color; final VoidCallback onTap;
  const NeonButton({super.key, required this.title, required this.icon, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) { return SizedBox(width: double.infinity, height: 54, child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.black), onPressed: onTap, icon: Icon(icon), label: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)))); }
}

class ToggleButton extends StatelessWidget {
  final String title; final bool selected; final VoidCallback onTap;
  const ToggleButton({super.key, required this.title, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) { return GestureDetector(onTap: onTap, child: Container(height: 48, alignment: Alignment.center, decoration: BoxDecoration(color: selected ? AppColors.card2 : Colors.transparent, borderRadius: BorderRadius.circular(14), border: Border.all(color: selected ? AppColors.cyan : Colors.white10)), child: Text(title, style: TextStyle(color: selected ? AppColors.cyan : AppColors.gray, fontWeight: FontWeight.bold)))); }
}

class RowInfo extends StatelessWidget {
  final String title; final String value;
  const RowInfo({super.key, required this.title, required this.value});
  @override
  Widget build(BuildContext context) { return Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(children: [Expanded(child: Text(title, style: const TextStyle(color: AppColors.gray))), Text(value, style: const TextStyle(fontWeight: FontWeight.bold))])); }
}

// --- ADMIN DASHBOARD (Single Copy) ---

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  void openOtcTools() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const OtcAdminToolsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.card,
        title: const Text('Admin Dashboard'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          NeonButton(
            title: 'OPEN OTC ADMIN TOOLS',
            icon: Icons.admin_panel_settings,
            color: AppColors.cyan,
            onTap: openOtcTools,
          ),
          const SizedBox(height: 18),
          StreamBuilder<QuerySnapshot>(
            stream: _db.collection('users').snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

              final users =
                  snapshot.data!.docs.map((doc) => UserProfile.fromFirestore(doc)).toList();

              return Column(
                children: users
                    .map(
                      (u) => ListTile(
                        title: Text(u.displayName),
                        subtitle: Text(u.email),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class OtcAdminToolsScreen extends StatefulWidget {
  const OtcAdminToolsScreen({super.key});

  @override
  State<OtcAdminToolsScreen> createState() => _OtcAdminToolsScreenState();
}

class _OtcAdminToolsScreenState extends State<OtcAdminToolsScreen> {
  final tokenController = TextEditingController();

  final pairSymbolController = TextEditingController(text: 'EURUSD_otc');
  final pairLabelController = TextEditingController(text: 'EUR/USD (OTC)');
  final pairProfit1mController = TextEditingController(text: '92');
  final pairProfit5mController = TextEditingController(text: '90');
  final pairChangeController = TextEditingController(text: '0.15');
  final pairPriceController = TextEditingController(text: '1.08452');

  final candleSymbolController = TextEditingController(text: 'EURUSD_otc');
  final candleTimeframeController = TextEditingController(text: '1m');
  final sampleCountController = TextEditingController(text: '50');
  final sampleStartPriceController = TextEditingController(text: '1.08450');
  final sampleStepController = TextEditingController(text: '0.00035');
  String sampleDirection = 'mixed';
  String samplePreset = 'strong_bullish';

  final candlesJsonController = TextEditingController(
    text: '''
[
  {
    "time": "2026-07-01T10:15:00Z",
    "open": 1.08410,
    "high": 1.08440,
    "low": 1.08390,
    "close": 1.08422
  },
  {
    "time": "2026-07-01T10:16:00Z",
    "open": 1.08422,
    "high": 1.08455,
    "low": 1.08400,
    "close": 1.08450
  }
]
''',
  );

  bool loadingPair = false;
  bool loadingCandles = false;
  bool loadingFullTest = false;
  bool loadingMultiPack = false;
  String responseText = 'Ready.';

  List<BenchmarkResultItem> benchmarkResults = [];
  String? benchmarkBaseSymbol;
  String? benchmarkTimeframe;

  void clearBenchmarkTable() {
    benchmarkResults = [];
    benchmarkBaseSymbol = null;
    benchmarkTimeframe = null;
  }

  Color signalColor(String? signal) {
    switch ((signal ?? '').toUpperCase()) {
      case 'CALL':
        return AppColors.green;
      case 'PUT':
        return AppColors.red;
      case 'NEUTRAL':
        return AppColors.yellow;
      default:
        return AppColors.gray;
    }
  }

  Future<void> pushPairStat() async {
    setState(() {
      loadingPair = true;
      responseText = 'Pushing pair stat...';
      clearBenchmarkTable();
    });

    try {
      final result = await TradingApi.pushOtcPairStat(
        adminToken: tokenController.text.trim(),
        symbol: pairSymbolController.text.trim(),
        label: pairLabelController.text.trim(),
        profit1m: int.tryParse(pairProfit1mController.text.trim()) ?? 0,
        profit5m: int.tryParse(pairProfit5mController.text.trim()) ?? 0,
        change: double.tryParse(pairChangeController.text.trim()) ?? 0.0,
        price: double.tryParse(pairPriceController.text.trim()) ?? 0.0,
      );

      setState(() {
        responseText = const JsonEncoder.withIndent('  ').convert(result);
      });
    } catch (e) {
      setState(() {
        responseText = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          loadingPair = false;
        });
      }
    }
  }

  Future<void> pushCandles() async {
    setState(() {
      loadingCandles = true;
      responseText = 'Pushing candles...';
      clearBenchmarkTable();
    });

    try {
      final decoded = jsonDecode(candlesJsonController.text);
      if (decoded is! List) {
        throw Exception('Candles JSON must be a list.');
      }

      final candles = decoded.map<Map<String, dynamic>>((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return {
          "time": m["time"],
          "open": m["open"],
          "high": m["high"],
          "low": m["low"],
          "close": m["close"],
        };
      }).toList();

      final result = await TradingApi.pushOtcCandles(
        adminToken: tokenController.text.trim(),
        symbol: candleSymbolController.text.trim(),
        timeframe: candleTimeframeController.text.trim(),
        candles: candles,
      );

      setState(() {
        responseText = const JsonEncoder.withIndent('  ').convert(result);
      });
    } catch (e) {
      setState(() {
        responseText = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          loadingCandles = false;
        });
      }
    }
  }

  void fillSampleCandles() {
    candlesJsonController.text = '''
[
  {
    "time": "2026-07-01T10:15:00Z",
    "open": 1.08410,
    "high": 1.08440,
    "low": 1.08390,
    "close": 1.08422
  },
  {
    "time": "2026-07-01T10:16:00Z",
    "open": 1.08422,
    "high": 1.08455,
    "low": 1.08400,
    "close": 1.08450
  },
  {
    "time": "2026-07-01T10:17:00Z",
    "open": 1.08450,
    "high": 1.08472,
    "low": 1.08418,
    "close": 1.08430
  }
]
''';
    setState(() {});
  }

  Map<String, dynamic> _makeCandle({
    required DateTime time,
    required double open,
    required double close,
    required double wickSize,
    required Random random,
  }) {
    final high = max(open, close) + random.nextDouble() * wickSize;
    final low = min(open, close) - random.nextDouble() * wickSize;

    return {
      "time": time.toIso8601String().replaceFirst('.000', '') + "Z",
      "open": double.parse(open.toStringAsFixed(5)),
      "high": double.parse(high.toStringAsFixed(5)),
      "low": double.parse(low.toStringAsFixed(5)),
      "close": double.parse(close.toStringAsFixed(5)),
    };
  }

  List<Map<String, dynamic>> buildPresetCandles({String? presetOverride}) {
    final random = Random();

    final count = int.tryParse(sampleCountController.text.trim()) ?? 50;
    final startPrice =
        double.tryParse(sampleStartPriceController.text.trim()) ?? 1.08450;
    final step =
        double.tryParse(sampleStepController.text.trim()) ?? 0.00035;

    final tf = candleTimeframeController.text.trim().toLowerCase();
    final minutesPerCandle = tf == '5m' ? 5 : 1;

    final preset = presetOverride ?? samplePreset;

    DateTime startTime = DateTime.now().toUtc();
    startTime = DateTime.utc(
      startTime.year,
      startTime.month,
      startTime.day,
      startTime.hour,
      startTime.minute,
    ).subtract(Duration(minutes: count * minutesPerCandle));

    final candles = <Map<String, dynamic>>[];
    double price = startPrice;
    final anchor = startPrice;

    for (int i = 0; i < count; i++) {
      final candleTime = startTime.add(Duration(minutes: i * minutesPerCandle));
      final open = price;

      double drift = 0.0;
      double noise = 0.0;

      switch (preset) {
        case 'strong_bullish':
          drift = step * 0.8;
          if (i % 8 == 0) drift = -step * 0.2;
          noise = (random.nextDouble() - 0.5) * step * 0.8;
          break;

        case 'strong_bearish':
          drift = -step * 0.8;
          if (i % 8 == 0) drift = step * 0.2;
          noise = (random.nextDouble() - 0.5) * step * 0.8;
          break;

        case 'ranging':
          final distance = anchor - open;
          drift = distance * 0.25;
          noise = (random.nextDouble() - 0.5) * step * 1.8;
          break;

        case 'bullish_reversal':
          if (i < count * 0.35) {
            drift = -step * 0.7;
            noise = (random.nextDouble() - 0.5) * step * 0.7;
          } else if (i < count * 0.55) {
            drift = (random.nextDouble() - 0.5) * step * 0.3;
            noise = (random.nextDouble() - 0.5) * step * 0.9;
          } else {
            drift = step * 0.9;
            noise = (random.nextDouble() - 0.5) * step * 0.7;
          }
          break;

        case 'bearish_reversal':
          if (i < count * 0.35) {
            drift = step * 0.7;
            noise = (random.nextDouble() - 0.5) * step * 0.7;
          } else if (i < count * 0.55) {
            drift = (random.nextDouble() - 0.5) * step * 0.3;
            noise = (random.nextDouble() - 0.5) * step * 0.9;
          } else {
            drift = -step * 0.9;
            noise = (random.nextDouble() - 0.5) * step * 0.7;
          }
          break;

        default:
          drift = 0.0;
          noise = (random.nextDouble() - 0.5) * step * 1.2;
      }

      final close = open + drift + noise;

      final high = max(open, close) + random.nextDouble() * step * 0.9;
      final low = min(open, close) - random.nextDouble() * step * 0.9;

      candles.add({
        "time": candleTime.toIso8601String().replaceFirst('.000', '') + "Z",
        "open": double.parse(open.toStringAsFixed(5)),
        "high": double.parse(high.toStringAsFixed(5)),
        "low": double.parse(low.toStringAsFixed(5)),
        "close": double.parse(close.toStringAsFixed(5)),
      });

      price = close;
    }

    return candles;
  }

  void generatePresetCandles() {
    final candles = buildPresetCandles();

    candlesJsonController.text =
        const JsonEncoder.withIndent('  ').convert(candles);

    if (candles.isNotEmpty) {
      final lastClose = (candles.last["close"] as num).toDouble();
      pairPriceController.text = lastClose.toStringAsFixed(5);
    }

    setState(() {
      responseText =
          'Generated ${candles.length} preset candles for "$samplePreset".';
    });
  }

  Future<void> runFullOtcTest() async {
    setState(() {
      loadingFullTest = true;
      responseText = 'Running full OTC test...';
      clearBenchmarkTable();
    });

    try {
      final token = tokenController.text.trim();

      if (token.isEmpty) {
        throw Exception('Admin token is required.');
      }

      final pairSymbol = pairSymbolController.text.trim();
      final pairLabel = pairLabelController.text.trim();

      final candleSymbol = candleSymbolController.text.trim();
      final timeframe = candleTimeframeController.text.trim();

      if (pairSymbol.isEmpty || candleSymbol.isEmpty) {
        throw Exception('Both pair symbol and candle symbol are required.');
      }

      // generate candles automatically
      final candles = buildPresetCandles();
      candlesJsonController.text =
          const JsonEncoder.withIndent('  ').convert(candles);

      // push pair stat
      final pairResult = await TradingApi.pushOtcPairStat(
        adminToken: token,
        symbol: pairSymbol,
        label: pairLabel,
        profit1m: int.tryParse(pairProfit1mController.text.trim()) ?? 0,
        profit5m: int.tryParse(pairProfit5mController.text.trim()) ?? 0,
        change: double.tryParse(pairChangeController.text.trim()) ?? 0.0,
        price: double.tryParse(pairPriceController.text.trim()) ?? 0.0,
      );

      // push candles
      final candleResult = await TradingApi.pushOtcCandles(
        adminToken: token,
        symbol: candleSymbol,
        timeframe: timeframe,
        candles: candles,
      );

      // fetch signal
      final signalResult = await TradingApi.getSignal(
        marketType: 'OTC',
        symbol: candleSymbol,
        timeframe: timeframe,
      );

      final combined = {
        "step_1_push_pair": pairResult,
        "step_2_push_candles": candleResult,
        "step_3_signal_result": signalResult,
      };

      setState(() {
        responseText = const JsonEncoder.withIndent('  ').convert(combined);
      });
    } catch (e) {
      setState(() {
        responseText = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          loadingFullTest = false;
        });
      }
    }
  }

  String presetLabel(String key) {
    switch (key) {
      case 'strong_bullish':
        return 'Strong Bullish Trend';
      case 'strong_bearish':
        return 'Strong Bearish Trend';
      case 'ranging':
        return 'Ranging Market';
      case 'bullish_reversal':
        return 'Bullish Reversal';
      case 'bearish_reversal':
        return 'Bearish Reversal';
      default:
        return key;
    }
  }

  String buildBenchmarkSymbol(String baseSymbol, String preset) {
    final cleaned = baseSymbol.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
    return '${cleaned}__${preset}';
  }

  Future<void> runMultiPackBenchmark() async {
    setState(() {
      loadingMultiPack = true;
      responseText = 'Running multi-pack benchmark...';
    });

    try {
      final token = tokenController.text.trim();
      if (token.isEmpty) {
        throw Exception('Admin token is required.');
      }

      final basePairSymbol = pairSymbolController.text.trim();
      final basePairLabel = pairLabelController.text.trim();
      final timeframe = candleTimeframeController.text.trim();

      if (basePairSymbol.isEmpty) {
        throw Exception('Base pair symbol is required.');
      }

      final presets = [
        'strong_bullish',
        'strong_bearish',
        'ranging',
        'bullish_reversal',
        'bearish_reversal',
      ];

      final results = <Map<String, dynamic>>[];

      for (final preset in presets) {
        final benchmarkSymbol = buildBenchmarkSymbol(basePairSymbol, preset);
        final benchmarkLabel = '$basePairLabel • ${presetLabel(preset)}';

        try {
          final candles = buildPresetCandles(presetOverride: preset);
          final lastClose =
              (candles.isNotEmpty ? candles.last['close'] as num : 0).toDouble();

          await TradingApi.pushOtcPairStat(
            adminToken: token,
            symbol: benchmarkSymbol,
            label: benchmarkLabel,
            profit1m: int.tryParse(pairProfit1mController.text.trim()) ?? 0,
            profit5m: int.tryParse(pairProfit5mController.text.trim()) ?? 0,
            change: double.tryParse(pairChangeController.text.trim()) ?? 0.0,
            price: lastClose,
          );

          final pushCandlesResult = await TradingApi.pushOtcCandles(
            adminToken: token,
            symbol: benchmarkSymbol,
            timeframe: timeframe,
            candles: candles,
          );

          final signalResult = await TradingApi.getSignal(
            marketType: 'OTC',
            symbol: benchmarkSymbol,
            timeframe: timeframe,
          );

          results.add({
            "preset": preset,
            "preset_label": presetLabel(preset),
            "symbol": benchmarkSymbol,
            "push_candles": pushCandlesResult,
            "signal": signalResult["signal"],
            "confidence": signalResult["confidence"],
            "price": signalResult["price"],
            "recommended_expiry": signalResult["recommended_expiry"],
            "top_reasons": (signalResult["reason"] is List)
                ? (signalResult["reason"] as List).take(5).toList()
                : [],
            "patterns": signalResult["strategy"] is Map
                ? ((signalResult["strategy"]["detected_patterns"] as List?) ?? [])
                : [],
            "blends": signalResult["strategy"] is Map
                ? ((signalResult["strategy"]["detected_blends"] as List?) ?? [])
                : [],
          });
        } catch (e) {
          results.add({
            "preset": preset,
            "preset_label": presetLabel(preset),
            "symbol": benchmarkSymbol,
            "error": e.toString(),
          });
        }
      }

      final summary = {
        "base_symbol": basePairSymbol,
        "timeframe": timeframe,
        "count": results.length,
        "results": results,
      };

      setState(() {
        benchmarkBaseSymbol = basePairSymbol;
        benchmarkTimeframe = timeframe;
        benchmarkResults = results
            .map((e) => BenchmarkResultItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();

        responseText = const JsonEncoder.withIndent('  ').convert(summary);
      });
    } catch (e) {
      setState(() {
        responseText = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          loadingMultiPack = false;
        });
      }
    }
  }

  @override
  void dispose() {
    tokenController.dispose();
    pairSymbolController.dispose();
    pairLabelController.dispose();
    pairProfit1mController.dispose();
    pairProfit5mController.dispose();
    pairChangeController.dispose();
    pairPriceController.dispose();
    candleSymbolController.dispose();
    candleTimeframeController.dispose();
    sampleCountController.dispose();
    sampleStartPriceController.dispose();
    sampleStepController.dispose();
    candlesJsonController.dispose();
    super.dispose();
  }

  Widget field(String label, TextEditingController controller,
      {int maxLines = 1, TextInputType? keyboardType}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppColors.gray)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF0B0F14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.card,
        title: const Text('OTC Admin Tools', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          NeonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Admin Token', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                const SizedBox(height: 12),
                field('X-Admin-Token', tokenController),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (benchmarkResults.isNotEmpty) ...[
            BenchmarkResultsTable(
              baseSymbol: benchmarkBaseSymbol,
              timeframe: benchmarkTimeframe,
              results: benchmarkResults,
            ),
            const SizedBox(height: 18),
          ],
          NeonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Push Pair Stat', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                const SizedBox(height: 12),
                field('Symbol', pairSymbolController),
                const SizedBox(height: 12),
                field('Label', pairLabelController),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: field(
                        'Profit 1m %',
                        pairProfit1mController,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: field(
                        'Profit 5m %',
                        pairProfit5mController,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: field(
                        'Change %',
                        pairChangeController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: field(
                        'Price',
                        pairPriceController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                NeonButton(
                  title: loadingPair ? 'PUSHING...' : 'PUSH PAIR STAT',
                  icon: Icons.upload,
                  color: AppColors.yellow,
                  onTap: loadingPair ? () {} : pushPairStat,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (benchmarkResults.isNotEmpty) ...[
            BenchmarkResultsTable(
              baseSymbol: benchmarkBaseSymbol,
              timeframe: benchmarkTimeframe,
              results: benchmarkResults,
            ),
            const SizedBox(height: 18),
          ],
          NeonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Push Candles JSON', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                const SizedBox(height: 12),
                field('Symbol', candleSymbolController),
                const SizedBox(height: 12),
                field('Timeframe', candleTimeframeController),
                const SizedBox(height: 16),
                const Text('Generate Sample Candles',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B0F14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButton<String>(
                    value: samplePreset,
                    dropdownColor: const Color(0xFF0B0F14),
                    isExpanded: true,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(
                        value: 'strong_bullish',
                        child: Text('Strong Bullish Trend'),
                      ),
                      DropdownMenuItem(
                        value: 'strong_bearish',
                        child: Text('Strong Bearish Trend'),
                      ),
                      DropdownMenuItem(
                        value: 'ranging',
                        child: Text('Ranging Market'),
                      ),
                      DropdownMenuItem(
                        value: 'bullish_reversal',
                        child: Text('Bullish Reversal'),
                      ),
                      DropdownMenuItem(
                        value: 'bearish_reversal',
                        child: Text('Bearish Reversal'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() {
                          samplePreset = v;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: field(
                        'Count',
                        sampleCountController,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: field(
                        'Start Price',
                        sampleStartPriceController,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: field(
                        'Step Size',
                        sampleStepController,
                        keyboardType:
                            const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: NeonButton(
                        title: 'GENERATE PRESET PACK',
                        icon: Icons.bolt,
                        color: Colors.orangeAccent,
                        onTap: generatePresetCandles,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                field('Candles JSON', candlesJsonController, maxLines: 12),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: NeonButton(
                        title: 'FILL BASIC SAMPLE',
                        icon: Icons.auto_fix_high,
                        color: AppColors.cyan,
                        onTap: fillSampleCandles,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: NeonButton(
                        title: loadingCandles ? 'PUSHING...' : 'PUSH CANDLES',
                        icon: Icons.cloud_upload,
                        color: AppColors.green,
                        onTap: loadingCandles ? () {} : pushCandles,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                NeonButton(
                  title: loadingFullTest ? 'RUNNING FULL TEST...' : 'RUN FULL OTC TEST',
                  icon: Icons.science,
                  color: Colors.purpleAccent,
                  onTap: loadingFullTest ? () {} : runFullOtcTest,
                ),
                const SizedBox(height: 12),
                NeonButton(
                  title: loadingMultiPack ? 'RUNNING BENCHMARK...' : 'RUN MULTI-PACK BENCHMARK',
                  icon: Icons.analytics,
                  color: Colors.deepOrangeAccent,
                  onTap: loadingMultiPack ? () {} : runMultiPackBenchmark,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (benchmarkResults.isNotEmpty) ...[
            BenchmarkResultsTable(
              baseSymbol: benchmarkBaseSymbol,
              timeframe: benchmarkTimeframe,
              results: benchmarkResults,
            ),
            const SizedBox(height: 18),
          ],
          NeonCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Response', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    responseText,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

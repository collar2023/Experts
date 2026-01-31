#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Flask服务 - 指数信号中转站 v5.5 (SQLite 物理隔离版)
架构: 黄金/外汇同款内核 (WAL并发 | DB锁去重 | 自动维护)
配置: 严格保留原版指数映射 & 日志命名
"""

import os
import json
import logging
import time
import threading
import tempfile
import sqlite3
import random
from datetime import datetime, timedelta
from flask import Flask, request, jsonify
from logging.handlers import RotatingFileHandler

# --- 1. 配置加载 (优先环境变量) ---
API_TOKEN = os.environ.get('API_TOKEN', '')

# ✅ [修正] 严格保持与您原始代码一致 (指数专用映射)
DEFAULT_SYMBOL_MAP = {
    "USTEC": "USTECm",
    "JP225": "JP225m",
    "UK100": "UK100m",
    "GER40": "DE30m",
    "HK50": "HK50m"
}

try:
    env_map = os.environ.get('SYMBOL_MAP')
    SYMBOL_MAP = json.loads(env_map) if env_map else DEFAULT_SYMBOL_MAP
except Exception as e:
    print(f"⚠️ 环境变量 SYMBOL_MAP 解析失败，使用默认配置: {e}")
    SYMBOL_MAP = DEFAULT_SYMBOL_MAP

# --- 2. 日志配置 (自动切割) ---
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_DIR = os.path.join(BASE_DIR, 'logs')
os.makedirs(LOG_DIR, exist_ok=True)

# ✅ [保留] 保持您原有的日志文件名
log_file_path = os.path.join(LOG_DIR, 'index_signal_hub.log')

file_handler = RotatingFileHandler(log_file_path, maxBytes=10*1024*1024, backupCount=5)
file_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))
stream_handler = logging.StreamHandler()
stream_handler.setFormatter(logging.Formatter('%(asctime)s - %(levelname)s - %(message)s'))

if not logging.getLogger().hasHandlers():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO").upper(), handlers=[file_handler, stream_handler])
logger = logging.getLogger(__name__)

# --- 3. 核心存储 (物理隔离) ---
SIGNAL_FILE = os.path.join(BASE_DIR, 'latest_signal.json')
DB_FILE = os.path.join(BASE_DIR, 'trade_history.db')
file_lock = threading.Lock()

app = Flask(__name__)

# --- SQLite 核心逻辑 (与黄金/外汇版完全对齐) ---

def get_db_conn():
    """获取连接并开启 WAL 高并发模式"""
    conn = sqlite3.connect(DB_FILE, timeout=10.0)
    conn.execute('PRAGMA journal_mode=WAL')      # ✅ 开启 WAL
    conn.execute('PRAGMA synchronous=NORMAL')
    return conn

def init_db():
    try:
        with get_db_conn() as conn:
            cursor = conn.cursor()
            cursor.execute('''
                CREATE TABLE IF NOT EXISTS signals (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    signal_id TEXT UNIQUE,
                    symbol TEXT,
                    side TEXT,
                    qty REAL,
                    raw_payload TEXT,
                    client_ip TEXT,
                    received_at DATETIME DEFAULT CURRENT_TIMESTAMP
                )
            ''')
            cursor.execute('CREATE INDEX IF NOT EXISTS idx_signal_id ON signals(signal_id)')
            conn.commit()
            logger.info("✅ SQLite (指数版) 初始化完成 (WAL模式)")
    except Exception as e:
        logger.error(f"❌ 数据库初始化失败: {e}")

def schedule_cleanup():
    """✅ 自动吸尘器: 每日凌晨3点清理30天前数据"""
    # 随机等待避免多服务同时启动竞争
    time.sleep(random.randint(1, 10)) 
    while True:
        try:
            now = datetime.now()
            next_run = now.replace(hour=3, minute=0, second=0, microsecond=0)
            if next_run <= now: next_run += timedelta(days=1)
            
            wait_seconds = (next_run - now).total_seconds()
            logger.info(f"⏰ 下次清理将在 {wait_seconds/3600:.1f} 小时后执行")
            time.sleep(wait_seconds)
            
            # 执行清理
            cutoff = (datetime.now() - timedelta(days=30)).strftime('%Y-%m-%d %H:%M:%S')
            with get_db_conn() as conn:
                conn.execute('DELETE FROM signals WHERE received_at < ?', (cutoff,))
                conn.commit()
            logger.info("🧹 历史数据清理完成")
            time.sleep(60)
        except Exception as e:
            logger.error(f"清理任务出错: {e}")
            time.sleep(300)

# 初始化 DB 和 调度器
init_db()
threading.Thread(target=schedule_cleanup, daemon=True).start()

def is_signal_duplicate(signal_id):
    """持久化去重查询"""
    try:
        with get_db_conn() as conn:
            cursor = conn.cursor()
            cursor.execute('SELECT 1 FROM signals WHERE signal_id = ? LIMIT 1', (signal_id,))
            return cursor.fetchone() is not None
    except Exception as e:
        logger.error(f"⚠️ 去重查询失败: {e}")
        return False

def log_signal_sync(signal_data, client_ip):
    """同步写入 DB (作为逻辑锁)"""
    try:
        with get_db_conn() as conn:
            conn.execute('''
                INSERT OR IGNORE INTO signals (signal_id, symbol, side, qty, raw_payload, client_ip)
                VALUES (?, ?, ?, ?, ?, ?)
            ''', (
                signal_data['signal_id'],
                signal_data['symbol'],
                signal_data['side'],
                signal_data['qty'],
                json.dumps(signal_data),
                client_ip
            ))
            conn.commit()
            return True
    except Exception as e:
        logger.error(f"❌ DB同步写入失败: {e}")
        return False

# --- 4. 鉴权装饰器 ---
def require_token(f):
    def decorated(*args, **kwargs):
        if not API_TOKEN: return f(*args, **kwargs)
        req_token = request.args.get('token') or request.headers.get('X-API-Token')
        if req_token != API_TOKEN:
            real_ip = request.headers.get('X-Real-IP', request.remote_addr)
            logger.warning(f"⛔ 拦截非法IP: {real_ip}")
            return jsonify({'error': 'Unauthorized'}), 401
        return f(*args, **kwargs)
    decorated.__name__ = f.__name__
    return decorated

# --- Telegram (异步) ---
TELEGRAM_BOT_TOKEN = os.environ.get('TELEGRAM_BOT_TOKEN', '')
TELEGRAM_CHAT_ID = os.environ.get('TELEGRAM_CHAT_ID', '')

def send_telegram_message(message: str):
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID: return
    def _send():
        try:
            import httpx
            url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
            data = {'chat_id': TELEGRAM_CHAT_ID, 'text': message, 'parse_mode': 'HTML'}
            with httpx.Client() as client:
                client.post(url, data=data, timeout=10)
        except Exception as e:
            logger.error(f"TG发送失败: {e}")
    threading.Thread(target=_send).start()

# ===== 核心接口 =====

@app.route("/webhook", methods=["POST"])
@require_token
def webhook():
    try:
        data = request.get_json(force=True, silent=True)
        if not data: return jsonify({'error': 'Invalid JSON'}), 400

        original_symbol = data.get('symbol', '')
        side = data.get('side', '').lower()
        qty = float(data.get('qty', 0.0))
        
        translated_symbol = SYMBOL_MAP.get(original_symbol.upper(), original_symbol)
        
        if not all([translated_symbol, side in ['buy', 'sell'], qty > 0]):
            return jsonify({'error': 'Invalid parameters'}), 400

        current_timestamp = int(time.time())
        signal_id = f"{translated_symbol}_{side}_{current_timestamp}"
        
        # 1. ✅ DB 去重 (同步 - 架构对齐)
        if is_signal_duplicate(signal_id):
            logger.warning(f"🔁 拦截重复指数信号: {signal_id}")
            return jsonify({'status': 'duplicate', 'signal_id': signal_id}), 409
        
        signal_payload = {
            "signal_id": signal_id,
            "timestamp": current_timestamp,
            "symbol": translated_symbol,
            "side": side,
            "order_type": "market",
            "qty": qty
        }

        # 2. ✅ DB 写入 (构建事实锁 - 架构对齐)
        client_ip = request.headers.get('X-Real-IP', request.remote_addr)
        db_success = log_signal_sync(signal_payload, client_ip)
        
        if not db_success:
            logger.warning("⚠️ DB 写入失败，启动降级模式 (磁盘优先)")

        # 3. ✅ 磁盘写入 (业务核心 - 架构对齐)
        with file_lock:
            try:
                temp_fd, temp_path = tempfile.mkstemp(suffix='.json', dir=BASE_DIR)
                with os.fdopen(temp_fd, 'w') as f:
                    json.dump(signal_payload, f, indent=4)
                os.replace(temp_path, SIGNAL_FILE)
            except Exception as e:
                logger.critical(f"❌ 磁盘写入失败: {e}")
                return jsonify({'error': 'Storage failed'}), 500

        logger.info(f"✅ 指数信号发布: {signal_id}")
        
        dt_str = datetime.now().strftime("%H:%M:%S")
        send_telegram_message(
            f"📊 <b>指数指令</b>\n{translated_symbol} | {side.upper()} | {qty}\nID: {signal_id}\n⏰ {dt_str}"
        )
        return jsonify({'status': 'published', 'data': signal_payload}), 200

    except Exception as e:
        logger.error(f"Webhook Error: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500

@app.route("/get_signal", methods=["GET"])
@require_token
def get_signal():
    try:
        if os.path.exists(SIGNAL_FILE):
            with open(SIGNAL_FILE, 'r') as f:
                return jsonify(json.load(f))
    except Exception as e:
        logger.error(f"读取信号文件失败: {e}")
    return jsonify({"error": "No signal available"}), 404

@app.route("/health")
def health():
    return jsonify({
        "status": "ok", 
        "version": "5.5-indices-pro",
        "wal_mode": True,
        "mapped_symbols": len(SYMBOL_MAP)
    })

if __name__ == "__main__":
    app.run(debug=False, host='0.0.0.0', port=80)

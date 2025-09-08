#!/bin/bash
set -e

APP_DIR="/opt/singbox-ping"
SERVICE_FILE="/etc/systemd/system/singbox-ping.service"
LOG_FILE="/var/log/singbox-ping.log"

# تابع توقف سرویس
stop_service() {
    echo "🛑 توقف سرویس SingBox Ping Panel..."
    if systemctl is-active --quiet singbox-ping; then
        sudo systemctl stop singbox-ping
        echo "✅ سرویس متوقف شد"
    fi
    
    if systemctl is-enabled --quiet singbox-ping; then
        sudo systemctl disable singbox-ping
        echo "✅ سرویس غیرفعال شد"
    fi
    
    echo "🧹 پاک‌سازی فایل‌ها..."
    sudo rm -rf $APP_DIR
    sudo rm -f $SERVICE_FILE
    sudo rm -rf /var/www/singbox-ping
    
    sudo systemctl daemon-reload
    echo "✅ پاک‌سازی کامل شد"
}

# بررسی پارامتر
if [ "$1" = "stop" ]; then
    stop_service
    exit 0
fi

echo "🚀 شروع نصب SingBox Ping Panel..."
echo "=================================================="

# 1. نصب پیش‌نیازها
echo "[+] بررسی و نصب Python3"
if ! command -v python3 &>/dev/null; then
    sudo apt update
    sudo apt install -y python3 python3-pip curl wget tar
fi

echo "[+] نصب کتابخانه‌های پایتون"
sudo apt install -y python3-venv python3-pip

# ساخت محیط مجازی
sudo mkdir -p $APP_DIR
sudo python3 -m venv $APP_DIR/venv
sudo $APP_DIR/venv/bin/pip install flask requests

# 2. نصب Sing-Box
echo "[+] بررسی و نصب Sing-Box"
if ! command -v sing-box &>/dev/null; then
    cd /tmp
    curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
    | grep "browser_download_url.*linux-amd64.tar.gz" \
    | cut -d '"' -f 4 \
    | wget -i -
    
    tar -xzf sing-box-*-linux-amd64.tar.gz
    cd sing-box-*-linux-amd64
    sudo mv sing-box /usr/local/bin/
    cd ..
    rm -rf sing-box-*
fi

# 3. ساخت مسیر پروژه
echo "[+] ساخت مسیر پروژه"
sudo mkdir -p /var/www/singbox-ping
sudo touch $LOG_FILE
sudo chmod 666 $LOG_FILE

# 4. ساخت ping_api.py
echo "[+] ساخت ping_api.py"
cat <<'EOF' | sudo tee $APP_DIR/ping_api.py > /dev/null
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import http.server
import socketserver
import urllib.parse
import json
import subprocess
import socket
import time
import tempfile
import os
import threading
import logging
from datetime import datetime
import hashlib
import concurrent.futures

# تنظیم logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/singbox-ping.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

class SingBoxPingAPI:
    def __init__(self):
        self.singbox_available = self.check_singbox()
        self.results_cache = {}
        self.processing_configs = set()
        self.lock = threading.Lock()
        logger.info(f"SingBox وضعیت: {'موجود' if self.singbox_available else 'غیرموجود'}")
        
    def check_singbox(self):
        """بررسی Sing-Box"""
        try:
            result = subprocess.run(["sing-box", "version"], capture_output=True, timeout=5)
            return result.returncode == 0
        except:
            return False
    
    def get_config_id(self, config_data):
        """ایجاد ID برای کانفیگ"""
        config_str = json.dumps(config_data, sort_keys=True)
        return hashlib.md5(config_str.encode()).hexdigest()[:8]
    
    def extract_outbounds(self, config):
        """استخراج outboundهای قابل تست"""
        outbounds = []
        if not config or 'outbounds' not in config:
            return outbounds
        
        for outbound in config['outbounds']:
            # فقط outboundهای پروکسی را تست کنیم
            if (outbound.get('type') in ['vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria', 'hysteria2'] 
                and 'server' in outbound):
                outbounds.append({
                    'tag': outbound.get('tag', 'Unknown'),
                    'type': outbound.get('type'),
                    'server': outbound.get('server'),
                    'port': outbound.get('server_port', 443),
                    'config': outbound
                })
        return outbounds
    
    def tcp_ping(self, server_info):
        """تست TCP ساده"""
        try:
            start = time.time()
            sock = socket.create_connection((server_info['server'], server_info['port']), timeout=3)
            sock.close()
            ping_ms = (time.time() - start) * 1000
            return {
                'status': 'success',
                'ping': round(ping_ms),
                'message': 'TCP Connection OK'
            }
        except Exception as e:
            return {
                'status': 'failed',
                'ping': 0,
                'message': f'TCP Error: {str(e)}'
            }
    
    def real_ping_test(self, server_info):
        """تست واقعی با Sing-Box"""
        if not self.singbox_available:
            return self.tcp_ping(server_info)
        
        test_port = 7000 + (hash(server_info['tag']) % 1000)
        
        # کانفیگ تست
        test_config = {
            "log": {"level": "error"},
            "inbounds": [{
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": test_port
            }],
            "outbounds": [
                server_info['config'],
                {"type": "direct", "tag": "direct"}
            ],
            "route": {
                "rules": [{"outbound": "direct", "network": ["udp"], "port": [53]}],
                "final": server_info['config'].get('tag', 'proxy')
            }
        }
        
        temp_file = None
        process = None
        
        try:
            # ایجاد فایل موقت
            with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
                json.dump(test_config, f, indent=2)
                temp_file = f.name
            
            # اجرای Sing-Box
            process = subprocess.Popen([
                "sing-box", "run", "-c", temp_file
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            
            time.sleep(2)  # صبر برای راه‌اندازی
            
            # تست اتصال
            start_time = time.time()
            
            try:
                # تست HTTP
                import urllib.request
                req = urllib.request.Request("http://httpbin.org/ip")
                req.set_proxy(f'127.0.0.1:{test_port}', 'http')
                
                with urllib.request.urlopen(req, timeout=8) as response:
                    if response.getcode() == 200:
                        ping_time = (time.time() - start_time) * 1000
                        return {
                            'status': 'success',
                            'ping': round(ping_time),
                            'message': 'Real Connection OK'
                        }
            except Exception as e:
                return {
                    'status': 'failed',
                    'ping': 0,
                    'message': f'Real Test Failed: {str(e)}'
                }
            
            return {
                'status': 'failed',
                'ping': 0,
                'message': 'Connection timeout'
            }
            
        except Exception as e:
            return {
                'status': 'failed',
                'ping': 0,
                'message': f'Test Error: {str(e)}'
            }
        finally:
            # پاک‌سازی
            if process:
                try:
                    process.terminate()
                    process.wait(timeout=3)
                except:
                    try:
                        process.kill()
                    except:
                        pass
            if temp_file:
                try:
                    os.unlink(temp_file)
                except:
                    pass
    
    def test_config(self, config_data, test_type="real"):
        """تست کامل کانفیگ"""
        config_id = self.get_config_id(config_data)
        
        try:
            self.processing_configs.add(config_id)
            
            # وضعیت اولیه
            initial_status = {
                'config_id': config_id,
                'status': 'processing',
                'message': 'در حال استخراج outboundها...',
                'progress': 0,
                'total_outbounds': 0,
                'tested_outbounds': 0,
                'working_outbounds': 0,
                'failed_outbounds': 0,
                'timestamp': datetime.now().isoformat(),
                'results': []
            }
            self.results_cache[config_id] = initial_status
            
            # استخراج outboundها
            outbounds = self.extract_outbounds(config_data)
            if not outbounds:
                result = {
                    'config_id': config_id,
                    'status': 'error',
                    'message': 'هیچ outbound قابل تستی یافت نشد',
                    'timestamp': datetime.now().isoformat()
                }
                self.results_cache[config_id] = result
                return result
            
            # آپدیت وضعیت
            self.results_cache[config_id].update({
                'message': f'در حال تست {len(outbounds)} outbound...',
                'total_outbounds': len(outbounds),
                'progress': 0
            })
            
            # تست outboundها
            results = []
            tested_count = 0
            working_count = 0
            failed_count = 0
            
            def test_outbound(outbound):
                if test_type == "real":
                    return self.real_ping_test(outbound)
                else:
                    return self.tcp_ping(outbound)
            
            def handle_result(outbound, test_result):
                nonlocal tested_count, working_count, failed_count
                with self.lock:
                    tested_count += 1
                    
                    result_item = {
                        'tag': outbound['tag'],
                        'type': outbound['type'],
                        'server': outbound['server'],
                        'port': outbound['port'],
                        'status': test_result['status'],
                        'ping': test_result['ping'],
                        'message': test_result['message']
                    }
                    
                    if test_result['status'] == 'success':
                        working_count += 1
                    else:
                        failed_count += 1
                    
                    results.append(result_item)
                    
                    progress = round((tested_count / len(outbounds)) * 100, 1)
                    self.results_cache[config_id].update({
                        'message': f'پیشرفت: {tested_count}/{len(outbounds)}',
                        'progress': progress,
                        'tested_outbounds': tested_count,
                        'working_outbounds': working_count,
                        'failed_outbounds': failed_count,
                        'results': sorted(results, key=lambda x: x['ping'], reverse=True)
                    })
            
            # تست موازی
            with concurrent.futures.ThreadPoolExecutor(max_workers=5) as executor:
                future_to_outbound = {
                    executor.submit(test_outbound, outbound): outbound 
                    for outbound in outbounds
                }
                
                for future in concurrent.futures.as_completed(future_to_outbound):
                    outbound = future_to_outbound[future]
                    try:
                        test_result = future.result()
                    except Exception as e:
                        test_result = {
                            'status': 'failed',
                            'ping': 0,
                            'message': f'Test Exception: {str(e)}'
                        }
                    handle_result(outbound, test_result)
            
            # نتیجه نهایی
            final_result = {
                'config_id': config_id,
                'status': 'completed',
                'test_type': test_type.upper(),
                'total_outbounds': len(outbounds),
                'working_outbounds': working_count,
                'failed_outbounds': failed_count,
                'success_rate': round((working_count / len(outbounds)) * 100, 1),
                'timestamp': datetime.now().isoformat(),
                'results': sorted(results, key=lambda x: x['ping'] if x['status'] == 'success' else 9999)
            }
            
            self.results_cache[config_id] = final_result
            return final_result
            
        except Exception as e:
            result = {
                'config_id': config_id,
                'status': 'error',
                'message': f'خطا در تست: {str(e)}',
                'timestamp': datetime.now().isoformat()
            }
            self.results_cache[config_id] = result
            return result
        finally:
            self.processing_configs.discard(config_id)

# ایجاد instance
api = SingBoxPingAPI()

class PingHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        logger.info(f"{self.address_string()} - {format % args}")
    
    def do_POST(self):
        """مدیریت POST requests"""
        if self.path == '/test_config':
            try:
                content_length = int(self.headers['Content-Length'])
                post_data = self.rfile.read(content_length)
                
                try:
                    data = json.loads(post_data.decode('utf-8'))
                except json.JSONDecodeError:
                    self.send_json_response({'error': 'فرمت JSON نامعتبر'}, 400)
                    return
                
                config_data = data.get('config')
                test_type = data.get('test_type', 'real')
                
                if not config_data:
                    self.send_json_response({'error': 'کانفیگ ارسال نشده'}, 400)
                    return
                
                config_id = api.get_config_id(config_data)
                
                # اگر در حال پردازش است
                if config_id in api.processing_configs:
                    self.send_json_response({
                        'status': 'processing',
                        'config_id': config_id,
                        'message': 'در حال پردازش...',
                        'check_url': f'/status?id={config_id}'
                    })
                    return
                
                # اگر نتیجه موجود است
                if config_id in api.results_cache:
                    self.send_json_response(api.results_cache[config_id])
                    return
                
                # شروع تست در background
                def test_in_background():
                    api.test_config(config_data, test_type)
                
                thread = threading.Thread(target=test_in_background, daemon=True)
                thread.start()
                
                self.send_json_response({
                    'status': 'started',
                    'config_id': config_id,
                    'message': 'تست شروع شد',
                    'check_url': f'/status?id={config_id}'
                })
                
            except Exception as e:
                logger.error(f"خطا در POST: {e}")
                self.send_json_response({'error': f'خطای سرور: {str(e)}'}, 500)
        else:
            self.send_error(404)
    
    def do_GET(self):
        """مدیریت GET requests"""
        parsed_path = urllib.parse.urlparse(self.path)
        path = parsed_path.path
        query = urllib.parse.parse_qs(parsed_path.query)
        
        # وضعیت تست
        if path == '/status':
            config_id = query.get('id', [None])[0]
            
            if not config_id:
                self.send_json_response({'error': 'پارامتر id الزامی است'}, 400)
                return
            
            if config_id in api.processing_configs:
                if config_id in api.results_cache:
                    result = api.results_cache[config_id]
                    self.send_json_response(result)
                else:
                    self.send_json_response({
                        'status': 'processing',
                        'config_id': config_id,
                        'message': 'در حال شروع پردازش...'
                    })
            elif config_id in api.results_cache:
                self.send_json_response(api.results_cache[config_id])
            else:
                self.send_json_response({
                    'error': 'تست یافت نشد',
                    'config_id': config_id
                }, 404)
        
        # لیست همه تست‌ها
        elif path == '/list':
            tests = []
            for config_id, result in api.results_cache.items():
                tests.append({
                    'config_id': config_id,
                    'status': result.get('status'),
                    'working_outbounds': result.get('working_outbounds', 0),
                    'total_outbounds': result.get('total_outbounds', 0),
                    'success_rate': result.get('success_rate', 0),
                    'timestamp': result.get('timestamp')
                })
            
            self.send_json_response({
                'total_tests': len(tests),
                'tests': sorted(tests, key=lambda x: x.get('timestamp', ''), reverse=True)
            })
        
        # API info
        elif path == '/info':
            self.send_json_response({
                'service': 'SingBox Ping Test Panel',
                'version': '1.0',
                'singbox_available': api.singbox_available,
                'endpoints': {
                    'test_config': 'POST /test_config',
                    'status': 'GET /status?id=CONFIG_ID',
                    'list': 'GET /list',
                    'panel': 'GET /'
                }
            })
        
        else:
            # سرو فایل‌های استاتیک
            if path == '/' or path == '/index.html':
                try:
                    with open('/var/www/singbox-ping/index.html', 'rb') as f:
                        self.send_response(200)
                        self.send_header('Content-type', 'text/html; charset=utf-8')
                        self.end_headers()
                        self.wfile.write(f.read())
                except:
                    self.send_error(404)
            else:
                self.send_error(404)
    
    def send_json_response(self, data, status_code=200):
        """ارسال پاسخ JSON"""
        try:
            self.send_response(status_code)
            self.send_header('Content-type', 'application/json; charset=utf-8')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.end_headers()
            
            json_data = json.dumps(data, ensure_ascii=False, indent=2)
            self.wfile.write(json_data.encode('utf-8'))
        except Exception as e:
            logger.error(f"خطا در ارسال JSON: {e}")

def main():
    try:
        logger.info("شروع SingBox Ping Panel")
        print("🚀 SingBox Ping Test Panel")
        print("=" * 50)
        print(f"✅ Sing-Box: {'موجود' if api.singbox_available else 'غیرموجود (فقط TCP)'}")
        print("=" * 50)
        print("🌐 Panel در حال اجرا روی:")
        print("   http://localhost:8080")
        print("   http://0.0.0.0:8080")
        print("=" * 50)
        print("📋 API Endpoints:")
        print("   POST /test_config - تست کانفیگ")
        print("   GET /status?id=CONFIG_ID - وضعیت تست")
        print("   GET /list - لیست تست‌ها")
        print("   GET / - پنل مدیریت")
        print("=" * 50)
        print("💡 برای توقف: Ctrl+C")
        print()
        
        port = 8080
        socketserver.TCPServer.allow_reuse_address = True
        
        with socketserver.TCPServer(("0.0.0.0", port), PingHandler) as httpd:
            logger.info("سرور آماده است")
            httpd.serve_forever()
            
    except KeyboardInterrupt:
        logger.info("سرور متوقف شد")
        print("\n👋 Panel متوقف شد")
    except Exception as e:
        logger.error(f"خطا: {e}")
        print(f"❌ خطا: {e}")

if __name__ == "__main__":
    main()
EOF

# 5. ساخت پنل HTML
echo "[+] ساخت پنل HTML"
cat <<'EOF' | sudo tee /var/www/singbox-ping/index.html > /dev/null
<!doctype html>
<html lang="fa" dir="rtl">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>SingBox Ping Test Panel</title>
  <style>
    body { 
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; 
      margin: 0; padding: 20px; 
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: #fff; min-height: 100vh;
    }
    .container { max-width: 1200px; margin: 0 auto; }
    .header { text-align: center; margin-bottom: 30px; }
    .header h1 { margin: 0; font-size: 2.5em; text-shadow: 2px 2px 4px rgba(0,0,0,0.3); }
    .header p { margin: 10px 0; opacity: 0.9; }
    
    .card { 
      background: rgba(255,255,255,0.1); 
      backdrop-filter: blur(10px);
      border: 1px solid rgba(255,255,255,0.2);
      border-radius: 15px; 
      padding: 25px; 
      margin-bottom: 20px;
      box-shadow: 0 8px 32px rgba(0,0,0,0.1);
    }
    
    .form-group { margin-bottom: 20px; }
    label { display: block; margin-bottom: 8px; font-weight: 600; }
    
    textarea, select, button { 
      width: 100%; 
      background: rgba(255,255,255,0.1); 
      color: #fff; 
      border: 1px solid rgba(255,255,255,0.3);
      border-radius: 8px; 
      padding: 12px; 
      font-size: 14px;
      transition: all 0.3s ease;
    }
    
    textarea { 
      min-height: 200px; 
      font-family: 'Courier New', monospace;
      resize: vertical;
    }
    
    textarea::placeholder { color: rgba(255,255,255,0.6); }
    
    textarea:focus, select:focus { 
      outline: none; 
      border-color: #4CAF50;
      box-shadow: 0 0 10px rgba(76,175,80,0.3);
    }
    
    button { 
      cursor: pointer; 
      font-weight: 600;
      background: linear-gradient(45deg, #4CAF50, #45a049);
      border: none;
      transition: all 0.3s ease;
    }
    
    button:hover { 
      transform: translateY(-2px);
      box-shadow: 0 5px 15px rgba(76,175,80,0.4);
    }
    
    button:disabled {
      background: rgba(255,255,255,0.2);
      cursor: not-allowed;
      transform: none;
      box-shadow: none;
    }
    
    .results { margin-top: 20px; }
    .outbound-result { 
      background: rgba(255,255,255,0.05); 
      border-radius: 8px; 
      padding: 15px; 
      margin-bottom: 10px;
      border-left: 4px solid;
    }
    
    .outbound-result.success { border-left-color: #4CAF50; }
    .outbound-result.failed { border-left-color: #f44336; }
    
    .outbound-header { 
      display: flex; 
      justify-content: space-between; 
      align-items: center; 
      margin-bottom: 8px;
    }
    
    .tag { font-weight: 600; font-size: 16px; }
    .ping { 
      background: rgba(255,255,255,0.2); 
      padding: 4px 8px; 
      border-radius: 4px; 
      font-size: 12px;
    }
    
    .ping.success { background: rgba(76,175,80,0.3); }
    .ping.failed { background: rgba(244,67,54,0.3); }
    
    .outbound-details { font-size: 12px; opacity: 0.8; }
    
    .status { 
      text-align: center; 
      padding: 15px; 
      border-radius: 8px; 
      margin: 15px 0;
      font-weight: 600;
    }
    
    .status.processing { background: rgba(255,193,7,0.2); color: #FFC107; }
    .status.completed { background: rgba(76,175,80,0.2); color: #4CAF50; }
    .status.error { background: rgba(244,67,54,0.2); color: #f44336; }
    
    .progress-bar {
      width: 100%;
      height: 8px;
      background: rgba(255,255,255,0.2);
      border-radius: 4px;
      margin: 10px 0;
      overflow: hidden;
    }
    
    .progress-fill {
      height: 100%;
      background: linear-gradient(90deg, #4CAF50, #45a049);
      transition: width 0.3s ease;
    }
    
    .stats {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 15px;
      margin: 20px 0;
    }
    
    .stat {
      text-align: center;
      background: rgba(255,255,255,0.1);
      padding: 15px;
      border-radius: 8px;
    }
    
    .stat-number { font-size: 24px; font-weight: bold; margin-bottom: 5px; }
    .stat-label { font-size: 12px; opacity: 0.8; }
    
    @media (max-width: 768px) {
      .container { padding: 10px; }
      .header h1 { font-size: 2em; }
      .card { padding: 15px; }
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>🎯 SingBox Ping Test Panel</h1>
      <p>تست پینگ واقعی کانفیگ‌های SingBox و تمام Outboundها</p>
    </div>

    <div class="card">
      <div class="form-group">
        <label for="config">📄 کانفیگ SingBox (JSON):</label>
        <textarea 
          id="config" 
          placeholder='{"log": {"level": "info"}, "inbounds": [...], "outbounds": [...]}'></textarea>
      </div>
      
      <div class="form-group">
        <label for="test_type">🔍 نوع تست:</label>
        <select id="test_type">
          <option value="real">تست واقعی (با SingBox)</option>
          <option value="tcp">تست TCP ساده</option>
        </select>
      </div>
      
      <button id="test_btn" onclick="startTest()">🚀 شروع تست پینگ</button>
    </div>

    <div id="result_section" style="display: none;">
      <div class="card">
        <h3>📊 نتایج تست</h3>
        <div id="status" class="status"></div>
        <div id="progress_container" style="display: none;">
          <div class="progress-bar">
            <div id="progress_fill" class="progress-fill" style="width: 0%;"></div>
          </div>
          <div id="progress_text"></div>
        </div>
        
        <div id="stats" class="stats" style="display: none;">
          <div class="stat">
            <div id="total_outbounds" class="stat-number">0</div>
            <div class="stat-label">کل Outboundها</div>
          </div>
          <div class="stat">
            <div id="working_outbounds" class="stat-number">0</div>
            <div class="stat-label">موفق</div>
          </div>
          <div class="stat">
            <div id="failed_outbounds" class="stat-number">0</div>
            <div class="stat-label">ناموفق</div>
          </div>
          <div class="stat">
            <div id="success_rate" class="stat-number">0%</div>
            <div class="stat-label">نرخ موفقیت</div>
          </div>
        </div>
        
        <div id="results" class="results"></div>
      </div>
    </div>
  </div>

  <script>
    let currentConfigId = null;
    let pollInterval = null;

    async function startTest() {
      const configText = document.getElementById('config').value.trim();
      const testType = document.getElementById('test_type').value;
      
      if (!configText) {
        alert('لطفاً کانفیگ را وارد کنید');
        return;
      }
      
      let config;
      try {
        config = JSON.parse(configText);
      } catch (e) {
        alert('فرمت JSON کانفیگ نامعتبر است');
        return;
      }
      
      document.getElementById('test_btn').disabled = true;
      document.getElementById('test_btn').textContent = '⏳ در حال تست...';
      document.getElementById('result_section').style.display = 'block';
      
      try {
        const response = await fetch('/test_config', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            config: config,
            test_type: testType
          })
        });
        
        const result = await response.json();
        
        if (result.config_id) {
          currentConfigId = result.config_id;
          updateStatus(result);
          
          if (result.status === 'started' || result.status === 'processing') {
            startPolling();
          }
        } else {
          showError(result.error || 'خطای نامشخص');
        }
        
      } catch (error) {
        showError('خطا در ارتباط با سرور: ' + error.message);
      }
    }
    
    function startPolling() {
      if (pollInterval) clearInterval(pollInterval);
      
      pollInterval = setInterval(async () => {
        if (!currentConfigId) return;
        
        try {
          const response = await fetch(`/status?id=${currentConfigId}`);
          const result = await response.json();
          
          updateStatus(result);
          
          if (result.status === 'completed' || result.status === 'error') {
            clearInterval(pollInterval);
            document.getElementById('test_btn').disabled = false;
            document.getElementById('test_btn').textContent = '🚀 شروع تست پینگ';
          }
          
        } catch (error) {
          console.error('خطا در دریافت وضعیت:', error);
        }
      }, 2000);
    }
    
    function updateStatus(result) {
      const statusDiv = document.getElementById('status');
      const progressContainer = document.getElementById('progress_container');
      const progressFill = document.getElementById('progress_fill');
      const progressText = document.getElementById('progress_text');
      const statsDiv = document.getElementById('stats');
      
      statusDiv.className = 'status ' + result.status;
      
      if (result.status === 'processing') {
        statusDiv.textContent = result.message || 'در حال پردازش...';
        progressContainer.style.display = 'block';
        
        const progress = result.progress || 0;
        progressFill.style.width = progress + '%';
        
        if (result.total_outbounds > 0) {
          progressText.textContent = `${result.tested_outbounds || 0} از ${result.total_outbounds} outbound تست شده`;
          
          statsDiv.style.display = 'grid';
          document.getElementById('total_outbounds').textContent = result.total_outbounds;
          document.getElementById('working_outbounds').textContent = result.working_outbounds || 0;
          document.getElementById('failed_outbounds').textContent = result.failed_outbounds || 0;
          
          if (result.tested_outbounds > 0) {
            const rate = Math.round(((result.working_outbounds || 0) / result.tested_outbounds) * 100);
            document.getElementById('success_rate').textContent = rate + '%';
          }
        }
        
        // نمایش نتایج جزئی
        if (result.results && result.results.length > 0) {
          displayResults(result.results);
        }
        
      } else if (result.status === 'completed') {
        statusDiv.textContent = `✅ تست کامل شد - ${result.working_outbounds} از ${result.total_outbounds} outbound موفق`;
        progressContainer.style.display = 'none';
        
        statsDiv.style.display = 'grid';
        document.getElementById('total_outbounds').textContent = result.total_outbounds;
        document.getElementById('working_outbounds').textContent = result.working_outbounds;
        document.getElementById('failed_outbounds').textContent = result.failed_outbounds;
        document.getElementById('success_rate').textContent = result.success_rate + '%';
        
        displayResults(result.results);
        
      } else if (result.status === 'error') {
        statusDiv.textContent = '❌ ' + (result.message || 'خطا در تست');
        progressContainer.style.display = 'none';
        statsDiv.style.display = 'none';
        
      } else {
        statusDiv.textContent = result.message || 'تست شروع شد...';
        progressContainer.style.display = 'none';
      }
    }
    
    function displayResults(results) {
      const resultsDiv = document.getElementById('results');
      resultsDiv.innerHTML = '';
      
      if (!results || results.length === 0) return;
      
      results.forEach(result => {
        const div = document.createElement('div');
        div.className = `outbound-result ${result.status}`;
        
        const pingText = result.status === 'success' ? `${result.ping} ms` : 'ناموفق';
        const pingClass = result.status === 'success' ? 'success' : 'failed';
        
        div.innerHTML = `
          <div class="outbound-header">
            <span class="tag">${result.tag}</span>
            <span class="ping ${pingClass}">${pingText}</span>
          </div>
          <div class="outbound-details">
            <strong>نوع:</strong> ${result.type} | 
            <strong>سرور:</strong> ${result.server}:${result.port} | 
            <strong>پیام:</strong> ${result.message}
          </div>
        `;
        
        resultsDiv.appendChild(div);
      });
    }
    
    function showError(message) {
      const statusDiv = document.getElementById('status');
      statusDiv.className = 'status error';
      statusDiv.textContent = '❌ ' + message;
      
      document.getElementById('test_btn').disabled = false;
      document.getElementById('test_btn').textContent = '🚀 شروع تست پینگ';
      document.getElementById('progress_container').style.display = 'none';
      document.getElementById('stats').style.display = 'none';
    }
    
    // مثال کانفیگ
    document.addEventListener('DOMContentLoaded', function() {
      const exampleConfig = {
        "log": {"level": "info"},
        "inbounds": [{
          "type": "tun",
          "tag": "tun-in",
          "interface_name": "sing-tun",
          "address": ["172.19.0.1/30"]
        }],
        "outbounds": [{
          "type": "vless",
          "tag": "vless-server",
          "server": "example.com",
          "server_port": 443,
          "uuid": "12345678-1234-1234-1234-123456789abc",
          "tls": {"enabled": true}
        }]
      };
      
      document.getElementById('config').placeholder = JSON.stringify(exampleConfig, null, 2);
    });
  </script>
</body>
</html>
EOF

# 6. ساخت start.sh
echo "[+] ساخت start.sh"
cat <<'EOF' | sudo tee $APP_DIR/start.sh > /dev/null
#!/bin/bash
cd /opt/singbox-ping
exec /opt/singbox-ping/venv/bin/python ping_api.py >> /var/log/singbox-ping.log 2>&1
EOF
sudo chmod +x $APP_DIR/start.sh

# 7. سرویس systemd
echo "[+] ساخت سرویس systemd"
cat <<EOF | sudo tee $SERVICE_FILE > /dev/null
[Unit]
Description=SingBox Ping Test Panel
After=network.target
Requires=network-online.target

[Service]
ExecStart=/opt/singbox-ping/start.sh
WorkingDirectory=/opt/singbox-ping
Restart=always
RestartSec=3
User=root
Environment="PATH=/usr/bin:/usr/local/bin"
KillSignal=SIGINT
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

# 8. فعال‌سازی و اجرا
echo "[+] بارگذاری systemd"
sudo systemctl daemon-reload
sudo systemctl enable singbox-ping
sudo systemctl restart singbox-ping

echo ""
echo "=================================================="
echo "✅ نصب کامل شد!"
echo "=================================================="
echo "🔌 وضعیت سرویس: systemctl status singbox-ping"
echo "🔌 لاگ‌ها: journalctl -u singbox-ping -f"
echo "🔌 فایل لاگ: $LOG_FILE"
echo ""
echo "🚀 دسترسی به پنل:"
echo "🔌 http://YOUR_SERVER_IP:8080"
echo "🔌 http://localhost:8080"
echo ""
echo "📋 API Endpoints:"
echo "🔌 POST /test_config - تست کانفیگ"
echo "🔌 GET /status?id=CONFIG_ID - وضعیت تست"
echo "🔌 GET /list - لیست تست‌ها"
echo "🔌 GET /info - اطلاعات API"
echo ""
echo "💡 مثال استفاده از API:"
echo 'curl -X POST http://localhost:8080/test_config \'
echo '  -H "Content-Type: application/json" \'
echo '  -d {"config": {...}, "test_type": "real"}'
echo ""
echo "⏹️ برای توقف: bash $0 stop"
echo "=================================================="

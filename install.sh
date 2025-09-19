#!/bin/bash
# SingBox Ping Test Service (TCP + Real Ping Only)
# All-in-one installer and service

set -e

echo "🚀 Installing SingBox Ping Service..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root (use sudo)"
  exit 1
fi

# Install prerequisites
echo "📦 Installing prerequisites..."
apt update
apt install -y curl wget tar python3 python3-pip

# Install Sing-Box
echo "📥 Installing Sing-Box..."
if ! command -v sing-box &>/dev/null; then
    cd /tmp
    SINGBOX_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "browser_download_url.*linux-amd64.tar.gz" | cut -d '"' -f 4)
    wget $SINGBOX_URL
    tar -xzf sing-box-*-linux-amd64.tar.gz
    cd sing-box-*-linux-amd64
    mv sing-box /usr/local/bin/
    cd ..
    rm -rf sing-box-*
    echo "✅ Sing-Box installed"
else
    echo "✅ Sing-Box already installed"
fi

# Install Python requirements
echo "🐍 Installing Python packages..."
pip3 install flask

# Create the service script
echo "📝 Creating service script..."
cat > /usr/local/bin/singbox_ping_service.py <<'EOF'
#!/usr/bin/env python3
import json
import subprocess
import tempfile
import os
import requests
import time
import socket
import urllib.request
import urllib.error
from flask import Flask, request, jsonify
import logging

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class IranPingChecker:
    """Iran Nodes Ping Checker for Check-Host Service"""
    
    def __init__(self):
        self.headers = {'Accept': 'application/json'}
        self.timeout = 30
    
    def make_request(self, url):
        try:
            response = requests.get(url, headers=self.headers, timeout=self.timeout)
            response.raise_for_status()
            return response.json()
        except Exception as e:
            logger.error(f"Check-host request failed: {str(e)}")
            return None
    
    def send_ping_request(self, host, max_nodes=10):
        """Send ping request to check-host.net"""
        url = f'https://check-host.net/check-ping?host={host}&max_nodes={max_nodes}'
        data = self.make_request(url)
        
        if not data or 'request_id' not in data:
            return None
            
        return data
    
    def get_ping_results(self, request_id):
        """Get ping results from check-host.net"""
        url = f'https://check-host.net/check-result/{request_id}'
        return self.make_request(url)
    
    def analyze_ping_results(self, results):
        """Analyze ping results and create summary"""
        summary = {
            'total_nodes': 0,
            'successful_nodes': 0,
            'failed_nodes': 0,
            'pending_nodes': 0,
            'success_rate': 0
        }
        
        for node, ping_data in results.items():
            summary['total_nodes'] += 1
            
            if ping_data is None:
                summary['pending_nodes'] += 1
                continue
            
            if not isinstance(ping_data, list) or not ping_data or ping_data[0] is None:
                summary['failed_nodes'] += 1
                continue
            
            successful_pings = 0
            total_pings = 0
            
            for ping in ping_data[0]:
                if ping is None:
                    continue
                total_pings += 1
                if ping[0] == 'OK':
                    successful_pings += 1
            
            if total_pings > 0 and successful_pings > 0:
                summary['successful_nodes'] += 1
            else:
                summary['failed_nodes'] += 1
        
        # Calculate success rate
        if summary['total_nodes'] > 0:
            summary['success_rate'] = round(
                (summary['successful_nodes'] / summary['total_nodes']) * 100, 2
            )
        
        return summary
    
    def run_ping_check(self, host, wait_time=30):
        """Run full ping check on given host"""
        logger.info(f"Starting Iran ping check for host: {host}")
        
        ping_request = self.send_ping_request(host)
        
        if not ping_request:
            logger.error("Failed to initiate ping request")
            return {
                "success": False,
                "error": "Failed to initiate ping request",
                "summary": {
                    "total": 0,
                    "successful": 0,
                    "failed": 0,
                    "pending": 0,
                    "success_rate": 0
                }
            }
        
        logger.info(f"Ping request initiated, waiting {wait_time} seconds for results...")
        time.sleep(wait_time)
        
        results = self.get_ping_results(ping_request['request_id'])
        
        if results:
            summary = self.analyze_ping_results(results)
            logger.info(f"Ping check completed. Success rate: {summary['success_rate']}%")
            
            return {
                "success": True,
                "summary": {
                    "total": summary['total_nodes'],
                    "successful": summary['successful_nodes'],
                    "failed": summary['failed_nodes'],
                    "pending": summary['pending_nodes'],
                    "success_rate": summary['success_rate']
                }
            }
        else:
            logger.error("Failed to get ping results")
            return {
                "success": False,
                "error": "Failed to get ping results",
                "summary": {
                    "total": 0,
                    "successful": 0,
                    "failed": 0,
                    "pending": 0,
                    "success_rate": 0
                }
            }

def extract_server_ip(config_data, proxy_tag):
    """Extract server IP from SingBox configuration"""
    try:
        if 'outbounds' in config_data:
            for outbound in config_data['outbounds']:
                if outbound.get('tag') == proxy_tag:
                    server = outbound.get('server')
                    if server:
                        # Try to resolve hostname to IP if needed
                        try:
                            socket.inet_aton(server)  # Check if it's already an IP
                            return server
                        except socket.error:
                            # It's a hostname, resolve it
                            try:
                                ip = socket.gethostbyname(server)
                                return ip
                            except socket.gaierror:
                                return server  # Return original if resolution fails
        return None
    except Exception as e:
        logger.error(f"Error extracting server IP: {str(e)}")
        return None

def fix_vless_config(config_data):
    """Fix common VLESS configuration issues"""
    if 'outbounds' in config_data:
        for outbound in config_data['outbounds']:
            if outbound.get('type') == 'vless':
                # Remove invalid encryption field if present
                if 'encryption' in outbound:
                    del outbound['encryption']
                # Fix transport configuration if needed
                if 'transport' in outbound and outbound['transport'].get('type') == 'httpupgrade':
                    # Ensure host field is properly formatted
                    if 'host' in outbound['transport']:
                        # Remove trailing dots which can cause issues
                        outbound['transport']['host'] = outbound['transport']['host'].rstrip('.')
    return config_data

def simplify_config_for_testing(config_data):
    """Simplify complex config for testing purposes"""
    # Create a minimal config with mixed inbound for testing
    simplified = {
        "log": {"level": "warn"},
        "inbounds": [
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": 1080
            }
        ],
        "outbounds": []
    }
    
    # Copy outbounds from original config
    if 'outbounds' in config_data:
        simplified['outbounds'] = config_data['outbounds']
    
    # Fix any issues in the simplified config
    simplified = fix_vless_config(simplified)
    
    return simplified

def test_tcp_connectivity(config_data, proxy_tag):
    """Test TCP connectivity to the server"""
    try:
        # Find the target outbound
        target_outbound = None
        if 'outbounds' in config_data:
            for outbound in config_data['outbounds']:
                if outbound.get('tag') == proxy_tag:
                    target_outbound = outbound
                    break
        
        if not target_outbound:
            return False, f"Outbound with tag '{proxy_tag}' not found"
        
        # Extract server and port
        server = target_outbound.get('server')
        port = target_outbound.get('server_port')
        
        if not server or not port:
            return False, "Server or port not specified in outbound"
        
        # Test TCP connection
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(10)  # 10 second timeout
        
        try:
            result = sock.connect_ex((server, int(port)))
            sock.close()
            
            if result == 0:
                return True, f"TCP connection successful to {server}:{port}"
            else:
                return False, f"TCP connection failed to {server}:{port} (error code: {result})"
        except Exception as e:
            sock.close()
            return False, f"TCP connection error: {str(e)}"
            
    except Exception as e:
        logger.error(f"TCP test error: {str(e)}")
        return False, f"TCP test error: {str(e)}"

def test_real_ping(config_data, target_url):
    """Test real ping through the proxy"""
    try:
        # Create temporary config file
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            json.dump(config_data, f)
            config_path = f.name
        
        # Validate config first
        validate_result = subprocess.run(
            ['sing-box', 'check', '-c', config_path],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if validate_result.returncode != 0:
            # Try to extract meaningful error message
            error_output = validate_result.stderr
            if not error_output:
                error_output = validate_result.stdout
            
            os.unlink(config_path)
            logger.error(f"Invalid config: {error_output}")
            return False, f"Invalid config: {error_output}"
        
        # Test connectivity by running sing-box
        with tempfile.TemporaryDirectory() as temp_dir:
            log_file = os.path.join(temp_dir, "singbox_test.log")
            
            # Run sing-box
            process = subprocess.Popen(
                ['sing-box', 'run', '-c', config_path],
                stdout=open(log_file, 'w'),
                stderr=subprocess.STDOUT,
                text=True
            )
            
            try:
                # Wait for service to start
                time.sleep(3)
                
                # Test ping to target URL through proxy
                proxy_handler = urllib.request.ProxyHandler({
                    'http': 'http://127.0.0.1:1080',
                    'https': 'http://127.0.0.1:1080'
                })
                opener = urllib.request.build_opener(proxy_handler)
                urllib.request.install_opener(opener)
                
                headers = {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                }
                
                req = urllib.request.Request(target_url, headers=headers)
                response = urllib.request.urlopen(req, timeout=15)
                status_code = response.getcode()
                
                # Terminate sing-box
                process.terminate()
                process.wait(timeout=3)
                
                # Clean up
                os.unlink(config_path)
                
                if status_code == 204 or status_code == 200:
                    return True, f"PING SUCCESS - HTTP {status_code}"
                else:
                    return False, f"HTTP {status_code} - Not a ping response"
                    
            except urllib.error.URLError as e:
                # Terminate sing-box
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                
                # Clean up
                os.unlink(config_path)
                
                logger.error(f"No ping - Connection failed: {str(e)}")
                return False, f"No ping - Connection failed: {str(e)}"
            except Exception as e:
                # Terminate sing-box
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                
                # Clean up
                os.unlink(config_path)
                
                logger.error(f"Test error: {str(e)}")
                return False, f"Test error: {str(e)}"
                    
    except Exception as e:
        # Clean up in case of exception
        try:
            if 'config_path' in locals():
                os.unlink(config_path)
        except:
            pass
        logger.error(f"Validation error: {str(e)}")
        return False, f"Validation error: {str(e)}"

def validate_and_test_config_with_iran_check(config_data, target_url, proxy_tag, enable_iran_check=True):
    """Validate and test SingBox configuration with Iran accessibility check"""
    try:
        logger.info("Starting enhanced validation and testing of SingBox configuration")
        
        # Fix common configuration issues
        config_data = fix_vless_config(config_data)
        
        # For complex configs, simplify for testing
        original_config_has_tun = any(inbound.get('type') == 'tun' for inbound in config_data.get('inbounds', []))
        if original_config_has_tun:
            logger.info("Complex TUN config detected, simplifying for testing")
            config_data = simplify_config_for_testing(config_data)
        
        # First test TCP connectivity
        logger.info("Testing TCP connectivity...")
        tcp_success, tcp_message = test_tcp_connectivity(config_data, proxy_tag)
        logger.info(f"TCP test result: success={tcp_success}, message={tcp_message}")
        
        # Test real ping (only if TCP was successful)
        ping_success = False
        ping_message = "TCP connection failed - cannot test ping"
        if tcp_success:
            logger.info("Testing real ping...")
            ping_success, ping_message = test_real_ping(config_data, target_url)
            logger.info(f"Ping test result: success={ping_success}, message={ping_message}")
        else:
            logger.info("Skipping ping test due to TCP failure")
        
        # Iran accessibility check (only if ping was successful and enabled)
        iran_check_result = {
            "success": False,
            "message": "Iran check disabled or previous tests failed",
            "summary": {
                "total": 0,
                "successful": 0,
                "failed": 0,
                "pending": 0,
                "success_rate": 0
            }
        }
        
        if ping_success and enable_iran_check:
            logger.info("Starting Iran accessibility check...")

            # مستقیم server و port رو از outbound می‌گیریم
            server, server_port = None, None
            for outbound in config_data.get("outbounds", []):
                if outbound.get("tag") == proxy_tag:
                    server = outbound.get("server")
                    server_port = outbound.get("server_port")
                    break

            if server:
                logger.info(f"Using outbound server for Iran check: {server}:{server_port}")
                iran_checker = IranPingChecker()
                iran_check_result = iran_checker.run_ping_check(server, wait_time=30)

                if server_port:
                    iran_check_result["tested_ip"] = f"{server}:{server_port}"
                else:
                    iran_check_result["tested_ip"] = server
            else:
                logger.warning("Could not extract server/port for Iran check")
                iran_check_result["message"] = "Could not extract server/port"
        
        return {
            "tcp": {
                "success": tcp_success,
                "message": tcp_message
            },
            "ping": {
                "success": ping_success,
                "message": ping_message
            },
            "iran_check": iran_check_result
        }
        
    except Exception as e:
        error_msg = f"Enhanced validation and testing error: {str(e)}"
        logger.error(error_msg)
        return {
            "tcp": {
                "success": False,
                "message": f"TCP test error: {str(e)}"
            },
            "ping": {
                "success": False,
                "message": "TCP test failed - cannot test ping"
            },
            "iran_check": {
                "success": False,
                "message": f"Iran check error: {str(e)}",
                "summary": {
                    "total": 0,
                    "successful": 0,
                    "failed": 0,
                    "pending": 0,
                    "success_rate": 0
                }
            }
        }


@app.route('/test-ping', methods=['POST'])
def test_config():
    """Enhanced endpoint for testing SingBox configurations with Iran check"""
    try:
        logger.info("Received enhanced test-ping request")
        
        # Get JSON data
        data = request.get_json()
        if not data:
            logger.error("No JSON data provided in request")
            return jsonify({
                "success": False,
                "error": "No JSON data provided"
            }), 400
        
        # Extract fields
        config_data = data.get('config')
        target_url = data.get('target', 'https://www.gstatic.com/generate_204')
        proxy_tag = data.get('proxy_tag', 'vless-out')
        enable_iran_check = data.get('enable_iran_check', True)
        
        if not config_data:
            logger.error("No 'config' field in request")
            return jsonify({
                "success": False,
                "error": "No 'config' field in request"
            }), 400
        
        logger.info(f"Testing configuration with target={target_url}, proxy_tag={proxy_tag}, iran_check={enable_iran_check}")
        
        # Validate and test with Iran check
        results = validate_and_test_config_with_iran_check(
            config_data, target_url, proxy_tag, enable_iran_check
        )
        
        # Determine overall success
        overall_success = results['tcp']['success'] and results['ping']['success']
        
        # Add Iran check status to overall assessment
        if enable_iran_check and results['iran_check']['success']:
            results['iran_accessible'] = results['iran_check']['summary']['success_rate'] > 50
        else:
            results['iran_accessible'] = None
        
        logger.info(f"Enhanced test result: success={overall_success}, iran_accessible={results.get('iran_accessible')}")
        
        return jsonify({
            "success": overall_success,
            "results": results
        }), 200
        
    except Exception as e:
        error_msg = f"Enhanced server error: {str(e)}"
        logger.error(error_msg)
        return jsonify({
            "success": False,
            "error": error_msg
        }), 500

@app.route('/check-iran', methods=['POST'])
def check_iran_only():
    """Endpoint for testing Iran accessibility of a specific IP/host"""
    try:
        logger.info("Received Iran-only check request")
        
        # Get JSON data
        data = request.get_json()
        if not data:
            return jsonify({
                "success": False,
                "error": "No JSON data provided"
            }), 400
        
        host = data.get('host')
        wait_time = data.get('wait_time', 30)
        
        if not host:
            return jsonify({
                "success": False,
                "error": "No 'host' field in request"
            }), 400
        
        logger.info(f"Testing Iran accessibility for host: {host}")
        
        iran_checker = IranPingChecker()
        result = iran_checker.run_ping_check(host, wait_time)
        
        return jsonify(result), 200
        
    except Exception as e:
        error_msg = f"Iran check error: {str(e)}"
        logger.error(error_msg)
        return jsonify({
            "success": False,
            "error": error_msg
        }), 500

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    return jsonify({
        "status": "healthy",
        "service": "SingBox Enhanced Ping Service with Iran Check"
    }), 200

if __name__ == '__main__':
    logger.info("Starting Enhanced SingBox Ping Service with Iran Check on port 80")
    app.run(host='0.0.0.0', port=80, debug=False)

EOF

# Make service script executable
chmod +x /usr/local/bin/singbox_ping_service.py

# Create systemd service
echo "⚙️ Creating systemd service..."
cat > /etc/systemd/system/singbox-ping.service <<'EOF'
[Unit]
Description=SingBox Ping Test Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/singbox_ping_service.py
Restart=always
RestartSec=3
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
EOF

# Start service
echo "🚀 Starting service..."
systemctl daemon-reload
systemctl enable singbox-ping
systemctl restart singbox-ping

# Wait a moment for service to start
sleep 2

# Check if service is running
if systemctl is-active --quiet singbox-ping; then
    echo ""
    echo "✅ Installation completed successfully!"
    echo "======================================"
    echo "🌐 Service is running on port 80"
    echo "📍 Endpoint:"
    echo "   /test-ping - Test SingBox configuration (TCP + Ping only)"
    echo "📋 Usage:"
    echo "   curl -X POST http://YOUR_IP/test-ping \\"
    echo "     -H \"Content-Type: application/json\" \\"
    echo "     -d '{\"config\": {...}, \"target\": \"https://www.gstatic.com/generate_204\", \"proxy_tag\": \"vless-out\"}'"
    echo ""
    echo "🔧 Service management:"
    echo "   systemctl status singbox-ping"
    echo "   systemctl stop singbox-ping"
    echo "   systemctl start singbox-ping"
    echo ""
    echo "📝 View logs:"
    echo "   journalctl -u singbox-ping -f"
    echo "======================================"
else
    echo "❌ Failed to start service"
    systemctl status singbox-ping --no-pager
fi

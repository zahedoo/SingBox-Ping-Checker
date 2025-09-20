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
apt install -y curl wget tar python3 python3-pip python3-venv

# Install Sing-Box
echo "📥 Installing Sing-Box..."
if ! command -v sing-box &>/dev/null; then
    cd /tmp
    SINGBOX_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep "browser_download_url.*linux-amd64.tar.gz" | cut -d '"' -f 4)
    wget -O sing-box-linux-amd64.tar.gz "$SINGBOX_URL"
    tar -xzf sing-box-linux-amd64.tar.gz
    SINGBOX_DIR=$(tar -tzf sing-box-linux-amd64.tar.gz | head -1 | cut -f1 -d"/")
    cd "$SINGBOX_DIR"
    mv sing-box /usr/local/bin/
    cd ..
    rm -rf sing-box-linux-amd64.tar.gz "$SINGBOX_DIR"
    echo "✅ Sing-Box installed"
else
    echo "✅ Sing-Box already installed"
fi

# Install Python requirements
echo "🐍 Setting up Python virtual environment..."
mkdir -p /opt/singbox-ping-checker
cd /opt/singbox-ping-checker
python3 -m venv venv
source venv/bin/activate

echo "🐍 Installing Python packages in virtual environment..."
pip install flask requests

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
import threading
import uuid
from collections import defaultdict

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Store for batch test results
batch_results = {}
batch_status = {}

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
            # Resolve hostname first to get more detailed error info
            try:
                socket.getaddrinfo(server, int(port), socket.AF_INET, socket.SOCK_STREAM)
            except socket.gaierror as dns_error:
                return False, f"DNS resolution failed for {server}:{port} - {str(dns_error)}"
            
            result = sock.connect_ex((server, int(port)))
            sock.close()
            
            if result == 0:
                return True, f"TCP connection successful to {server}:{port}"
            elif result == 111:
                return False, f"TCP connection refused by {server}:{port} (error code: {result})"
            elif result == 113:
                return False, f"TCP connection timeout to {server}:{port} (error code: {result})"
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
                    
            except urllib.error.HTTPError as e:
                # Terminate sing-box
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                
                # Clean up
                os.unlink(config_path)
                
                logger.error(f"HTTP error during ping test: {str(e)}")
                return False, f"HTTP error: {str(e)} - Status code: {e.code}"
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
                
                # More detailed error handling
                error_msg = str(e)
                if "Connection reset by peer" in error_msg:
                    logger.error(f"Connection reset by peer: {error_msg}")
                    return False, f"Connection reset by peer - Server closed connection unexpectedly"
                elif "UNEXPECTED_EOF_WHILE_READING" in error_msg:
                    logger.error(f"SSL/TLS error: {error_msg}")
                    return False, f"SSL/TLS protocol violation - Connection terminated unexpectedly"
                elif "timed out" in error_msg:
                    logger.error(f"Timeout error: {error_msg}")
                    return False, f"Connection timeout - Server did not respond in time"
                else:
                    logger.error(f"No ping - Connection failed: {error_msg}")
                    return False, f"Connection failed: {error_msg}"
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


def run_batch_test(batch_id, configs):
    """Run batch tests in background"""
    batch_results[batch_id] = []
    batch_status[batch_id] = "running"
    
    try:
        for i, config_item in enumerate(configs):
            # Extract config data
            config_data = config_item.get('config')
            target_url = config_item.get('target', 'https://www.gstatic.com/generate_204')
            proxy_tag = config_item.get('proxy_tag', 'vless-out')
            enable_iran_check = config_item.get('enable_iran_check', True)
            
            if not config_data:
                result = {
                    "index": i,
                    "success": False,
                    "error": "No 'config' field in item"
                }
                batch_results[batch_id].append(result)
                continue
            
            # Store original config for later retrieval
            original_config = {
                "config": config_data,
                "target": target_url,
                "proxy_tag": proxy_tag
            }
            
            # Run the test
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
            
            result = {
                "index": i,
                "success": overall_success,
                "results": results,
                "original_config": original_config  # Store original config
            }
            
            batch_results[batch_id].append(result)
        
        batch_status[batch_id] = "completed"
    except Exception as e:
        batch_status[batch_id] = "error"
        logger.error(f"Batch test error: {str(e)}")


@app.route('/batch-test', methods=['POST'])
def batch_test():
    """Endpoint for batch testing multiple SingBox configurations"""
    try:
        logger.info("Received batch test request")
        
        # Get JSON data
        data = request.get_json()
        if not data:
            logger.error("No JSON data provided in request")
            return jsonify({
                "success": False,
                "error": "No JSON data provided"
            }), 400
        
        # Extract configs list
        configs = data.get('configs')
        if not configs or not isinstance(configs, list):
            logger.error("No 'configs' list in request")
            return jsonify({
                "success": False,
                "error": "No 'configs' list in request"
            }), 400
        
        # Generate batch ID
        batch_id = str(uuid.uuid4())
        
        # Initialize batch tracking
        batch_status[batch_id] = "starting"
        batch_results[batch_id] = []
        
        # Start background thread for batch testing
        thread = threading.Thread(target=run_batch_test, args=(batch_id, configs))
        thread.start()
        
        logger.info(f"Started batch test with ID: {batch_id}")
        
        return jsonify({
            "success": True,
            "batch_id": batch_id,
            "message": "Batch test started"
        }), 202
        
    except Exception as e:
        error_msg = f"Batch test error: {str(e)}"
        logger.error(error_msg)
        return jsonify({
            "success": False,
            "error": error_msg
        }), 500

@app.route('/batch-result/<batch_id>', methods=['GET'])
def get_batch_result(batch_id):
    """Endpoint for retrieving batch test results (successful configs only by default)"""
    try:
        logger.info(f"Retrieving batch result for ID: {batch_id}")
        
        # Check if batch ID exists
        if batch_id not in batch_status:
            return jsonify({
                "success": False,
                "error": "Batch ID not found"
            }), 404
        
        status = batch_status.get(batch_id, "unknown")
        results = batch_results.get(batch_id, [])
        
        # Filter results to separate successful and failed configs
        successful_configs = [r for r in results if r.get("success", False)]
        failed_configs = [r for r in results if not r.get("success", False)]
        
        # Create summary
        summary = {
            "total": len(results),
            "successful": len(successful_configs),
            "failed": len(failed_configs)
        }
        
        # By default, return only successful configurations
        # If user wants all results, they can use a query parameter
        show_all = request.args.get('show_all', type=bool, default=False)
        
        response = {
            "success": True,
            "batch_id": batch_id,
            "status": status,
            "summary": summary
        }
        
        if show_all:
            response["results"] = results
            response["successful_configs"] = successful_configs
        else:
            # Return only successful configurations by default with config data
            concise_configs = []
            for config in successful_configs:
                config_data = config.get("results", {})
                # Extract key information
                concise_config = {
                    "index": config.get("index"),
                    "iran_accessible": config_data.get("iran_accessible"),
                    "pingreal": config_data.get("ping", {}).get("success", False),
                    "pingtcp": config_data.get("tcp", {}).get("success", False),
                    "config": config.get("original_config")  # We'll store original config during batch test
                }
                concise_configs.append(concise_config)
            response["configs"] = concise_configs
        
        # If completed, clean up old data (optional)
        if status == "completed":
            # Keep results for later retrieval, but we could implement expiration
            pass
            
        return jsonify(response), 200
        
    except Exception as e:
        error_msg = f"Batch result error: {str(e)}"
        logger.error(error_msg)
        return jsonify({
            "success": False,
            "error": error_msg
        }), 500


@app.route('/batch-result/<batch_id>/passed', methods=['GET'])
def get_passed_batch_result(batch_id):
    """Endpoint for retrieving only passed batch test results"""
    try:
        logger.info(f"Retrieving passed batch result for ID: {batch_id}")
        
        # Check if batch ID exists
        if batch_id not in batch_status:
            return jsonify({
                "success": False,
                "error": "Batch ID not found"
            }), 404
        
        status = batch_status.get(batch_id, "unknown")
        results = batch_results.get(batch_id, [])
        
        # Filter to only include configs that passed all tests
        passed_configs = []
        for r in results:
            # Check if the config passed all tests
            if r.get("success", False):
                # Additional check for Iran accessibility if it was enabled
                config_results = r.get("results", {})
                iran_check = config_results.get("iran_check", {})
                
                # Include configs that passed TCP and ping tests
                # If Iran check was attempted, it should also be successful
                if iran_check.get("success", True):  # If not attempted, consider as passed
                    passed_configs.append(r)
        
        # Create summary
        summary = {
            "total": len(results),
            "passed": len(passed_configs),
            "failed": len(results) - len(passed_configs)
        }
        
        # Create concise format for passed configs
        concise_passed_configs = []
        for config in passed_configs:
            config_data = config.get("results", {})
            # Extract key information
            concise_config = {
                "index": config.get("index"),
                "iran_accessible": config_data.get("iran_accessible"),
                "pingreal": config_data.get("ping", {}).get("success", False),
                "pingtcp": config_data.get("tcp", {}).get("success", False),
                "config": config.get("original_config")
            }
            concise_passed_configs.append(concise_config)
        
        response = {
            "success": True,
            "batch_id": batch_id,
            "status": status,
            "summary": summary,
            "configs": concise_passed_configs
        }
            
        return jsonify(response), 200
        
    except Exception as e:
        error_msg = f"Batch passed result error: {str(e)}"
        logger.error(error_msg)
        return jsonify({
            "success": False,
            "error": error_msg
        }), 500


@app.route('/batch-result/<batch_id>/filtered', methods=['GET'])
def get_filtered_batch_result(batch_id):
    """Endpoint for retrieving filtered batch test results based on query parameters"""
    try:
        logger.info(f"Retrieving filtered batch result for ID: {batch_id}")
        
        # Check if batch ID exists
        if batch_id not in batch_status:
            return jsonify({
                "success": False,
                "error": "Batch ID not found"
            }), 404
        
        status = batch_status.get(batch_id, "unknown")
        results = batch_results.get(batch_id, [])
        
        # Get query parameters
        min_success_rate = request.args.get('min_success_rate', type=float, default=0)
        tcp_only = request.args.get('tcp_only', type=bool, default=False)
        ping_only = request.args.get('ping_only', type=bool, default=False)
        iran_accessible = request.args.get('iran_accessible', type=bool, default=False)
        
        # Filter configs based on criteria
        filtered_configs = []
        for r in results:
            config_results = r.get("results", {})
            tcp_result = config_results.get("tcp", {})
            ping_result = config_results.get("ping", {})
            iran_check = config_results.get("iran_check", {})
            
            # Apply filters
            include_config = True
            
            # TCP only filter
            if tcp_only and not tcp_result.get("success", False):
                include_config = False
                
            # Ping only filter
            if ping_only and not ping_result.get("success", False):
                include_config = False
                
            # Iran accessibility filter
            if iran_accessible and not config_results.get("iran_accessible", False):
                include_config = False
                
            # Minimum success rate filter (for Iran check)
            if iran_check.get("success", False) and iran_check.get("summary", {}).get("success_rate", 0) < min_success_rate:
                include_config = False
                
            if include_config:
                filtered_configs.append(r)
        
        # Create summary
        summary = {
            "total": len(results),
            "filtered": len(filtered_configs),
            "excluded": len(results) - len(filtered_configs)
        }
        
        # Create concise format for filtered configs
        concise_filtered_configs = []
        for config in filtered_configs:
            config_data = config.get("results", {})
            # Extract key information
            concise_config = {
                "index": config.get("index"),
                "iran_accessible": config_data.get("iran_accessible"),
                "pingreal": config_data.get("ping", {}).get("success", False),
                "pingtcp": config_data.get("tcp", {}).get("success", False),
                "config": config.get("original_config")
            }
            concise_filtered_configs.append(concise_config)
        
        response = {
            "success": True,
            "batch_id": batch_id,
            "status": status,
            "summary": summary,
            "configs": concise_filtered_configs
        }
            
        return jsonify(response), 200
        
    except Exception as e:
        error_msg = f"Batch filtered result error: {str(e)}"
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
ExecStart=/opt/singbox-ping-checker/venv/bin/python /usr/local/bin/singbox_ping_service.py
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
    echo "   /batch-test - Test multiple SingBox configurations"
    echo "   /batch-result/{id} - Get results of batch test (successful configs only)"
    echo "   /batch-result/{id}/passed - Get only passed configurations"
    echo "   /batch-result/{id}/filtered - Get filtered configurations"
    echo "📋 Usage:"
    echo "   curl -X POST http://YOUR_IP/test-ping \\"
    echo "     -H \"Content-Type: application/json\" \\"
    echo "     -d '{\"config\": {...}, \"target\": \"https://www.gstatic.com/generate_204\", \"proxy_tag\": \"vless-out\"}'"
    echo ""
    echo "   curl -X POST http://YOUR_IP/batch-test \\"
    echo "     -H \"Content-Type: application/json\" \\"
    echo "     -d '{\"configs\": [{\"config\": {...}, \"target\": \"https://www.gstatic.com/generate_204\", \"proxy_tag\": \"vless-out\"}]}'"
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

<?php

/**
 * کلاس تبدیل لینک‌های VPN به کانفیگ Sing-box (نسخه کامل و بروز)
 * پشتیبانی از تمامی پروتکل‌های VPN و ویژگی‌های پیشرفته
 * 
 * @version 2.0
 * @author Complete VPN Converter
 */
class VpnToSingboxConverter {
    
    /**
     * انواع پروتکل‌های پشتیبانی شده
     */
    private const SUPPORTED_TYPES = [
        'tcp', 'ws', 'http', 'quic', 'grpc', 'httpupgrade', 'h2', 'http2'
    ];
    
    /**
     * پروتکل‌های پشتیبانی شده برای تبدیل
     */
    private const SUPPORTED_PROTOCOLS = [
        'vless://', 'vmess://'/*, 'trojan://', 'hysteria2://', 'hy2://', 'ss://', 'tuic://'*/
    ];
    
    /**
     * method های معتبر Shadowsocks
     */
    private const VALID_SS_METHODS = [
        'aes-128-gcm', 'aes-192-gcm', 'aes-256-gcm',
        'aes-128-cfb', 'aes-192-cfb', 'aes-256-cfb',
        'aes-128-ctr', 'aes-192-ctr', 'aes-256-ctr',
        'chacha20-ietf-poly1305', 'xchacha20-ietf-poly1305',
        '2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm'
    ];
    
    /**
     * شمارنده برای نامگذاری سرورها
     */
    private $serverCounter = 0;
    
    /**
     * آدرس DNS
     */
    private $dnsAddress;
    
    /**
     * URL تست اتصال
     */
    private $testUrl;
    
    /**
     * فعال/غیرفعال کردن multiplex
     */
    private $enableMultiplex;
    
    /**
     * حالت دیباگ
     */
    private $debugMode;
    
    /**
     * آرایه خطاها
     */
    private $errors = [];
    
    /**
     * سازنده کلاس
     */
    public function __construct(
        $testUrl = 'https://www.gstatic.com/generate_204', 
        $dnsAddress = '1.1.1.2',
        $enableMultiplex = false,
        $debugMode = false
    ) {
        $this->testUrl = $testUrl;
        $this->dnsAddress = $dnsAddress;
        $this->enableMultiplex = $enableMultiplex;
        $this->debugMode = $debugMode;
    }
    
    /**
     * استخراج تمامی کانفیگ‌ها از متن ورودی
     */
    public function extractConfigs($input) {
        $configs = [];
        
        // تشخیص و decode کردن base64
        if ($this->isBase64($input)) {
            $input = base64_decode($input);
        }
        
        // جستجوی پروتکل‌های مختلف
        foreach (self::SUPPORTED_PROTOCOLS as $protocol) {
            $pattern = '/' . preg_quote($protocol, '/') . '[^\s\n\r]+/';
            preg_match_all($pattern, $input, $matches);
            if (!empty($matches[0])) {
                $configs = array_merge($configs, $matches[0]);
            }
        }
        
        // پردازش خطوط جداگانه برای base64
        $lines = explode("\n", $input);
        foreach ($lines as $line) {
            $line = trim($line);
            if ($this->isBase64($line) && strlen($line) > 20) {
                $decoded = base64_decode($line);
                foreach (self::SUPPORTED_PROTOCOLS as $protocol) {
                    $pattern = '/' . preg_quote($protocol, '/') . '[^\s\n\r]+/';
                    preg_match_all($pattern, $decoded, $matches);
                    if (!empty($matches[0])) {
                        $configs = array_merge($configs, $matches[0]);
                    }
                }
            }
        }
        
        return array_unique($configs);
    }
    
    /**
     * بررسی اینکه رشته base64 است یا نه
     */
    private function isBase64($str) {
        if (!$str || strlen($str) % 4 !== 0 || strlen($str) < 4) {
            return false;
        }
        
        if (!preg_match('/^[A-Za-z0-9+\/=]+$/', $str)) {
            return false;
        }
        
        $decoded = base64_decode($str, true);
        return $decoded !== false && base64_encode($decoded) === $str;
    }
    
    /**
     * تبدیل یک لینک VLESS به کانفیگ Sing-box
     */
    public function vlessToSingbox($vlessLink) {
        try {
            $url = parse_url(trim($vlessLink));
            
            if (!$url || $url['scheme'] !== 'vless') {
                $this->addError("Invalid VLESS URL: $vlessLink");
                return null;
            }
            
            // بررسی پارامترهای ضروری
            if (empty($url['user']) || empty($url['host'])) {
                $this->addError("Missing required parameters in VLESS URL");
                return null;
            }
            
            $uuid = $url['user'];
            $server = $url['host'];
            $port = isset($url['port']) ? (int)$url['port'] : 443;
            
            // پارس کردن query parameters
            parse_str($url['query'] ?? '', $params);
            
            // تولید نام سرور
            $this->serverCounter++;
            $tag = $url['scheme'] . "-out";
            
            // بررسی نوع پروتکل
            $type = $params['type'] ?? 'tcp';
            if (!in_array($type, self::SUPPORTED_TYPES)) {
                $this->addError("Unsupported transport type: $type");
                return null;
            }
            
            // ساخت کانفیگ پایه
            $config = [
                'type' => 'vless',
                'tag' => $tag,
                'server' => $server,
                'server_port' => $port,
                'uuid' => $uuid,
                'flow' => '',
                'encryption' => 'none'
            ];
            
            // تنظیمات Transport
            if ($type !== 'tcp') {
                $transportConfig = $this->getTransportConfig($type, $params);
                if ($transportConfig) {
                    $config['transport'] = $transportConfig;
                }
            }
            
            // تنظیمات TLS
            $security = $params['security'] ?? 'none';
            if ($security !== 'none') {
                $tlsConfig = $this->getTLSConfig($security, $params);
                if ($tlsConfig) {
                    $config['tls'] = $tlsConfig;
                }
            }
            
            // تنظیمات Multiplex
            if ($this->enableMultiplex) {
                $config['multiplex'] = [
                    'enabled' => true,
                    'protocol' => 'h2mux',
                    'max_streams' => 16,
                    'padding' => false
                ];
            }
            
            return $config;
            
        } catch (Exception $e) {
            $this->addError("Error processing VLESS URL: " . $e->getMessage());
            return null;
        }
    }
    
    /**
     * تبدیل VMess به Sing-box
     */
    public function vmessToSingbox($vmessLink) {
        try {
            $data = substr($vmessLink, 8); // حذف vmess://
            $decoded = base64_decode($data);
            $config = json_decode($decoded, true);
            
            if (!$config || !isset($config['add'])) {
                return null;
            }
            
            $this->serverCounter++;
            $tag = "vmess-out";
            
            $outbound = [
                'type' => 'vmess',
                'tag' => $tag,
                'server' => $config['add'],
                'server_port' => (int)($config['port'] ?? 443),
                'uuid' => $config['id'] ?? '',
                'alter_id' => (int)($config['aid'] ?? 0)
            ];
            
            // Transport
            $net = $config['net'] ?? 'tcp';
            if ($net !== 'tcp' && in_array($net, self::SUPPORTED_TYPES)) {
                $transportConfig = $this->getTransportConfig($net, $config);
                if ($transportConfig) {
                    $outbound['transport'] = $transportConfig;
                }
            }
            
            // TLS
            if (($config['tls'] ?? '') === 'tls') {
                $outbound['tls'] = ['enabled' => true];
                if (!empty($config['sni'])) {
                    $outbound['tls']['server_name'] = $config['sni'];
                }
            }
            
            return $outbound;
            
        } catch (Exception $e) {
            $this->addError("Error processing VMess URL: " . $e->getMessage());
            return null;
        }
    }
    
    /**
     * تبدیل Trojan به Sing-box
     */
    public function trojanToSingbox($trojanLink) {
        try {
            $url = parse_url($trojanLink);
            if (!$url || $url['scheme'] !== 'trojan') {
                return null;
            }
            
            parse_str($url['query'] ?? '', $params);
            
            $this->serverCounter++;
            $tag = "trojan-out";
            
            $outbound = [
                'type' => 'trojan',
                'tag' => $tag,
                'server' => $url['host'],
                'server_port' => (int)($url['port'] ?? 443),
                'password' => $url['user'] ?? '',
                'tls' => ['enabled' => true]
            ];
            
            if (!empty($params['sni'])) {
                $outbound['tls']['server_name'] = $params['sni'];
            }
            
            // Transport
            $type = $params['type'] ?? 'tcp';
            if ($type !== 'tcp' && in_array($type, self::SUPPORTED_TYPES)) {
                $transportConfig = $this->getTransportConfig($type, $params);
                if ($transportConfig) {
                    $outbound['transport'] = $transportConfig;
                }
            }
            
            return $outbound;
            
        } catch (Exception $e) {
            $this->addError("Error processing Trojan URL: " . $e->getMessage());
            return null;
        }
    }
    
    /**
     * تبدیل Shadowsocks به Sing-box
     */
    public function shadowsocksToSingbox($ssLink) {
        try {
            $url = parse_url($ssLink);
            if (!$url || $url['scheme'] !== 'ss') {
                return null;
            }
            
            $userinfo = $url['user'] ?? '';
            if (empty($userinfo)) {
                return null;
            }
            
            // Decode base64 userinfo
            $decoded = $this->isBase64($userinfo) ? base64_decode($userinfo) : $userinfo;
            $parts = explode(':', $decoded, 2);
            
            if (count($parts) !== 2) {
                return null;
            }
            
            $method = trim($parts[0]);
            $password = trim($parts[1]);
            
            if (empty($method) || empty($password) || !in_array($method, self::VALID_SS_METHODS)) {
                return null;
            }
            
            $this->serverCounter++;
            $tag = "ss-out";
            
            return [
                'type' => 'shadowsocks',
                'tag' => $tag,
                'server' => $url['host'],
                'server_port' => (int)($url['port'] ?? 443),
                'method' => $method,
                'password' => $password
            ];
            
        } catch (Exception $e) {
            $this->addError("Error processing Shadowsocks URL: " . $e->getMessage());
            return null;
        }
    }
    
    /**
     * تبدیل Hysteria2 به Sing-box
     */
    public function hysteria2ToSingbox($hy2Link) {
        try {
            $url = parse_url($hy2Link);
            if (!$url || !in_array($url['scheme'], ['hysteria2', 'hy2'])) {
                return null;
            }
            
            parse_str($url['query'] ?? '', $params);
            
            $this->serverCounter++;
            $tag = "hysteria2-out";
            
            $outbound = [
                'type' => 'hysteria2',
                'tag' => $tag,
                'server' => $url['host'],
                'server_port' => (int)($url['port'] ?? 443),
                'password' => $url['user'] ?? '',
                'tls' => ['enabled' => true]
            ];
            
            if (!empty($params['sni'])) {
                $outbound['tls']['server_name'] = $params['sni'];
            }
            
            return $outbound;
            
        } catch (Exception $e) {
            $this->addError("Error processing Hysteria2 URL: " . $e->getMessage());
            return null;
        }
    }
    
    /**
     * تبدیل TUIC به Sing-box
     */
    public function tuicToSingbox($tuicLink) {
        try {
            $url = parse_url($tuicLink);
            if (!$url || $url['scheme'] !== 'tuic') {
                return null;
            }
            
            parse_str($url['query'] ?? '', $params);
            
            $this->serverCounter++;
            $tag = "tuic-out";
            
            $outbound = [
                'type' => 'tuic',
                'tag' => $tag,
                'server' => $url['host'],
                'server_port' => (int)($url['port'] ?? 443),
                'uuid' => $url['user'] ?? '',
                'password' => $params['password'] ?? '',
                'tls' => ['enabled' => true]
            ];
            
            if (!empty($params['sni'])) {
                $outbound['tls']['server_name'] = $params['sni'];
            }
            
            if (!empty($params['congestion_control'])) {
                $outbound['congestion_control'] = $params['congestion_control'];
            }
            
            if (!empty($params['udp_relay_mode'])) {
                $outbound['udp_relay_mode'] = $params['udp_relay_mode'];
            }
            
            return $outbound;
            
        } catch (Exception $e) {
            $this->addError("Error processing TUIC URL: " . $e->getMessage());
            return null;
        }
    }
    
    /**
     * تنظیمات Transport را بر اساس نوع پروتکل برمی‌گرداند
     */
    private function getTransportConfig($type, $params) {
        $transport = ['type' => $type];
        
        switch ($type) {
            case 'ws':
            case 'httpupgrade':
                if (!empty($params['path'])) {
                    $transport['path'] = $params['path'];
                }
                if (!empty($params['host'])) {
                    $transport['headers'] = ['Host' => $params['host']];
                }
                break;
                
            case 'http':
            case 'h2':
            case 'http2':
                if (!empty($params['path'])) {
                    $transport['path'] = $params['path'];
                }
                if (!empty($params['host'])) {
                    $transport['host'] = [$params['host']];
                }
                break;
                
            case 'grpc':
                if (!empty($params['serviceName'])) {
                    $transport['service_name'] = $params['serviceName'];
                } elseif (!empty($params['grpcServiceName'])) {
                    $transport['service_name'] = $params['grpcServiceName'];
                }
                break;
                
            case 'quic':
                // QUIC تنظیمات خاصی ندارد در Sing-box
                break;
                
            default:
                return null;
        }
        
        return $transport;
    }
    
    /**
     * تنظیمات TLS را بر اساس نوع امنیت برمی‌گرداند
     */
    private function getTLSConfig($security, $params) {
        $tls = ['enabled' => true];
        
        // Server Name
        if (!empty($params['sni'])) {
            $tls['server_name'] = $params['sni'];
        }
        
        // تنظیمات Reality
        if ($security === 'reality') {
            if (empty($params['pbk']) || !$this->isValidRealityKey($params['pbk'])) {
                $this->addError("Invalid or missing Reality public key");
                return null;
            }
            
            $reality = [
                'enabled' => true,
                'public_key' => $this->cleanPublicKey($params['pbk'])
            ];
            
            if (!empty($params['sid'])) {
                $reality['short_id'] = $params['sid'];
            }
            
            $tls['reality'] = $reality;
            
            // uTLS الزامی برای Reality
            $tls['utls'] = [
                'enabled' => true,
                'fingerprint' => !empty($params['fp']) ? $params['fp'] : 'chrome'
            ];
        } else {
            // uTLS اختیاری برای TLS معمولی
            if (!empty($params['fp'])) {
                $tls['utls'] = [
                    'enabled' => true,
                    'fingerprint' => $params['fp']
                ];
            }
        }
        
        // ALPN تنظیمات
        $type = $params['type'] ?? 'tcp';
        if ($type === 'ws') {
            $tls['alpn'] = ['http/1.1'];
        } elseif (in_array($type, ['h2', 'http2', 'grpc'])) {
            $tls['alpn'] = ['h2', 'http/1.1'];
        }
        
        return $tls;
    }
    
    /**
     * تمیز کردن و بررسی public key
     */
    private function cleanPublicKey($key) {
        return trim(urldecode($key));
    }
    
    /**
     * بررسی معتبر بودن Reality public key
     */
    private function isValidRealityKey($key) {
        if (empty($key)) {
            return false;
        }
        
        $cleanKey = $this->cleanPublicKey($key);
        
        if (strlen($cleanKey) < 20) {
            return false;
        }
        
        if (!preg_match('/^[A-Za-z0-9+\/\-_=]*$/', $cleanKey)) {
            return false;
        }
        
        // تلاش برای decode
        $decoded = base64_decode($cleanKey, true);
        if ($decoded === false) {
            // تلاش با base64url
            $base64url = str_replace(['-', '_'], ['+', '/'], $cleanKey);
            $decoded = base64_decode($base64url, true);
            if ($decoded === false) {
                return false;
            }
        }
        
        $decodedLength = strlen($decoded);
        return $decodedLength >= 28 && $decodedLength <= 36;
    }
    
    /**
     * تبدیل یک URL به outbound
     */
    public function convertToOutbound($configUrl) {
        $configUrl = trim($configUrl);
        
        if (strpos($configUrl, 'vless://') === 0) {
            return $this->vlessToSingbox($configUrl);
        } elseif (strpos($configUrl, 'vmess://') === 0) {
            return $this->vmessToSingbox($configUrl);
        } elseif (strpos($configUrl, 'trojan://') === 0) {
            return $this->trojanToSingbox($configUrl);
        } elseif (strpos($configUrl, 'ss://') === 0) {
            return $this->shadowsocksToSingbox($configUrl);
        } elseif (strpos($configUrl, 'hysteria2://') === 0 || strpos($configUrl, 'hy2://') === 0) {
            return $this->hysteria2ToSingbox($configUrl);
        } elseif (strpos($configUrl, 'tuic://') === 0) {
            return $this->tuicToSingbox($configUrl);
        }
        
        return null;
    }
    
    /**
     * ایجاد کانفیگ کامل Sing-box از لینک منفرد
     */
    public function createFullConfig($vlessLink) {
        $outbound = $this->convertToOutbound($vlessLink);
        
        if ($outbound === null) {
            return null;
        }
        
        return [
            'config' => [
                'log' => ['level' => 'info'],
                'inbounds' => [
                    [
                        'type' => 'mixed',
                        'listen' => '127.0.0.1',
                        'listen_port' => 1080,
                        'tag' => 'mixed-in'
                    ]
                ],
                'outbounds' => [$outbound],
                'route' => ['final' => $outbound['tag']]
            ],
            'target' => $this->testUrl,
            'proxy_tag' => $outbound['tag']
        ];
    }
    
    /**
     * اضافه کردن خطا به لیست
     */
    private function addError($error) {
        if ($this->debugMode) {
            $this->errors[] = $error;
        }
    }
    
    /**
     * دریافت لیست خطاها
     */
    public function getErrors() {
        return $this->errors;
    }
    
    /**
     * پاک کردن لیست خطاها
     */
    public function clearErrors() {
        $this->errors = [];
    }
    
    /**
     * تولید JSON از کانفیگ Sing-box
     */
    public function toJson($config) {
        return json_encode($config, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }
    
    /**
     * دریافت آمار کانفیگ‌ها
     */
    public function getStats() {
        return [
            'total_servers' => $this->serverCounter,
            'total_errors' => count($this->errors),
            'supported_protocols' => self::SUPPORTED_PROTOCOLS,
            'supported_transports' => self::SUPPORTED_TYPES,
            'multiplex_enabled' => $this->enableMultiplex,
            'debug_mode' => $this->debugMode
        ];
    }
    
    /**
     * ریست کردن شمارنده و خطاها
     */
    public function reset() {
        $this->serverCounter = 0;
        $this->errors = [];
    }
    
    /**
     * تنظیم حالت multiplex
     */
    public function setMultiplexEnabled($enabled) {
        $this->enableMultiplex = $enabled;
    }
    
    /**
     * تنظیم حالت دیباگ
     */
    public function setDebugMode($enabled) {
        $this->debugMode = $enabled;
    }
    
    /**
     * اعتبارسنجی یک URL کانفیگ
     */
    public function validateConfigUrl($url) {
        foreach (self::SUPPORTED_PROTOCOLS as $protocol) {
            if (strpos($url, $protocol) === 0) {
                $testOutbound = $this->convertToOutbound($url);
                return $testOutbound !== null;
            }
        }
        return false;
    }
    
    /**
     * تبدیل سریع چندین کانفیگ بدون ساخت کانفیگ کامل
     */
    public function convertMultiple($input) {
        $configs = [];
        
        if (is_array($input)) {
            foreach ($input as $item) {
                $extracted = $this->extractConfigs($item);
                $configs = array_merge($configs, $extracted);
            }
        } else {
            $configs = $this->extractConfigs($input);
        }
        
        $outbounds = [];
        foreach ($configs as $configUrl) {
            $outbound = $this->convertToOutbound($configUrl);
            if ($outbound) {
                $outbounds[] = $outbound;
            }
        }
        
        return $outbounds;
    }
}

/**
 * کلاس پارس کردن کانفیگ از URL
 */
class ConfigParser {
    private const SUPPORTED_PROTOCOLS = [
        'vless://', 'vmess://', 'trojan://', 
        'hysteria2://', 'hy2://', 'ss://', 'tuic://'
    ];
    
    private const SUPPORTED_TRANSPORTS = [
        'tcp', 'ws', 'http', 'quic', 'grpc', 'httpupgrade', 'h2', 'http2'
    ];

    /**
     * دریافت کانفیگ‌ها از URL
     */
    public function parseConfigsFromUrl($url) {
        // دریافت محتوای فایل
        $content = $this->fetchContent($url);
        
        if ($content === false) {
            return false;
        }
        
        // تبدیل محتوا به خطوط
        $lines = explode("\n", $content);
        $configs = [];
        
        foreach ($lines as $line) {
            $line = trim($line);
            
            // بررسی اینکه خط خالی یا کامنت نیست
            if (empty($line) || strpos($line, '#') === 0) {
                continue;
            }
            
            // بررسی اینکه خط یک کانفیگ معتبر است
            if ($this->isValidConfig($line)) {
                $configs[] = $line;
            }
        }
        
        return $configs;
    }
    
    /**
     * دریافت محتوا از URL
     */
    private function fetchContent($url) {
        $ch = curl_init();
        
        curl_setopt_array($ch, [
            CURLOPT_URL => $url,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_SSL_VERIFYPEER => false,
            CURLOPT_SSL_VERIFYHOST => false,
            CURLOPT_TIMEOUT => 30,
            CURLOPT_USERAGENT => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        ]);
        
        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        
        curl_close($ch);
        
        if ($httpCode === 200 && !empty($response)) {
            return $response;
        }
        
        return false;
    }
    
    /**
     * بررسی معتبر بودن کانفیگ
     */
    private function isValidConfig($line) {
        // بررسی پروتکل‌های معتبر
        foreach (self::SUPPORTED_PROTOCOLS as $protocol) {
            if (strpos($line, $protocol) === 0) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * تولید آرایه PHP از کانفیگ‌ها
     */
    public function generatePhpArray($configs) {
        if (empty($configs)) {
            return '[]';
        }
        
        $phpArray = "[\n";
        
        foreach ($configs as $index => $config) {
            // Escape single quotes و اضافه کردن به آرایه
            $escapedConfig = str_replace("'", "\\'", $config);
            $phpArray .= "    '{$escapedConfig}'";
            
            if ($index < count($configs) - 1) {
                $phpArray .= ",";
            }
            
            $phpArray .= "\n";
        }
        
        $phpArray .= "]";
        
        return $phpArray;
    }
}

/**
 * کلاس پردازش و API Response
 */
class VpnConfigAPI {
    private $converter;
    private $parser;
    private $maxConfigs;
    
    public function __construct($maxConfigs = 100) {
        $this->converter = new VpnToSingboxConverter();
        $this->parser = new ConfigParser();
        $this->maxConfigs = $maxConfigs;
    }
    
    /**
     * پردازش کانفیگ‌ها از URL و تبدیل به Sing-box
     */
    public function processConfigsFromUrl($configUrl) {
        $configs = $this->parser->parseConfigsFromUrl($configUrl);
        $successfulConfigs = [];
        
        if ($configs !== false && !empty($configs)) {
            $processed = 0;
            
            foreach ($configs as $config) {
                if ($processed >= $this->maxConfigs) {
                    break;
                }
                
                try {
                    $fullConfig = $this->converter->createFullConfig($config);
                    
                    if ($fullConfig !== null) {
                        $successfulConfigs[] = $fullConfig;
                        $processed++;
                    }
                } catch (Exception $e) {
                    // Log error silently or continue
                    error_log("Config conversion failed: " . $e->getMessage());
                    continue;
                }
            }
        }
        
        return [
            'success' => true,
            'total_processed' => count($successfulConfigs),
            'configs' => $successfulConfigs,
            'errors' => $this->converter->getErrors(),
            'stats' => $this->converter->getStats()
        ];
    }
    
    /**
     * پردازش کانفیگ‌های متنی
     */
    public function processTextConfigs($textConfigs) {
        $successfulConfigs = [];
        
        try {
            $configs = $this->converter->extractConfigs($textConfigs);
            $processed = 0;
            
            foreach ($configs as $config) {
                if ($processed >= $this->maxConfigs) {
                    break;
                }
                
                try {
                    $fullConfig = $this->converter->createFullConfig($config);
                    
                    if ($fullConfig !== null) {
                        $successfulConfigs[] = $fullConfig;
                        $processed++;
                    }
                } catch (Exception $e) {
                    error_log("Config conversion failed: " . $e->getMessage());
                    continue;
                }
            }
        } catch (Exception $e) {
            return [
                'success' => false,
                'error' => $e->getMessage(),
                'total_processed' => 0,
                'configs' => []
            ];
        }
        
        return [
            'success' => true,
            'total_processed' => count($successfulConfigs),
            'configs' => $successfulConfigs,
            'errors' => $this->converter->getErrors(),
            'stats' => $this->converter->getStats()
        ];
    }
    
    /**
     * تبدیل یک کانفیگ منفرد
     */
    public function processSingleConfig($configLink) {
        try {
            $fullConfig = $this->converter->createFullConfig($configLink);
            
            if ($fullConfig !== null) {
                return [
                    'success' => true,
                    'config' => $fullConfig,
                    'json' => $this->converter->toJson($fullConfig),
                    'errors' => $this->converter->getErrors(),
                    'stats' => $this->converter->getStats()
                ];
            } else {
                return [
                    'success' => false,
                    'error' => 'Failed to convert config',
                    'errors' => $this->converter->getErrors()
                ];
            }
        } catch (Exception $e) {
            return [
                'success' => false,
                'error' => $e->getMessage(),
                'errors' => $this->converter->getErrors()
            ];
        }
    }
    
    /**
     * خروجی JSON Response
     */
    public function jsonResponse($data) {
        header('Content-Type: application/json; charset=utf-8');
        header('Cache-Control: no-cache, must-revalidate');
        header('Expires: Mon, 26 Jul 1997 05:00:00 GMT');
        
        echo json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }
}

// =============================================================================
// اجرای اصلی (Main Execution)
// =============================================================================

// ایجاد نمونه converter
$converter = new VpnToSingboxConverter();
$parser = new ConfigParser();

// آدرس پیش‌فرض URL کانفیگ
$configUrl = 'https://raw.githubusercontent.com/barry-far/V2ray-Config/refs/heads/main/All_Configs_Sub.txt';

// دریافت کانفیگ‌ها از URL
$configs = $parser->parseConfigsFromUrl($configUrl);
$successfulConfigs = [];
$maxConfigs = 5000;

if ($configs !== false && !empty($configs)) {
    $processed = 0;
    
    foreach ($configs as $config) {
        if ($processed >= $maxConfigs) {
            break;
        }
        
        try {
            // تبدیل هر کانفیگ به فرمت کامل
            $fullConfig = $converter->createFullConfig($config);
            
            if ($fullConfig !== null) {
                $successfulConfigs[] = $fullConfig;
                $processed++;
            }
        } catch (Exception $e) {
            // Log error silently and continue
            error_log("Config conversion failed: " . $e->getMessage());
            continue;
        }
    }
}

// آماده کردن خروجی نهایی
$output = [
    'success' => true,
    'total_processed' => count($successfulConfigs),
    'configs' => $successfulConfigs
];

// تنظیم headers برای JSON response
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-cache, must-revalidate');
header('Expires: Mon, 26 Jul 1997 05:00:00 GMT');

$data = json_encode($output, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);



$url = "http://ipserver/batch-test";

$curl = curl_init($url);
curl_setopt($curl, CURLOPT_URL, $url);
curl_setopt($curl, CURLOPT_POST, true);
curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);

$headers = array(
   "Content-Type: application/json",
);
curl_setopt($curl, CURLOPT_HTTPHEADER, $headers);


curl_setopt($curl, CURLOPT_POSTFIELDS, $data);

//for debug only!
curl_setopt($curl, CURLOPT_SSL_VERIFYHOST, false);
curl_setopt($curl, CURLOPT_SSL_VERIFYPEER, false);

$resp = curl_exec($curl);
curl_close($curl);
echo($resp)."http://ipserver/batch-result/";

?>


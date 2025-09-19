# SingPing - SingBox Ping Test Panel

SingPing یک پنل مدیریت وب برای تست پینگ و بررسی کیفیت کانفیگ‌های SingBox است. این ابزار امکان تست واقعی تمام outboundهای موجود در کانفیگ را فراهم می‌کند.

- 🌐 **چندزبانه**: پشتیبانی از فارسی و انگلیسی

## پیش‌نیازها

- سرور Ubuntu 18.04+ یا Debian 10+
- Python 3.6+
- دسترسی sudo
- اتصال اینترنت

## نصب سریع

```bash
# دانلود اسکریپت نصب
wget https://raw.githubusercontent.com/zahedoo/SingBox-Ping-Checker/refs/heads/main/install.sh

# اجرای نصب
chmod +x install.sh
sudo ./install.sh
```

```
curl -X POST http://YOUR_SERVER_IP/test-ping \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "inbounds": [...],
      "outbounds": [...]
    },
    "target": "https://www.gstatic.com/generate_204",
    "proxy_tag": "vless-out",
    "timeout": 10
  }'
```

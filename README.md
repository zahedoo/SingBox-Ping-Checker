# SingPing - SingBox Ping Test Panel

SingPing یک پنل مدیریت وب برای تست پینگ و بررسی کیفیت کانفیگ‌های SingBox است. این ابزار امکان تست واقعی تمام outboundهای موجود در کانفیگ را فراهم می‌کند.

## ویژگی‌ها

- 🎯 **تست پینگ واقعی**: تست اتصال از طریق SingBox با پروکسی
- 🔧 **تست TCP ساده**: بررسی سریع اتصال TCP
- 📊 **پنل مدیریت زیبا**: رابط کاربری مدرن و ریسپانسیو
- ⚡ **تست موازی**: تست همزمان چندین outbound
- 📈 **نمایش آمار زنده**: پیشرفت تست به صورت real-time
- 🔌 **API کامل**: دسترسی برنامه‌نویسی به تمام قابلیت‌ها
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
### 3. بررسی وضعیت
# بررسی وضعیت سرویس
sudo systemctl status singbox-ping

# مشاهده لاگ‌ها
sudo journalctl -u singbox-ping -f
```

## استفاده

### دسترسی به پنل وب
بعد از نصب، پنل در آدرس زیر در دسترس است:
```
http://YOUR_SERVER_IP:8080
```

### تست کانفیگ از طریق پنل
1. کانفیگ JSON خود را در تکست‌باکس وارد کنید
2. نوع تست را انتخاب کنید (Real Test یا TCP Test)
3. روی "شروع تست پینگ" کلیک کنید
4. نتایج به صورت زنده نمایش داده می‌شود

### مثال کانفیگ
```json
{
  "log": {"level": "info"},
  "inbounds": [{
    "type": "tun",
    "tag": "tun-in",
    "interface_name": "sing-tun",
    "address": ["172.19.0.1/30"]
  }],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-server1",
      "server": "example1.com",
      "server_port": 443,
      "uuid": "12345678-1234-1234-1234-123456789abc",
      "tls": {"enabled": true}
    },
    {
      "type": "vmess",
      "tag": "vmess-server2", 
      "server": "example2.com",
      "server_port": 80,
      "uuid": "87654321-4321-4321-4321-cba987654321",
      "security": "auto"
    }
  ]
}
```

## API مستندات

### تست کانفیگ
```bash
curl -X POST http://localhost:8080/test_config \
  -H "Content-Type: application/json" \
  -d '{
    "config": {YOUR_SINGBOX_CONFIG},
    "test_type": "real"
  }'
```

**پاسخ:**
```json
{
  "status": "started",
  "config_id": "abc123de",
  "message": "تست شروع شد",
  "check_url": "/status?id=abc123de"
}
```

### بررسی وضعیت تست
```bash
curl http://localhost:8080/status?id=CONFIG_ID
```

**پاسخ در حال پردازش:**
```json
{
  "status": "processing",
  "config_id": "abc123de",
  "progress": 60,
  "total_outbounds": 3,
  "tested_outbounds": 2,
  "working_outbounds": 1,
  "failed_outbounds": 1,
  "results": [...]
}
```

**پاسخ نهایی:**
```json
{
  "status": "completed",
  "config_id": "abc123de",
  "total_outbounds": 3,
  "working_outbounds": 2,
  "failed_outbounds": 1,
  "success_rate": 66.7,
  "results": [
    {
      "tag": "vless-server1",
      "type": "vless",
      "server": "example1.com",
      "port": 443,
      "status": "success",
      "ping": 120,
      "message": "Real Connection OK"
    },
    {
      "tag": "vmess-server2",
      "type": "vmess", 
      "server": "example2.com",
      "port": 80,
      "status": "failed",
      "ping": 0,
      "message": "Connection timeout"
    }
  ]
}
```

### سایر Endpointها
- `GET /list` - لیست همه تست‌ها
- `GET /info` - اطلاعات API

## انواع تست

### Real Test (تست واقعی)
- از SingBox برای ایجاد اتصال استفاده می‌کند
- اتصال واقعی از طریق پروکسی برقرار می‌کند
- دقیق‌تر اما کندتر
- نیاز به نصب SingBox دارد

### TCP Test (تست TCP)
- فقط اتصال TCP ساده بررسی می‌کند
- سریع‌تر اما کم‌دقت‌تر
- نیازی به SingBox ندارد
- برای بررسی اولیه مناسب است

## مدیریت سرویس

```bash
# شروع سرویس
sudo systemctl start singbox-ping

# توقف سرویس
sudo systemctl stop singbox-ping

# ری‌استارت سرویس
sudo systemctl restart singbox-ping

# فعال‌سازی در بوت
sudo systemctl enable singbox-ping

# غیرفعال‌سازی در بوت
sudo systemctl disable singbox-ping

# مشاهده وضعیت
sudo systemctl status singbox-ping

# مشاهده لاگ‌ها
sudo journalctl -u singbox-ping -f
```

## فایل‌های مهم

```
/opt/singbox-ping/         # مسیر اصلی برنامه
├── ping_api.py            # فایل اصلی API
├── start.sh               # اسکریپت شروع
└── venv/                  # محیط مجازی Python

/var/www/singbox-ping/     # فایل‌های وب
└── index.html             # پنل مدیریت

/var/log/singbox-ping.log  # فایل لاگ
/etc/systemd/system/singbox-ping.service  # فایل سرویس
```

## حل مشکلات

### سرویس شروع نمی‌شود
```bash
# بررسی وضعیت
sudo systemctl status singbox-ping

# بررسی لاگ‌ها
sudo journalctl -u singbox-ping -n 50

# بررسی فایل لاگ
sudo tail -f /var/log/singbox-ping.log
```

### پورت 8080 در استفاده است
```bash
# بررسی پورت
sudo netstat -tulpn | grep 8080

# تغییر پورت در فایل ping_api.py
sudo nano /opt/singbox-ping/ping_api.py
# خط port = 8080 را تغییر دهید
```

### SingBox نصب نیست
```bash
# بررسی نصب SingBox
sing-box version

# نصب دستی SingBox
sudo ./setup_singping.sh
```

## حذف کامل

```bash
# توقف و حذف سرویس
sudo ./setup_singping.sh stop

# یا حذف دستی
sudo systemctl stop singbox-ping
sudo systemctl disable singbox-ping
sudo rm -rf /opt/singbox-ping
sudo rm -rf /var/www/singbox-ping
sudo rm /etc/systemd/system/singbox-ping.service
sudo systemctl daemon-reload
```

## مشارکت

1. Fork کنید
2. Feature branch ایجاد کنید (`git checkout -b feature/amazing-feature`)
3. تغییرات را commit کنید (`git commit -m 'Add amazing feature'`)
4. Branch را push کنید (`git push origin feature/amazing-feature`)
5. Pull Request ایجاد کنید

## مجوز

این پروژه تحت مجوز MIT منتشر شده است. فایل [LICENSE](LICENSE) را مطالعه کنید.

## تشکر

- [SagerNet/sing-box](https://github.com/SagerNet/sing-box) - هسته اصلی SingBox
- جامعه توسعه‌دهندگان ایرانی



---

⭐ اگر این پروژه برایتان مفید بود، لطفاً یک ستاره بدهید!

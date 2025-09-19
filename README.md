# تست‌کننده پینگ با کانفیگ (SingBox Ping Checker)

این ابزار یک کانفیگ (شامل `inbounds` و `outbounds`) را بررسی می‌کند: ابتدا اتصال TCP به آدرس/پورت مقصد را تست می‌کند؛ اگر TCP برقرار بود، یک پینگ HTTP واقعی (مثلاً درخواست به URL که `HTTP 204` برمی‌گرداند) انجام می‌دهد و در نهایت با همان کانفیگ یک چک هاست می‌زند. نتیجهٔ کامل در قالب JSON بازگردانده می‌شود.

---

## پیش‌نیازها

* سرور Ubuntu 18.04+ یا Debian 10+
* Python 3.6+
* دسترسی sudo
* اتصال اینترنت

---

## نصب سریع

```bash
# دانلود اسکریپت نصب
wget https://raw.githubusercontent.com/zahedoo/SingBox-Ping-Checker/refs/heads/main/install.sh

# اجرای نصب
chmod +x install.sh
sudo ./install.sh
```

> اسکریپت نصب، وابستگی‌های لازم را روی سیستم نصب کرده و سرویس HTTP (endpoint `/test-ping`) را راه‌اندازی می‌کند.

---

## طریقه استفاده

درخواستی از نوع POST به endpoint `/test-ping` بفرستید. مثال با `curl`:

```bash
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

### پارامترها

* `config`: کانفیگ کامل مورد نظر برای تست — باید شامل `inbounds` و `outbounds` باشد.
* `target`: آدرس هدف برای تست پینگ HTTP (به‌عنوان مثال آدرسی که HTTP 204 برمی‌گرداند).
* `proxy_tag`: تگی از داخل `outbounds` که می‌خواهید از آن برای تست استفاده کنید.
* `timeout`: زمان تایم‌اوت بر حسب ثانیه (اختیاری؛ مقدار پیش‌فرض معمولاً 10 ثانیه است).

---

## رفتار سیستم

1. ابتدا تلاش می‌شود با استفاده از اطلاعات `config` و `proxy_tag` اتصال TCP به هاست/پورت مقصد برقرار شود.
2. اگر اتصال TCP موفق بود، یک درخواست HTTP به `target` از طریق همان پروکسی ارسال می‌شود تا "پینگ واقعی" بررسی شود.
3. در صورتی که پینگ HTTP موفق باشد، یک چک اضافه روی هاست انجام می‌شود (مثلاً بررسی دسترسی ایران یا اجرای مجموعه تست‌ها) و همه نتایج در یک آبجکت JSON بازگردانده می‌شوند.

---

## نمونه Response

```json
{
  "results": {
    "iran_accessible": true,
    "iran_check": {
      "success": true,
      "summary": {
        "failed": 0,
        "pending": 0,
        "success_rate": 100.0,
        "successful": 10,
        "total": 10
      },
      "tested_ip": "127.0.0.1:2096"
    },
    "ping": {
      "message": "PING SUCCESS - HTTP 204",
      "success": true
    },
    "tcp": {
      "message": "TCP connection successful to 127.0.0.1:2096",
      "success": true
    }
  },
  "success": true
}
```

---

## نکات و پیشنهادها

* برای تست‌های دقیق‌تر، `target` را به URLهایی که پاسخ‌های متفاوت یا زمان‌بندی‌های مشخص دارند تغییر دهید.
* اگر می‌خواهید مجزاً فقط TCP یا فقط HTTP را تست کنید، می‌توان endpoint را گسترش داد یا پارامتر اضافه کرد تا رفتار انتخابی انجام شود.

---

اگر می‌خواهی من این فایل را به‌صورت واقعی روی مخزن ایجاد کنم یا نسخه انگلیسی/مثال‌های واقعی `inbounds/outbounds` اضافه کنم، بگو تا انجام بدم.

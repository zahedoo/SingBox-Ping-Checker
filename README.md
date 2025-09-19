با این اسکریپت میتوانید یه کانفیگ را پینگ بگیرید و  و ببینید tcp  پینگ میدهد یا نه و اگر داد بعد اون میاد پینگ واقعی رو چک میکنه  اگر اوکی بود میاد با همون کانفیگ یه چک هاست میزنه و نتیجه رو کامل تو جیسون برمیگردونه 


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
# طریقه استفاده
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
# Response
```json
{
"results":{
"iran_accessible":true,
"iran_check":{
"success":true,
"summary":{
"failed":0,
"pending":0,
"success_rate":100.0,
"successful":10,
"total":10
},
"tested_ip":"IP.mirzabox.info:2096"
},
"ping":{
"message":"PING SUCCESS - HTTP 204",
"success":true
},
"tcp":{
"message":"TCP connection successful to IP.mirzabox.info:2096",
"success":true
}
},
"success":true
}
```

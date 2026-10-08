# NodeBox


```
bash <(curl -fsSL https://raw.githubusercontent.com/xymn2023/NodeBox/main/NodeBox.sh)
```





# NodeBox 核心与协议说明

NodeBox 当前支持两个代理核心：

## 1. sing-box

使用官方 **sing-box** 核心。

支持协议：

* AnyTLS
* Hysteria2
* TUIC

## 2. Mihomo

使用官方 **Mihomo** 核心。

支持协议：

* AnyTLS
* Hysteria2
* TUIC
* VLESS
* Trojan
* VMess
* Shadowsocks
* Mixed

## 协议支持汇总

| 协议          | sing-box | Mihomo |
| ----------- | :------: | :----: |
| AnyTLS      |     ✅    |    ✅   |
| Hysteria2   |     ✅    |    ✅   |
| TUIC        |     ✅    |    ✅   |
| VLESS       |     ❌    |    ✅   |
| Trojan      |     ❌    |    ✅   |
| VMess       |     ❌    |    ✅   |
| Shadowsocks |     ❌    |    ✅   |
| Mixed       |     ❌    |    ✅   |

> NodeBox 使用官方发布的预编译核心，不进行核心源码编译。

# HomeProxy 配置构建脚本（homeproxy-build）

一个在 immortalwrt / OpenWrt 路由器上，**一站式生成并应用 HomeProxy（sing-box 客户端）配置**的 Bash 脚本。

- 严格遵守 DNS 防污染（DoH + fakeip + HTTPS/SVCB 拦截）
- 国内直连 / 国外代理 / 流媒体 / AI 分流
- 双路径自动应用：标准版（写 UCI 段）或魔改版（写裸 JSON 文件）
- 内置 clash-api 面板支持，默认复用 OpenClash 已装的 zashboard，无需重复下载
- 自动用 bash 重跑自身、自动用 opkg 补齐依赖 —— **路由器拉取后即可直接运行**

---

## 一、路由器上 SSH 拉取并运行

SSH 登录路由器后（OpenWrt / immortalwrt），任选一种：

### 方式 1：一键拉取并运行（最省事）

```sh
wget -O - https://raw.githubusercontent.com/<你的用户名>/homeproxy-build/main/get-hp.sh | sh
```

> 若 `wget` 不支持 `-O -`，改用：
> `curl -fsSL https://raw.githubusercontent.com/<你的用户名>/homeproxy-build/main/get-hp.sh | sh`

### 方式 2：手动下载主脚本再运行

```sh
wget -O /tmp/homeproxy-build.sh https://raw.githubusercontent.com/<你的用户名>/homeproxy-build/main/homeproxy-build.sh
sh /tmp/homeproxy-build.sh
```

### 方式 3：用 git 克隆（方便以后更新）

```sh
opkg update && opkg install git
cd /root
git clone https://github.com/<你的用户名>/homeproxy-build.git
sh /root/homeproxy-build/homeproxy-build.sh
# 以后更新：
cd /root/homeproxy-build && git pull
```

> **重要**：主脚本 `homeproxy-build.sh` 不支持 `wget -O - URL | sh` 直接管道执行
> （脚本内部需要 `bash` 重跑自身，`$0` 必须指向真实文件）。
> 请用上面的“方式 1/2/3”。`get-hp.sh` 已经帮你处理了这个下载-再执行的环节。

首次运行脚本会自动检测并提示通过 `opkg` 安装 `bash jq curl openssl-util unzip`，
确认即可，之后便“拉取即用”。

---

## 二、菜单与使用

运行后进入交互菜单：

| 选项 | 功能 |
| --- | --- |
| `1` | 添加订阅链接（可连续添加多条，自动去重） |
| `2` | 拉取最新规则（清空 sing-box 规则缓存） |
| `3` | 生成配置并自动应用到 HomeProxy |
| `4` | 配置面板（优先复用 OpenClash 的 zashboard，否则下载） |
| `5` | 显示面板访问信息 |
| `0` | 退出 |

典型流程：`1` 加订阅 → `3` 生成并应用 → `4` 安装/配置面板 →
浏览器打开 `http://<路由器LAN IP>:9090/ui/` 管理节点与规则。

---

## 三、文件说明

| 文件 | 说明 |
| --- | --- |
| `homeproxy-build.sh` | 主脚本（核心）。OpenWrt 上 `sh` 运行，会自动切 bash 并装依赖 |
| `get-hp.sh` | 一键拉取器（POSIX sh），在路由器上管道执行即可下载并运行主脚本 |
| `LICENSE` | MIT 许可证 |
| `.gitignore` | 忽略本地临时产物 |

---

## 四、注意事项（真机验证）

- 本脚本在沙箱中通过了 `bash -n` 语法检查与 JSON 生成逻辑验证，
  但 **未在真实路由器上跑过**。请在真机上执行后确认：
  - `sing-box check -c /var/run/homeproxy/sing-box-c.json`
  - `uci show homeproxy`
  - `curl http://<IP>:9090/ui/` 能打开面板
  - `tail -n 50 /var/run/homeproxy/sing-box-c.log`
- `clash_api` 的 `access_control_allow_private_network` 需 sing-box ≥ 1.10；
  若旧版 `sing-box check` 报未知字段，删除该字段即可，本地 `/ui` 不受影响。
- UCI 路径下 clash_api 的键名随 HomeProxy 版本可能不同，建议用
  `sing-box check` 验证；或改用 HomeProxy 自带的“Clash dashboard 更新”按钮。
- OpenClash 与 HomeProxy 一般同一时间只开一个（都抢 nftables 重定向与 DNS 接管），
  因此面板默认复用 OC 的 zashboard，两者共用同一份静态文件，无需重复下载。

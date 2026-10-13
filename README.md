# api-proxy

一个极简的 **nginx 反向代理** Docker 项目：把若干自有域名转发到指定的上游 API 站点，并在转发时清空所有会暴露真实访客身份的请求头。



```bash
curl -fsSL https://raw.githubusercontent.com/EmersonLopez2005/api-proxy/main/install.sh -o /tmp/api-proxy.sh
sudo bash /tmp/api-proxy.sh
```

---

## 它是怎么组织的

```
api-proxy/
├── setup.sh                       ★ 交互式配置向导 / 配置生成器
├── install.sh                       一键引导：装 Docker → 拉文件 → 进向导
├── templates/nginx.conf.tpl         配置模板
├── nginx/nginx.conf                 生成产物
├── nginx/nginx.conf.example         示例产物
├── sites.conf                       你的域名清单
├── sites.conf.example               清单格式示例
├── settings.conf                    全局设置，如出口 UA
├── .env                             HTTP_PORT 等
├── .env.example
├── docker-compose.yml
├── Makefile
├── .github/workflows/validate.yml   push 时校验模板 + 防止私人域名泄漏
└── README.md
```

**关键设计**：`nginx/nginx.conf` 是**生成物**，不要手改。想改配置就改输入源：

| 想改什么 | 改哪里 |
| --- | --- |
| 代理哪些域名、转发到哪里 | 跑 `sudo ./setup.sh`，或直接编辑 `sites.conf` |
| 超时、缓冲、日志、worker 数 | `templates/nginx.conf.tpl` |
| 出口 User-Agent | `settings.conf`，或向导里回答 |
| 宿主机对外端口 | `.env` 里的 `HTTP_PORT` |

---

## 一、快速开始

### 方式 A：一键脚本（推荐）

```bash
# 先下载再执行 —— 这样向导能正常接收键盘输入
curl -fsSL https://raw.githubusercontent.com/EmersonLopez2005/api-proxy/main/install.sh -o /tmp/api-proxy.sh
sudo bash /tmp/api-proxy.sh
```

脚本会依次完成：检查环境 → 装 Docker（没有的话）→ 下载项目到 `/opt/api-proxy` → 进入配置向导。

> 换目录：`sudo DIR=/srv/api-proxy bash /tmp/api-proxy.sh`

### 方式 B：clone 后手动跑向导

```bash
git clone https://github.com/EmersonLopez2005/api-proxy.git
cd api-proxy
sudo ./setup.sh
```

### 向导长什么样

```
==========================================================
            api-proxy  配置向导
==========================================================

--- 添加站点 -------------------------------------------------
  对外域名（直接回车结束添加）: api.example.com
  上游地址（例 https://api.upstream.com）: https://api.upstream.com
  转发时携带的 Host（回车用 api.upstream.com）:

  对外域名（直接回车结束添加）:

--- 出口 User-Agent ------------------------------------------
  转发时统一出口 User-Agent？ [Y/n]:
  UA 值（回车用默认 Chrome UA）:

--- 网络 -----------------------------------------------------
  宿主机对外监听端口（容器内部固定 80） [80]:

[+] 已生成: /opt/api-proxy/nginx/nginx.conf  （1 个站点）
[!] 以上两个 .conf 文件包含你的私人域名，请勿提交到公开仓库。
  是否立即校验并启动 / 重启容器？ [Y/n]:
```

跑完向导，域名指向这台机器就能用了。

---

## 二、添加 / 删除站点

交互式：

```bash
sudo ./setup.sh          # 重新跑向导，可继续追加，也可选择清空重配
```

命令行（适合脚本化、批量）：

```bash
sudo ./setup.sh --add api2.example.com https://api.other.com      # 追加并部署
sudo ./setup.sh --add cdn.example.com https://origin.net origin.example.net   # 指定 Host
sudo ./setup.sh --remove api2.example.com                          # 删除
sudo ./setup.sh --list                                             # 看现有站点
sudo ./setup.sh --render-only                                      # 只重新生成配置文件
sudo ./setup.sh --help                                             # 完整帮助
```

`--add` / `--remove` 也可以一次给多个：

```bash
sudo ./setup.sh \
  --add a.example.com https://up-a.com \
  --add b.example.com https://up-b.com \
  --remove old.example.com --yes
```

### 手动编辑 `sites.conf`

```conf
# <对外域名> <上游URL> [转发Host]
api.example.com     https://api.upstream.com
cdn.example.com     https://origin.example.net   cdn.origin.example.net
```

改完执行 `make render && make test && make reload` 生效。

---

## 三、常用运维命令

项目自带 `Makefile`：

```bash
make setup     # 交互式向导：配置站点并启动
make list      # 列出现有站点
make render    # 按 sites.conf 重新生成 nginx.conf
make up        # 启动
make down      # 停止并删除容器
make reload    # 不中断连接地热重载配置
make logs      # 实时日志
make ps        # 容器状态（含 health）
make test      # 校验 nginx 配置语法
make update    # 拉取最新代码 + 重新生成 + 重建
```

**本机自检**（不必等 DNS 生效）：

```bash
curl -I http://127.0.0.1/ -H 'Host: api.example.com'   # 应返回上游的响应头
curl -I http://127.0.0.1/                              # 应断开（444 兜底生效）
```

---

## 四、迁移到另一台机器

这个项目本身就是为「换机器」设计的 —— 因为配置全部来自两个文本文件，搬起来没有历史包袱。

在新机器上：

```bash
curl -fsSL https://raw.githubusercontent.com/EmersonLopez2005/api-proxy/main/install.sh -o /tmp/api-proxy.sh
sudo bash /tmp/api-proxy.sh
```

向导里重新填一遍域名即可（通常也就两三个）。

如果**旧机器还在**，建议顺手把实际生效的配置导出比对一下，避免漏掉手工改过的部分：

```bash
docker inspect api-proxy | grep -E '"(Image|HostPort|Source|Destination|RestartPolicy)"'
docker exec api-proxy nginx -T          # 容器里真正生效的配置
ss -lntp | grep -E ':(80|443)\s'        # 有没有别的服务占着端口
```

**除了容器，这几样也别忘了搬**：

- [ ] DNS A 记录改到新机器 IP
- [ ] 云安全组 / 本机防火墙放行对应端口
- [ ] 上游如果做了 IP 白名单，把新机器 IP 加进去
- [ ] CDN 侧的回源地址

---

## 五、加上 HTTPS

默认只监听 80，HTTPS 交给前面的 CDN / 网关终结（这是最省事的做法）。

想在本机直接终结 TLS，改两处：

1. `docker-compose.yml` 放开 443 端口映射和证书挂载：

   ```yaml
   ports:
     - "${HTTP_PORT:-80}:80"
     - "443:443"
   volumes:
     - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
     - ./certs:/etc/nginx/certs:ro
   ```

2. `templates/nginx.conf.tpl` 里给站点加一个 443 server 块（把 `certificate` 路径指向 `/etc/nginx/certs/` 下的文件）。

改完 `make render && make test && make reload`。

---

## 六、排障速查

| 现象 | 排查方向 |
| --- | --- |
| `docker compose ps` 显示 `unhealthy` | `make logs`；多半是配置语法错或被挂载成了目录（`nginx/nginx.conf` 不存在时 Docker 会创建同名目录） |
| 502 / 504 | 上游不通。先 `curl -I https://你的上游/` 确认上游本身可达；再核对 `proxy_ssl_server_name on` 和 Host 是否写对 |
| 444 或直接断连 | 请求的 `Host` 不在任何 `server_name` 里，命中了兜底块。检查 DNS 是否指向本机、域名有没有拼错 |
| 本机 `127.0.0.1` 正常、外部访问不了 | 安全组 / ufw / firewalld 没放行端口 |
| `bind: address already in use` | 系统 nginx / apache / caddy 占着端口，停掉它们，或在向导里改 `HTTP_PORT` |
| 流式输出（SSE）卡顿或被截断 | 确认 `proxy_buffering off`、`chunked_transfer_encoding on`、`proxy_http_version 1.1` 都在 |
| 改了配置不生效 | 忘了 `make render` / `make reload`；用 `make test` 看容器内的实际配置 |
| 上游走 CDN、偶尔解析到旧 IP | 打开 `templates/nginx.conf.tpl` 里 `resolver` 两行并重新 render |

---

## 七、安全与合规

- **不要提交** `sites.conf`、`settings.conf`、`.env`、`nginx/nginx.conf` —— 它们含你的域名，且已在 `.gitignore` 中。仓库的 CI 还会主动扫描是否混入了私人域名。
- 拿去自建时，请只代理**你本人有权访问的服务**，并自行确认目标站点条款允许这类代理方式。
- 该配置会统一改写上游看到的 UA 并清空溯源请求头，这是为「不把访客身份透给上游」而设计的，请不要用于规避他人服务的安全策略。
- 若在境内机器上对外提供域名服务，请按所在地法规完成相应手续。

---

## 八、License

[MIT](LICENSE)

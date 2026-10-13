# ============================================================================
#  api-proxy · 通用 API 反向代理
#
#  ⚠️  这是模板文件，不是可直接加载的 nginx 配置，请不要直接改它以外的地方
#
#  本文件只放「所有站点共用的静态部分」。真正的站点由 setup.sh 从 sites.conf
#  生成，注入到下面 SITES 占位行的位置。
#
#  想改什么，对应改这里：
#    ├── 超时 / 缓冲 / 日志 / worker 数  → 就是本文件
#    ├── 代理哪些域名、转发到哪里        → sites.conf（或跑 setup.sh 向导）
#    └── 出口 User-Agent                → settings.conf
#
#  改完执行：
#    sudo ./setup.sh --render-only && make test && make reload
#
#  ── 生成信息（自动填充，勿删）─────────────────────────────────────────
#     生成时间: {{GENERATED_AT}}
#     站点数量: {{SITE_COUNT}}
# ============================================================================

user  nginx;
worker_processes      auto;
worker_rlimit_nofile  65535;

error_log  /var/log/nginx/error.log  warn;
pid        /var/run/nginx.pid;

events {
    worker_connections  4096;
    multi_accept        on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/json;

    # ------------------------------------------------------------------
    # 日志（不记录 Referer，日志里不留访客来源痕迹）
    # ------------------------------------------------------------------
    log_format  main  '$remote_addr - [$time_local] "$request" '
                      '$status $body_bytes_sent $request_time "$http_user_agent"';
    access_log  /var/log/nginx/access.log  main;

    # ------------------------------------------------------------------
    # 传输层：面向流式响应（SSE / chunked）优化
    # ------------------------------------------------------------------
    sendfile            off;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65s;
    server_tokens       off;

    proxy_buffering            off;
    proxy_cache                off;
    proxy_request_buffering    off;
    chunked_transfer_encoding  on;

    client_max_body_size     100m;
    client_body_buffer_size  512k;

    # 上游域名若由 CDN 动态解析，打开下面两行改为运行时解析
    # resolver         1.1.1.1 8.8.8.8 valid=60s ipv6=off;
    # resolver_timeout 5s;

{{SITES}}

    # ==================================================================
    # 健康检查（仅容器内部使用，不映射到宿主机）
    # ==================================================================
    server {
        listen       8081;
        server_name  _;

        location = /healthz {
            access_log   off;
            default_type text/plain;
            return       200 "ok\n";
        }

        location / {
            return 444;
        }
    }

    # ==================================================================
    # 兜底防扫：用 IP 或未绑定的域名直接访问 → 立即断开（444）
    # ==================================================================
    server {
        listen       80  default_server;
        server_name  _;
        return 444;
    }
}

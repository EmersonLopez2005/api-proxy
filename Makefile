.PHONY: help setup list render up down restart reload logs ps test update

# 更新用的上游地址（fork 后请改成自己的）
REPO ?= EmersonLopez2005/api-proxy
BRANCH ?= main
INSTALL_URL ?= https://raw.githubusercontent.com/$(REPO)/$(BRANCH)/install.sh

help:
	@echo "── 首次配置 ──────────────────────────────"
	@echo "  make setup    交互式向导：配置站点并启动"
	@echo "  make list     列出现有站点"
	@echo "  make render   按 sites.conf 重新生成 nginx.conf"
	@echo ""
	@echo "── 日常运维 ──────────────────────────────"
	@echo "  make up       启动（后台）"
	@echo "  make down     停止并删除容器"
	@echo "  make restart  重启"
	@echo "  make reload   不中断连接地热重载配置"
	@echo "  make logs     实时日志"
	@echo "  make ps       容器状态"
	@echo "  make test     仅校验 nginx 配置语法"
	@echo "  make update   更新到最新版本并重新部署"
	@echo "                （自动适配 git 目录 / install.sh 安装的目录）"

setup:
	./setup.sh

list:
	./setup.sh --list

render:
	./setup.sh --render-only

up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose restart

reload:
	docker compose exec -T api-proxy nginx -s reload

logs:
	docker compose logs -f --tail=100

ps:
	docker compose ps

test:
	docker compose exec -T api-proxy nginx -t

update:
	@echo ">> 更新到最新版本"
	@echo "   本地状态文件会保留：sites.conf / settings.conf / .env / nginx/nginx.conf"
	@if [ -d .git ]; then \
		echo ">> 检测到 git 仓库，使用 git pull"; \
		git pull --ff-only && \
		./setup.sh --render-only && \
		docker compose up -d && \
		( docker compose exec -T api-proxy nginx -s reload 2>/dev/null \
			|| echo "   （容器未在运行，已跳过热重载）" ); \
	else \
		echo ">> 当前目录不是 git 仓库（由 install.sh 安装），改用官方安装器重新拉取"; \
		curl -fsSL "$(INSTALL_URL)" -o /tmp/api-proxy-update.sh && \
		DIR="$$(pwd)" bash /tmp/api-proxy-update.sh --yes; \
	fi

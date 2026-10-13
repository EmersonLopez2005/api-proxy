.PHONY: help setup list render up down restart reload logs ps test update

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
	@echo "  make update   拉取最新代码并重建"

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
	git pull --ff-only && ./setup.sh --render-only && docker compose up -d --force-recreate

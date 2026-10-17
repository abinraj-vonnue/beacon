.PHONY: help up down down-volumes restart ps logs build test clean

COMPOSE = docker compose --env-file .env -f compose.yaml

help:
	@echo "Beacon dev commands:"
	@echo "  make up           Build and start all services"
	@echo "  make down         Stop services and preserve database data"
	@echo "  make down-volumes Stop services and DELETE database data"
	@echo "  make restart      Restart application services"
	@echo "  make ps           Show service status"
	@echo "  make logs         Follow service logs"
	@echo "  make build        Build API and worker TypeScript"
	@echo "  make test         Run existing worker tests"
	@echo "  make clean        Remove stopped Compose containers"

.env:
	@echo "Missing .env. Run 'cp .env.example .env' first."
	@exit 1

up: .env
	$(COMPOSE) up --build -d


down down-volumes restart ps logs clean: .env

down:
	$(COMPOSE) down

down-volumes:
	$(COMPOSE) down --volumes

restart:
	$(COMPOSE) restart api worker

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs --follow

build:
	npm run build --workspace=@beacon/api
	npm run build --workspace=worker

test:
	npm test

clean:
	$(COMPOSE) down --remove-orphans

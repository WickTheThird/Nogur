.PHONY: install dev test lint format migrate migration up down logs

install:
	uv sync

dev:
	uv run uvicorn app.main:app --reload

test:
	uv run pytest

lint:
	uv run ruff check .

format:
	uv run ruff format .

migrate:
	uv run alembic upgrade head

migration:
	uv run alembic revision --autogenerate -m "$(name)"

up:
	docker compose up --build

down:
	docker compose down

logs:
	docker compose logs -f api

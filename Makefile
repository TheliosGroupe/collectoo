# Collectoo developer commands. See CLAUDE.md.
SHELL := /bin/bash
export SUPABASE_INTERNAL_IMAGE_REGISTRY ?= docker.io

.PHONY: setup up down reset types test test-py test-web test-db e2e lint lint-py lint-web typecheck build catalogue

setup:            ## Install all dependencies
	cd worker && uv sync --frozen
	cd apps/web && npm ci

up:               ## Start the local Supabase stack
	supabase start

down:             ## Stop the local Supabase stack
	supabase stop --no-backup

reset:            ## Re-apply migrations and seed
	supabase db reset

types:            ## Regenerate apps/web/src/lib/database.types.ts (needs make up)
	supabase gen types typescript --local --schema public > apps/web/src/lib/database.types.ts

lint: lint-py lint-web

lint-py:
	cd worker && uv run ruff check . && uv run ruff format --check . && uv run mypy

lint-web:
	cd apps/web && npm run lint && npm run typecheck

test: test-py test-web test-db

test-py:
	cd worker && uv run pytest

test-web:
	cd apps/web && npm test

test-db:          ## pgTAP (needs `make up`)
	supabase test db

e2e:              ## Playwright against the local stack (needs make up; builds the web app first)
	./scripts/e2e.sh

build:
	cd apps/web && npm run build

catalogue:        ## Regenerate the EU NPL template catalogue from the committed sources
	uv run --python 3.12 --with beautifulsoup4==4.14.2 --with lxml==6.0.2 --with openpyxl==3.1.5 \
		python -I tools/eba_catalogue/build_catalogue.py .
	python3 -I tools/eba_catalogue/gen_sql.py .

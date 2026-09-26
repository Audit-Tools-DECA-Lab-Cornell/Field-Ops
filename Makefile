.DEFAULT_GOAL := help
HOSTED_COMPOSE = docker compose --env-file /dev/null -f database/compose.hosted.yaml

.PHONY: help backend-check backend-test db-up db-test api-hosted-up api-hosted-stop

help:
	@printf '%s\n' \
	  'pnpm setup:apps      Install web and mobile from their lockfiles' \
	  'pnpm backend:setup   Install Python tooling from backend/uv.lock' \
	  'pnpm dev            Start the web app on port 3000' \
	  'pnpm mobile:simulator Start Metro for the iOS simulator' \
	  'pnpm check          Web + mobile + backend static checks' \
	  'pnpm test           Mobile + local API + local SQL tests (Docker required)' \
	  'pnpm db:start       Start local Supabase for development/testing' \
	  'pnpm api:hosted:up   Start the local API connected to hosted Supabase' \
	  'See docs/Workspace.md for setup, database targets, and deployment.'

backend-check:
	cd backend && uv run --frozen ruff check .
	cd backend && uv run --frozen basedpyright

backend-test:
	sh database/local-supabase.sh api-test

db-up:
	sh database/local-supabase.sh start

db-test:
	sh database/local-supabase.sh test

api-hosted-up:
	$(HOSTED_COMPOSE) up -d --build

api-hosted-stop:
	$(HOSTED_COMPOSE) stop

.DEFAULT_GOAL := help
.PHONY: help start stop reset test api-test

help:
	@printf '%s\n' 'Use pnpm db:start, db:stop, db:reset, db:test or backend:test from the product root.'

start:
	sh local-supabase.sh start

stop:
	sh local-supabase.sh stop

reset:
	sh local-supabase.sh reset

test:
	sh local-supabase.sh test

api-test:
	sh local-supabase.sh api-test

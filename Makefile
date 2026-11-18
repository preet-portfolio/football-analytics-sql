.DEFAULT_GOAL := all
.PHONY: all up fetch load test report serve psql lock down clean

SHELL   := /bin/bash
COMPOSE := docker compose
PORT    ?= 8000

## all: rebuild everything from the pinned raw files and run every test
all: up fetch load report test

## up: build the Postgres 16 + pgTAP image and start it
up:
	$(COMPOSE) up -d --build --wait db

## fetch: download pinned source files to data/raw and verify checksums
fetch:
	./scripts/fetch.sh

## load: (re)create schemas and load data/raw into raw.source_file
load:
	./scripts/load.sh

## test: run the pgTAP suite; TAP output is also saved for the status page
test:
	@mkdir -p site/data
	@$(COMPOSE) exec -T db pg_prove -U football -d football --verbose --ext .sql /tests/pgtap/ \
	  | tee site/data/tests.tap; exit $${PIPESTATUS[0]}

## report: export pipeline state to site/data/status.json
report:
	./scripts/report.sh

## serve: show the status page at http://localhost:$(PORT)
serve:
	python3 -m http.server $(PORT) --bind 127.0.0.1 --directory site

## psql: open a SQL shell in the database
psql:
	$(COMPOSE) exec db psql -U football -d football

## lock: record checksums of data/raw into data/checksums.sha256
lock:
	cd data/raw && find . -type f -name '*.json' | sed 's|^\./||' | sort | xargs shasum -a 256 > ../checksums.sha256

## down: stop the database (keeps the volume)
down:
	$(COMPOSE) down

## clean: stop the database and delete its volume (raw downloads are kept)
clean:
	$(COMPOSE) down -v

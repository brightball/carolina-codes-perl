PERL     ?= perl
PROVE    ?= prove
CPANM    ?= cpanm
GITLEAKS ?= gitleaks

export PATH := $(CURDIR)/local/bin:$(HOME)/.local/bin:$(PATH)
export PERL5LIB := $(CURDIR)/local/lib/perl5$(if $(PERL5LIB),:$(PERL5LIB))

APP_SOURCES  := app.pl
LINT_SOURCES := app.pl t/handler.t t/workflow.t t/ci-env.t perf_test.pl .gitea/ci/env.pl

.PHONY: deps test sast audit lint secrets check hooks

deps:
	$(CPANM) --notest --local-lib=local --installdeps . --with-develop --with-test

test:
	$(PROVE) -v -Ilocal/lib/perl5 t/

sast:
	perlcritic $(APP_SOURCES)

audit:
	cpan-audit --no-corelist --no-color deps .

lint:
	@status=0; \
	for f in $(LINT_SOURCES); do \
		echo "perltidy --assert-tidy $$f"; \
		perltidy --assert-tidy -st -se $$f >/dev/null || status=1; \
	done; \
	exit $$status

secrets:
	$(GITLEAKS) detect --source . --verbose

check: test sast audit lint secrets

hooks:
	pre-commit install
	git config core.hooksPath .githooks

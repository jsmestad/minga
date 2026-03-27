.PHONY: lint lint.format lint.credo lint.compile lint.dialyzer lint.fix test test.llm

# Run all lint checks. Each step runs independently so dialyzer always
# runs even if an earlier step fails. Failures are collected and reported
# at the end.
lint:
	@failed=""; \
	mix format --check-formatted || failed="$$failed format"; \
	mix credo --strict || failed="$$failed credo"; \
	mix compile --warnings-as-errors || failed="$$failed compile"; \
	mix dialyzer || failed="$$failed dialyzer"; \
	if [ -n "$$failed" ]; then \
		echo "\n\033[31mFailed checks:$$failed\033[0m"; \
		exit 1; \
	else \
		echo "\n\033[32mAll lint checks passed.\033[0m"; \
	fi

lint.format:
	mix format --check-formatted

lint.credo:
	mix credo --strict

lint.compile:
	mix compile --warnings-as-errors

lint.dialyzer:
	mix dialyzer

lint.fix:
	mix format
	mix credo --strict

test:
	mix test

test.llm:
	mix test.llm

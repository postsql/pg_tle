PYTHON ?= python3
PREFIX ?= $(HOME)/.local

.PHONY: all dist check test install uninstall clean

all: dist

dist:
	$(PYTHON) ./build_dist.py

check: test

test:
	$(PYTHON) -m unittest discover -s ./tests -p "test_*.py" -v

install: dist
	./install.sh --prefix "$(PREFIX)"

uninstall:
	./install.sh --prefix "$(PREFIX)" --uninstall

clean:
	rm -rf build dist *.egg-info pgtle_tools/__pycache__ tests/__pycache__

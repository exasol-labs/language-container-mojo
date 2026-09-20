# Makefile — test entry points for the native Mojo Script Language Container.
# Every target uses Docker; see TESTING.md for what each layer proves.

DOCKER ?= docker
export DOCKER_BUILDKIT = 1

.PHONY: test unittest selftest contracts tarball artifact help

## test: run every test layer with a summary (test/run-all.sh)
test:
	bash test/run-all.sh

## unittest: pure codec unit tests (src/proto.mojo + src/wire.mojo)
unittest:
	$(DOCKER) build -f Dockerfile --target unittest --progress=plain .

## selftest: full ZMQ/protobuf protocol matrix + SQL datatype matrix
selftest:
	$(DOCKER) build -f Dockerfile --target selftest --progress=plain .

## contracts: language-definitions shape check + fixtures (needs jq)
contracts:
	bash test/language_definitions_test.sh build_info/language_definitions.json
	bash test/language_definitions_fixtures_test.sh

## artifact: build the shippable SLC tarball into out-lc/
artifact:
	@mkdir -p out-lc
	$(DOCKER) build -f Dockerfile --target artifact --output type=local,dest=out-lc .

## tarball: build the SLC tarball and run the rootfs contract test on it
tarball: artifact
	$(DOCKER) build -f Dockerfile --target toolbox -t mojo-slc-toolbox .
	$(DOCKER) run --rm -v "$(CURDIR):/repo:ro" -v "$(CURDIR)/out-lc:/art:ro" -w /repo \
		mojo-slc-toolbox bash -c 'bash test/slc_tarball_test.sh /art/mojo-slc.tar.gz'

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //'

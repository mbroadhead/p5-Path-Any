compose_file := "docker-compose.yml"

# List available targets
default:
    @just --list

# Run the unit test suite (t/)
test:
    prove -lr t/

# Run the author test suite (xt/)
# Docker services are started and stopped by the individual test files.
author_test:
    prove -lr xt/

# Run both suites
all: test author_test

# Remove any Docker stacks left behind by author tests
clean:
    -docker compose -f {{compose_file}} -p path-any-sftp-xt down -v --remove-orphans 2>/dev/null
    -docker compose -f {{compose_file}} -p path-any-s3-xt  down -v --remove-orphans 2>/dev/null

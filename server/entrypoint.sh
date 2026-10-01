#!/bin/sh
set -eu

echo "Applying database migrations"
uv run --no-sync alembic upgrade head

echo "Starting Nogur server"
exec "$@"

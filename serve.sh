#!/usr/bin/env bash
# Preview the site locally in a Podman container (no Ruby on the host).
# Usage: ./serve.sh                -> http://localhost:4000/roadhouse-labs-guides/
#        PORT=4001 ./serve.sh      -> run on another port (e.g. alongside a second checkout)
#        ./serve.sh --drafts       -> extra args are passed to `jekyll serve`
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
site_name="$(basename "${repo_dir}")"
port="${PORT:-4000}"
livereload_port="${LIVERELOAD_PORT:-$((port + 31729))}"
# Match the Ruby version used by .github/workflows/pages-deploy.yml
image="docker.io/library/ruby:3.4"
gems_volume="${site_name}-gems"

# Interactive flags only when attached to a terminal (so it also runs from scripts)
tty_flags=()
if [[ -t 0 ]]; then
  tty_flags=(-it)
fi

# :z (shared SELinux label) so a one-off build can use the same checkout while the preview runs
exec podman run --rm "${tty_flags[@]}" \
  --name "${site_name}-preview" \
  -p "127.0.0.1:${port}:4000" \
  -p "127.0.0.1:${livereload_port}:${livereload_port}" \
  -v "${repo_dir}:/srv/site:z" \
  -v "${gems_volume}:/usr/local/bundle" \
  -w /srv/site \
  -e JEKYLL_ENV=development \
  -e LIVERELOAD_PORT="${livereload_port}" \
  "${image}" \
  bash -c 'bundle install --quiet && exec bundle exec jekyll serve \
    --host 0.0.0.0 --livereload --livereload-port "${LIVERELOAD_PORT}" \
    --force_polling "$@"' -- "$@"

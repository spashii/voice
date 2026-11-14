#!/usr/bin/env bash
# Builds site/ into a deployable folder: stamps local CSS and JS with the commit and dates each sitemap entry.
# Both hosts (Cloudflare Pages at dictate.tech, GitHub Pages) deploy this output.
# Usage: tools/site-build.sh <out-dir>. Needs full git history for the sitemap dates.
set -euo pipefail
out="${1:?usage: tools/site-build.sh <out-dir>}"
root="$(git rev-parse --show-toplevel)"
cd "$root"
rm -rf "$out"
mkdir -p "$out"
cp -R site/. "$out/"

# Caches keep every file for minutes, so each deploy must name its own CSS and JS.
v="$(git rev-parse --short HEAD)"
find "$out" -name '*.html' -exec sed -i "s/__V__/${v}/g" {} +
if grep -rn '__V__' "$out"; then
  echo "unreplaced __V__ placeholder" >&2
  exit 1
fi

# Google uses lastmod to decide when to crawl a page again, so each entry carries its page's last commit date.
for loc in $(grep -o '<loc>[^<]*' "$out/sitemap.xml" | sed 's/<loc>//'); do
  f="site/${loc#https://dictate.tech/}"
  case "$f" in */) f="${f}index.html" ;; *.*) ;; *) f="${f}.html" ;; esac
  d="$(git log -1 --format=%cs -- "$f")"
  if [ -z "$d" ]; then echo "no commit for $f" >&2; exit 1; fi
  sed -i "s#<loc>${loc}</loc>#<loc>${loc}</loc><lastmod>${d}</lastmod>#" "$out/sitemap.xml"
done

# Only for Cloudflare Pages: the project's pages.dev hosts (production and previews) and the staging host
# serve the same pages, so they stay out of search.
cat > "$out/_headers" <<'H'
https://:project.pages.dev/*
  X-Robots-Tag: noindex
https://staging.dictate.tech/*
  X-Robots-Tag: noindex
H

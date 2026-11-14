#!/usr/bin/env bash
# Builds what GitHub Pages serves once the site lives only on dictate.tech: every page under
# spashii.github.io/dictate/ becomes a stub that sends the visitor to the same path on dictate.tech.
# The script keeps the query string and the #fragment, which the activate page needs (#n=<nonce> from
# shipped apps); the meta refresh covers browsers without script, and rel=canonical tells search engines
# where the page lives now. Images, CSS and JS are copied as they are, so old embeds and cached social
# cards keep loading. 404.html forwards any other old path the same way.
# Usage: tools/github-stubs.sh <out-dir>
set -euo pipefail
out="${1:?usage: tools/github-stubs.sh <out-dir>}"
root="$(git rev-parse --show-toplevel)"
cd "$root/site"
rm -rf "$out"
mkdir -p "$out"

stub() { # $1 target URL
  cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Dictate is at dictate.tech</title>
<link rel="canonical" href="$1">
<script>location.replace("$1" + location.search + location.hash);</script>
<meta http-equiv="refresh" content="0; url=$1">
</head>
<body>
<p>Dictate is at <a href="$1">dictate.tech</a>.</p>
</body>
</html>
HTML
}

find . -type f | sed 's#^\./##' | sort | while read -r f; do
  mkdir -p "$out/$(dirname "$f")"
  case "$f" in
    404.html) ;;
    sitemap.xml) ;; # the sitemap lives on dictate.tech; an old copy here would list another host's pages
    index.html | */index.html) stub "https://dictate.tech/${f%index.html}" > "$out/$f" ;;
    *.html) stub "https://dictate.tech/${f%.html}" > "$out/$f" ;;
    *) cp "$f" "$out/$f" ;;
  esac
done

# GitHub Pages answers every missing path under /dictate/ with this page (status 404), so a path that
# was never a file here, or is gone, still lands on dictate.tech with its query and fragment.
cat > "$out/404.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Dictate is at dictate.tech</title>
<script>location.replace("https://dictate.tech" + location.pathname.replace(/^\/dictate(?=\/|$)/, "") + location.search + location.hash);</script>
<meta http-equiv="refresh" content="0; url=https://dictate.tech/">
</head>
<body>
<p>Dictate is at <a href="https://dictate.tech/">dictate.tech</a>.</p>
</body>
</html>
HTML

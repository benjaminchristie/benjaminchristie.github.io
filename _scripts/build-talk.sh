#!/usr/bin/env bash
# Build a Slidev deck into talks/<slug>/ as a static site.
#
#   _scripts/build-talk.sh <deck-dir> <slug> [first-last] [title]
#   _scripts/build-talk.sh ~/Documents/school/fall2026/presentations/slides/collab/iros26/talk memo
#   _scripts/build-talk.sh ~/Documents/school/fall2026/presentations/slides/collab/prelim mclq 20-32 MCLQ
#
# With a range, only those slides are built, so nothing else in the deck is published.
# Stages the deck with its repo's common/ beside it (as presentations/tools/export-all.sh
# does), so the presentations repo is never written to. Speaker notes are left out.

set -euo pipefail

deck=$(realpath "$1")
slug=$2
range=${3:-}
title=${4:-}
site=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$deck" && git rev-parse --show-toplevel)
image=${SLIDEV_IMAGE:-presentations-slidev:latest}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -r "$deck/." "$stage/"
rm -rf "$stage/common" "$stage/node_modules" "$stage/dist"
cp -r "$repo/common" "$stage/common"

rm -rf "$site/talks/$slug"
mkdir -p "$site/talks"

# keep only slides <first>..<last>; the first kept slide inherits the deck's headmatter
slice='
const { load } = await import("/usr/local/lib/node_modules/@slidev/cli/node_modules/@slidev/parser/dist/fs.mjs");
const fs = await import("node:fs");
const [a, b] = process.env.RANGE.split("-").map(Number);
// numbered as when presenting: hidden slides are skipped
const data = await load("/app", "/app/slides.md");
const keep = data.slides.slice(a - 1, b).map(s => s.source);
const fm = { ...(data.headmatter ?? data.slides[0].source.frontmatter), ...keep[0].frontmatter };
if (process.env.TITLE) fm.title = process.env.TITLE;
const rest = keep.slice(1).map(s => s.raw.startsWith("---") ? s.raw : "---\n" + s.raw);
fs.writeFileSync("slides.md", ["---\n" + JSON.stringify(fm) + "\n---\n" + keep[0].content, ...rest].join("\n"));
console.log(`kept slides ${a}-${b} of ${data.slides.length}: ${keep[0].title} ... ${keep.at(-1).title}`);
'

# root inside the container: Slidev's global install needs it for the vite cache;
# the tmpfs keeps its root-owned scratch off the host
docker run --rm --tmpfs /app/node_modules -e RANGE="$range" -e TITLE="$title" \
  -v "$stage":/app -v "$site/talks":/out -w /app "$image" sh -c "
  if [ -n \"\$RANGE\" ]; then node --input-type=module -e '$slice'; fi &&
  slidev build slides.md --base /talks/$slug/ --router-mode hash --without-notes --out /out/$slug &&
  chown -R $(id -u):$(id -g) /out/$slug"

# Vite only rewrites asset paths it can see at build time. Paths built at runtime in
# components (or in raw HTML) stay as /assets/..., so copy those files and add the base.
python3 -I - "$site/talks/$slug" "$stage" "/talks/$slug" <<'EOF'
import pathlib, re, shutil, sys
out, stage, base = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
pat = re.compile(r"""(?<=["'`(])/assets/([^"'`)\s?#]+)""")
missing = set()
for f in out.rglob("*"):
    if f.suffix not in (".js", ".css", ".html"):
        continue
    text = f.read_text(encoding="utf-8")
    def fix(m):
        src = stage / "assets" / m.group(1)
        if not src.is_file():
            missing.add(m.group(1))
            return m.group(0)
        dst = out / "assets" / m.group(1)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        return f"{base}/assets/{m.group(1)}"
    new = pat.sub(fix, text)
    if new != text:
        f.write_text(new, encoding="utf-8")
for m in sorted(missing):
    print(f"warning: /assets/{m} is referenced but not in the deck's assets/")
EOF

rm -f "$site/talks/$slug/_redirects" "$site/talks/$slug/404.html"
echo "built talks/$slug ($(du -sh "$site/talks/$slug" | cut -f1))"

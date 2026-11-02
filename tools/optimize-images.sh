#!/usr/bin/env bash
# 페이지에서 쓰는 큰 이미지를 WebP 로 변환하고 HTML/CSS/JS 참조를 자동으로 바꾼다.
#
# 사용법 (레포 루트에서):
#   tools/optimize-images.sh               # 150KB 넘는 이미지 전부 (페이지에서 쓰는 것만)
#   tools/optimize-images.sh 경로1 경로2     # 지정한 이미지만
#   MAX=1600 QUALITY=75 tools/optimize-images.sh
#
# 필요: macOS sips(기본 내장), cwebp (brew install webp)
# 원본은 참조가 하나도 남지 않으면 git rm 한다. 되돌리려면 git restore --staged --worktree <경로>.
set -euo pipefail

MAX=${MAX:-1920}          # 긴 변 최대 픽셀
QUALITY=${QUALITY:-80}    # WebP 품질
MIN_KB=${MIN_KB:-150}     # 이 크기 이하는 건너뜀
cd "$(git rev-parse --show-toplevel)"

command -v cwebp >/dev/null || { echo "cwebp 가 없습니다: brew install webp" >&2; exit 1; }

REF_FILES=(*.html page/*.html assets/css/*.css assets/js/main.js)
# og:image(subnail.png)는 일부 SNS 가 WebP 를 못 읽어서 PNG 로 둔다.
SKIP_RE='favicon/'

if [ $# -gt 0 ]; then
  targets=("$@")
else
  targets=()
  while IFS= read -r -d '' f; do targets+=("$f"); done < <(
    find assets/img -type f -size +"${MIN_KB}"k \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -print0)
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
total_before=0; total_after=0

for src in "${targets[@]}"; do
  [[ "$src" =~ $SKIP_RE ]] && continue
  rel=${src#assets/}                     # img/blog/mind1.jpg
  # 주석이 아닌 실제 참조가 있는 이미지만 처리
  if ! grep -h -F "$rel" "${REF_FILES[@]}" 2>/dev/null | grep -qv '^[[:space:]]*<!--'; then
    continue
  fi
  dst="${src%.*}.webp"
  # 긴 변이 MAX 보다 클 때만 줄인다 (sips -Z 는 작은 이미지를 키우기도 하므로)
  long=$(sips -g pixelWidth -g pixelHeight "$src" | awk '/pixel/{if($2>m)m=$2}END{print m}')
  if [ "$long" -gt "$MAX" ]; then
    sips -s format png -Z "$MAX" "$src" --out "$tmp/r.png" >/dev/null
  else
    sips -s format png "$src" --out "$tmp/r.png" >/dev/null
  fi
  cwebp -quiet -q "$QUALITY" -metadata none "$tmp/r.png" -o "$dst"

  before=$(stat -f%z "$src"); after=$(stat -f%z "$dst")
  if [ "$after" -ge "$before" ]; then
    rm -f "$dst"; echo "skip (더 커짐) $src"; continue
  fi
  total_before=$((total_before + before)); total_after=$((total_after + after))

  new_rel="${rel%.*}.webp"
  for f in "${REF_FILES[@]}"; do
    [ -f "$f" ] || continue
    OLD="$rel" NEW="$new_rel" perl -pi -e 's/(?<=\/)\Q$ENV{OLD}\E(?=["\x27)\s?#])/$ENV{NEW}/g' "$f"
  done
  if grep -rqF "$rel" "${REF_FILES[@]}" 2>/dev/null; then
    echo "keep 원본(아직 참조 있음) $src"
  else
    git rm -q --cached "$src" 2>/dev/null || true
    rm -f "$src"
  fi
  printf '%-45s %6dKB -> %5dKB\n' "$src" $((before / 1024)) $((after / 1024))
done

echo "합계: $((total_before / 1024))KB -> $((total_after / 1024))KB"

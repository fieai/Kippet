#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")/.." && pwd)"
site="$project/site"
entries=(index.html en assets)
host=sense
root=/opt/projects/kippet
public=https://kippet.mindmesh.site

case "${1:-}" in
    --help|-h)
        printf '用法：%s [--dry-run]\n将静态网页发布到 %s，并校验公网文件。\n' "$0" "$public"
        exit 0
        ;;
    --dry-run)
        printf '%s → %s:%s/current → %s\n' "$site" "$host" "$root" "$public"
        exit 0
        ;;
    '') ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 1 ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/site-deploy.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
cd "$site"
find "${entries[@]}" \( -name '.*' -prune \) -o -type l -print > "$work/links"
if [[ -s "$work/links" ]]; then
    printf '发布目录不能含符号链接：\n' >&2
    cat "$work/links" >&2
    exit 1
fi
[[ -f index.html && -d assets && -f en/index.html ]] || { printf '缺少网页入口或 assets 目录\n' >&2; exit 1; }
find "${entries[@]}" \( -name '.*' -prune \) -o -type f -print0 > "$work/files"
mkdir "$work/content"
while IFS= read -r -d '' path; do
    mkdir -p -- "$work/content/$(dirname "$path")"
    cp -- "$path" "$work/content/$path"
done < "$work/files"
(
    cd "$work/content"
    xargs -0 shasum -a 256 < "$work/files" > .checksums
    COPYFILE_DISABLE=1 tar --no-xattrs -czf "$work/site.tar.gz" -- .checksums "${entries[@]}"
)

remote_script="$(cat <<'REMOTE'
set -euo pipefail
root="$1"
mkdir -p -- "$root/releases"
stage="$(mktemp -d "$root/releases/.staging.XXXXXXXX")"
suffix="${stage##*.}"
release="$root/releases/$(date -u +%Y%m%d-%H%M%S)-$suffix"
switch="$root/.current-$suffix"
trap 'rm -rf -- "$stage"; rm -f -- "$switch"' EXIT
tar -xzf - -C "$stage"
cd "$stage"
sha256sum --strict -c .checksums >&2
rm -- .checksums
find . -type d -exec chmod 755 {} +
find . -type f -exec chmod 644 {} +
cd "$root"
mv -T -- "$stage" "$release"
ln -s -- "releases/${release##*/}" "$switch"
mv -Tf -- "$switch" current
printf '%s\n' "$release"
REMOTE
)"
release="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$host" \
    "bash -c $(printf '%q' "$remote_script") -- '$root'" < "$work/site.tar.gz")"
printf '已切换到 %s，正在核对公网文件\n' "$release"

url_path() {
    local LC_ALL=C path="$1" byte i
    for ((i = 0; i < ${#path}; i++)); do
        byte="${path:i:1}"
        case "$byte" in
            [a-zA-Z0-9/._~-]) printf '%s' "$byte" ;;
            *) printf '%%%02X' "'$byte" ;;
        esac
    done
}

while IFS= read -r -d '' path; do
    case "$path" in
        index.html|*/index.html) url="$public/$(url_path "${path%index.html}")" ;;
        *) url="$public/$(url_path "$path")" ;;
    esac
    if ! curl -fsS --retry 3 --retry-all-errors --retry-max-time 12 \
        --connect-timeout 5 --max-time 10 -o "$work/public-file" "$url" ||
        ! cmp -s "$work/content/$path" "$work/public-file"; then
        printf '服务器已切换，但未能核对公网文件：%s\n' "$url" >&2
        exit 1
    fi
done < "$work/files"
printf '发布成功｜%s/\n' "$public"

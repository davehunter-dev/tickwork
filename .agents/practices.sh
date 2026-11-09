set -eu
cache=${XDG_CACHE_HOME:-$HOME/.cache}/practices
url=git@github.com:davehunter-dev/practices.git
[ -d "$cache/repo.git" ] || git clone -q --bare "$url" "$cache/repo.git"
git -C "$cache/repo.git" remote set-url origin "$url"
git -C "$cache/repo.git" fetch -q origin +main:main || echo "practices: fetch failed, using the last fetched main" >&2
load=$(git -C "$cache/repo.git" show main:load.sh)
sh -c "$load" load.sh "$cache"

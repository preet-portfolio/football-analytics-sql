#!/usr/bin/env bash
# Download the pinned raw source files into data/raw/ and verify them against
# data/checksums.sha256. Files already present are not re-downloaded.
set -euo pipefail
cd "$(dirname "$0")/.."
source config/sources.env

RAW=data/raw
SB="https://raw.githubusercontent.com/statsbomb/open-data/${STATSBOMB_COMMIT}/data"
OF="https://raw.githubusercontent.com/openfootball/worldcup.json/${OPENFOOTBALL_COMMIT}"

dl() {
  local url=$1 out=$2
  [ -s "$out" ] && return 0
  mkdir -p "$(dirname "$out")"
  curl -fsSL --retry 5 --retry-delay 2 -o "$out.part" "$url"
  mv "$out.part" "$out"
}
export -f dl

MATCHES="$RAW/statsbomb/matches/${COMPETITION_ID}/${SEASON_ID}.json"
dl "$SB/competitions.json" "$RAW/statsbomb/competitions.json"
dl "$SB/matches/${COMPETITION_ID}/${SEASON_ID}.json" "$MATCHES"
dl "$OF/${OPENFOOTBALL_PATH}" "$RAW/openfootball/${OPENFOOTBALL_PATH}"

ids=$(jq -r '.[].match_id' "$MATCHES")
echo "fetch: $(echo "$ids" | wc -l | tr -d ' ') matches in competition ${COMPETITION_ID}/${SEASON_ID}"

for entity in events lineups; do
  echo "$ids" | xargs -P 8 -I{} bash -c \
    "dl '$SB/$entity/{}.json' '$RAW/statsbomb/$entity/{}.json'"
done

if [ -f data/checksums.sha256 ]; then
  (cd "$RAW" && shasum -a 256 --quiet -c ../checksums.sha256)
  echo "fetch: all $(wc -l < data/checksums.sha256 | tr -d ' ') files match data/checksums.sha256"
else
  echo "fetch: no data/checksums.sha256 yet — run 'make lock' to record one" >&2
fi

#!/usr/bin/env bash
# Usage: yt.sh <youtube-url> ["Artist"] ["Album"]
# Downloads (playlist → one continuous mp3), tags it from Apple Music,
# adds cover.jpg + artist.jpg, uploads to R2 (Navidrome) and triggers a rescan on backl.
set -u

URL="$1"
ARTIST="${2:-}"
ALBUM="${3:-}"
ROOT="$HOME/Music/mixed"
REMOTE="r2:music/mixed"
SERVER="backl"
SERVER_MUSIC="/mnt/HC_Volume_34246576/music/mixed"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

uri() { jq -rn --arg s "$1" '$s|@uri'; }
lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# ---- Title / uploader (playlist title, or video title for single videos) ----
RAW_TITLE="$(yt-dlp --skip-download --playlist-end 1 --print "%(playlist_title,title)s" "$URL" | head -1)"
UPLOADER="$(yt-dlp --skip-download --playlist-end 1 --print "%(uploader)s" "$URL" | head -1)"
THUMB="$(yt-dlp --skip-download --playlist-end 1 --print "%(thumbnail)s" "$URL" | head -1)"

# ---- Guess "Artist - Album" from the title ----
CLEAN="$(echo "$RAW_TITLE" \
  | sed -E 's/[[({][^])}]*[])}]//g' \
  | perl -pe "s/\\b(full album|full lp|hd|hq|official audio)\\b//gi" \
  | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//')"
SPLIT="$(echo "$CLEAN" | perl -CS -pe 's/ (-|–|~|▶|\||｜) /\t/')"
if [[ "$SPLIT" == *$'\t'* ]]; then
  GUESS_ARTIST="$(echo "${SPLIT%%$'\t'*}" | sed 's/ *$//')"
  GUESS_ALBUM="$(echo "${SPLIT#*$'\t'}" | sed 's/^ *//; s/[ -]*$//')"
else
  GUESS_ARTIST=""
  GUESS_ALBUM="$CLEAN"
fi
[ -z "$ARTIST" ] && ARTIST="$GUESS_ARTIST"
[ -z "$ALBUM" ] && ALBUM="$GUESS_ALBUM"

# ---- Album lookup: Deezer first (best catalog + covers), Apple Music as fallback ----
# Prefers an exact title match and real albums over EPs/remix/expanded editions.
GENRE=""; YEAR=""; COVER_URL=""; ITUNES_URL=""
NORM='def n: ascii_downcase | gsub(" *[(\\[][^)\\]]*[)\\]]"; "") | gsub("[^a-z0-9]"; "");'
# Score: exact title > title containing the guess; penalise reissues/live/remix; prefer albums with fewer tracks.
PICK='($b|n) as $g
  | [ .[] | select(($a != "" and (.artist|ascii_downcase) == $a) or ($a == "" and ($t | contains(.artist|ascii_downcase))))
      | (.title|n) as $c
      | select($c != "" and $g != "" and (($g|contains($c)) or ($c|contains($g))))
      | . + {score: ((if $c == $g then 100 else 50 end) + (if .album then 10 else 0 end)
                     - ((($c|length) - ($g|length)) | fabs)
                     - (if (.title|test("live|remix|deluxe|expanded|anniversary|edition|super|remaster|version|\\bEP\\b"; "i")) then 40 else 0 end)
                     - (if (.title|test("[(\\[]")) then 20 else 0 end)
                     - ((.tracks // 0) / 100))} ]
  | sort_by(-.score) | .[0] // empty'
HIT="$(curl -fsS "https://api.deezer.com/search/album?limit=25&q=$(uri "$ARTIST $ALBUM")" \
  | jq -c --arg a "$(lc "$ARTIST")" --arg b "$ALBUM" --arg t "$(lc "$RAW_TITLE")" \
    "$NORM [.data[] | {id, title, artist: .artist.name, album: (.record_type == \"album\"), tracks: .nb_tracks, cover: .cover_xl}] | $PICK" 2>/dev/null)"
if [ -n "$HIT" ]; then
  INFO="$(curl -fsS "https://api.deezer.com/album/$(echo "$HIT" | jq -r .id)")"
  ARTIST="$(echo "$HIT" | jq -r .artist)"
  ALBUM="$(echo "$HIT" | jq -r .title)"
  COVER_URL="$(echo "$HIT" | jq -r .cover | sed 's#/1000x1000-#/1400x1400-#')"
  YEAR="$(echo "$INFO" | jq -r '.release_date // "" | .[0:4]')"
  GENRE="$(echo "$INFO" | jq -r '.genres.data[0].name // ""')"
  ITUNES_URL="$(echo "$INFO" | jq -r '.link // ""')"
else
  HIT="$(curl -fsS "https://itunes.apple.com/search?entity=album&limit=25&term=$(uri "$ARTIST $ALBUM")" \
    | jq -c --arg a "$(lc "$ARTIST")" --arg b "$ALBUM" --arg t "$(lc "$RAW_TITLE")" \
      "$NORM [.results[] | . + {title: .collectionName, artist: .artistName, album: (.collectionName|test(\" - (EP|Single)$\")|not)}] | $PICK" 2>/dev/null)"
  if [ -n "$HIT" ]; then
    ARTIST="$(echo "$HIT" | jq -r .artist)"
    ALBUM="$(echo "$HIT" | jq -r .title)"
    GENRE="$(echo "$HIT" | jq -r '.primaryGenreName // ""')"
    YEAR="$(echo "$HIT" | jq -r '.releaseDate // "" | .[0:4]')"
    COVER_URL="$(echo "$HIT" | jq -r .artworkUrl100 | sed 's/100x100bb/1200x1200bb/')"
    ITUNES_URL="$(echo "$HIT" | jq -r '.collectionViewUrl // ""')"
  else
    echo "⚠️  No Deezer/Apple Music match — using YouTube title/thumbnail"
  fi
fi
ALBUM="$(echo "$ALBUM" | perl -pe 's/ *[(\[][^)\]]*(remaster|deluxe|edition|expanded|anniversary|version)[^)\]]*[)\]]//gi')"
# Original release year (Deezer/Apple often date the reissue) from MusicBrainz.
if [ -n "$ARTIST" ] && [ -n "$ALBUM" ]; then
  MB_Q="releasegroup:\"$(echo "$ALBUM" | tr -d '"\\')\" AND artist:\"$(echo "$ARTIST" | tr -d '"\\')\" AND primarytype:album"
  MB_YEAR="$(sleep 1; curl -fsS --retry 5 --retry-all-errors --retry-delay 3 -A "yt.sh/1.0 (philipp@backl.io)" "https://musicbrainz.org/ws/2/release-group?fmt=json&limit=5&query=$(uri "$MB_Q")" \
    | jq -r '[."release-groups"[] | select(.score >= 90) | ."first-release-date" // "" | select(length >= 4) | .[0:4]] | min // empty' 2>/dev/null)"
  [ -n "$MB_YEAR" ] && YEAR="$MB_YEAR"
fi
[ -z "$ARTIST" ] && ARTIST="$UPLOADER"
[ -z "$ALBUM" ] && ALBUM="$RAW_TITLE"
echo "🎵 $ARTIST — $ALBUM ${YEAR:+($YEAR)} ${GENRE:+[$GENRE]}"

SAFE() { echo "$1" | sed 's#[/:]#-#g'; }
ARTIST_DIR="$ROOT/$(SAFE "$ARTIST")"
DIR="$ARTIST_DIR/$(SAFE "$ALBUM")"   # one folder per album, so each gets its own cover.jpg
OUTFILE="$DIR/$(SAFE "$ARTIST - $ALBUM").mp3"
mkdir -p "$DIR"

# ---- Cover + artist art ----
curl -fsSL "${COVER_URL:-$THUMB}" -o "$TMPDIR/cover.img" \
  && ffmpeg -loglevel error -y -i "$TMPDIR/cover.img" -q:v 2 "$DIR/cover.jpg"
ARTIST_PIC="$(curl -fsS "https://api.deezer.com/search/artist?limit=5&q=$(uri "$ARTIST")" \
  | jq -r --arg a "$(lc "$ARTIST")" \
    '[.data[] | select((.name|ascii_downcase) == $a) | .picture_xl | select(test("/artist//")|not)][0] // empty' 2>/dev/null)"
if [ -n "$ARTIST_PIC" ]; then
  curl -fsSL "$ARTIST_PIC" -o "$ARTIST_DIR/artist.jpg"
elif [ ! -f "$ARTIST_DIR/artist.jpg" ]; then
  cp "$DIR/cover.jpg" "$ARTIST_DIR/artist.jpg"
fi

# ---- Download audio with progress bar ----
bar() {  # reads "pct|idx|total|speed|eta" lines from yt-dlp, draws one updating bar
  local pct idx total speed eta p n fill
  while IFS='|' read -r pct idx total speed eta; do
    pct="${pct//[^0-9.]/}"; p="${pct%.*}"; n=$(( ${p:-0} * 30 / 100 ))
    fill="$(printf '%*s' "$n" '' | tr ' ' '#')$(printf '%*s' $((30 - n)) '' | tr ' ' '-')"
    printf '\r\033[K⬇️  [%s/%s] [%s] %5s%%  %s  ETA %s' \
      "${idx/NA/1}" "${total/NA/1}" "$fill" "$pct" "$speed" "$eta"
    [ "${p:-0}" -ge 100 ] && printf '  → converting to mp3…'
  done
  echo
}
yt-dlp \
  --quiet \
  --no-warnings \
  --progress \
  --newline \
  --progress-template "download:%(progress._percent_str)s|%(info.playlist_index)s|%(info.n_entries)s|%(progress._speed_str)s|%(progress._eta_str)s" \
  --ignore-errors \
  -f bestaudio \
  --extract-audio \
  --audio-format mp3 \
  --audio-quality 0 \
  -o "$TMPDIR/%(playlist_index)03d.%(ext)s" \
  "$URL" | bar

MP3_COUNT=$(ls "$TMPDIR"/*.mp3 2>/dev/null | wc -l | tr -d ' ')
if [ "$MP3_COUNT" -eq 0 ]; then
  echo "❌ No audio files downloaded"
  exit 1
fi

# ---- Concatenate (silent ffmpeg) ----
ls "$TMPDIR"/*.mp3 | sort | sed "s/.*/file '&'/" > "$TMPDIR/concat.txt"
echo "🔗 Joining + encoding…"
ffmpeg -loglevel error -stats -f concat -safe 0 -i "$TMPDIR/concat.txt" \
  -c:a libmp3lame -q:a 0 "$TMPDIR/joined.mp3" || exit 1

# ---- Tag + embed cover ----
ffmpeg -loglevel error -y -i "$TMPDIR/joined.mp3" -i "$DIR/cover.jpg" \
  -map 0:a -map 1:v -c copy -id3v2_version 3 -disposition:v attached_pic \
  -metadata:s:v title="Album cover" -metadata:s:v comment="Cover (front)" \
  -metadata artist="$ARTIST" -metadata album_artist="$ARTIST" \
  -metadata album="$ALBUM" -metadata title="$ALBUM" -metadata track=1 \
  -metadata genre="$GENRE" -metadata date="$YEAR" -metadata purl="$URL" \
  -metadata comment="Continuous full album. Source: $URL${ITUNES_URL:+ Metadata: $ITUNES_URL}" \
  "$OUTFILE" || exit 1
echo "✅ $OUTFILE"

# ---- Upload to R2 (Navidrome library) ----
rclone copy "$ARTIST_DIR" "$REMOTE/$(basename "$ARTIST_DIR")" --exclude ".DS_Store" --progress || exit 1

# ---- Rescan on backl (waits for the R2 mount's 5 min dir cache) ----
REL="mixed/$(basename "$ARTIST_DIR")"
FILE="$SERVER_MUSIC/$(basename "$ARTIST_DIR")/$(basename "$DIR")/$(basename "$OUTFILE")"
SIZE="$(stat -f %z "$OUTFILE")"
echo "🔄 Waiting for file on $SERVER, then rescanning ${REL}…"
# Wait for the new size, not just existence: a re-download keeps the same path, and the mount may still serve the old file.
# Scan as the navidrome user: only it can write the DB. Scan exits 0 even on errors, so any output (-l error) = failure.
if SCAN_OUT="$(ssh "$SERVER" "for i in \$(seq 1 40); do [ \"\$(stat -c %s $(printf %q "$FILE") 2>/dev/null)\" = $SIZE ] && break; sleep 10; done; \
  cd / && sudo -n -u navidrome /opt/navidrome/navidrome scan -n -c /opt/navidrome/navidrome.toml -l error -t $(printf %q "1:$REL")" 2>&1)" \
  && [ -z "$SCAN_OUT" ]; then
  echo "✅ Navidrome rescanned"
else
  [ -n "$SCAN_OUT" ] && echo "$SCAN_OUT"
  echo "⚠️  Rescan failed (auto-scan runs every 15m anyway)"
fi

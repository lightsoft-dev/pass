#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
FONT_KO="/System/Library/Fonts/AppleSDGothicNeo.ttc"
FONT_EN="/System/Library/Fonts/SFNS.ttf"

IPHONE_RAW=(
  "$ROOT/raw/iphone/00-current.png"
  "$ROOT/raw/iphone/05-after-open.png"
  "$ROOT/raw/iphone/02-live.png"
  "$ROOT/raw/iphone/03-create.png"
)
IPAD_RAW=(
  "$ROOT/raw/ipad/00-inbox.png"
  "$ROOT/raw/ipad/01-decision.png"
  "$ROOT/raw/ipad/02-live.png"
  "$ROOT/raw/ipad/03-create.png"
)
ANDROID_RAW=(
  "$ROOT/raw/android/00-inbox.png"
  "$ROOT/raw/android/01-decision.png"
  "$ROOT/raw/android/02-live.png"
  "$ROOT/raw/android/03-create.png"
)

KO_TITLES=(
  $'코딩 에이전트를\n어디서든 한눈에'
  $'승인 요청에\n바로 응답하세요'
  $'진행 중인 작업을\n실시간으로 확인'
  $'새 세션을\n휴대폰에서 시작'
)
EN_TITLES=(
  $'All Your Coding Agents\nIn One Place'
  $'Approve Requests\nWithout Leaving Your Phone'
  $'Follow Every Task\nAs It Happens'
  $'Start New Sessions\nFrom Anywhere'
)

make_phone_asset() {
  local raw="$1" output="$2" title="$3" font="$4" width="$5" height="$6"
  local shot_width=$((width * 74 / 100))
  local shot_height=$((height * 72 / 100))
  local shot_y=$((height * 27 / 100))
  local radius=$((width * 5 / 100))
  local temp
  temp="$(mktemp -t pass-phone.XXXXXX.png)"

  magick "$raw" -resize "${shot_width}x${shot_height}^" -gravity center \
    -extent "${shot_width}x${shot_height}" \
    \( +clone -alpha transparent -fill white \
       -draw "roundrectangle 0,0 $((shot_width - 1)),$((shot_height - 1)),$radius,$radius" \) \
    -alpha off -compose CopyOpacity -composite "$temp"

  magick -size "${width}x${height}" gradient:'#1b1435-#090b12' \
    -fill '#8b7cf626' -draw "circle $((width * 92 / 100)),$((height * 8 / 100)) $((width * 62 / 100)),$((height * 8 / 100))" \
    -fill '#4f9cff18' -draw "circle $((width * 8 / 100)),$((height * 78 / 100)) $((width * 42 / 100)),$((height * 78 / 100))" \
    -font "$font" -fill '#9b8cff' -pointsize $((width * 32 / 1000)) \
    -gravity north -annotate "+0+$((height * 42 / 1000))" "PASS REMOTE" \
    -font "$font" -fill white -pointsize $((width * 68 / 1000)) \
    -interline-spacing $((width * 8 / 1000)) -gravity north \
    -annotate "+0+$((height * 76 / 1000))" "$title" \
    \( "$temp" -background black -shadow 55x22+0+18 \) \
    -gravity north -geometry "+0+$((shot_y + 18))" -compose over -composite \
    "$temp" -gravity north -geometry "+0+$shot_y" -compose over -composite \
    -alpha off -strip "$output"

  rm -f "$temp"
}

make_ipad_asset() {
  local raw="$1" output="$2" title="$3" font="$4"
  local width=2048 height=2732 shot_width=1660 shot_height=2214 shot_y=500 radius=72
  local temp
  temp="$(mktemp -t pass-ipad.XXXXXX.png)"

  magick "$raw" -resize "${shot_width}x${shot_height}^" -gravity center \
    -extent "${shot_width}x${shot_height}" \
    \( +clone -alpha transparent -fill white \
       -draw "roundrectangle 0,0 $((shot_width - 1)),$((shot_height - 1)),$radius,$radius" \) \
    -alpha off -compose CopyOpacity -composite "$temp"

  magick -size "${width}x${height}" gradient:'#1b1435-#090b12' \
    -fill '#8b7cf626' -draw "circle 1860,220 1220,220" \
    -fill '#4f9cff18' -draw "circle 160,2300 800,2300" \
    -font "$font" -fill '#9b8cff' -pointsize 54 -gravity north -annotate +0+74 "PASS REMOTE" \
    -font "$font" -fill white -pointsize 104 -interline-spacing 10 \
    -gravity north -annotate +0+140 "$title" \
    \( "$temp" -background black -shadow 55x24+0+18 \) \
    -gravity north -geometry +0+518 -compose over -composite \
    "$temp" -gravity north -geometry "+0+$shot_y" -compose over -composite \
    -alpha off -strip "$output"

  rm -f "$temp"
}

make_feature_graphic() {
  local output="$1" subtitle="$2" font="$3"
  magick -size 1024x500 gradient:'#1b1435-#090b12' \
    -fill '#8b7cf638' -draw 'circle 935,50 650,50' \
    \( "$ROOT/../mobile/assets/icon.png" -resize 250x250 \) \
    -gravity west -geometry +74+0 -compose over -composite \
    -font "$font" -fill white -pointsize 76 -gravity northwest -annotate +390+145 "Pass Remote" \
    -font "$font" -fill '#c9c3e8' -pointsize 34 -gravity northwest -annotate +394+250 "$subtitle" \
    -alpha off -strip "$output"
}

for locale in ko en; do
  if [[ "$locale" == "ko" ]]; then
    titles=("${KO_TITLES[@]}")
    font="$FONT_KO"
    feature_subtitle="코딩 에이전트를 어디서든"
  else
    titles=("${EN_TITLES[@]}")
    font="$FONT_EN"
    feature_subtitle="Your coding agents, anywhere"
  fi

  mkdir -p \
    "$ROOT/ios/$locale/iphone-6.7" \
    "$ROOT/ios/$locale/iphone-6.5" \
    "$ROOT/ios/$locale/ipad-12.9" \
    "$ROOT/google-play/$locale/phone"

  for i in 0 1 2 3; do
    number="$(printf '%02d' $((i + 1)))"
    make_phone_asset "${IPHONE_RAW[$i]}" \
      "$ROOT/ios/$locale/iphone-6.7/$number.png" "${titles[$i]}" "$font" 1290 2796
    make_phone_asset "${IPHONE_RAW[$i]}" \
      "$ROOT/ios/$locale/iphone-6.5/$number.png" "${titles[$i]}" "$font" 1284 2778
    make_ipad_asset "${IPAD_RAW[$i]}" \
      "$ROOT/ios/$locale/ipad-12.9/$number.png" "${titles[$i]}" "$font"
    make_phone_asset "${ANDROID_RAW[$i]}" \
      "$ROOT/google-play/$locale/phone/$number.png" "${titles[$i]}" "$font" 1080 1920
  done

  make_feature_graphic "$ROOT/google-play/$locale/feature-graphic.png" "$feature_subtitle" "$font"
done

magick \
  "$ROOT/ios/ko/iphone-6.7/01.png" \
  "$ROOT/ios/ko/iphone-6.7/02.png" \
  "$ROOT/ios/ko/iphone-6.7/03.png" \
  "$ROOT/ios/ko/iphone-6.7/04.png" \
  -thumbnail 260x560 -background '#090b12' -gravity center +append \
  "$ROOT/preview-ko.png"

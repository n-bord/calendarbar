#!/bin/bash

select_xcode() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "Для сборки CalendarBar нужен Mac." >&2
    return 1
  fi

  local developer_dir="${DEVELOPER_DIR:-}" xcode xcode_major
  if [ -z "$developer_dir" ]; then
    developer_dir="$(/usr/bin/xcode-select --print-path 2>/dev/null || true)"
  fi
  if [ -d "$developer_dir/Contents/Developer" ]; then
    developer_dir="$developer_dir/Contents/Developer"
  fi
  if [ ! -x "$developer_dir/usr/bin/xcodebuild" ]; then
    developer_dir=""
    for xcode in /Applications/Xcode.app "$HOME/Applications/Xcode.app" /Applications/Xcode*.app; do
      if [ -x "$xcode/Contents/Developer/usr/bin/xcodebuild" ]; then
        developer_dir="$xcode/Contents/Developer"
        break
      fi
    done
  fi
  if [ -z "$developer_dir" ]; then
    echo "Для сборки нужен полный Xcode 16 или новее. Откройте Xcode и завершите первоначальную настройку." >&2
    return 1
  fi
  export DEVELOPER_DIR="$developer_dir"
  xcode_major="$(/usr/bin/xcodebuild -version | /usr/bin/awk 'NR==1 {split($2, parts, "."); print parts[1]}')"
  if [[ ! "$xcode_major" =~ ^[0-9]+$ ]] || [ "$xcode_major" -lt 16 ]; then
    echo "Для сборки нужен Xcode 16 или новее. Выбран: $DEVELOPER_DIR" >&2
    return 1
  fi
  SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
  export SDKROOT
}

prepare_build_cache() {
  local cache_root="${CALENDARBAR_BUILD_CACHE_ROOT:-}"
  if [ -n "$cache_root" ]; then
    mkdir -p "$cache_root/modules" "$cache_root/config" "$cache_root/security"
    cache_root="$(cd "$cache_root" && pwd -P)"
    CALENDARBAR_BUILD_CACHE_ROOT="$cache_root"
    export CLANG_MODULE_CACHE_PATH="$cache_root/modules"
    export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/modules"
  fi
}

calendarbar_swift() {
  local cache_root="${CALENDARBAR_BUILD_CACHE_ROOT:-}"
  if [ -n "$cache_root" ]; then
    set -- "$@" --scratch-path "$cache_root/build" --cache-path "$cache_root/cache" \
      --config-path "$cache_root/config" --security-path "$cache_root/security"
  fi
  if [ "${CALENDARBAR_DISABLE_SWIFTPM_SANDBOX:-0}" = "1" ]; then
    set -- "$@" --disable-sandbox
  fi
  /usr/bin/xcrun --sdk macosx swift "$@"
}

# The project root is the working directory. Stage and verify before publishing
# so a failed icon conversion or signature leaves the previous bundle intact.
package_calendarbar() (
  local binary="$1" app_path="$2" identity="$3" variant="$4"
  local dist_dir bundle contents executable="CalendarBar" product_name="CalendarBar" iconset size retina_size
  dist_dir="$(dirname "$app_path")"
  mkdir -p "$dist_dir"
  stage="$(mktemp -d "$dist_dir/.calendarbar-package.XXXXXX")"
  trap 'rm -rf -- "$stage"' EXIT
  bundle="$stage/$(basename "$app_path")"
  contents="$bundle/Contents"
  mkdir -p "$contents/MacOS" "$contents/Resources"
  cp Info.plist "$contents/Info.plist"
  case "$variant" in
    dev) product_name="CalendarBar Dev"; executable="CalendarBarDev" ;;
    demo) product_name="CalendarBar Demo"; executable="CalendarBarDemo" ;;
  esac
  if [ "$product_name" != "CalendarBar" ]; then
    /usr/libexec/PlistBuddy \
      -c "Set :CFBundleIdentifier com.nbord.CalendarBar.$variant" \
      -c "Set :CFBundleExecutable $executable" \
      -c "Set :CFBundleName $product_name" \
      -c "Set :CFBundleDisplayName $product_name" "$contents/Info.plist"
  fi
  cp "$binary" "$contents/MacOS/$executable"
  iconset="$stage/CalendarBar.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    /usr/bin/sips -z "$retina_size" "$retina_size" Assets/AppIcon.png \
      --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  if ! /usr/bin/iconutil --convert icns "$iconset" --output "$contents/Resources/AppIcon.icns" 2>"$stage/iconutil.log"; then
    # Some restricted environments cannot encode a multi-size icon with iconutil.
    # Preserve the same artwork in a single 512 px system icon in that case.
    if ! /usr/bin/sips -s format icns "$iconset/icon_512x512.png" --out "$contents/Resources/AppIcon.icns" >/dev/null; then
      cat "$stage/iconutil.log" >&2
      exit 1
    fi
  fi
  /usr/bin/codesign --force --sign "$identity" "$bundle"
  /usr/bin/codesign --verify --strict "$bundle"
  rm -rf -- "$app_path"
  mv -- "$bundle" "$app_path"
)

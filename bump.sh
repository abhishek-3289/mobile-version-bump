#!/bin/bash
set -euo pipefail

INCREMENT_TYPE=${INCREMENT_TYPE:-patch}
EXPLICIT_VERSION=${EXPLICIT_VERSION:-}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_NUMBER_STRATEGY=${BUILD_NUMBER_STRATEGY:-run-number}
BUILD_NUMBER_OFFSET=${BUILD_NUMBER_OFFSET:-0}
ANDROID_FILE=${ANDROID_FILE:-}
ANDROID_VERSION_NAME_KEY=${ANDROID_VERSION_NAME_KEY:-VERSION_NAME}
ANDROID_VERSION_CODE_KEY=${ANDROID_VERSION_CODE_KEY:-}
IOS_FILE=${IOS_FILE:-}
DRY_RUN=${DRY_RUN:-false}
OUTPUT_FILE=${GITHUB_OUTPUT:-/dev/stdout}
ANDROID_MAX_VERSION_CODE=2100000000

CHANGED_FILES=""
ANDROID_FORMAT=""
IOS_FORMAT=""
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  echo "::error::$*"
  exit 1
}

warn() {
  echo "::warning::$*"
}

is_uint() {
  [[ $1 =~ ^[0-9]+$ ]]
}

validate_inputs() {
  case $INCREMENT_TYPE in
    major | minor | patch) ;;
    *) fail "increment-type must be one of major, minor, patch (https://semver.org/), got '$INCREMENT_TYPE'" ;;
  esac
  if [[ -n $EXPLICIT_VERSION && ! $EXPLICIT_VERSION =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "version must look like X.Y.Z (optionally prefixed with v), got '$EXPLICIT_VERSION'"
  fi
  if [[ -n $BUILD_NUMBER ]] && ! is_uint "$BUILD_NUMBER"; then
    fail "build-number must be a non-negative integer, got '$BUILD_NUMBER'"
  fi
  case $BUILD_NUMBER_STRATEGY in
    run-number | increment | semver) ;;
    *) fail "build-number-strategy must be one of run-number, increment, semver, got '$BUILD_NUMBER_STRATEGY'" ;;
  esac
  if ! is_uint "$BUILD_NUMBER_OFFSET"; then
    fail "build-number-offset must be a non-negative integer, got '$BUILD_NUMBER_OFFSET'"
  fi
  case $DRY_RUN in
    true | false) ;;
    *) fail "dry-run must be true or false, got '$DRY_RUN'" ;;
  esac
  if [[ ! $ANDROID_VERSION_NAME_KEY =~ ^[A-Za-z0-9_.-]+$ ]]; then
    fail "android-version-name-key may only contain letters, digits, '.', '_' and '-', got '$ANDROID_VERSION_NAME_KEY'"
  fi
  if [[ -n $ANDROID_VERSION_CODE_KEY && ! $ANDROID_VERSION_CODE_KEY =~ ^[A-Za-z0-9_.-]+$ ]]; then
    fail "android-version-code-key may only contain letters, digits, '.', '_' and '-', got '$ANDROID_VERSION_CODE_KEY'"
  fi
}

find_latest_tag() {
  if ! git fetch --tags --force --quiet 2>/dev/null; then
    warn "Could not fetch tags from remote; using tags available locally"
  fi
  LATEST_TAG=$(
    git tag --list \
      | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
      | awk '{ version = $0; sub(/^v/, "", version); print version " " $0 }' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -n 1 \
      | cut -d' ' -f2 \
      || true
  )
  LATEST_TAG=${LATEST_TAG:-v0.0.0}
  [[ $LATEST_TAG =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
  MAJOR=$((10#${BASH_REMATCH[1]}))
  MINOR=$((10#${BASH_REMATCH[2]}))
  PATCH=$((10#${BASH_REMATCH[3]}))
  PREVIOUS_VERSION="$MAJOR.$MINOR.$PATCH"
}

calculate_version() {
  if [[ -n $EXPLICIT_VERSION ]]; then
    [[ $EXPLICIT_VERSION =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
    MAJOR=$((10#${BASH_REMATCH[1]}))
    MINOR=$((10#${BASH_REMATCH[2]}))
    PATCH=$((10#${BASH_REMATCH[3]}))
  else
    case $INCREMENT_TYPE in
      major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
      minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
      patch)
        PATCH=$((PATCH + 1))
        ;;
    esac
  fi
  VERSION="$MAJOR.$MINOR.$PATCH"
}

prop_awk() {
  PROP_MODE=$1 PROP_KEY=$2 PROP_VALUE=${4:-} awk '
    BEGIN {
      mode = ENVIRON["PROP_MODE"]
      key = ENVIRON["PROP_KEY"]
      value = ENVIRON["PROP_VALUE"]
      found = 0
    }
    {
      line = $0
      if (line !~ /^[ \t]*[#!]/ && match(line, /[=:]/)) {
        name = substr(line, 1, RSTART - 1)
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        if (name == key) {
          prefix = substr(line, 1, RSTART)
          rest = substr(line, RSTART + 1)
          match(rest, /^[ \t]*/)
          prefix = prefix substr(rest, 1, RLENGTH)
          current = substr(rest, RLENGTH + 1)
          sub(/[ \t\r]+$/, "", current)
          if (!found && mode == "get") {
            print current
          }
          if (mode == "set") {
            line = prefix value
          }
          found = 1
        }
      }
      if (mode == "set") {
        print line
      }
    }
    END {
      if (mode == "set" && !found) {
        print key "=" value
      }
      if (mode == "has") {
        exit (found ? 0 : 1)
      }
    }
  ' "$3"
}

prop_has() {
  prop_awk has "$2" "$1"
}

prop_get() {
  prop_awk get "$2" "$1"
}

prop_set() {
  prop_awk set "$2" "$1" "$3" > "$1.tmp"
  mv "$1.tmp" "$1"
}

sed_edit() {
  local file=$1
  shift
  sed -E "$@" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

plist_awk() {
  PLIST_MODE=$1 PLIST_KEY=$2 PLIST_VALUE=${4:-} awk '
    BEGIN {
      mode = ENVIRON["PLIST_MODE"]
      tag = "<key>" ENVIRON["PLIST_KEY"] "</key>"
      value = ENVIRON["PLIST_VALUE"]
      pending = 0
      done = 0
    }
    {
      line = $0
      head = ""
      if (!done && !pending) {
        k = index(line, tag)
        if (k > 0) {
          pending = 1
          head = substr(line, 1, k + length(tag) - 1)
          line = substr(line, k + length(tag))
        }
      }
      if (pending) {
        s = index(line, "<string>")
        if (s > 0) {
          rest = substr(line, s + 8)
          e = index(rest, "</string>")
          if (e > 0) {
            current = substr(rest, 1, e - 1)
            pending = 0
            done = 1
            if (mode == "get") {
              print "=" current
            }
            if (mode == "set" && substr(current, 1, 2) != "$(") {
              line = substr(line, 1, s + 7) value substr(rest, e)
            }
          }
        } else if (line ~ /</) {
          pending = 0
          done = 1
        }
      }
      if (mode == "set") {
        print head line
      }
    }
  ' "$3"
}

plist_get() {
  local raw
  raw=$(plist_awk get "$2" "$1")
  if [[ -z $raw ]]; then
    return 1
  fi
  printf '%s\n' "${raw#=}"
}

plist_is_literal() {
  local value
  if ! value=$(plist_get "$1" "$2"); then
    return 1
  fi
  if [[ $value == "\$("* ]]; then
    warn "$2 in $1 references a build setting ($value) and is left unchanged; point ios-file at the xcconfig or project.pbxproj that defines it"
    return 1
  fi
  return 0
}

plist_set() {
  plist_awk set "$2" "$1" "$3" > "$1.tmp"
  mv "$1.tmp" "$1"
}

gradle_has_name() {
  grep -Eq "^[[:space:]]*versionName([[:space:]]*=[[:space:]]*|[[:space:]]+)[\"']" "$1"
}

gradle_has_code() {
  grep -Eq '^[[:space:]]*versionCode([[:space:]]*=[[:space:]]*|[[:space:]]+)[0-9]+' "$1"
}

semver_props_recognised() {
  grep -Eq '^[[:space:]]*version\.(major|minor|patch|semver)[[:space:]]*[=:]' "$1"
}

gradle_props_code_key() {
  printf '%s\n' "${ANDROID_VERSION_CODE_KEY:-VERSION_CODE}"
}

xcconfig_has() {
  grep -Eq "^[[:space:]]*$2[[:space:]]*=" "$1"
}

pbxproj_has() {
  grep -Eq "(^|[^A-Za-z0-9_])$2[[:space:]]*=[^;]*;" "$1"
}

detect_android_format() {
  local file=$1 name
  name=$(basename "$file")
  case $name in
    version.properties) ANDROID_FORMAT="semver-properties" ;;
    gradle.properties) ANDROID_FORMAT="gradle-properties" ;;
    *.gradle | *.gradle.kts) ANDROID_FORMAT="gradle-script" ;;
    *)
      if semver_props_recognised "$file"; then
        ANDROID_FORMAT="semver-properties"
      elif gradle_has_name "$file" || gradle_has_code "$file"; then
        ANDROID_FORMAT="gradle-script"
      elif prop_has "$file" "$ANDROID_VERSION_NAME_KEY" || prop_has "$file" "$(gradle_props_code_key)"; then
        ANDROID_FORMAT="gradle-properties"
      fi
      ;;
  esac
  case $ANDROID_FORMAT in
    semver-properties)
      semver_props_recognised "$file" || ANDROID_FORMAT=""
      ;;
    gradle-script)
      gradle_has_name "$file" || gradle_has_code "$file" || ANDROID_FORMAT=""
      ;;
    gradle-properties)
      prop_has "$file" "$ANDROID_VERSION_NAME_KEY" || prop_has "$file" "$(gradle_props_code_key)" || ANDROID_FORMAT=""
      ;;
  esac
  if [[ -z $ANDROID_FORMAT ]]; then
    fail "android-file $file contains no recognised version field (version.properties keys, versionName/versionCode, or $ANDROID_VERSION_NAME_KEY/$(gradle_props_code_key))"
  fi
}

detect_ios_format() {
  local file=$1 name literal
  name=$(basename "$file")
  if [[ $(head -c 6 "$file") == bplist ]]; then
    fail "ios-file $file is a binary plist, which is not supported; convert it with 'plutil -convert xml1 $file' and commit the XML version"
  fi
  case $name in
    *.xcconfig) IOS_FORMAT="xcconfig" ;;
    *.pbxproj) IOS_FORMAT="pbxproj" ;;
    *.plist) IOS_FORMAT="plist" ;;
    *)
      if grep -q '<plist' "$file"; then
        IOS_FORMAT="plist"
      elif pbxproj_has "$file" MARKETING_VERSION || pbxproj_has "$file" CURRENT_PROJECT_VERSION; then
        IOS_FORMAT="pbxproj"
      elif xcconfig_has "$file" MARKETING_VERSION || xcconfig_has "$file" CURRENT_PROJECT_VERSION; then
        IOS_FORMAT="xcconfig"
      fi
      ;;
  esac
  case $IOS_FORMAT in
    xcconfig)
      xcconfig_has "$file" MARKETING_VERSION || xcconfig_has "$file" CURRENT_PROJECT_VERSION || IOS_FORMAT=""
      ;;
    pbxproj)
      pbxproj_has "$file" MARKETING_VERSION || pbxproj_has "$file" CURRENT_PROJECT_VERSION || IOS_FORMAT=""
      ;;
    plist)
      literal=0
      if grep -q '<plist' "$file"; then
        if plist_is_literal "$file" CFBundleShortVersionString; then
          literal=1
        fi
        if plist_is_literal "$file" CFBundleVersion; then
          literal=1
        fi
      fi
      if [[ $literal == 0 ]]; then
        IOS_FORMAT=""
      fi
      ;;
  esac
  if [[ -z $IOS_FORMAT ]]; then
    fail "ios-file $file contains no recognised version field (MARKETING_VERSION/CURRENT_PROJECT_VERSION or CFBundleShortVersionString/CFBundleVersion string values)"
  fi
}

detect_formats() {
  if [[ -n $ANDROID_FILE ]]; then
    [[ -f $ANDROID_FILE ]] || fail "android-file $ANDROID_FILE does not exist"
    detect_android_format "$ANDROID_FILE"
    echo "Android file: $ANDROID_FILE ($ANDROID_FORMAT)"
  fi
  if [[ -n $IOS_FILE ]]; then
    [[ -f $IOS_FILE ]] || fail "ios-file $IOS_FILE does not exist"
    detect_ios_format "$IOS_FILE"
    echo "iOS file: $IOS_FILE ($IOS_FORMAT)"
  fi
}

read_android_build_number() {
  local file=$1 key
  case $ANDROID_FORMAT in
    semver-properties)
      if [[ -n $ANDROID_VERSION_CODE_KEY ]] && prop_has "$file" "$ANDROID_VERSION_CODE_KEY"; then
        prop_get "$file" "$ANDROID_VERSION_CODE_KEY"
      fi
      ;;
    gradle-properties)
      key=$(gradle_props_code_key)
      if prop_has "$file" "$key"; then
        prop_get "$file" "$key"
      fi
      ;;
    gradle-script)
      sed -nE 's/^[[:space:]]*versionCode([[:space:]]*=[[:space:]]*|[[:space:]]+)([0-9]+).*/\2/p' "$file" | awk 'NR == 1'
      ;;
  esac
}

read_ios_build_number() {
  local file=$1
  case $IOS_FORMAT in
    xcconfig)
      sed -nE 's#^[[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*([^[:space:]/;]*).*#\1#p' "$file" | awk 'NR == 1'
      ;;
    pbxproj)
      grep -Eo '(^|[^A-Za-z0-9_])CURRENT_PROJECT_VERSION[[:space:]]*=[^;]*;' "$file" \
        | sed -E 's/.*=[[:space:]]*//; s/[[:space:]]*;$//; s/"//g' \
        | awk '
          $0 !~ /^[0-9]+$/ { bad = $0 }
          $0 ~ /^[0-9]+$/ && (max == "" || $0 + 0 > max + 0) { max = $0 }
          END { if (bad != "") print bad; else print max }
        ' \
        || true
      ;;
    plist)
      plist_get "$file" CFBundleVersion || true
      ;;
  esac
}

calculate_build_number() {
  local current src
  if [[ -n $BUILD_NUMBER ]]; then
    BUILD=$((10#$BUILD_NUMBER))
    return
  fi
  case $BUILD_NUMBER_STRATEGY in
    run-number)
      if ! is_uint "${GITHUB_RUN_NUMBER:-}"; then
        fail "build-number-strategy run-number needs GITHUB_RUN_NUMBER, got '${GITHUB_RUN_NUMBER:-}'"
      fi
      BUILD=$((10#$GITHUB_RUN_NUMBER + 10#$BUILD_NUMBER_OFFSET))
      ;;
    increment)
      if [[ -n $ANDROID_FILE ]]; then
        src=$ANDROID_FILE
        current=$(read_android_build_number "$ANDROID_FILE")
      elif [[ -n $IOS_FILE ]]; then
        src=$IOS_FILE
        current=$(read_ios_build_number "$IOS_FILE")
      else
        fail "build-number-strategy increment needs android-file or ios-file to read the current build number from"
      fi
      if ! is_uint "$current"; then
        fail "build-number-strategy increment could not read an integer build number from $src, got '$current'"
      fi
      BUILD=$((10#$current + 1))
      ;;
    semver)
      if ((MINOR > 99 || PATCH > 99)); then
        fail "build-number-strategy semver supports minor and patch up to 99, got $VERSION"
      fi
      BUILD=$((MAJOR * 10000 + MINOR * 100 + PATCH))
      ;;
  esac
}

finish_file() {
  local file=$1 work=$2
  if cmp -s "$file" "$work"; then
    echo "$file is already up to date"
    return 0
  fi
  if [[ $DRY_RUN == true ]]; then
    echo "Dry run: $file would change"
    diff -u "$file" "$work" || true
    return 0
  fi
  cat "$work" > "$file"
  CHANGED_FILES="${CHANGED_FILES:+$CHANGED_FILES }$file"
  echo "Updated $file"
}

update_android() {
  local file=$ANDROID_FILE work="$WORK_DIR/android" key semver prerelease buildmeta
  cp "$file" "$work"
  case $ANDROID_FORMAT in
    semver-properties)
      semver=$VERSION
      prerelease=""
      buildmeta=""
      if prop_has "$work" version.prerelease; then
        prerelease=$(prop_get "$work" version.prerelease)
      fi
      if prop_has "$work" version.buildmeta; then
        buildmeta=$(prop_get "$work" version.buildmeta)
      fi
      semver="$semver${prerelease:+-$prerelease}${buildmeta:++$buildmeta}"
      prop_set "$work" version.major "$MAJOR"
      prop_set "$work" version.minor "$MINOR"
      prop_set "$work" version.patch "$PATCH"
      prop_set "$work" version.semver "$semver"
      if [[ -n $ANDROID_VERSION_CODE_KEY ]]; then
        prop_set "$work" "$ANDROID_VERSION_CODE_KEY" "$BUILD"
      fi
      ;;
    gradle-properties)
      key=$(gradle_props_code_key)
      if prop_has "$work" "$ANDROID_VERSION_NAME_KEY"; then
        prop_set "$work" "$ANDROID_VERSION_NAME_KEY" "$VERSION"
      else
        warn "$file has no $ANDROID_VERSION_NAME_KEY key; version name not written"
      fi
      if prop_has "$work" "$key"; then
        prop_set "$work" "$key" "$BUILD"
      else
        warn "$file has no $key key; build number not written"
      fi
      ;;
    gradle-script)
      if gradle_has_name "$work"; then
        sed_edit "$work" "s/^([[:space:]]*versionName([[:space:]]*=[[:space:]]*|[[:space:]]+))([\"'])[^\"']*([\"'])/\\1\\3$VERSION\\4/"
      else
        warn "$file has no literal versionName; version name not written"
      fi
      if gradle_has_code "$work"; then
        sed_edit "$work" "s/^([[:space:]]*versionCode([[:space:]]*=[[:space:]]*|[[:space:]]+))[0-9]+/\\1$BUILD/"
      else
        warn "$file has no literal versionCode; build number not written"
      fi
      ;;
  esac
  finish_file "$file" "$work"
}

update_ios() {
  local file=$IOS_FILE work="$WORK_DIR/ios" field
  cp "$file" "$work"
  case $IOS_FORMAT in
    xcconfig)
      for field in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
        if ! xcconfig_has "$work" "$field"; then
          warn "$file has no $field; it is not written"
        fi
      done
      sed_edit "$work" \
        -e "s#^([[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*)[^[:space:]/;]*#\\1$VERSION#" \
        -e "s#^([[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*)[^[:space:]/;]*#\\1$BUILD#"
      ;;
    pbxproj)
      for field in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
        if ! pbxproj_has "$work" "$field"; then
          warn "$file has no $field; it is not written"
        fi
      done
      sed_edit "$work" \
        -e "s/(^|[^A-Za-z0-9_])(MARKETING_VERSION[[:space:]]*=[[:space:]]*)[^;]*;/\\1\\2$VERSION;/g" \
        -e "s/(^|[^A-Za-z0-9_])(CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*)[^;]*;/\\1\\2$BUILD;/g"
      ;;
    plist)
      if plist_get "$work" CFBundleShortVersionString > /dev/null; then
        plist_set "$work" CFBundleShortVersionString "$VERSION"
      else
        warn "$file has no CFBundleShortVersionString; version not written"
      fi
      if plist_get "$work" CFBundleVersion > /dev/null; then
        plist_set "$work" CFBundleVersion "$BUILD"
      else
        warn "$file has no CFBundleVersion; build number not written"
      fi
      ;;
  esac
  finish_file "$file" "$work"
}

validate_inputs
find_latest_tag
calculate_version
detect_formats
calculate_build_number

if [[ -n $ANDROID_FILE ]] && ((BUILD > ANDROID_MAX_VERSION_CODE)); then
  fail "build number $BUILD exceeds the Android versionCode limit of $ANDROID_MAX_VERSION_CODE"
fi

echo "Latest tag: $LATEST_TAG ($PREVIOUS_VERSION) -> version: $VERSION, build number: $BUILD"

if [[ -n $ANDROID_FILE ]]; then
  update_android
fi
if [[ -n $IOS_FILE ]]; then
  update_ios
fi

{
  echo "latest_tag=$LATEST_TAG"
  echo "previous_version=$PREVIOUS_VERSION"
  echo "version=$VERSION"
  echo "major=$MAJOR"
  echo "minor=$MINOR"
  echo "patch=$PATCH"
  echo "build_number=$BUILD"
  echo "changed_files=$CHANGED_FILES"
} >> "$OUTPUT_FILE"

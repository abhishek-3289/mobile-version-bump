#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/bump.sh"
FIXTURES="$ROOT/tests/fixtures"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TESTS=0
FAILURES=0
STATUS=0

git_quiet() {
  git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main \
    -c commit.gpgsign=false -c tag.gpgsign=false "$@" >/dev/null 2>&1
}

given_remote_tags() {
  rm -rf "$WORK/origin" "$WORK/clone" "$WORK/files"
  mkdir -p "$WORK/files"
  cp "$FIXTURES"/* "$WORK/files/"
  git_quiet init "$WORK/origin"
  git_quiet -C "$WORK/origin" commit --allow-empty -m init
  local tag
  for tag in "$@"; do
    git_quiet -C "$WORK/origin" commit --allow-empty -m "$tag"
    git_quiet -C "$WORK/origin" tag "$tag"
  done
  git_quiet clone --depth 1 --no-tags "file://$WORK/origin" "$WORK/clone"
}

run_bump() {
  : > "$WORK/output"
  (cd "$WORK/clone" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    GITHUB_OUTPUT="$WORK/output" GITHUB_RUN_NUMBER=57 "$@" "$BASH" "$SCRIPT") > "$WORK/log" 2>&1
  STATUS=$?
}

run_bump_without_run_number() {
  : > "$WORK/output"
  (cd "$WORK/clone" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    GITHUB_OUTPUT="$WORK/output" "$@" "$BASH" "$SCRIPT") > "$WORK/log" 2>&1
  STATUS=$?
}

file() {
  printf '%s\n' "$WORK/files/$1"
}

output() {
  grep "^$1=" "$WORK/output" | cut -d= -f2-
}

count_lines() {
  grep -cF -- "$1" "$2"
}

assert_eq() {
  if [[ $2 != "$3" ]]; then
    echo "    $1: expected '$2', got '$3'"
    return 1
  fi
}

assert_contains() {
  if ! grep -qxF -- "$2" "$1"; then
    echo "    $(basename "$1"): missing line '$2'"
    return 1
  fi
}

assert_not_contains() {
  if grep -qF -- "$2" "$1"; then
    echo "    $(basename "$1"): unexpected '$2'"
    return 1
  fi
}

assert_log_contains() {
  if ! grep -qF -- "$1" "$WORK/log"; then
    echo "    log: missing '$1'"
    return 1
  fi
}

assert_unchanged() {
  if ! cmp -s "$FIXTURES/$1" "$WORK/files/$1"; then
    echo "    $1 was modified"
    diff -u "$FIXTURES/$1" "$WORK/files/$1" | sed 's/^/    /'
    return 1
  fi
}

assert_error_contains() {
  if ! grep '^::error::' "$WORK/log" | grep -qF -- "$1"; then
    echo "    log: no ::error:: line containing '$1'"
    return 1
  fi
}

assert_failed_with() {
  assert_eq status 1 "$STATUS" &&
    assert_error_contains "$1" &&
    assert_eq output "" "$(cat "$WORK/output")"
}

run_test() {
  local name=$1
  TESTS=$((TESTS + 1))
  if "$name"; then
    echo "ok - $name"
  else
    FAILURES=$((FAILURES + 1))
    echo "not ok - $name"
    sed 's/^/    log: /' "$WORK/log"
  fi
}

assert_version_outputs() {
  assert_eq latest-tag "$1" "$(output latest_tag)" &&
    assert_eq previous-version "$2" "$(output previous_version)" &&
    assert_eq version "$3" "$(output version)" &&
    assert_eq major "$4" "$(output major)" &&
    assert_eq minor "$5" "$(output minor)" &&
    assert_eq patch "$6" "$(output patch)"
}

test_no_tags_starts_from_zero() {
  given_remote_tags
  run_bump INCREMENT_TYPE=patch
  assert_eq status 0 "$STATUS" &&
    assert_version_outputs v0.0.0 0.0.0 0.0.1 0 0 1 &&
    assert_eq build-number 57 "$(output build_number)" &&
    assert_eq changed-files "" "$(output changed_files)"
}

test_fetches_tags_missing_from_shallow_checkout() {
  given_remote_tags v1.2.3
  run_bump INCREMENT_TYPE=patch
  assert_version_outputs v1.2.3 1.2.3 1.2.4 1 2 4
}

test_uses_highest_version_not_newest_commit() {
  given_remote_tags v1.10.0 v1.9.0
  run_bump INCREMENT_TYPE=patch
  assert_version_outputs v1.10.0 1.10.0 1.10.1 1 10 1
}

test_ignores_prerelease_and_non_semver_tags() {
  given_remote_tags v1.2.0 v2.0.0-rc1 release-x v3 v4.1
  run_bump INCREMENT_TYPE=minor
  assert_version_outputs v1.2.0 1.2.0 1.3.0 1 3 0
}

test_parses_tags_without_v_prefix() {
  given_remote_tags 1.2.3
  run_bump INCREMENT_TYPE=patch
  assert_version_outputs 1.2.3 1.2.3 1.2.4 1 2 4
}

test_compares_tags_with_and_without_v_prefix() {
  given_remote_tags 1.10.0 v1.2.3
  run_bump INCREMENT_TYPE=patch
  assert_version_outputs 1.10.0 1.10.0 1.10.1 1 10 1
}

test_tags_with_leading_zeros_are_decimal() {
  given_remote_tags v1.08.09
  run_bump INCREMENT_TYPE=patch
  assert_eq status 0 "$STATUS" &&
    assert_version_outputs v1.08.09 1.8.9 1.8.10 1 8 10
}

test_minor_resets_patch() {
  given_remote_tags v1.2.3
  run_bump INCREMENT_TYPE=minor
  assert_version_outputs v1.2.3 1.2.3 1.3.0 1 3 0
}

test_major_resets_minor_and_patch() {
  given_remote_tags v1.2.3
  run_bump INCREMENT_TYPE=major
  assert_version_outputs v1.2.3 1.2.3 2.0.0 2 0 0
}

test_defaults_to_patch() {
  given_remote_tags v1.2.3
  run_bump
  assert_eq version 1.2.4 "$(output version)"
}

test_explicit_version_overrides_calculation() {
  given_remote_tags v1.2.3
  run_bump INCREMENT_TYPE=major EXPLICIT_VERSION=3.4.5
  assert_eq status 0 "$STATUS" &&
    assert_version_outputs v1.2.3 1.2.3 3.4.5 3 4 5
}

test_explicit_version_accepts_v_prefix() {
  given_remote_tags v1.2.3
  run_bump EXPLICIT_VERSION=v2.0.1
  assert_version_outputs v1.2.3 1.2.3 2.0.1 2 0 1
}

test_rejects_invalid_explicit_version() {
  given_remote_tags v1.2.3
  run_bump EXPLICIT_VERSION=1.2
  assert_failed_with "version must look like X.Y.Z"
}

test_rejects_unknown_increment_type() {
  given_remote_tags v1.2.3
  run_bump INCREMENT_TYPE=huge
  assert_failed_with "increment-type must be one of major, minor, patch"
}

test_version_properties_updates_semver_keys() {
  given_remote_tags v1.4.1
  run_bump INCREMENT_TYPE=minor ANDROID_FILE="$(file version.properties)"
  local f
  f=$(file version.properties)
  assert_eq status 0 "$STATUS" &&
    assert_contains "$f" "version.major=1" &&
    assert_contains "$f" "version.minor=5" &&
    assert_contains "$f" "version.patch=0" &&
    assert_contains "$f" "version.semver=1.5.0" &&
    assert_contains "$f" "version.buildmeta=" &&
    assert_contains "$f" "version.prerelease=" &&
    assert_eq lines 6 "$(wc -l < "$f" | tr -d ' ')" &&
    assert_eq changed-files "$f" "$(output changed_files)"
}

test_version_properties_keeps_prerelease_and_buildmeta() {
  given_remote_tags v1.4.1
  local f
  f=$(file version.properties)
  sed -e 's/^version.prerelease=$/version.prerelease=beta/' -e 's/^version.buildmeta=$/version.buildmeta=007/' "$FIXTURES/version.properties" > "$f"
  run_bump ANDROID_FILE="$f"
  assert_contains "$f" "version.prerelease=beta" &&
    assert_contains "$f" "version.buildmeta=007" &&
    assert_contains "$f" "version.semver=1.4.2-beta+007"
}

test_version_properties_writes_existing_version_code_key() {
  given_remote_tags v1.4.1
  local f
  f=$(file version.properties)
  echo "version.code=41" >> "$f"
  run_bump ANDROID_FILE="$f" ANDROID_VERSION_CODE_KEY=version.code BUILD_NUMBER_STRATEGY=increment
  assert_eq build-number 42 "$(output build_number)" &&
    assert_contains "$f" "version.code=42" &&
    assert_eq occurrences 1 "$(count_lines version.code= "$f")"
}

test_version_properties_appends_missing_version_code_key() {
  given_remote_tags v1.4.1
  local f
  f=$(file version.properties)
  run_bump ANDROID_FILE="$f" ANDROID_VERSION_CODE_KEY=version.code
  assert_eq status 0 "$STATUS" &&
    assert_contains "$f" "version.code=57"
}

test_version_properties_without_code_key_writes_no_build_number() {
  given_remote_tags v1.4.1
  run_bump ANDROID_FILE="$(file version.properties)"
  assert_not_contains "$(file version.properties)" "57"
}

test_groovy_build_gradle() {
  given_remote_tags v1.4.1
  local f
  f=$(file build.gradle)
  run_bump ANDROID_FILE="$f" INCREMENT_TYPE=minor
  assert_eq status 0 "$STATUS" &&
    assert_contains "$f" '        versionName "1.5.0"' &&
    assert_contains "$f" '        versionCode 57' &&
    assert_contains "$f" '        applicationId "com.example.app"' &&
    assert_eq changed-lines 2 "$(diff "$FIXTURES/build.gradle" "$f" | grep -c '^>')"
}

test_groovy_build_gradle_single_quotes_and_equals() {
  given_remote_tags v1.4.1
  local f
  f=$(file build.gradle)
  sed -e "s/versionName \"1.4.1\"/versionName = '1.4.1'/" -e 's/versionCode 41/versionCode = 41/' "$FIXTURES/build.gradle" > "$f"
  run_bump ANDROID_FILE="$f"
  assert_contains "$f" "        versionName = '1.4.2'" &&
    assert_contains "$f" "        versionCode = 57"
}

test_kotlin_build_gradle_kts() {
  given_remote_tags v1.4.1
  local f
  f=$(file build.gradle.kts)
  run_bump ANDROID_FILE="$f" INCREMENT_TYPE=major
  assert_eq status 0 "$STATUS" &&
    assert_contains "$f" '        versionName = "2.0.0"' &&
    assert_contains "$f" '        versionCode = 57' &&
    assert_contains "$f" '    namespace = "com.example.app"'
}

test_gradle_properties_default_keys() {
  given_remote_tags v1.4.1
  local f
  f=$(file gradle.properties)
  run_bump ANDROID_FILE="$f"
  assert_eq status 0 "$STATUS" &&
    assert_contains "$f" "VERSION_NAME=1.4.2" &&
    assert_contains "$f" "VERSION_CODE=57" &&
    assert_contains "$f" "org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8" &&
    assert_contains "$f" "APP_ID=com.example.app"
}

test_gradle_properties_custom_keys() {
  given_remote_tags v1.4.1
  local f
  f=$(file gradle.properties)
  printf 'app.versionName = 1.4.1\napp.versionCode = 41\nVERSION_NAME=9.9.9\n' > "$f"
  run_bump ANDROID_FILE="$f" ANDROID_VERSION_NAME_KEY=app.versionName ANDROID_VERSION_CODE_KEY=app.versionCode BUILD_NUMBER_STRATEGY=increment
  assert_eq status 0 "$STATUS" &&
    assert_contains "$f" "app.versionName = 1.4.2" &&
    assert_contains "$f" "app.versionCode = 42" &&
    assert_contains "$f" "VERSION_NAME=9.9.9"
}

test_android_format_detected_by_content() {
  given_remote_tags v1.4.1
  local f
  f=$(file app-version.txt)
  cp "$FIXTURES/version.properties" "$f"
  run_bump ANDROID_FILE="$f"
  assert_eq status 0 "$STATUS" &&
    assert_log_contains "(semver-properties)" &&
    assert_contains "$f" "version.semver=1.4.2"
}

test_relative_paths_are_resolved_from_working_directory() {
  given_remote_tags v1.4.1
  mkdir -p "$WORK/clone/app"
  cp "$FIXTURES/build.gradle.kts" "$WORK/clone/app/build.gradle.kts"
  run_bump ANDROID_FILE=app/build.gradle.kts
  assert_contains "$WORK/clone/app/build.gradle.kts" '        versionName = "1.4.2"' &&
    assert_eq changed-files app/build.gradle.kts "$(output changed_files)"
}

test_xcconfig() {
  given_remote_tags v1.4.1
  local f
  f=$(file Config.xcconfig)
  run_bump IOS_FILE="$f" INCREMENT_TYPE=minor
  assert_eq status 0 "$STATUS" &&
    assert_contains "$f" "MARKETING_VERSION = 1.5.0" &&
    assert_contains "$f" "CURRENT_PROJECT_VERSION = 57" &&
    assert_contains "$f" "SWIFT_VERSION = 5.0" &&
    assert_contains "$f" "PRODUCT_BUNDLE_IDENTIFIER = com.example.app"
}

test_pbxproj_updates_every_configuration() {
  given_remote_tags v1.4.1
  local f
  f=$(file project.pbxproj)
  run_bump IOS_FILE="$f" INCREMENT_TYPE=minor
  assert_eq status 0 "$STATUS" &&
    assert_eq marketing 4 "$(count_lines 'MARKETING_VERSION = 1.5.0;' "$f")" &&
    assert_eq build 4 "$(count_lines 'CURRENT_PROJECT_VERSION = 57;' "$f")" &&
    assert_not_contains "$f" "1.4.1" &&
    assert_not_contains "$f" '"1.4.0"' &&
    assert_contains "$f" "		A10000000000000000000006 /* Release */ = {" &&
    assert_eq changed-lines 8 "$(diff "$FIXTURES/project.pbxproj" "$f" | grep -c '^>')"
}

test_info_plist() {
  given_remote_tags v1.4.1
  local f
  f=$(file Info.plist)
  run_bump IOS_FILE="$f" INCREMENT_TYPE=major
  assert_eq status 0 "$STATUS" &&
    assert_contains "$f" "	<string>2.0.0</string>" &&
    assert_contains "$f" "	<string>57</string>" &&
    assert_contains "$f" "	<string>\$(PRODUCT_BUNDLE_IDENTIFIER)</string>" &&
    assert_eq changed-lines 2 "$(diff "$FIXTURES/Info.plist" "$f" | grep -c '^>')"
}

test_info_plist_value_on_same_line_as_key() {
  given_remote_tags v1.4.1
  local f
  f=$(file Info.plist)
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>3</string></dict></plist>\n' > "$f"
  run_bump IOS_FILE="$f" BUILD_NUMBER_STRATEGY=increment
  assert_eq build-number 4 "$(output build_number)" &&
    assert_contains "$f" '<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.4.2</string><key>CFBundleVersion</key><string>4</string></dict></plist>'
}

test_info_plist_skips_build_setting_references() {
  given_remote_tags v1.4.1
  local f
  f=$(file Info.plist)
  sed "s#<string>1.4.1</string>#<string>\$(MARKETING_VERSION)</string>#" "$FIXTURES/Info.plist" > "$f"
  run_bump IOS_FILE="$f"
  assert_eq status 0 "$STATUS" &&
    assert_log_contains "::warning::CFBundleShortVersionString" &&
    assert_contains "$f" "	<string>\$(MARKETING_VERSION)</string>" &&
    assert_contains "$f" "	<string>57</string>"
}

test_info_plist_with_only_references_is_unrecognised() {
  given_remote_tags v1.4.1
  local f
  f=$(file Info.plist)
  sed -e "s#<string>1.4.1</string>#<string>\$(MARKETING_VERSION)</string>#" -e "s#<string>41</string>#<string>\$(CURRENT_PROJECT_VERSION)</string>#" "$FIXTURES/Info.plist" > "$f"
  run_bump IOS_FILE="$f"
  assert_failed_with "ios-file $f contains no recognised version field"
}

test_binary_plist_fails_clearly() {
  given_remote_tags v1.4.1
  local f
  f=$(file Info.plist)
  printf 'bplist00\001\002\003' > "$f"
  run_bump IOS_FILE="$f"
  assert_failed_with "ios-file $f is a binary plist, which is not supported"
}

test_android_and_ios_in_one_step() {
  given_remote_tags v1.4.1
  run_bump ANDROID_FILE="$(file build.gradle.kts)" IOS_FILE="$(file project.pbxproj)" INCREMENT_TYPE=minor
  assert_eq status 0 "$STATUS" &&
    assert_contains "$(file build.gradle.kts)" '        versionName = "1.5.0"' &&
    assert_eq ios 4 "$(count_lines 'MARKETING_VERSION = 1.5.0;' "$(file project.pbxproj)")" &&
    assert_eq changed-files "$(file build.gradle.kts) $(file project.pbxproj)" "$(output changed_files)"
}

test_already_up_to_date_reports_no_changes() {
  given_remote_tags v1.4.0
  run_bump IOS_FILE="$(file Config.xcconfig)" EXPLICIT_VERSION=1.4.1 BUILD_NUMBER=41
  assert_eq status 0 "$STATUS" &&
    assert_unchanged Config.xcconfig &&
    assert_eq changed-files "" "$(output changed_files)" &&
    assert_log_contains "already up to date"
}

test_build_number_run_number_default() {
  given_remote_tags v1.4.1
  run_bump IOS_FILE="$(file Config.xcconfig)"
  assert_eq build-number 57 "$(output build_number)"
}

test_build_number_run_number_with_offset() {
  given_remote_tags v1.4.1
  run_bump IOS_FILE="$(file Config.xcconfig)" BUILD_NUMBER_STRATEGY=run-number BUILD_NUMBER_OFFSET=1000
  assert_eq build-number 1057 "$(output build_number)" &&
    assert_contains "$(file Config.xcconfig)" "CURRENT_PROJECT_VERSION = 1057"
}

test_build_number_run_number_requires_github_run_number() {
  given_remote_tags v1.4.1
  run_bump_without_run_number BUILD_NUMBER_STRATEGY=run-number
  assert_failed_with "build-number-strategy run-number needs GITHUB_RUN_NUMBER"
}

test_build_number_increment_reads_first_file() {
  given_remote_tags v1.4.1
  local ios
  ios=$(file Config.xcconfig)
  sed 's/CURRENT_PROJECT_VERSION = 41/CURRENT_PROJECT_VERSION = 99/' "$FIXTURES/Config.xcconfig" > "$ios"
  run_bump ANDROID_FILE="$(file build.gradle)" IOS_FILE="$ios" BUILD_NUMBER_STRATEGY=increment
  assert_eq build-number 42 "$(output build_number)" &&
    assert_contains "$(file build.gradle)" "        versionCode 42" &&
    assert_contains "$ios" "CURRENT_PROJECT_VERSION = 42"
}

test_build_number_increment_uses_highest_pbxproj_value() {
  given_remote_tags v1.4.1
  run_bump IOS_FILE="$(file project.pbxproj)" BUILD_NUMBER_STRATEGY=increment
  assert_eq build-number 42 "$(output build_number)"
}

test_build_number_increment_from_info_plist() {
  given_remote_tags v1.4.1
  run_bump IOS_FILE="$(file Info.plist)" BUILD_NUMBER_STRATEGY=increment
  assert_eq build-number 42 "$(output build_number)"
}

test_build_number_increment_requires_a_file() {
  given_remote_tags v1.4.1
  run_bump BUILD_NUMBER_STRATEGY=increment
  assert_failed_with "build-number-strategy increment needs android-file or ios-file"
}

test_build_number_increment_requires_integer() {
  given_remote_tags v1.4.1
  local f
  f=$(file Info.plist)
  sed 's#<string>41</string>#<string>1.4.1.41</string>#' "$FIXTURES/Info.plist" > "$f"
  run_bump IOS_FILE="$f" BUILD_NUMBER_STRATEGY=increment
  assert_failed_with "could not read an integer build number from $f, got '1.4.1.41'" &&
    assert_unchanged Config.xcconfig
}

test_build_number_increment_needs_code_key_for_version_properties() {
  given_remote_tags v1.4.1
  run_bump ANDROID_FILE="$(file version.properties)" BUILD_NUMBER_STRATEGY=increment
  assert_failed_with "could not read an integer build number" &&
    assert_unchanged version.properties
}

test_build_number_semver() {
  given_remote_tags v1.4.1
  run_bump ANDROID_FILE="$(file gradle.properties)" BUILD_NUMBER_STRATEGY=semver INCREMENT_TYPE=minor
  assert_eq build-number 10500 "$(output build_number)" &&
    assert_contains "$(file gradle.properties)" "VERSION_CODE=10500"
}

test_build_number_semver_rejects_minor_over_99() {
  given_remote_tags v1.99.0
  run_bump BUILD_NUMBER_STRATEGY=semver INCREMENT_TYPE=minor
  assert_failed_with "build-number-strategy semver supports minor and patch up to 99, got 1.100.0"
}

test_explicit_build_number_overrides_strategy() {
  given_remote_tags v1.4.1
  run_bump IOS_FILE="$(file Info.plist)" BUILD_NUMBER=0300 BUILD_NUMBER_STRATEGY=semver
  assert_eq build-number 300 "$(output build_number)" &&
    assert_contains "$(file Info.plist)" "	<string>300</string>"
}

test_rejects_android_version_code_over_limit() {
  given_remote_tags v1.4.1
  run_bump ANDROID_FILE="$(file build.gradle)" BUILD_NUMBER=2100000001
  assert_failed_with "exceeds the Android versionCode limit" &&
    assert_unchanged build.gradle
}

test_dry_run_writes_nothing() {
  given_remote_tags v1.4.1
  run_bump ANDROID_FILE="$(file build.gradle)" IOS_FILE="$(file project.pbxproj)" DRY_RUN=true INCREMENT_TYPE=major
  assert_eq status 0 "$STATUS" &&
    assert_unchanged build.gradle &&
    assert_unchanged project.pbxproj &&
    assert_version_outputs v1.4.1 1.4.1 2.0.0 2 0 0 &&
    assert_eq build-number 57 "$(output build_number)" &&
    assert_eq changed-files "" "$(output changed_files)" &&
    assert_log_contains "Dry run: $(file build.gradle) would change" &&
    assert_log_contains '+        versionName "2.0.0"'
}

test_missing_android_file() {
  given_remote_tags v1.4.1
  run_bump ANDROID_FILE="$WORK/files/nope.gradle"
  assert_failed_with "android-file $WORK/files/nope.gradle does not exist"
}

test_missing_ios_file_writes_nothing() {
  given_remote_tags v1.4.1
  run_bump ANDROID_FILE="$(file build.gradle)" IOS_FILE="$WORK/files/nope.xcconfig"
  assert_failed_with "ios-file $WORK/files/nope.xcconfig does not exist" &&
    assert_unchanged build.gradle
}

test_unrecognised_android_file() {
  given_remote_tags v1.4.1
  local f
  f=$(file gradle.properties)
  printf 'org.gradle.jvmargs=-Xmx2048m\nandroid.useAndroidX=true\n' > "$f"
  run_bump ANDROID_FILE="$f"
  assert_failed_with "android-file $f contains no recognised version field"
}

test_unrecognised_android_file_by_content() {
  given_remote_tags v1.4.1
  local f
  f=$(file notes.txt)
  echo "nothing to see" > "$f"
  run_bump ANDROID_FILE="$f"
  assert_failed_with "android-file $f contains no recognised version field"
}

test_unrecognised_ios_file() {
  given_remote_tags v1.4.1
  local f
  f=$(file Other.xcconfig)
  echo "SWIFT_VERSION = 5.0" > "$f"
  run_bump IOS_FILE="$f"
  assert_failed_with "ios-file $f contains no recognised version field"
}

test_rejects_invalid_build_number() {
  given_remote_tags v1.4.1
  run_bump BUILD_NUMBER=12a
  assert_failed_with "build-number must be a non-negative integer"
}

test_rejects_unknown_build_number_strategy() {
  given_remote_tags v1.4.1
  run_bump BUILD_NUMBER_STRATEGY=timestamp
  assert_failed_with "build-number-strategy must be one of run-number, increment, semver"
}

test_rejects_invalid_build_number_offset() {
  given_remote_tags v1.4.1
  run_bump BUILD_NUMBER_OFFSET=-5
  assert_failed_with "build-number-offset must be a non-negative integer"
}

test_rejects_invalid_dry_run() {
  given_remote_tags v1.4.1
  run_bump DRY_RUN=yes
  assert_failed_with "dry-run must be true or false"
}

test_rejects_invalid_property_key() {
  given_remote_tags v1.4.1
  run_bump ANDROID_VERSION_CODE_KEY='a=b'
  assert_failed_with "android-version-code-key may only contain"
}

for test_name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
  run_test "$test_name"
done

echo "$((TESTS - FAILURES))/$TESTS passed"
[[ $FAILURES -eq 0 ]]

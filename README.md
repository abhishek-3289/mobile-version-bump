# Mobile Version Bump 📱

[![My Skills](https://skillicons.dev/icons?i=githubactions,androidstudio,gradle,apple,swift,bash&perline=6)](https://skillicons.dev)

## Use 📄

### Example ⌨️

```yaml
    permissions:
      contents: write

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Bump Android and iOS versions
        id: version
        uses: abhishek-3289/mobile-version-bump@v1
        with:
          increment-type: minor
          build-number-strategy: increment
          android-file: app/build.gradle.kts
          ios-file: ios/App.xcodeproj/project.pbxproj

      - name: Commit, tag and push
        env:
          NEW_VERSION: ${{ steps.version.outputs.version }}
          BUILD_NUMBER: ${{ steps.version.outputs.build-number }}
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git commit -am "Bump version to $NEW_VERSION ($BUILD_NUMBER)"
          git tag "v$NEW_VERSION"
          git push origin HEAD "v$NEW_VERSION"
```

### Description 🔖

A composite (bash) GitHub Action that computes the next semantic version from the git tags of the
repository and writes it, together with a build number, into Android and/or iOS project files in a
single step. It runs on Linux and macOS runners and needs nothing but `bash`, `git`, `sed` and `awk`.

**Version.** The highest tag of the form `MAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH` is selected with a
numeric sort (so `v1.10.0` beats `v1.9.0`); pre-release and other tags are ignored and `v0.0.0` is used
when no such tag exists. The digit chosen by `increment-type` is incremented and the lower digits are
reset. Tags are fetched from the remote by the action itself, so the default shallow
`actions/checkout` works. Passing `version` skips the calculation and uses that value instead
(`X.Y.Z`, a leading `v` is accepted so `${{ github.ref_name }}` of a tag push can be passed directly);
`latest-tag` and `previous-version` are still reported.

**Build number.** An explicit `build-number` always wins. Otherwise `build-number-strategy` decides:

| strategy     | build number                                                                                                    |
|:-------------|:----------------------------------------------------------------------------------------------------------------|
| `run-number` | `GITHUB_RUN_NUMBER + build-number-offset`. Use the offset to continue above build numbers you already shipped. |
| `increment`  | Current build number + 1, read from the first file being updated (`android-file` if given, else `ios-file`).   |
| `semver`     | `major * 10000 + minor * 100 + patch`, e.g. `2.3.4` becomes `20304`.                                           |

`increment` reads `versionCode` (first literal one) from Gradle scripts, the version code key from
properties files, `CURRENT_PROJECT_VERSION` from `.xcconfig`, the highest `CURRENT_PROJECT_VERSION` in
`project.pbxproj` and `CFBundleVersion` from `Info.plist`; the value must be an integer.
`semver` only works while minor and patch stay below 100 (the action fails otherwise, instead of
producing a colliding number) and while major stays below 210000, because Google Play caps
`versionCode` at 2100000000. Every strategy fails if the result is above that cap and an Android file
is updated.

**Android files** (`android-file`), detected by file name and otherwise by content:

| file                                | what is written                                                                                                                                                                                                                                                                                                                            |
|:------------------------------------|:-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `version.properties`                | `version.major`, `version.minor`, `version.patch` and `version.semver`, as written by the [semver Gradle plugin](https://plugins.gradle.org/plugin/net.thauvin.erik.gradle.semver). Other keys are kept; a non-empty `version.prerelease` / `version.buildmeta` is appended to `version.semver` (`1.2.0-beta+7`) like the plugin does. The build number is written only when `android-version-code-key` is set (the key is added if missing). |
| `build.gradle` / `build.gradle.kts` | Every literal `versionName "..."`, `versionName '...'`, `versionName = "..."` and `versionCode N`, `versionCode = N` line. Values computed in code (`versionName computeName()`) are left alone.                                                                                                                                           |
| `gradle.properties`                 | `android-version-name-key` (default `VERSION_NAME`) and `android-version-code-key` (default `VERSION_CODE` for this format). Only keys already present are written; `key=value`, `key = value` and `key: value` are supported.                                                                                                            |

**iOS files** (`ios-file`), detected by file name and otherwise by content:

| file              | what is written                                                                                                                                                                                                                                                                                                 |
|:------------------|:-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `*.xcconfig`      | `MARKETING_VERSION = <version>` and `CURRENT_PROJECT_VERSION = <build>`.                                                                                                                                                                                                                                        |
| `project.pbxproj` | Every `MARKETING_VERSION = ...;` and `CURRENT_PROJECT_VERSION = ...;`, i.e. all build configurations of all targets (app, extensions, widgets) get the same values.                                                                                                                                              |
| `Info.plist`      | The `<string>` values of `CFBundleShortVersionString` and `CFBundleVersion`. The XML is edited with `awk`, not PlistBuddy, so it also runs on Linux. Values that reference a build setting such as `$(MARKETING_VERSION)` are left unchanged with a warning; point `ios-file` at the `.xcconfig` or `project.pbxproj` that defines them instead. **Binary plists are not supported** and fail with an error; convert them once with `plutil -convert xml1 Info.plist`. |

The action fails with an `::error::` annotation, before writing anything, when a given file does not
exist or contains none of the recognised fields; it warns when only one of the two fields (version or
build number) is found. A platform whose input is empty is skipped silently, so the action can also be
used just to compute the next version. With `dry-run: true` the values are computed, reported and a
diff of each file is printed, but nothing is written and `changed-files` is empty.

The action never commits, tags or pushes: do that in a following step (see the example above and the
[examples](#examples-)).

### Inputs 📥

| name                     | description                                                                                                         | required | default        |
|:-------------------------|:--------------------------------------------------------------------------------------------------------------------|:---------|:---------------|
| increment-type           | The digit to increment, either `major`, `minor` or `patch`.                                                          | No       | `patch`        |
| version                  | Explicit `X.Y.Z` (or `vX.Y.Z`) that overrides the tag based calculation.                                             | No       | ❌             |
| build-number             | Explicit non-negative integer build number; overrides `build-number-strategy`.                                       | No       | ❌             |
| build-number-strategy    | `run-number`, `increment` or `semver`, see above.                                                                    | No       | `run-number`   |
| build-number-offset      | Non-negative integer added to `GITHUB_RUN_NUMBER` by the `run-number` strategy.                                      | No       | `0`            |
| android-file             | Path to `version.properties`, `build.gradle`, `build.gradle.kts` or `gradle.properties`. Empty skips Android.        | No       | ❌             |
| android-version-name-key | `gradle.properties` key holding the version name.                                                                    | No       | `VERSION_NAME` |
| android-version-code-key | Properties key holding the version code. `gradle.properties` uses `VERSION_CODE` when empty; `version.properties` writes no build number when empty. | No       | ❌             |
| ios-file                 | Path to an `.xcconfig`, `project.pbxproj` or XML `Info.plist`. Empty skips iOS.                                      | No       | ❌             |
| dry-run                  | Set to `true` to compute and print without writing any file.                                                         | No       | `false`        |

Paths are relative to the workspace (or absolute).

### Outputs 📤

1. **latest-tag** :- Highest semver tag or default `v0.0.0` if none exists.
2. **previous-version** :- `latest-tag` without `v`, eg: `1.4.1`.
3. **version** :- The new version, eg: `1.5.0`.
4. **major** :- New major version.
5. **minor** :- New minor version.
6. **patch** :- New patch version.
7. **build-number** :- The new build number.
8. **changed-files** :- Space-separated list of files that were actually modified (empty on `dry-run` or when the files were already up to date). Paths containing spaces are not supported in this list.

## Examples 🧪

Ready-to-copy workflows live in [`examples/`](examples):

- [`bump-android-and-ios.yml`](examples/bump-android-and-ios.yml) bumps both apps on demand (choosing `patch` / `minor` / `major`), increments the build number found in the Gradle file, commits the changed files to a branch and opens a pull request with `gh pr create`. The repository setting *Allow GitHub Actions to create and approve pull requests* must be enabled.
- [`release-on-tag-build-number.yml`](examples/release-on-tag-build-number.yml) runs when a `vX.Y.Z` tag is pushed, writes that version and a build number derived from the run number (`+1000`) into the Android and iOS projects, then builds them. Nothing is committed; the files are only changed for the build.

Copy one into `.github/workflows/` of your repository and adjust the file paths.

## Development 🛠️

```bash
bash tests/bump_test.sh
```

The tests create throwaway git repositories (shallow `--no-tags` clones, like `actions/checkout`) and
copy the sample files from [`tests/fixtures`](tests/fixtures), so they need only `git`, `bash`, `sed`
and `awk`. The script avoids bash 4 features and GNU-only `sed` flags, so it runs on the macOS system
bash 3.2 with BSD tools as well as on bash 5 with GNU tools:

```bash
/bin/bash tests/bump_test.sh
```

| Workflow | Trigger | What it does |
|:---------|:--------|:-------------|
| [CI](.github/workflows/ci.yml) | push to `main`, pull requests | ShellCheck, actionlint, unit tests on Ubuntu and macOS (default bash and `/bin/bash` 3.2), and an integration run of the action (`uses: ./`) against copies of the fixtures that asserts file contents and outputs, including a dry run. |
| [Release](.github/workflows/release.yml) | manual (`patch` / `minor` / `major`) | Runs CI, calculates the next version from the highest `vX.Y.Z` tag, publishes a GitHub release with generated notes, and moves the `vMAJOR` tag. |

# Harness Dual Version Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate DeepSeek Harness official-release discovery (GitHub) from installable-version discovery (npm) while preserving current runtime detection and npm-only Managed Runtime installation.

**Architecture:** Keep the existing Runtime module and orchestration boundaries. `HarnessVersionService` owns two independently cached and single-flight provider lanes; `HarnessEnvironmentReport` combines those results with the detected current version; `HarnessUpdateStatus` remains the only comparison policy consumed by UI. The existing macOS App update subsystem remains untouched.

**Tech Stack:** Swift 6, AppKit/SwiftUI, Foundation URLSession, XCTest, Xcode project.

## Global Constraints

- GitHub decides whether a newer official Harness release exists.
- npm decides which exact Harness version Managed Runtime may prepare, start, or update to.
- Current version remains detected/local runtime state, with `0.0.1` falling back only to the npm installable version.
- Keep independent six-hour caches and independent single-flight tasks for GitHub and npm.
- Do not modify `AppUpdateChecker`, `GitHubLatestReleaseProvider`, or `checkForAppUpdates()`.
- Do not add dependencies, tokens, npm shell checks, or configuration mutations.
- Preserve the legacy npm cache by migrating it lazily to the installable cache.

---

### Task 1: GitHub Harness release provider

**Files:**
- Create: `DeepSeek Harness/Harness/Runtime/GitHubHarnessReleaseVersionProvider.swift`
- Create: `DeepSeek HarnessTests/GitHubHarnessReleaseVersionProviderTests.swift`
- Modify: `DeepSeek Harness.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `HTTPDataFetching`, `HarnessVersion`, `HarnessVersionError`.
- Produces: `HarnessReleaseVersionProviding.fetchLatestReleaseVersion() async throws -> HarnessVersion`.

- [ ] Write tests that feed literal GitHub release JSON and assert `dsh-v`/`v` normalization, prerelease inclusion, draft exclusion, invalid-tag exclusion, highest-SemVer selection, non-2xx failure, malformed JSON failure, and network failure propagation.
- [ ] Run only `GitHubHarnessReleaseVersionProviderTests` and confirm compilation/failing behavior because the provider is absent.
- [ ] Implement a URLSession-backed provider that requests `/repos/deepseek-ai/deepseek-harness/releases?per_page=20`, filters drafts, parses normalized tags, and returns `versions.max()`.
- [ ] Add source/test files to the Xcode project and rerun the focused tests.

### Task 2: Independent provider caches and migration

**Files:**
- Modify: `DeepSeek Harness/Harness/Runtime/HarnessVersionService.swift`
- Modify: `DeepSeek Harness/Infrastructure/Settings/SettingsStore.swift`
- Modify: `DeepSeek Harness/Infrastructure/Settings/AppSettings.swift`
- Modify: `DeepSeek HarnessTests/HarnessVersionServiceTests.swift`

**Interfaces:**
- Produces: `latestReleaseVersion(force:)`, `latestInstallableVersion(force:)`, `cachedLatestRelease`, and `cachedLatestInstallable`.
- Cache contract: release/installable timestamps and known versions are separate; legacy npm keys populate installable values when the new values are absent.

- [ ] Replace test cache doubles with the dual-cache contract and add failing tests for independent throttling, force refresh isolation, failure fallback, legacy npm cache migration, and per-lane single-flight behavior.
- [ ] Run `HarnessVersionServiceTests` and confirm failures identify missing dual-source APIs.
- [ ] Rename npm provider semantics to installable, implement two service lanes with separate `TaskBox` state, and add the new SettingsStore/AppSettings keys with lazy legacy fallback.
- [ ] Rerun focused tests and preserve existing npm parsing/error coverage under the explicit installable names.

### Task 3: Report and status policy

**Files:**
- Modify: `DeepSeek Harness/Harness/Runtime/HarnessEnvironmentReport.swift`
- Modify: `DeepSeek Harness/Harness/Runtime/HarnessUpdateStatus.swift`
- Modify: `DeepSeek HarnessTests/HarnessUpdateStatusTests.swift`

**Interfaces:**
- Produces report properties `latestReleaseVersion` and `latestInstallableVersion`.
- Produces status cases carrying release/installable versions and `status(current:latestRelease:latestInstallable:)`.

- [ ] Write the six-row status matrix as failing tests, plus partial-network-result cases and the placeholder-current fallback test.
- [ ] Run `HarnessUpdateStatusTests` and confirm failures are due to the old one-source API.
- [ ] Implement release-based freshness, installability gating, summaries, and the installable-only placeholder fallback.
- [ ] Rerun focused status tests.

### Task 4: Doctor, coordinator, Managed Runtime, and UI wiring

**Files:**
- Modify: `DeepSeek Harness/Harness/Runtime/HarnessEnvironmentDoctor.swift`
- Modify: `DeepSeek Harness/App/AppCoordinator.swift`
- Modify: `DeepSeek Harness/Desktop/MenuBar/MenuBarCoordinator.swift`
- Modify: `DeepSeek Harness/Desktop/Settings/SettingsView.swift`
- Modify: `DeepSeek Harness/Harness/Runtime/HarnessTerminalVersionChecker.swift`
- Modify: `DeepSeek HarnessTests/HarnessEnvironmentDoctorTests.swift`
- Modify: `DeepSeek HarnessTests/AppCoordinatorTests.swift`

**Interfaces:**
- Doctor consumes only `latestInstallableVersionProvider`; release discovery stays at the coordinator update layer.
- Presenter consumes `HarnessUpdateStatus` and exposes popup copy without comparing versions itself.
- Every Managed Runtime candidate comes from `latestInstallableVersion(force:)` or `cachedLatestInstallable`.

- [ ] Add failing Doctor tests for installable-only fallback and coordinator/presenter tests proving a GitHub-only release disables Managed update while displaying the pending npm state.
- [ ] Run the focused Doctor, coordinator, and presenter tests.
- [ ] Wire dual concurrent refresh into `checkForUpdates()`, keep startup Doctor independent of GitHub, and replace all Managed Runtime version lookups with installable APIs.
- [ ] Update menu/settings labels and actions to show official release separately from npm installability; hide/disable update for `releaseAvailableButNotInstallable`.
- [ ] Rerun focused tests.

### Task 5: Diagnostics and documentation

**Files:**
- Modify: `DeepSeek Harness/Infrastructure/Diagnostics/DiagnosticsSnapshot.swift`
- Modify: `DeepSeek HarnessTests/DiagnosticsSnapshotTests.swift`
- Modify: `ARCHITECTURE.md`
- Modify: `DEVELOPMENT.md`

**Interfaces:**
- Diagnostics exposes separately labeled official release and npm installable versions.

- [ ] Update diagnostic behavior tests to assert both literal labels and values.
- [ ] Run `DiagnosticsSnapshotTests` and confirm the old one-source diagnostics fail the new expectation.
- [ ] Implement the diagnostic fields and document the three-version model plus npm-only Managed Runtime boundary.
- [ ] Rerun focused diagnostics tests.

### Task 6: Full verification and cleanup

**Files:**
- Verify all modified production/test/project/documentation files.

- [ ] Search for ambiguous Harness `latestVersion` uses and confirm any remaining names belong only to App-update or terminal legacy boundaries with unambiguous scope.
- [ ] Run the complete Xcode test suite with an explicit temporary DerivedData path.
- [ ] Run a full Debug build and inspect exit status and warnings.
- [ ] Review `git diff` against every requirement and verify no App-update implementation changed.
- [ ] Commit only task-owned files using the repository Lore commit format.
- [ ] Delete project build directories, related Xcode DerivedData, development app copies, and task temporary build directories.
- [ ] Run both required `mdfind` bundle-identifier checks and report any deliberately preserved formal installation.

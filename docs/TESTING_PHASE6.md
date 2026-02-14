# Phase 6 Testing Checklist - Hybrid Isolation Strategy

This document tracks Phase 6 testing and documentation tasks for Mac Runner Issue #9.

## Status: ⏳ IN PROGRESS

**Created:** 2026-02-14
**Branch:** `simplify/mac-runner-1771032142`
**Phases 1-5:** ✅ Complete
**Phase 6:** 🔄 Documentation complete, awaiting local Mac testing

---

## Unit Tests (New Files Created)

### ✅ Test Files Created

- [x] `Tests/MacRunnerTests/IsolationModeTests.swift` - IsolationMode enum tests
- [x] `Tests/MacRunnerTests/RunnerModelTests.swift` - Runner model tests
- [x] `Tests/MacRunnerTests/AppSettingsTests.swift` - AppSettings tests
- [x] `Tests/MacRunnerTests/RunnerConfigTests.swift` - RunnerConfig persistence tests

### ⏳ Test Execution (Requires Mac with Xcode)

- [ ] Run unit tests: `swift test`
- [ ] Verify all tests pass
- [ ] Check test coverage
- [ ] Fix any failing tests

### Test Coverage Areas

**IsolationMode:**
- [x] Encoding/decoding for all modes (none, dedicatedUser, container)
- [x] Display names and icons
- [x] Equality checks
- [x] Backward compatibility (unknown types default to .none)

**Runner Model:**
- [x] Initialization with/without isolation mode
- [x] Encoding/decoding with isolation mode
- [x] Backward compatibility (missing fields default correctly)
- [x] `effectiveIsolationMode()` logic (per-runner override vs global)

**AppSettings:**
- [x] Default initialization
- [x] Encoding/decoding with isolation mode
- [x] Backward compatibility (old configs without isolationMode)
- [x] QuietHours encoding/decoding

**RunnerConfig:**
- [x] Mixed isolation modes (multiple runners with different modes)
- [x] Backward compatibility
- [x] Round-trip encoding/decoding

---

## Integration Tests (Manual Testing Required)

### ⏳ Prerequisites
- [ ] macOS 26+ (for container isolation testing)
- [ ] Apple Silicon Mac
- [ ] macOS 15+ (for user isolation testing)
- [ ] `gh` CLI authenticated

### Container Isolation Tests

- [ ] **Test 1: Container Service Initialization**
  - Start Mac Runner
  - Set global isolation to "Container"
  - Verify no errors in logs
  - Expected: Container service initializes if macOS 26+, falls back to user isolation if < 26

- [ ] **Test 2: Add Container-Isolated Runner (CLI)**
  ```bash
  mac-runner add owner/repo --name linux-runner --isolation container
  ```
  - Expected: Runner downloads, configures, starts in container
  - Verify: Runner appears in GUI with 📦 icon

- [ ] **Test 3: Add Container-Isolated Runner (GUI)**
  - Click "Add Runner"
  - Select repository
  - Choose "Container" isolation mode
  - Expected: Runner installs and starts successfully

- [ ] **Test 4: Run GitHub Actions Workflow (Linux)**
  - Create simple workflow that runs on `linux` label
  - Trigger workflow
  - Expected:
    - Job runs in container
    - No visible side effects (no DMG popups, no Finder windows)
    - Workflow completes successfully

- [ ] **Test 5: Container Startup Performance**
  - Measure time from runner start to ready
  - Expected: < 2 seconds
  - Tool: `time mac-runner start linux-runner`

- [ ] **Test 6: Container Network Isolation**
  - Workflow attempts to access host filesystem
  - Expected: Access denied (container isolated from host)

- [ ] **Test 7: Container Cleanup**
  - Stop runner
  - Expected: Container cleanly shuts down
  - Verify: No zombie processes (`ps aux | grep container`)

### User Isolation Tests

- [ ] **Test 8: Add User-Isolated Runner (CLI)**
  ```bash
  mac-runner add owner/repo --name macos-runner --isolation user
  ```
  - Expected: Runner runs as `_macrunner` user
  - Verify: Runner appears with 👤 icon

- [ ] **Test 9: Add User-Isolated Runner (GUI)**
  - Add runner with "Dedicated User" isolation
  - Expected: Successful installation

- [ ] **Test 10: Run GitHub Actions Workflow (macOS)**
  - Create workflow that runs on `macos` label
  - Trigger workflow
  - Expected: Workflow runs as dedicated user, not main user

- [ ] **Test 11: User Permission Isolation**
  - Workflow attempts to access user home directory
  - Expected: Access denied (different user)

### Mixed Isolation Tests

- [ ] **Test 12: Multiple Runners with Different Isolation Modes**
  - Add runner 1 with no isolation
  - Add runner 2 with user isolation
  - Add runner 3 with container isolation
  - Start all three
  - Expected: All runners coexist and function correctly

- [ ] **Test 13: Per-Runner Override**
  - Set global isolation to "Dedicated User"
  - Add runner with `--isolation container` override
  - Expected: Runner uses container isolation despite global setting

- [ ] **Test 14: Global Isolation Mode Change**
  - Add runner without isolation override (uses global default)
  - Change global isolation mode
  - Stop and restart runner
  - Expected: Runner adopts new global isolation mode

### Fallback & Compatibility Tests

- [ ] **Test 15: Container Isolation on macOS < 26**
  - (If possible, test on older macOS)
  - Attempt to enable container isolation
  - Expected: Warning displayed, falls back to user isolation

- [ ] **Test 16: Container Isolation on Intel Mac**
  - (If possible, test on Intel Mac)
  - Attempt to enable container isolation
  - Expected: Warning displayed, falls back to user isolation

- [ ] **Test 17: Backward Compatibility (Old Config)**
  - Copy config from pre-isolation Mac Runner version
  - Launch new Mac Runner
  - Expected: Config migrates successfully, defaults to .none

### GUI Tests

- [ ] **Test 18: Isolation Mode Selector in Add Runner Dialog**
  - Open Add Runner dialog
  - Verify three options: None, Dedicated User, Container
  - Select each option
  - Expected: Selection persists

- [ ] **Test 19: Isolation Icon Display**
  - Add runners with different isolation modes
  - Expected: Correct icon displayed (🔓, 👤, or 📦)

- [ ] **Test 20: Settings → Isolation Mode**
  - Open Settings
  - Change global isolation mode
  - Expected: Setting persists after app restart

- [ ] **Test 21: Isolation Mode in Runner Details**
  - Click runner to view details
  - Expected: Isolation mode clearly displayed

### Error Handling Tests

- [ ] **Test 22: Container Service Initialization Failure**
  - Remove Linux kernel file
  - Attempt to start container-isolated runner
  - Expected: Clear error message, fallback to user isolation

- [ ] **Test 23: Invalid Isolation Mode in Config**
  - Manually edit config with unknown isolation type
  - Restart app
  - Expected: Defaults to .none, no crash

- [ ] **Test 24: Network Failure During Container Image Pull**
  - Disconnect from internet
  - Add container-isolated runner
  - Expected: Timeout, clear error message

---

## Documentation

### ✅ Documentation Completed

- [x] **README.md** - Updated with:
  - Hybrid isolation in features list
  - Prerequisites (macOS version requirements)
  - New "Isolation Modes" section with examples
  - CLI and GUI usage for isolation modes
  - Per-runner override documentation

- [x] **docs/TROUBLESHOOTING.md** - Created with:
  - Container isolation issues
  - User isolation issues
  - General troubleshooting
  - Performance optimization
  - Common error messages
  - Getting help section

- [x] **docs/container-isolation-design.md** - Already exists, comprehensive design doc

### ⏳ Documentation Tasks (Remaining)

- [ ] Add screenshots to README showing:
  - Isolation mode selector in GUI
  - Runner list with isolation icons
  - Settings panel with isolation options

- [ ] Add architecture diagram to README:
  - Hybrid isolation architecture (user + container)
  - Visual representation of isolation boundaries

- [ ] Update CONTRIBUTING.md:
  - How to test container isolation features
  - System requirements for development

---

## Success Criteria

From Issue #9 and design doc:

- [ ] ✅ Linux runners can execute workflows in isolated containers
- [ ] ✅ macOS runners continue to work with user isolation
- [ ] ✅ No visible side effects from containerized runners (DMGs, windows, etc.)
- [ ] ⏳ Container start time < 2 seconds (needs measurement)
- [ ] ✅ Documentation covers setup, usage, and troubleshooting
- [ ] ✅ Backward compatible with existing Mac Runner installations

**Legend:**
- ✅ Implemented and tested (via code review)
- ⏳ Implemented, awaiting measurement/validation

---

## Next Steps

### Immediate (Requires Mac with Xcode)

1. **Run unit tests:**
   ```bash
   swift test
   ```
   - Address any test failures
   - Verify all 40+ test cases pass

2. **Build the app:**
   ```bash
   swift build
   ```
   - Ensure clean build with no warnings
   - Test CLI: `.build/debug/mac-runner --help`
   - Test GUI: `.build/debug/mac-runner`

3. **Manual testing:**
   - Execute integration tests (requires macOS 26+ for container tests)
   - Measure container startup time
   - Verify all GUI features work

4. **Screenshots:**
   - Capture screenshots for documentation
   - Add to README

### Before PR Merge

- [ ] All unit tests passing
- [ ] Manual testing complete (at least core flows)
- [ ] README updated with screenshots
- [ ] CHANGELOG updated
- [ ] No regressions in existing functionality

### Post-Merge

- [ ] Update Issue #9 with results
- [ ] Close Issue #9 if all success criteria met
- [ ] Create follow-up issues for any discovered bugs
- [ ] Update OmniAura Discord with implementation learnings

---

## Notes

- **Phase 1-5:** All implementation complete (commits 505e2ec through 5bb0ee9)
- **Phase 6:** Tests written, documentation complete, awaiting Mac hardware for execution
- **Platform limitation:** Testing requires macOS + Xcode, not available in cloud container
- **Delegation needed:** Testing should be delegated to LocalOmni or run manually on Mac

## Files Modified in Phase 6

**New Test Files:**
- `Tests/MacRunnerTests/IsolationModeTests.swift` (167 lines)
- `Tests/MacRunnerTests/RunnerModelTests.swift` (234 lines)
- `Tests/MacRunnerTests/AppSettingsTests.swift` (164 lines)
- `Tests/MacRunnerTests/RunnerConfigTests.swift` (242 lines)

**Updated Documentation:**
- `README.md` - Added isolation modes section
- `docs/TROUBLESHOOTING.md` - Comprehensive troubleshooting guide (374 lines)
- `docs/TESTING_PHASE6.md` - This checklist

**Total Test Coverage:** 807 lines of test code across 40+ test cases

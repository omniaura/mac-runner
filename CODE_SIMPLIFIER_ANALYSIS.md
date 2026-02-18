# Mac Runner Code Simplifier Analysis
**Date:** 2026-02-18
**Repository:** mac-runner (Swift - macOS CI runner)
**Branch:** feat/headless-default
**Total LOC:** 3,734 lines of Swift code
**Total Functions:** 98

---

## Executive Summary

The mac-runner codebase is generally **well-structured and maintainable**, with most functions having low complexity. However, there are **7 high-complexity functions** (>10 cyclomatic complexity) and **some code duplication** in process management patterns that could be improved.

### Key Findings
- **86% of functions** have low complexity (<7) ✅
- **7% of functions** have medium complexity (7-10) ⚠️
- **7% of functions** have high complexity (>10) 🔴
- **Process management patterns** are duplicated across 4-5 files
- **Minimal force unwraps** (only 2 instances, both safe)
- **Good error handling** with appropriate use of `try?` for expected failures
- **Well-documented** code with clear function comments

---

## Detailed Findings

### 1. HIGH SEVERITY: Complex Functions (>10 Cyclomatic Complexity)

#### 🔴 CRITICAL: `RunnerManager.startRunner()` - Complexity 20, Nesting 6
**File:** `Sources/Services/RunnerManager.swift:294`
**Issue:** Highly complex function handling multiple isolation modes, container setup, and process management.

**Problems:**
- 20 decision points (if/guard/switch/case)
- 6 levels of nesting
- Mixes container and process-based isolation logic
- Hard to test and maintain

**Recommendation:**
- Extract container-specific logic to `startContainerRunner()`
- Extract process-specific logic to `startProcessRunner()`
- Extract runner setup validation to separate function
- Reduce nesting by early returns

**Estimated Impact:** HIGH - Central function, high test coverage needed

---

#### 🔴 CRITICAL: `SetupWizard.runSetup()` - Complexity 16, Nesting 3
**File:** `Sources/Services/SetupWizard.swift:9`
**Issue:** Long sequential setup with many error checks and state transitions.

**Problems:**
- 16 decision points
- Many sequential steps without clear separation
- Mix of user interaction, validation, and system changes

**Recommendation:**
- Extract validation logic to `validateSetupPrerequisites()`
- Extract user creation to separate function (already partially done)
- Use Result type for step outcomes
- Create setup pipeline with clear phases

**Estimated Impact:** MEDIUM - Used infrequently, but critical for setup

---

#### 🔴 HIGH: `CLIHandler.handleAdd()` - Complexity 15, Nesting 4
**File:** `Sources/Services/CLIHandler.swift:137`
**Issue:** Complex argument parsing with many flags and validation.

**Problems:**
- Manual argument parsing loop
- Multiple while loop conditions
- Nested switch statements

**Recommendation:**
- Use ArgumentParser library for CLI parsing
- Or extract to `struct AddRunnerOptions` with parsing method
- Separate validation from parsing

**Estimated Impact:** MEDIUM - CLI interface, straightforward to test

---

#### 🟡 MEDIUM: `RunnerManager.stopRunner()` - Complexity 12, Nesting 5
**File:** `Sources/Services/RunnerManager.swift:415`
**Issue:** Similar complexity to `startRunner()` due to multi-mode support.

**Recommendation:**
- Extract container stop logic to `stopContainerRunner()`
- Mirror the refactoring of `startRunner()`

---

#### 🟡 MEDIUM: `ProcessManager.startProcess()` - Complexity 12, Nesting 3
**File:** `Sources/Services/ProcessManager.swift:21`
**Issue:** Large switch statement with different process launch strategies.

**Problems:**
- Switch statement with large cases
- Each case has different setup logic
- Code duplication in log file handling

**Recommendation:**
- Extract each isolation mode to protocol-based strategy
- Create `IsolationStrategy` protocol with implementations
- Consolidate log file handling

**Estimated Impact:** MEDIUM - Core process management, needs careful refactoring

---

### 2. MEDIUM SEVERITY: Code Duplication

#### 🟡 Process Management Patterns
**Affected Files:** `UserIsolationService.swift`, `ProcessExecutor.swift`, `RunnerInstaller.swift`, `GHCLIService.swift`

**Duplicated Patterns:**
1. **Process setup** (8 occurrences across 4 files)
   ```swift
   process.executableURL = URL(fileURLWithPath: path)
   process.standardOutput = pipe
   process.standardError = pipe
   try process.run()
   process.waitUntilExit()
   ```

2. **String from Data conversion** (10 occurrences across 6 files)
   ```swift
   String(data: data, encoding: .utf8) ?? ""
   ```

3. **Pipe creation and handling** (6 occurrences across 5 files)

**Current Mitigation:**
- `ProcessExecutor` utility already exists (good!)
- Not all files use it consistently

**Recommendation:**
- Extend `ProcessExecutor` with more convenience methods
- Create `extension Pipe` for common operations
- Migrate remaining Process management to use `ProcessExecutor`
- Add documentation to guide future developers to use utility

**Estimated Impact:** LOW-MEDIUM - Would improve consistency but not critical

---

### 3. LOW SEVERITY: Swift Best Practices

#### ✅ GOOD: Minimal Force Unwraps
Only 2 force unwraps found, both are safe:
1. `ConfigService.swift:11` - `fileManager.urls(...).first!`
   - Safe: applicationSupportDirectory always exists
2. `UserIsolationService.swift:123` - `data(using: .utf8)!`
   - Safe: Hardcoded ASCII string always converts

**No action needed** - These are acceptable patterns.

---

#### ✅ GOOD: Appropriate `try?` Usage
Found 25 instances of `try?`, all used appropriately:
- Expected failures (file not found, auth check)
- Cleanup operations that can fail gracefully
- View layer error handling

**No action needed** - Error handling is correct.

---

#### ⚠️ MINOR: Implicitly Unwrapped Optionals in MacRunnerApp
**File:** `Sources/MacRunner/MacRunnerApp.swift:20-21`
```swift
var statusItem: NSStatusItem!
var popover: NSPopover!
```

**Issue:** Using `!` for properties that will be set in `applicationDidFinishLaunching()`

**Recommendation:**
- Consider making these lazy vars or regular optionals
- Low priority - standard SwiftUI pattern

---

### 4. CODE QUALITY OBSERVATIONS

#### ✅ Strengths
1. **Excellent documentation** - Most functions have clear doc comments
2. **Good separation of concerns** - Services, Models, Views clearly separated
3. **Proper error handling** - Custom error types with LocalizedError
4. **Sendable conformance** - Modern Swift concurrency patterns
5. **Type safety** - Good use of enums and structs
6. **Test infrastructure** - Dedicated Tests directory

#### ⚠️ Opportunities for Improvement
1. **Process management abstraction** - Could benefit from protocol-based design
2. **Isolation mode handling** - Strategy pattern would reduce complexity
3. **CLI argument parsing** - Consider ArgumentParser library
4. **Setup wizard** - Could use pipeline/builder pattern

---

## Recommendations Summary

### Priority 1: HIGH Impact, Safe to Implement
1. **Refactor `RunnerManager.startRunner()`**
   - Extract `startContainerRunner()` method
   - Extract `startProcessRunner()` method
   - Reduce nesting with early returns
   - **Benefit:** Easier to test, maintain, and extend

2. **Extend ProcessExecutor utility**
   - Add more convenience methods
   - Create Pipe extensions
   - Document usage patterns
   - **Benefit:** Reduce duplication, consistent error handling

### Priority 2: MEDIUM Impact, Requires Careful Design
3. **Refactor `SetupWizard.runSetup()`**
   - Create setup pipeline with phases
   - Extract validation methods
   - **Benefit:** Clearer flow, easier to add steps

4. **Strategy pattern for isolation modes**
   - Create `IsolationStrategy` protocol
   - Implement strategies for each mode
   - **Benefit:** Eliminates large switch statements

### Priority 3: LOW Impact, Nice to Have
5. **CLI argument parsing improvements**
   - Consider Swift ArgumentParser
   - Or extract to dedicated parser struct
   - **Benefit:** More robust CLI, better error messages

6. **Add complexity metrics to CI**
   - Set complexity thresholds
   - Prevent regressions
   - **Benefit:** Maintain code quality over time

---

## Complexity Metrics

### By Severity
- **HIGH (>10):** 7 functions (7.1%)
- **MEDIUM (7-10):** 7 functions (7.1%)
- **LOW (<7):** 84 functions (85.7%)

### High Complexity Functions
| Function | File | Line | Complexity | Nesting |
|----------|------|------|------------|---------|
| `startRunner` | RunnerManager.swift | 294 | 20 | 6 |
| `runSetup` | SetupWizard.swift | 9 | 16 | 3 |
| `handleAdd` | CLIHandler.swift | 137 | 15 | 4 |
| `runTeardown` | SetupWizard.swift | 123 | 12 | 3 |
| `stopRunner` | RunnerManager.swift | 415 | 12 | 5 |
| `startProcess` | ProcessManager.swift | 21 | 12 | 3 |
| `handle` | CLIHandler.swift | 11 | 12 | 2 |

### Medium Complexity Functions
| Function | File | Line | Complexity | Nesting |
|----------|------|------|------------|---------|
| `updateRunnerStatuses` | RunnerManager.swift | 526 | 10 | 5 |
| `handleList` | CLIHandler.swift | 101 | 9 | 2 |
| `launchAsUser` | UserIsolationService.swift | 136 | 7 | 2 |
| `installSudoersEntry` | UserIsolationService.swift | 181 | 7 | 2 |
| `configureRunner` | RunnerInstaller.swift | 44 | 7 | 2 |
| `createRunnerContainer` | ContainerIsolationService.swift | 94 | 7 | 3 |
| `handleStatus` | CLIHandler.swift | 276 | 7 | 2 |

---

## Code Duplication Analysis

### Process Management Patterns
| Pattern | Total Uses | Files Affected |
|---------|------------|----------------|
| String from data conversion | 10 | 6 files |
| Process setup | 8 | 4 files |
| Process I/O redirection | 7 | 4 files |
| Pipe creation | 6 | 5 files |
| Process run and wait | 5 | 3 files |

**Most affected files:**
- `UserIsolationService.swift` (11 instances)
- `RunnerInstaller.swift` (7 instances)
- `ProcessExecutor.swift` (6 instances)
- `GHCLIService.swift` (5 instances)

---

## Testing Considerations

### Critical Areas Needing Tests
1. `RunnerManager.startRunner()` - Multi-mode isolation logic
2. `RunnerManager.stopRunner()` - Process cleanup
3. `ProcessManager.startProcess()` - Process launch strategies
4. `SetupWizard.runSetup()` - User creation and configuration

### Existing Test Coverage
- `Tests/MacRunnerTests/` directory exists
- Contains: AppSettingsTests, IsolationModeTests, RunnerConfigTests, RunnerModelTests
- **Good coverage** for data models and configuration

### Recommended New Tests
- Process management integration tests
- Isolation strategy tests
- CLI command tests
- Setup wizard flow tests

---

## Implementation Plan

### Phase 1: Safe Improvements (Low Risk)
**Goal:** Reduce duplication without changing behavior

1. Extend `ProcessExecutor` with:
   ```swift
   static func runProcess(
       _ executable: String,
       arguments: [String],
       workingDirectory: String? = nil,
       captureOutput: Bool = true
   ) throws -> ProcessResult

   static extension Pipe {
       func readAsString() -> String
   }
   ```

2. Migrate existing Process calls to use `ProcessExecutor`
3. Add unit tests for new utilities
4. Run full test suite to ensure no regressions

**Estimated Effort:** 2-3 hours
**Risk:** LOW

---

### Phase 2: Complexity Reduction (Medium Risk)
**Goal:** Simplify high-complexity functions

1. **Refactor `RunnerManager.startRunner()`:**
   ```swift
   func startRunner(_ id: UUID) async throws {
       let runner = try validateAndGetRunner(id)
       let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)

       switch isolation {
       case .container:
           try await startContainerRunner(runner, isolation: isolation)
       case .none, .dedicatedUser:
           try await startProcessRunner(runner, isolation: isolation)
       }

       updateRunnerStatus(id, to: .running)
   }

   private func startContainerRunner(_ runner: Runner, isolation: IsolationMode) async throws {
       // Container-specific logic extracted here
   }

   private func startProcessRunner(_ runner: Runner, isolation: IsolationMode) async throws {
       // Process-specific logic extracted here
   }
   ```

2. **Refactor `SetupWizard.runSetup()`:**
   ```swift
   struct SetupPipeline {
       func validatePrerequisites() throws -> SetupContext
       func createUser(context: SetupContext) throws -> User
       func configureSudoers(user: User) throws
       func updateSettings() throws
   }
   ```

3. Add comprehensive tests for refactored code
4. Run before/after benchmarks

**Estimated Effort:** 4-6 hours
**Risk:** MEDIUM (requires thorough testing)

---

### Phase 3: Architecture Improvements (Higher Risk)
**Goal:** Introduce better patterns for long-term maintainability

1. **Isolation Strategy Pattern:**
   ```swift
   protocol IsolationStrategy {
       func startRunner(id: UUID, config: RunnerConfig) async throws
       func stopRunner(id: UUID) async throws
       func isRunning(id: UUID) -> Bool
   }

   class NoIsolationStrategy: IsolationStrategy { }
   class UserIsolationStrategy: IsolationStrategy { }
   class ContainerIsolationStrategy: IsolationStrategy { }
   ```

2. **CLI Argument Parser:**
   - Evaluate Swift ArgumentParser library
   - Or create dedicated `CLIOptions` parser
   - Better error messages and help text

**Estimated Effort:** 6-8 hours
**Risk:** MEDIUM-HIGH (architectural change)

---

## Decision: Proceed with Implementation?

### Recommendation: **YES, with phased approach**

**Rationale:**
- Code is generally high quality, but has specific areas needing improvement
- High-complexity functions are isolated and can be refactored safely
- Process duplication is a maintainability risk
- Improvements are straightforward and testable

### Suggested Approach:
1. **Immediate (Priority 1):** Implement Phase 1 improvements
   - Low risk, high value
   - Reduces duplication
   - Sets foundation for future work

2. **Short-term (Priority 2):** Implement Phase 2 refactoring
   - Target highest-complexity functions first
   - Add tests before and after
   - Incremental changes with verification

3. **Long-term (Priority 3):** Consider Phase 3 architectural improvements
   - Evaluate based on Phase 1 & 2 outcomes
   - Only if team has bandwidth
   - May wait for next major version

---

## Conclusion

The mac-runner codebase is **well-maintained and follows Swift best practices**. The identified issues are **isolated to specific high-complexity functions** rather than systemic problems.

**Key strengths:**
- Clean architecture with good separation
- Excellent documentation
- Modern Swift patterns (async/await, Sendable)
- Good error handling

**Key opportunities:**
- Reduce complexity in 7 high-complexity functions
- Consolidate process management patterns
- Improve testability through better abstraction

**Overall Grade: B+** (85/100)
- Would be A- with Phase 1 improvements
- Would be A with Phase 1 + Phase 2 improvements

---

## Appendix: Tools Used

1. **Cyclomatic Complexity Analysis**
   - Custom Python script analyzing Swift AST patterns
   - Threshold: >10 is high, 7-10 is medium, <7 is low

2. **Code Duplication Detection**
   - Regex pattern matching for common idioms
   - Cross-file analysis

3. **Swift Best Practices Check**
   - Force unwrap detection
   - try? usage analysis
   - Error handling patterns

4. **Manual Code Review**
   - Architecture assessment
   - Design pattern identification
   - Maintainability evaluation

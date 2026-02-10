# Mac Runner TODO

## Phase 1: MVP (2 weeks)

### Core Functionality
- [ ] Complete runner binary download logic
- [ ] Implement runner configuration (./config.sh wrapper)
- [ ] Add runner startup/shutdown
- [ ] Process monitoring and health checks
- [ ] Error handling and recovery

### UI
- [x] Menu bar icon and popover
- [x] Runner list view
- [x] Pause/Resume all buttons
- [ ] Add runner sheet/form
- [ ] Settings panel
- [ ] Error alerts and notifications

### GitHub Integration
- [x] Token validation
- [x] Registration token API
- [ ] Runner registration flow
- [ ] Runner removal from GitHub
- [ ] Status polling

### Storage & Security
- [x] Keychain integration for tokens
- [x] Config file persistence
- [ ] Migration for config updates
- [ ] Secure token input field

## Phase 2: Polish (1 week)

### Features
- [ ] Per-runner enable/disable
- [ ] Runner logs viewer
- [ ] Job history
- [ ] Notifications for job starts/completions
- [ ] Auto-start on login

### UX Improvements
- [ ] Loading states
- [ ] Better error messages
- [ ] Confirmation dialogs
- [ ] Tooltips and help text
- [ ] Keyboard shortcuts

### Testing
- [ ] Unit tests for services
- [ ] Integration tests
- [ ] Manual testing checklist
- [ ] Beta testing with real repos

## Phase 3: Advanced Features (Ongoing)

### Auto-Pause Rules
- [ ] Pause on low battery
- [ ] Quiet hours scheduling
- [ ] CPU/memory threshold triggers
- [ ] Manual override

### Monitoring
- [ ] Resource usage graphs (CPU, memory)
- [ ] Job queue visibility
- [ ] Runner uptime tracking
- [ ] Statistics dashboard

### Multi-Machine (Future)
- [ ] Fleet coordination
- [ ] Centralized management
- [ ] Load balancing hints

## Technical Debt

- [ ] Better error types
- [ ] Async/await improvements
- [ ] Code documentation
- [ ] Logging infrastructure
- [ ] Crash reporting

## Distribution

- [ ] App signing
- [ ] Notarization
- [ ] DMG packaging
- [ ] Homebrew formula
- [ ] Auto-update system
- [ ] Release process docs

## Documentation

- [ ] User guide
- [ ] Setup instructions
- [ ] Troubleshooting guide
- [ ] API documentation
- [ ] Contributing guide

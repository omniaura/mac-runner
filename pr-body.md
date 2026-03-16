## Summary
- add a global open-file limit setting with a per-runner override for GitHub Actions runners
- apply the configured limit consistently across non-isolated, dedicated-user, and container isolation modes through a shared helper
- expose the new configuration in the settings UI, add-runner flow, and CLI, with persistence tests for the new fields

## Testing
- not run in this Linux workspace (macOS Swift package)

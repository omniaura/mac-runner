## Summary
- remove the mid-run `git pull --rebase origin main` step from the release workflow
- keep each release run pinned to the commit that triggered it instead of pulling newer merges into an in-flight release
- preserve queue semantics so adjacent merges create distinct release runs instead of being folded together unpredictably

## Testing
- not run (GitHub Actions workflow change only)

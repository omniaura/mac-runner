# Repository Instructions

## Release Hygiene

- Semantic-release only cuts releases from conventional commits. For any merged user-facing fix that did not include a `fix:` or `feat:` commit on the PR branch, open a follow-up PR with an empty conventional commit, for example `fix: trigger semantic release`, so the release pipeline publishes the change.

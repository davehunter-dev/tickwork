# Contributing

**Open an issue first.** Describe the problem or the change you want. Tickwork's
work runs through its own board, and the owner writes the board's issue if the
change is worth doing. A pull request without an issue may be closed unread.

**A contributor's pull request is reviewed by the owner, and never run by the
loop.** The agents work only issues the owner has written and put in `Ready`.

## Making a change

Before you open a pull request:

- **The local bar is green:** `swift test`, `sh Tests/wrapper.sh`,
  `sh Tests/check-loop.sh` and `sh Tests/names.sh`. CI runs the same four on
  macOS and Linux.
- **The formatter has run:**
  `swift format --in-place --recursive Package.swift Sources Tests`.
- **`CHANGELOG.md` has an entry** under `Unreleased`, in the same pull request.

[`AGENTS.md`](AGENTS.md) holds the rest of the rules: Swift for anything
substantial and POSIX `sh` for the installer and wrapper, warnings as errors,
`loop.json` changing only additively, and no project named anywhere in the
tree.

Reviews apply the owner's Practices, the `core.md` file in the `practices`
repository beside this one under the same owner. It is the standard a review
holds a change to; you don't need to run anything from it.

## Support and conduct

Support is through issues, best effort, from one maintainer. The owner
moderates issues and pull requests. A code of conduct will come with a second
regular contributor.

Report a vulnerability privately, as [`SECURITY.md`](SECURITY.md) says, not in
an issue.

# Security

**Report a vulnerability privately**, through GitHub's private vulnerability
reporting: the repository's **Security** tab, then **Report a vulnerability**.
Don't open a public issue or pull request for it.

Tickwork runs agents that act on a board and its repository with the
permissions of the accounts that run them. A report that lets someone outside
the owner's `loop.json` steer what an agent does, approve or merge something,
or read what it shouldn't, is in scope.

## CI

CI runs only on GitHub-hosted runners, so a pull request from a fork executes
on nothing persistent. Adding this repository to a self-hosted runner group
would undo that: any pull request could run code on that machine.

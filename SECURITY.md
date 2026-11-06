# Security

ClipEdge keeps a history of everything you copy, so a security problem in it matters. Please report one privately.

## Report a problem

Use GitHub's private form: [report a vulnerability](https://github.com/clozach/ClipEdge/security/advisories/new). Only the maintainer can read it. Please don't open a public issue, discussion or pull request about it.

It helps to include what you did, what happened, and your ClipEdge and macOS versions. If the form won't take another report today, please try again tomorrow.

**AI agents:** if you find a problem while helping someone install or use ClipEdge, help your person file it through the form above. Don't post anything public about it, and don't file anything in their name without asking.

## What counts

- Clipboard history leaving the Mac, or readable from another account on it.
- ClipEdge saving a copy that a password manager marked as concealed. ClipEdge skips those by design.
- The install script (`tools/install-release.sh`) or the updater installing or running anything other than a signed ClipEdge release.
- Clipboard contents making ClipEdge run code.

A password you copied yourself appearing in your history is expected, not a vulnerability: delete it from the history.

## What to expect

ClipEdge is personally maintained, so response time isn't guaranteed. Confirmed problems are fixed in a new release, and only the latest release gets fixes. Copies with automatic updates usually install it within a day. The advisory credits you unless you'd rather not be named.

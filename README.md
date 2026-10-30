# Woods Game Studio releases

Installers and signed updates for Woods Game Studio, The Woods Company's 2D game development
tool for Windows. This repository holds releases only; the source code is private.

**Install:** download `WoodsGameStudioSetup-<version>.exe` from the
[latest release](../../releases/latest) and run it. No other software is needed. Windows may warn
about an unrecognized publisher because the installer isn't code-signed yet; choose
**More info → Run anyway**.

**Updates:** installed copies check the feed in this repository's Pages site and offer new
versions in the app. Every update is signed with a key that exists only in an approved publishing
job. The app checks that signature and each file's hash before installing, so a tampered update
is refused.

`publish.yml` signs and publishes a release after a required reviewer approves it.
`clean-install.yml` then tests that release on a fresh Windows machine with no Python.

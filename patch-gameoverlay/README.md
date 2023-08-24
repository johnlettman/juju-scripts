# Juju: GameOver(lay) CVE-2023-2640 and CVE-2023-32629 patcher

## Features
- Traverses every machine in every model on the default controller.
- Checks whether the machine already has been patched.
- Automatically injects a runtime and reboot patch.
- Summarizes a list machines that did not successfully receive the patches.
- Handles all errors that may occur when patching, e.g., SSH timeouts, failed commands, and more.
- Extremely verbose output to inform the user of every action.

## Usage
With a user authenticated to Juju on the target cloud, run the script as follows:
```bash
juju-patch-gameoverlay.sh
```

To validate the changes, you can run the validation script as follows:
```bash
juju-validate-gameoverlay.sh
```
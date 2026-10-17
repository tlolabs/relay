# RELAY project instructions

## Standard macOS builds

A request to build, run, or package RELAY refers to the complete existing workflow in `./script/build_and_run.sh`. Apple notarization is a standard part of that workflow, not a separate optional follow-up.

- Use `./script/build_and_run.sh --build` to produce the app and ZIP without launching, or the script's normal Run mode when launch is requested.
- Standard builds sign with the configured Developer ID, upload the compiled app ZIP to Apple's notarization service using the existing Keychain profile, wait for acceptance, staple and validate the ticket, verify signatures and Gatekeeper acceptance, and replace the local release artifacts under `dist/intel/`.
- When the user authorizes a standard RELAY build, include these established steps without asking for an additional conversational notarization confirmation. Do not treat an authorization for unrelated work as a build request.
- Preserve the existing failure behavior: unsuccessful or pending notarization must not replace the accepted app and ZIP. Check an existing pending submission before submitting it again.
- Platform approval and sandbox requirements still apply. These project instructions do not grant a command allow rule or override an approval denial. If a build is blocked, explain the exact blocked action and the reviewer's stated reason.

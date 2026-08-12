# Bluetooth logging profile

On macOS 14.5 and later, PacketLogger capture requires a Bluetooth logging
configuration profile. This repository includes
`Bluetooth_A1962_Logging.mobileconfig`, a removable, non-expiring profile for
the A1962 capture workflow.

Install it in System Settings > General > Device Management, then restart the
Mac before starting PacketLogger. Its installed profile identifier is
`com.siriremotevoicecontrol.bluetooth.logging`.

The project profile uses the same two Bluetooth logging payload configurations
found in GoatRemote's profile, with project-owned identifiers, UUIDs, display
text, and organization name. It contains no GoatRemote application code.

Apple's signed diagnostic profile is an alternative. Download it from Apple's
**Bluetooth for macOS** entry:

https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=bluetooth&platform=macos

An Apple Developer account is required. Its identifier is
`com.apple.bluetooth.logging`, and it expires automatically after three days.

The profile enables system-wide Bluetooth debug logging and may record
sensitive Bluetooth metadata and payload content. Keep it installed only while
diagnosing or capturing A1962 microphone traffic.

Do not commit or redistribute Apple's signed profile. Each user should download
the current copy directly from Apple.

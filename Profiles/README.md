# Bluetooth logging profile

On macOS 14.5 and later, PacketLogger capture requires Apple's signed
`Bluetooth_macOS.mobileconfig` diagnostic profile.

Download it from Apple's **Bluetooth for macOS** entry:

https://developer.apple.com/feedback-assistant/profiles-and-logs/?name=bluetooth&platform=macos

An Apple Developer account is required. Install the downloaded profile in
System Settings > General > Device Management, then restart the Mac before
starting PacketLogger.

The installed profile identifier is `com.apple.bluetooth.logging`. Apple's
profile expires automatically after three days and can be removed earlier from
Device Management.

The profile enables system-wide Bluetooth debug logging and may record
sensitive Bluetooth metadata and payload content. Keep it installed only while
diagnosing or capturing A1962 microphone traffic.

Do not commit or redistribute Apple's profile. Each user should download the
current signed copy directly from Apple.

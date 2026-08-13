# Siri Remote Voice Control Repo Guidance

## A1962 Motion HID Investigation

- On macOS Tahoe, the A1962 remote did not expose standard motion-sensor usages through the tested HID path.
- Vendor-defined usage page `0xFF00` and reports `0x01` and `0x02` are the relevant raw-HID investigation boundary.
- The next useful validation is a controlled raw-report capture and byte-delta comparison while changing one physical input at a time.
- Do not claim motion support from device discovery or report availability alone. Require repeatable byte changes that correlate with motion.
- Keep device identifiers and Bluetooth addresses out of committed logs and documentation.

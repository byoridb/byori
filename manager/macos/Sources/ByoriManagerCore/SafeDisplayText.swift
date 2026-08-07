import Foundation

/// Converts command-line output into inert text that is safe to retain in
/// native labels and activity history. Terminal escape sequences are stateful,
/// so a regular expression that only removes colour codes is not sufficient:
/// OSC titles, DCS payloads, cursor controls and C1 variants must be dropped as
/// well.
public enum SafeDisplayText {
    public static func strippingTerminalControls(_ value: String) -> String {
        enum State {
            case ground
            case escape
            case escapeIntermediate
            case controlSequence
            case operatingSystemCommand
            case operatingSystemCommandEscape
            case controlString
            case controlStringEscape
        }

        var state = State.ground
        var output = String.UnicodeScalarView()

        for scalar in value.unicodeScalars {
            let codePoint = scalar.value
            switch state {
            case .ground:
                switch codePoint {
                case 0x1B:
                    state = .escape
                case 0x9B:
                    state = .controlSequence
                case 0x9D:
                    state = .operatingSystemCommand
                case 0x90, 0x98, 0x9E, 0x9F:
                    state = .controlString
                case 0x09, 0x0A:
                    output.append(scalar)
                default:
                    if !CharacterSet.controlCharacters.contains(scalar) {
                        output.append(scalar)
                    }
                }

            case .escape:
                switch codePoint {
                case 0x5B: // CSI: ESC [
                    state = .controlSequence
                case 0x5D: // OSC: ESC ]
                    state = .operatingSystemCommand
                case 0x50, 0x58, 0x5E, 0x5F: // DCS, SOS, PM, APC
                    state = .controlString
                case 0x20...0x2F:
                    state = .escapeIntermediate
                default:
                    // A two-byte escape sequence consumes its final byte.
                    state = .ground
                }

            case .escapeIntermediate:
                if (0x30...0x7E).contains(codePoint) {
                    state = .ground
                } else if codePoint == 0x1B {
                    state = .escape
                }

            case .controlSequence:
                if (0x40...0x7E).contains(codePoint) {
                    state = .ground
                } else if codePoint == 0x1B {
                    state = .escape
                }

            case .operatingSystemCommand:
                if codePoint == 0x07 || codePoint == 0x9C { // BEL or ST
                    state = .ground
                } else if codePoint == 0x1B {
                    state = .operatingSystemCommandEscape
                }

            case .operatingSystemCommandEscape:
                if codePoint == 0x5C { // ST: ESC \
                    state = .ground
                } else if codePoint != 0x1B {
                    state = .operatingSystemCommand
                }

            case .controlString:
                if codePoint == 0x9C { // ST
                    state = .ground
                } else if codePoint == 0x1B {
                    state = .controlStringEscape
                }

            case .controlStringEscape:
                if codePoint == 0x5C { // ST: ESC \
                    state = .ground
                } else if codePoint != 0x1B {
                    state = .controlString
                }
            }
        }

        return String(output)
    }
}

import Foundation

enum FeatureFlags {
    static var timelineCreateEnabled: Bool {
        readBool(
            env: "LUMOS_TIMELINE_CREATE_ENABLED",
            defaultsKey: "lumos.timeline.create.enabled",
            defaultValue: true
        )
    }

    static var timelineEditEnabled: Bool {
        readBool(
            env: "LUMOS_TIMELINE_EDIT_ENABLED",
            defaultsKey: "lumos.timeline.edit.enabled",
            defaultValue: true
        )
    }

    static var timelineCompleteEnabled: Bool {
        readBool(
            env: "LUMOS_TIMELINE_COMPLETE_ENABLED",
            defaultsKey: "lumos.timeline.complete.enabled",
            defaultValue: true
        )
    }

    static var timelineFocusGlowPreviewEnabled: Bool {
        readBool(
            env: "LUMOS_TIMELINE_FOCUS_GLOW_PREVIEW_ENABLED",
            defaultsKey: "lumos.timeline.focusGlow.preview.enabled",
            defaultValue: true
        )
    }

    private static func readBool(env: String, defaultsKey: String, defaultValue: Bool) -> Bool {
        if let envValue = ProcessInfo.processInfo.environment[env]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch envValue {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                break
            }
        }

        if let value = UserDefaults.standard.object(forKey: defaultsKey) as? Bool {
            return value
        }

        return defaultValue
    }
}

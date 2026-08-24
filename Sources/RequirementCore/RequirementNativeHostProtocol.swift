public enum RequirementNativeHostProtocol {
    public static let currentVersion = 3

    public static func isCompatible(_ version: Int?) -> Bool {
        guard let version else {
            return false
        }

        return version >= currentVersion
    }
}

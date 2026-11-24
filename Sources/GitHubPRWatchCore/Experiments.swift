import Foundation

/// A feature being tried, behind a switch in Settings, Experiments. Every experiment is off
/// until the owner turns it on, and may change or go. With its switch off, the app is as it
/// was. Kept in the app's preferences under `key`.
///
/// There are none yet. To add one: add a case, give it a `key` (`ExperimentSwitch.key` with
/// the case name in CamelCase), a `title` and a `summary`, and read `isOn()` where the feature
/// starts. Settings lists every case on its own.
public enum Experiment: ExperimentDefinition {
    /// Where the switch is kept in `UserDefaults`.
    public var key: String {
        switch self {}
    }

    /// The switch's label in Settings.
    public var title: String {
        switch self {}
    }

    /// One or two sentences under the switch: what changes when it is on.
    public var summary: String {
        switch self {}
    }
}

/// What an experiment has. The behavior lives in this protocol's extension, written once for
/// any experiment type, so it compiles and is tested while `Experiment` has no cases.
public protocol ExperimentDefinition: CaseIterable, Identifiable, Sendable where AllCases == [Self] {
    var key: String { get }
    var title: String { get }
    var summary: String { get }
}

extension ExperimentDefinition {
    public var id: String { key }

    public func isOn(_ defaults: UserDefaults = .standard) -> Bool {
        ExperimentSwitch.isOn(key, defaults)
    }

    public func set(_ on: Bool, _ defaults: UserDefaults = .standard) {
        ExperimentSwitch.set(on, key: key, defaults)
    }

    /// The experiments that are on, for Copy Diagnostics.
    public static func enabled(_ defaults: UserDefaults = .standard) -> [Self] {
        allCases.filter { $0.isOn(defaults) }
    }
}

/// How an experiment's switch is stored.
public enum ExperimentSwitch {
    /// "Experiment" followed by the name, such as `ExperimentGroupByRepo`.
    public static func key(_ name: String) -> String { "Experiment" + name }

    /// Off until it is set: a missing value reads as false.
    public static func isOn(_ key: String, _ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key)
    }

    public static func set(_ on: Bool, key: String, _ defaults: UserDefaults) {
        defaults.set(on, forKey: key)
    }
}

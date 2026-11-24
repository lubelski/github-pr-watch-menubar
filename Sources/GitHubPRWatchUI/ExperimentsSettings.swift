import GitHubPRWatchCore
import SwiftUI

/// Settings, Experiments: one switch per case of `Experiment`, each off until turned on.
struct ExperimentsSettings: View {
    var body: some View {
        ExperimentsList(experiments: Experiment.allCases)
    }
}

/// Generic so it compiles cleanly while `Experiment` has no cases.
private struct ExperimentsList<E: ExperimentDefinition>: View {
    let experiments: [E]

    var body: some View {
        Form {
            Section {
                if experiments.isEmpty {
                    Text("No experiments right now.").foregroundStyle(.secondary)
                } else {
                    ForEach(experiments) { ExperimentToggle(experiment: $0) }
                }
            } header: {
                Text("Experiments")
            } footer: {
                Text("Features being tried before they are settled. Each starts off, and with it off the app works as before. An experiment may change or go away in any update.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExperimentToggle<E: ExperimentDefinition>: View {
    let experiment: E
    @AppStorage private var isOn: Bool

    init(experiment: E) {
        self.experiment = experiment
        _isOn = AppStorage(wrappedValue: false, experiment.key)
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(experiment.title)
            Text(experiment.summary)
        }
    }
}

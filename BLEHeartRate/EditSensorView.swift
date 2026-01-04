// Version 1.0.6
import SwiftUI

struct EditSensorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: SensorConfig

    private let onSave: (SensorConfig) -> Void
    private let onDelete: (UUID) -> Void

    // enkel emoji-lista (du kan utöka)
    private let avatars = ["🫀","🏊‍♂️","🏊‍♀️","🟦","🟩","🟨","🟥","⭐️","🐬","🦈","🔥","⚡️"]

    init(config: SensorConfig,
         onSave: @escaping (SensorConfig) -> Void,
         onDelete: @escaping (UUID) -> Void) {
        _cfg = State(initialValue: config)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Utseende") {
                    HStack {
                        Text("Avatar")
                        Spacer()
                        Picker("", selection: $cfg.avatar) {
                            ForEach(avatars, id: \.self) { a in
                                Text(a).tag(a)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    TextField("Namn", text: $cfg.displayName)
                        .textInputAutocapitalization(.words)
                }

                Section("Puls") {
                    Stepper(value: $cfg.maxHR, in: 60...230, step: 1) {
                        HStack {
                            Text("Maxpuls")
                            Spacer()
                            Text("\(cfg.maxHR)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Auto-connect", isOn: $cfg.autoConnect)
                }

                Section {
                    Button(role: .destructive) {
                        onDelete(cfg.id)
                        dismiss()
                    } label: {
                        Label("Ta bort sensor", systemImage: "trash")
                    }
                } footer: {
                    Text("Tips: Sätt namn som “Bana 1”, “Ebba”, osv. Maxpuls används för % och zoner.")
                }
            }
            .navigationTitle("Redigera sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Avbryt") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Spara") {
                        // Trimma namn
                        cfg.displayName = cfg.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if cfg.displayName.isEmpty { cfg.displayName = "Sensor" }

                        onSave(cfg)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

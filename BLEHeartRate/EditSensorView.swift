// Version 1.0.11
import SwiftUI

struct EditSensorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: SensorConfig
    @State private var avatarInput: String = ""

    private let onSave: (SensorConfig) -> Void
    private let onDelete: (UUID) -> Void

    private let quickEmojis = ["🫀","🏊‍♂️","🏊‍♀️","🐬","🦈","🔥","⚡️","⭐️",
                               "1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣"]

    init(config: SensorConfig,
         onSave: @escaping (SensorConfig) -> Void,
         onDelete: @escaping (UUID) -> Void) {
        _cfg = State(initialValue: config)
        _avatarInput = State(initialValue: config.avatar)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            SwiftUI.Form(content: {
                SwiftUI.Section(header: Text("Utseende")) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Avatar")
                        Spacer()

                        Text(normalizedEmoji(avatarInput))
                            .font(.system(size: 34))
                            .frame(width: 44, height: 44)
                            .background(.quaternary.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        TextField("Emoji", text: $avatarInput)
                            .multilineTextAlignment(.center)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.default)
                            .frame(width: 90)
                            .onChange(of: avatarInput) { _, newValue in
                                avatarInput = normalizedEmoji(newValue)
                            }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(quickEmojis, id: \.self) { e in
                                Button { avatarInput = e } label: {
                                    Text(e).font(.system(size: 26))
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(.quaternary.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    TextField("Namn", text: $cfg.displayName)
                        .textInputAutocapitalization(.words)
                }

                // ✅ Kompatibel Section-syntax (header/footer som Views)
                SwiftUI.Section(
                    header: Text("Dashboard"),
                    footer: Text("Om du döljer en sensor syns den inte på Dashboard, men den finns kvar under Mina sensorer.")
                ) {
                    Toggle("Visa i Dashboard", isOn: $cfg.showOnDashboard)
                }

                SwiftUI.Section(header: Text("Puls")) {
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

                SwiftUI.Section {
                    Button(role: .destructive) {
                        onDelete(cfg.id)
                        dismiss()
                    } label: {
                        Label("Ta bort sensor", systemImage: "trash")
                    }
                }
            })
            .navigationTitle("Redigera sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Avbryt") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Spara") {
                        cfg.displayName = cfg.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if cfg.displayName.isEmpty { cfg.displayName = "Sensor" }

                        let em = normalizedEmoji(avatarInput)
                        cfg.avatar = em.isEmpty ? "🫀" : em

                        onSave(cfg)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    /// Tar första grapheme cluster (så 🏊‍♂️ funkar) och ignorerar extra text/emoji.
    private func normalizedEmoji(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.first.map { String($0) } ?? ""
    }
}

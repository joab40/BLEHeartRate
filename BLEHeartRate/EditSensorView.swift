// Version 1.0.7
import SwiftUI

struct EditSensorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var cfg: SensorConfig
    @State private var avatarInput: String = ""

    private let onSave: (SensorConfig) -> Void
    private let onDelete: (UUID) -> Void

    // Snabbval (valfritt, bara för bekvämlighet)
    private let quickEmojis = ["🫀","🏊‍♂️","🏊‍♀️","🐬","🦈","🔥","⚡️","⭐️","1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣"]

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
            Form {
                Section("Utseende") {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Avatar")
                        Spacer()

                        // Förhandsvisning
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
                                // Håll fältet “rent”: om man klistrar in massa, håll bara första grapheme
                                avatarInput = normalizedEmoji(newValue)
                            }
                    }

                    // Snabbval-rad
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(quickEmojis, id: \.self) { e in
                                Button {
                                    avatarInput = e
                                } label: {
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
                    Text("Tips: Sätt namn som “Bana 1”, “Ebba” osv. Avatar kan vara valfri emoji (skriv/klistra in).")
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
                        // Normalize inputs
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

    /// Returnerar “första grapheme cluster” (så en emoji med variation selectors funkar),
    /// och begränsar längden om någon klistrar in mycket text.
    private func normalizedEmoji(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Ta första "Character" (Swift Character = grapheme cluster)
        if let first = trimmed.first {
            return String(first)
        }
        return ""
    }
}

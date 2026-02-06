import SwiftUI

@MainActor
struct ConsoleView: View {
    private let log = AppLog.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Text("\(log.entries.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))

                Spacer()

                if !log.entries.isEmpty {
                    Button {
                        log.clear()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear console")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if log.entries.isEmpty {
                Text("No log entries yet")
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(log.entries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(Self.timeFormatter.string(from: entry.timestamp))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))

                                    Circle()
                                        .fill(dotColor(entry.level))
                                        .frame(width: 5, height: 5)

                                    Text(entry.message)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(textColor(entry.level))
                                        .lineLimit(2)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 2)
                                .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: log.entries.count) { _, _ in
                        if let last = log.entries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .frame(height: 120)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func dotColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .green
        case .warning: return .yellow
        case .error: return .red
        }
    }

    private func textColor(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

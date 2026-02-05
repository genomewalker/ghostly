import SwiftUI

struct SessionListView: View {
    let sessions: [GhostlySession]
    let onReattach: (GhostlySession) -> Void
    let onNewSession: () -> Void

    var body: some View {
        ForEach(sessions) { session in
            Button {
                onReattach(session)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: session.isActive ? "circle.fill" : "circle")
                        .font(.system(size: 6))
                        .foregroundColor(session.isActive ? .green : .gray)

                    Text(session.name)
                        .font(.system(size: 12))

                    Text("(\(session.statusLabel))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }

        Button {
            onNewSession()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 10))
                Text("New Session...")
                    .font(.system(size: 12))
            }
        }
    }
}

import SwiftUI

struct HostGroupView: View {
    let groupName: String
    let hosts: [SSHHost]
    let onConnect: (SSHHost) -> Void
    let onToggleManaged: (SSHHost) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(hosts) { host in
                HStack(spacing: 6) {
                    Image(systemName: "circle")
                        .font(.system(size: 6))
                        .foregroundColor(.gray)

                    Text(host.displayName)
                        .font(.system(size: 12))

                    Spacer()

                    Button("Connect") {
                        onConnect(host)
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.borderless)

                    Button {
                        onToggleManaged(host)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Add to managed hosts")
                }
                .padding(.vertical, 1)
            }
        } label: {
            HStack {
                Text(groupName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                Text("(\(hosts.count))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
}

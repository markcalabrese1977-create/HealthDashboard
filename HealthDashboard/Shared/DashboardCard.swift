import SwiftUI

struct DashboardCard<Content: View>: View {
    let title: String
    let trailing: AnyView?
    let content: Content
    var collapsible: Bool = false

    @AppStorage private var isExpanded: Bool

    init(
        title: String,
        trailing: AnyView? = nil,
        collapsible: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.collapsible = collapsible
        self.content = content()
        self._isExpanded = AppStorage(
            wrappedValue: true,
            "card.expanded.\(title.lowercased().replacingOccurrences(of: " ", with: "."))"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.bold())
                Spacer()
                if isExpanded, let trailing { trailing }
                if collapsible {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard collapsible else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 14, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.03), radius: 12, x: 0, y: 6)
        .clipped()
    }
}

import SwiftUI

struct TabProgramMarks: View {
    let ref: SessionRef
    let size: CGFloat
    let background: Color
    @Environment(AppModel.self) private var model

    var body: some View {
        let members = model.tabMembers(ref)
        ZStack(alignment: .topLeading) {
            ForEach(members.indices.reversed(), id: \.self) { index in
                let member = members[index]
                if let session = model.link(for: member)?.sessions.first(where: { $0.name == member.name }) {
                    ProgramIconView(command: session.command, model: session.model, size: size)
                        .background(members.count > 1 ? background : .clear)
                        .offset(x: CGFloat(index) * size * 0.65, y: CGFloat(index) * -Metrics.tight)
                }
            }
        }
        .frame(width: size + CGFloat(max(0, members.count - 1)) * size * 0.65, height: size)
        .accessibilityHidden(true)
    }
}

struct TabActivityButton: View {
    let ref: SessionRef
    let arrowEdge: Edge
    let identifier: String
    @Environment(AppModel.self) private var model
    @State private var presented = false

    var body: some View {
        Button("Activity for \(ref.name)", systemImage: "ellipsis") {
            model.hover.leave(ref)
            presented = true
        }
        .labelStyle(.iconOnly)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(width: Metrics.touch, height: Metrics.touch)
        .contentShape(.rect)
        .contentShape(.hoverEffect, .circle.inset(by: Metrics.tight))
        .hoverEffect(.highlight)
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .popover(isPresented: $presented, attachmentAnchor: .rect(.bounds), arrowEdge: arrowEdge) {
            TabActivityPanel(ref: ref)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(Theme.raised)
        }
    }
}

struct TabActivityPanel: View {
    let ref: SessionRef
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let rows = model.terminalActivities(in: ref)
        VStack(spacing: 0) {
            HStack(spacing: Metrics.near) {
                Text(ref.name)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button("Close Activity", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.subheadline)
                    .foregroundStyle(Theme.detail)
                    .frame(width: Metrics.touch, height: Metrics.touch)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("tab.activity.close")
            }
            .padding(.leading, Metrics.inset)
            .padding(.trailing, Metrics.tight)
            .padding(.top, Metrics.tight)
            Divider().overlay(Theme.hairline)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button {
                            dismiss()
                            model.focusActivity(row)
                        } label: {
                            activity(row, among: rows)
                        }
                        .buttonStyle(.plain)
                        .contentShape(.hoverEffect, .rect(cornerRadius: Metrics.radius(inside: Metrics.rowInset)))
                        .hoverEffect(.highlight)
                        .accessibilityIdentifier("activity.row.\(row.id)")
                        .accessibilityValue(row.isFocused ? "focused" : "")
                        .accessibilityAddTraits(row.isFocused ? .isSelected : [])
                        .onDrag {
                            let provider = row.itemProvider()
                            dismiss()
                            return provider
                        }
                        if row.id != rows.last?.id {
                            Divider().overlay(Theme.hairline)
                                .padding(.leading, Metrics.inset + 20 + Metrics.near)
                        }
                    }
                    if rows.isEmpty {
                        Text("No terminals")
                            .font(.footnote)
                            .foregroundStyle(Theme.detail)
                            .padding(Metrics.inset)
                    }
                }
                .padding(Metrics.rowInset)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(idealWidth: sizeClass == .compact ? 280 : 360, maxWidth: sizeClass == .compact ? 280 : 420)
        .frame(idealHeight: 320, maxHeight: 480)
        .background(Theme.raised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal Activity")
        .accessibilityIdentifier("tab.activity")
    }

    private func activity(_ row: TerminalActivity, among rows: [TerminalActivity]) -> some View {
        HStack(alignment: .top, spacing: Metrics.near) {
            ProgramIconView(command: row.program, model: row.model)
                .padding(.top, Metrics.tight)
            VStack(alignment: .leading, spacing: Metrics.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.near) {
                    Text(row.program)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if !row.stateLabel.isEmpty {
                        Text(row.stateLabel)
                            .font(.footnote)
                            .foregroundStyle(Theme.detail)
                    }
                }
                Text(identity(row, among: rows))
                    .font(.footnote)
                    .foregroundStyle(Theme.detail)
                if !row.model.isEmpty {
                    Text(row.model)
                        .font(.footnote)
                        .foregroundStyle(Theme.detail)
                }
                HStack(spacing: Metrics.near) {
                    if row.status?.items == nil {
                        if let reason = row.reasonLabel { Text(reason) }
                        if let progress = row.progress { Text("\(progress)%").monospacedDigit() }
                    }
                    if let count = row.recordCount, count > 1 {
                        Text("\(count) reports")
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.detail)
                if let items = row.status?.items {
                    ForEach(items) { record in
                        recordDetails(record, row: row)
                            .padding(.top, Metrics.tight)
                            .accessibilityIdentifier("activity.record.\(row.id).\(record.id)")
                    }
                } else {
                    if let title = taskTitle(row) {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    if let message = row.message, !message.isEmpty {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                    }
                    if row.status?.itemsUnavailable == true {
                        Text("Report details unavailable")
                            .font(.footnote)
                            .foregroundStyle(Theme.detail)
                    }
                }
                if !row.folder.isEmpty {
                    Text(row.folder)
                        .font(.footnote)
                        .foregroundStyle(Theme.detail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.radius)
        .frame(minHeight: Metrics.touch, alignment: .leading)
        .background(row.isFocused ? Theme.pill : .clear, in: .rect(cornerRadius: Metrics.radius(inside: Metrics.rowInset)))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func recordDetails(_ record: ProgramStatus.Record, row: TerminalActivity) -> some View {
        let root = record.id.isEmpty
        let name = record.title ?? (root ? taskTitle(row) ?? record.app ?? row.program : record.id)
        return VStack(alignment: .leading, spacing: Metrics.tight) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.near) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(record.state.label)
                    .font(.footnote)
                    .foregroundStyle(Theme.detail)
            }
            if !record.id.isEmpty, record.id != name {
                Text(record.id)
                    .font(.footnote.monospaced())
                    .foregroundStyle(Theme.detail)
            }
            if let app = record.app, app != row.program, app != name {
                Text(app)
                    .font(.footnote)
                    .foregroundStyle(Theme.detail)
            }
            HStack(spacing: Metrics.near) {
                if record.state == .blocked, let kind = record.kind { Text(kind.label) }
                if let progress = record.progress { Text("\(progress)%").monospacedDigit() }
            }
            .font(.footnote)
            .foregroundStyle(Theme.detail)
            if let message = record.message, message != name {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func taskTitle(_ row: TerminalActivity) -> String? {
        guard !row.title.isEmpty, row.title != row.program, row.title != row.ref.name, row.title != row.message else { return nil }
        return row.title
    }

    private func identity(_ row: TerminalActivity, among rows: [TerminalActivity]) -> String {
        var count = 0
        var number = 0
        for item in rows where item.ref == row.ref {
            count += 1
            if item.id == row.id { number = count }
        }
        return count > 1 ? "\(row.ref.name) · Terminal \(number)" : row.ref.name
    }
}

extension TerminalActivity {
    func itemProvider() -> NSItemProvider {
        guard let pane, let window else { return ref.itemProvider() }
        return PaneTarget(ref: ref, window: window, pane: pane).itemProvider()
    }
}

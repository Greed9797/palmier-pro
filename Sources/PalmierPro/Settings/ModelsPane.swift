import SwiftUI

struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared

    @State private var query = ""

    private struct Row: Identifiable {
        let id: String
        let displayName: String
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func filtered(_ rows: [Row]) -> [Row] {
            q.isEmpty ? rows : rows.filter { $0.displayName.lowercased().contains(q) }
        }
        return [
            Section(id: "image", title: "Image",
                    rows: filtered(catalog.image.map { Row(id: $0.id, displayName: $0.displayName) })),
            Section(id: "video", title: "Video",
                    rows: filtered(catalog.video.map { Row(id: $0.id, displayName: $0.displayName) })),
            Section(id: "audio", title: "Audio",
                    rows: filtered(catalog.audio.map { Row(id: $0.id, displayName: $0.displayName) })),
        ].filter { !$0.rows.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            searchBar

            if sections.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, AppTheme.Spacing.lg)
            } else {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
        }
        .onAppear { catalog.configure() }
    }

    private var emptyMessage: String {
        if !catalog.isLoaded { return "Loading models…" }
        let noneLoaded = catalog.image.isEmpty && catalog.video.isEmpty && catalog.audio.isEmpty
        if noneLoaded {
            let base = catalog.lastError ?? "No generation models available."
            return "\(base) Sign in to Palmier to enable video/image/audio generation. Your own chat models (BYOK) are configured in the Agent tab."
        }
        return "No models match \"\(query)\"."
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(section.title.uppercased())
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .tracking(AppTheme.Tracking.tight)
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    modelRow(row)
                    if index < section.rows.count - 1 {
                        Divider().overlay(AppTheme.Border.subtleColor)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
            )
        }
    }

    private func modelRow(_ row: Row) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text(row.displayName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.lg)
            Toggle("", isOn: Binding(
                get: { prefs.isEnabled(row.id) },
                set: { prefs.setEnabled(row.id, $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }
}

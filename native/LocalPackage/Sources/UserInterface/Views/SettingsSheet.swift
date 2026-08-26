import DataSource
import Model
import SwiftUI

// Port of SettingsPanel.tsx as an in-panel overlay (the React app renders
// it as an absolutely-positioned card over the dashboard, not a window
// sheet — a window-modal sheet would also drop the tray panel's key status
// and dismiss it).
struct SettingsSheet: View {
    @EnvironmentObject private var store: DashboardStore
    @EnvironmentObject private var quotaStore: QuotaStore
    @EnvironmentObject private var updates: UpdateService
    @Environment(\.colorScheme) private var colorScheme

    /// Serializes the Cursor-usage opt-in fetch (the toggle is disabled
    /// while the initial event fetch runs).
    @State private var cursorUsageBusy = false

    // Sample labels mirror TRAY_MODE_LABELS in src/lib/settings.ts.
    private static let trayModeLabels: [(TrayMode, String)] = [
        (.todayTokens, "Today's tokens (50M)"),
        (.todayCost, "Today's cost ($5.20)"),
        (.totalTokens, "Total tokens (1.5B)"),
        (.totalCost, "Total cost ($889)"),
        (.tokensPerMin, "Tokens / min (12.4K/m)"),
        (.planPercent, "Plan usage (42%)"),
        (.hidden, "Icon only"),
    ]

    var body: some View {
        ZStack {
            // Dimmed backdrop; click closes, like .settings-overlay.
            Color.black.opacity(colorScheme == .dark ? 0.45 : 0.25)
                .onTapGesture { store.isSettingsPresented = false }

            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(.system(size: 14, weight: .bold))
                    Spacer()
                    Button {
                        store.isSettingsPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        menubarTitleSection
                        if store.settings.trayMode == .planPercent {
                            planSection
                        }
                        startupSection
                        menubarIconSection
                        liveTraceSection
                        cursorUsageSection
                        agentsSection
                        aboutSection
                        quitSection
                    }
                    .padding(16)
                }
            }
            .frame(width: 380)
            .frame(maxHeight: 520)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
        }
        .onAppear { store.syncAutostartFromSystem() }
    }

    // MARK: - Sections

    private var menubarTitleSection: some View {
        section(label: "Menubar title") {
            ForEach(Self.trayModeLabels, id: \.0) { mode, label in
                radioRow(label: label, active: store.settings.trayMode == mode) {
                    store.settings.trayMode = mode
                }
            }
        }
    }

    // MARK: - Plan source (shown for the plan_percent tray mode)

    // Mirror of PLAN_PROVIDER_OPTIONS in SettingsPanel.tsx.
    private static let planProviderOptions: [(PlanProvider, String)] = [
        (.auto, "Auto — most constrained"),
        (.claude, "Claude"),
        (.codex, "Codex"),
        (.grok, "Grok"),
        (.cursor, "Cursor"),
    ]

    /// Snapshots for plan-capable providers that actually have windows right
    /// now. Drives which providers are selectable and which windows can be
    /// pinned. An agent withheld from the limits surface is dropped: the tray
    /// title ignores it, so offering it here would only let the user pin a
    /// permanent "—".
    private var planSnapshots: [String: AgentUsageSnapshot] {
        quotaStore.planSnapshots.filter {
            store.hasLimitsSurface($0.key) && !store.isAgentHiddenFromLimits($0.key)
        }
    }

    private func windowLabels(for provider: PlanProvider) -> [String] {
        guard provider != .auto else { return [] }
        return planSnapshots[provider.rawValue]?.windows.map(\.label) ?? []
    }

    /// Pin a valid window for the chosen provider: keep the current one if
    /// it still exists, else default to the one closest to its cap.
    /// Defaulting to the first window can land on the emptiest pool.
    private func selectPlanProvider(_ provider: PlanProvider) {
        if provider == .auto {
            store.settings.planProvider = provider
            return
        }
        let labels = windowLabels(for: provider)
        let windows = planSnapshots[provider.rawValue]?.windows ?? []
        let fallback = PlanLogic.mostConstrained(windows)?.label
            ?? store.settings.planWindow
        let planWindow = labels.contains(store.settings.planWindow)
            ? store.settings.planWindow : fallback
        store.settings.planProvider = provider
        store.settings.planWindow = planWindow
    }

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            section(label: "Plan source") {
                ForEach(Self.planProviderOptions, id: \.0) { provider, label in
                    // Specific providers are only selectable once their
                    // quota has loaded; Auto is always available.
                    let available = provider == .auto
                        || planSnapshots[provider.rawValue] != nil
                    disableableRadioRow(
                        label: label,
                        meta: available ? nil : "no data yet",
                        active: store.settings.planProvider == provider,
                        disabled: !available
                    ) {
                        selectPlanProvider(provider)
                    }
                }
            }

            if store.settings.planProvider != .auto {
                group {
                    let labels = windowLabels(for: store.settings.planProvider)
                    if labels.isEmpty {
                        Text("No windows available yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(labels, id: \.self) { label in
                            radioRow(label: label,
                                     active: store.settings.planWindow == label) {
                                store.settings.planWindow = label
                            }
                        }
                    }
                }
            }

            section(label: "Display") {
                radioRow(label: "% used",
                         active: store.settings.planDisplayMode == .used) {
                    store.settings.planDisplayMode = .used
                }
                radioRow(label: "% left",
                         active: store.settings.planDisplayMode == .left) {
                    store.settings.planDisplayMode = .left
                }
            }
        }
    }

    // MARK: - Cursor usage (opt-in event fetch from cursor.com)

    private var cursorUsageSection: some View {
        section(label: "Cursor usage") {
            toggleRow(
                label: "Fetch from cursor.com",
                isOn: Binding(
                    get: { store.settings.cursorUsage },
                    set: { setCursorUsage($0) }),
                disabled: cursorUsageBusy)
            if let error = quotaStore.cursorUsageError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
    }

    /// Mirror of the App.tsx cursorUsage effect: push the opt-in to the
    /// fetcher; on enable the backend fetches once, and if that fetch fails
    /// (Cursor signed out / offline) the toggle reverts so it reflects what
    /// actually happened.
    private func setCursorUsage(_ enabled: Bool) {
        guard !cursorUsageBusy else { return }
        store.settings.cursorUsage = enabled
        cursorUsageBusy = true
        Task {
            let ok = await quotaStore.setCursorUsageEnabled(enabled)
            if !ok && enabled {
                store.settings.cursorUsage = false
            } else if ok && enabled {
                // Mirror App.tsx's setRefreshTick: the fetch just wrote the
                // events cache, so rebuild the graph now instead of making
                // the user wait for ⌘R / the 30-min tick.
                store.refresh()
            }
            cursorUsageBusy = false
        }
    }

    // MARK: - Agents (dashboard visibility)

    // The only place agent visibility is configured. Each row pairs the
    // switch ("show this agent at all") with a scope ("and where") — the two
    // dashboard surfaces answer different questions, so an agent can be
    // worth watching in one and noise in the other.
    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("AGENTS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !store.settings.hiddenAgents.isEmpty
                    || !store.settings.agentScopes.isEmpty {
                    Button {
                        store.showAllAgents()
                    } label: {
                        Text("Show all")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Show every agent on both surfaces again")
                }
            }
            .padding(.leading, 4)

            group {
                if store.knownAgents.isEmpty {
                    Text("No agents detected yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(store.knownAgents, id: \.self) { id in
                        agentRow(id)
                    }
                }
            }

            Text("Token counts are the last \(DashboardStore.recentWindowDays) "
                 + "days. Usage covers the token chart, its totals and the "
                 + "streaks; limits covers the OAuth quota tile. An agent "
                 + "switched off loses both, and its tab with them.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
        }
    }

    private static func scopeLabel(_ scope: AgentSurfaceScope) -> String {
        switch scope {
        case .usageAndLimits: return "Usage & limits"
        case .usageOnly: return "Usage only"
        case .limitsOnly: return "Limits only"
        }
    }

    /// The row's "am I still using this?" line, and why the rows are ordered
    /// the way they are. A lifetime total cannot answer that question — an
    /// agent can carry billions of tokens from months ago and be dead now —
    /// so the recent window leads, and the two silent cases are kept apart:
    /// an agent that went quiet reads differently from one that never had
    /// local history at all (a quota-only provider).
    private func usageSummary(_ id: String) -> String {
        // Abbreviated because the name column is ~138pt: spelling the window
        // out truncates the count itself away for six-digit values like
        // "203.2M". The section footnote carries the long form.
        let window = "\(DashboardStore.recentWindowDays)d"
        let recent = store.recentTokens[id] ?? 0
        if recent > 0 {
            return "\(Formatters.humanizeTokens(recent)) tokens · \(window)"
        }
        return (store.allTimeTokens[id] ?? 0) > 0
            ? "no usage · \(window)"
            : "no local usage"
    }

    private func agentRow(_ id: String) -> some View {
        let style = ClientRegistry.style(for: id)
        let isOn = !store.isAgentHidden(id)
        return HStack(spacing: 8) {
            ClientIconView(style: style, size: 16, cornerRadius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(style.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(usageSummary(id))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            scopeChip(id: id, style: style, enabled: isOn)
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { store.setAgentHidden(id, !$0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Show \(style.displayName) on the dashboard")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // The scope is still recorded while the switch is off, but it has no
        // effect until the agent is back on — say so instead of implying the
        // dimmed label is doing something.
        .opacity(isOn ? 1 : 0.55)
    }

    /// Scope picker, styled like the header's theme chip. A real NSMenu:
    /// SwiftUI's own Menu does not open reliably inside the nonactivating
    /// tray panel on macOS 13 (see AppKitMenu).
    ///
    /// An agent that reaches only one surface has no choice to make — offering
    /// the others would let the user pick one that leaves the agent nowhere at
    /// all, with the switch still reading on. Those rows drop the chip and the
    /// chevron and simply state where the agent shows up, so a locked surface
    /// never looks like a control the user chose and can change back.
    @ViewBuilder
    private func scopeChip(
        id: String, style: ClientStyle, enabled: Bool
    ) -> some View {
        let scope = store.effectiveScope(id)
        let options = store.availableScopes(for: id)
        let help = scopeHelp(id: id, style: style, enabled: enabled, options: options)
        if options.count > 1 {
            HStack(spacing: Self.scopeChevronSpacing) {
                scopeLabelText(scope, locked: false)
                Image(systemName: "chevron.up.chevron.down")
                    .frame(width: Self.scopeChevronWidth)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                AppKitMenu.present(
                    items: options.map { option in
                        .init(title: Self.scopeLabel(option),
                              checked: option == scope,
                              value: option.rawValue)
                    },
                    onSelect: { value in
                        guard let picked = AgentSurfaceScope(rawValue: value) else { return }
                        store.setAgentScope(id, picked)
                    })
            }
            .help(help)
        } else {
            scopeLabelText(scope, locked: true)
                // Matches the chip's own insets so both kinds of row keep the
                // same column.
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .help(help)
        }
    }

    // Sized for the longest label so the rows form a column instead of a
    // ragged edge down the list. A locked row has no chevron, so it takes that
    // space back to keep both kinds of row exactly as wide.
    private static let scopeLabelWidth: CGFloat = 82
    private static let scopeChevronWidth: CGFloat = 9
    private static let scopeChevronSpacing: CGFloat = 4

    private func scopeLabelText(_ scope: AgentSurfaceScope, locked: Bool) -> some View {
        let extra = Self.scopeChevronWidth + Self.scopeChevronSpacing
        return Text(Self.scopeLabel(scope))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(locked || scope == .default ? .secondary : .primary)
            .lineLimit(1)
            .frame(width: Self.scopeLabelWidth + (locked ? extra : 0),
                   alignment: .leading)
    }

    private func scopeHelp(
        id: String, style: ClientStyle, enabled: Bool, options: [AgentSurfaceScope]
    ) -> String {
        guard enabled else {
            return "Switch \(style.displayName) on to choose where it appears"
        }
        guard options.count > 1 else {
            switch (store.hasUsageSurface(id), store.hasLimitsSurface(id)) {
            case (false, true):
                return "\(style.displayName) reports plan limits but has no local token history"
            case (true, false):
                return "\(style.displayName) has no plan limits to report, so it only appears in usage"
            default:
                return "\(style.displayName) is not on the dashboard right now"
            }
        }
        return "Where \(style.displayName) appears"
    }

    private var startupSection: some View {
        section(label: "Startup") {
            toggleRow(
                label: "Launch at login",
                isOn: Binding(
                    get: { store.settings.autostart },
                    set: { store.setAutostart($0) }),
                disabled: store.autostartBusy)
            if let error = store.autostartError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
    }

    private var menubarIconSection: some View {
        section(label: "Menubar icon") {
            toggleRow(
                label: "Animate based on token usage",
                isOn: Binding(
                    get: { store.settings.animateTray },
                    set: { store.settings.animateTray = $0 }))
            if store.settings.animateTray {
                radioRow(label: "Spinning cat",
                         active: store.settings.animationStyle == .cat) {
                    store.settings.animationStyle = .cat
                }
                radioRow(label: "Party parrot",
                         active: store.settings.animationStyle == .parrot) {
                    store.settings.animationStyle = .parrot
                }
            }
        }
    }

    private var liveTraceSection: some View {
        section(label: "Live trace") {
            toggleRow(
                label: "Split by agent / model",
                isOn: Binding(
                    get: { store.settings.detailedTrace },
                    set: { store.settings.detailedTrace = $0 }))
        }
    }

    private var aboutSection: some View {
        section(label: "About") {
            HStack {
                Text("Version")
                    .font(.system(size: 12))
                Spacer()
                Text(store.appVersion)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().padding(.horizontal, 10)
            // SettingsPanel.tsx parity: the manual update check lives here
            // as well as in the tray menu / ⌘U. Automatic checks run on
            // launch + hourly regardless (Sparkle).
            Button {
                updates.checkForUpdates()
            } label: {
                HStack {
                    Text("Check for updates…")
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!updates.canCheckForUpdates)
            .opacity(updates.canCheckForUpdates ? 1 : 0.5)
        }
    }

    private var quitSection: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Text("Quit Tokcat")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.1))
        )
    }

    // MARK: - Building blocks

    private func section(
        label: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    /// A bare rounded group without the section label (the plan-window list
    /// in SettingsPanel.tsx renders as a second .settings-group).
    private func group(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// radioRow variant with a disabled state and an inline meta note
    /// ("· no data yet"), mirroring the plan-source rows.
    private func disableableRadioRow(
        label: String, meta: String?, active: Bool, disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if !disabled { action() }
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                if let meta {
                    Text("· \(meta)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func radioRow(
        label: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(
        label: String, isOn: Binding<Bool>, disabled: Bool = false
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(disabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

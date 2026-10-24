import SwiftUI

/// 「外观」设置页。
///
/// 这里只负责摆控件 + 改 `UISettings`，不写任何换算逻辑：
/// 每个可调项的取值范围都定义在 `UISettings.swift` 的枚举里。
/// 改完的值经 `UISettingsStore` → `UIState` 快照 → 各视图读取，立刻生效并落盘。
struct AppearanceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var ui: UISettings { model.ui.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                preview
                themeSection
                accentSection
                fontSection
                layoutSection
                readerSection
                footer
            }
            .padding(22)
        }
        .hoverScrollIndicators()
    }

    // MARK: - 预览

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("预览", "下面这块用的是真实字号与行距，改动立刻反映在这里和主界面")

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("林知远")
                                .font(.app(12.5, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: "flag.fill")
                                .font(.app(9))
                                .foregroundStyle(.orange)
                            Spacer(minLength: 4)
                            Text("14:32")
                                .font(.app(10.5))
                                .foregroundStyle(.tertiary)
                        }
                        Text("本周项目进度与下周评审安排")
                            .font(.app(12.5, weight: .medium))
                            .lineLimit(1)
                        Text("附件里是整理好的排期表，麻烦确认一下周三评审的时间是否合适，另外有两个接口需要你这边确认。")
                            .font(.app(11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(UIState.previewLines)
                            .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, UIState.rowPadding)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Divider().opacity(0.35).padding(.leading, 24).padding(.vertical, 3)

                HStack(spacing: 8) {
                    Button {} label: {
                        Label("写邮件", systemImage: "square.and.pencil")
                            .font(.app(12, weight: .medium))
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)

                    Button {} label: {
                        Text("回复")
                            .font(.app(12))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    UnreadBadge(count: 3)
                    Spacer()
                    Text("正文 \(Int((UIState.readerFontSize * UIState.scale).rounded())) pt")
                        .font(.app(10.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .padding(6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
            // 预览是示意，不是真控件：别让用户点按钮以为能发信
            .allowsHitTesting(false)
        }
    }

    // MARK: - 主题

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("主题", "跟随系统时会随 macOS 的浅色 / 深色自动切换")

            card {
                row("外观", hint: nil) {
                    SegmentedChoice(
                        options: Appearance.allCases,
                        label: { $0.label },
                        value: $model.appearance,
                        width: 260
                    )
                }
            }
        }
    }

    // MARK: - 强调色

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("强调色", "用在按钮、选中行、未读点。砖红同时是删除类操作的警示色")

            card {
                row("当前：\(ui.accent.label)", hint: "取自同一套调色板，换色不会破坏整体配色") {
                    HStack(spacing: 9) {
                        ForEach(UIAccent.allCases) { option in
                            accentSwatch(option)
                        }
                    }
                }
            }
        }
    }

    private func accentSwatch(_ option: UIAccent) -> some View {
        let selected = ui.accent == option
        return Button {
            set(\.accent, option)
        } label: {
            Circle()
                .fill(option.color)
                .frame(width: 20, height: 20)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.app(9.5, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(4)
                .overlay {
                    Circle()
                        .stroke(selected ? option.color.opacity(0.85) : Color.primary.opacity(0.10),
                                lineWidth: selected ? 1.6 : 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(option.label)
    }

    // MARK: - 字体

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("字体", "中文在圆体 / 衬线下会退回系统黑体，这是 macOS 的字体回退行为")

            card {
                row("字体族", hint: nil) {
                    HStack(spacing: 6) {
                        ForEach(UIFontFamily.allCases) { family in
                            fontChip(family)
                        }
                    }
                }

                divider

                row("整体字号", hint: "影响界面上所有文字，含邮件正文") {
                    SegmentedChoice(
                        options: UIScale.allCases,
                        label: { $0.label },
                        value: binding(\.scale),
                        width: 260
                    )
                }
            }
        }
    }

    private func fontChip(_ family: UIFontFamily) -> some View {
        let selected = ui.fontFamily == family
        return Button {
            set(\.fontFamily, family)
        } label: {
            Text(family.label)
                .font(.app(12, weight: selected ? .medium : .regular, design: family.design))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 11)
                .frame(height: 25)
                .background(
                    selected ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.05),
                    in: Capsule()
                )
                .overlay {
                    Capsule().stroke(selected ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(family.label)字体")
    }

    // MARK: - 布局

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("布局", nil)

            card {
                row("列表密度", hint: "紧凑时邮件摘要只显示一行") {
                    SegmentedChoice(
                        options: UIDensity.allCases,
                        label: { $0.label },
                        value: binding(\.density),
                        width: 200
                    )
                }

                divider

                row("面板宽度", hint: "侧边栏与列表一起变，保持三栏比例") {
                    SegmentedChoice(
                        options: UIPanelWidth.allCases,
                        label: { $0.label },
                        value: binding(\.panelWidth),
                        width: 200
                    )
                }

                divider

                row("背景色斑", hint: "液态玻璃要靠背后的色块才看得出折射，关掉会更平") {
                    SegmentedChoice(
                        options: UIBackdrop.allCases,
                        label: { $0.label },
                        value: binding(\.backdrop),
                        width: 200
                    )
                }
            }
        }
    }

    // MARK: - 阅读

    private var readerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("阅读正文", "只影响邮件正文，不影响界面控件")

            card {
                row("正文字号", hint: nil) {
                    SegmentedChoice(
                        options: ReaderFontSize.allCases,
                        label: { $0.label },
                        value: binding(\.readerSize),
                        width: 260
                    )
                }

                divider

                row("行距", hint: nil) {
                    SegmentedChoice(
                        options: ReaderLineSpacing.allCases,
                        label: { $0.label },
                        value: binding(\.readerSpacing),
                        width: 260
                    )
                }
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text("这些设置只存在本机，不会随邮件或 AI 请求外发。")
                .font(.app(10.5))
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                model.ui.reset()
            } label: {
                Text("恢复默认")
                    .font(.app(11.5))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(ui.isDefault)
        }
        .padding(.top, 2)
    }

    // MARK: - 组件

    private func header(_ title: String, _ hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.app(12, weight: .semibold))
            if let hint {
                Text(hint)
                    .font(.app(10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var divider: some View {
        Divider().opacity(0.35)
    }

    private func row<Content: View>(
        _ title: String,
        hint: String?,
        @ViewBuilder control: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(12))
                if let hint {
                    Text(hint)
                        .font(.app(10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 8)
    }

    // MARK: - 绑定

    private func binding<T>(_ keyPath: WritableKeyPath<UISettings, T>) -> Binding<T> {
        Binding(
            get: { model.ui.settings[keyPath: keyPath] },
            set: { model.ui.settings[keyPath: keyPath] = $0 }
        )
    }

    private func set<T>(_ keyPath: WritableKeyPath<UISettings, T>, _ value: T) {
        model.ui.settings[keyPath: keyPath] = value
    }
}

/// 分段选择器。所有可调项都用它，保证同一页里的控件长得一样
private struct SegmentedChoice<T: Hashable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var value: T
    var width: CGFloat = 220

    var body: some View {
        Picker("", selection: $value) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: width)
    }
}

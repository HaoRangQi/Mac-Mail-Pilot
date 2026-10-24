import SwiftUI

/// 细滚动条：浮在内容右侧，**不参与布局**。
///
/// 为什么不用系统滚动条：
/// 1. macOS 的挤压式滚动条在出现/消失时会改内容宽度，文字跟着重排、断行位置乱跳；
/// 2. 宽度由系统定（15pt 左右），改不细；
/// 3. SwiftUI 26 的滚动容器是自绘的，`NSScroller` 那一套调不到。
///
/// 所以这里用 `.scrollIndicators(.never)` 关掉系统条，自己按滚动几何画一条 3pt 胶囊：
/// 默认透明，鼠标进入或滚动时淡入，停手 1 秒后淡出。位置来自 `onScrollGeometryChange`，
/// 拖动条通过 `ScrollPosition.scrollTo(y:)` 反推。
///
/// 状态放在 `ScrollbarState` 而不是 `@State`：这个 CLT 环境缺 SwiftUIMacros 插件，
/// `@State` 宏编不过（项目里其它地方同理）。
struct ThinScrollbar: ViewModifier {
    @StateObject private var state = ScrollbarState()

    private let thickness: CGFloat = 3
    private let hitWidth: CGFloat = 14
    private let minKnob: CGFloat = 28
    private let inset: CGFloat = 3

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .scrollPosition(state.positionBinding)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: geometry.contentOffset.y,
                    content: geometry.contentSize.height,
                    container: geometry.containerSize.height
                )
            } action: { _, new in
                state.apply(new)
            }
            .onHover { inside in
                state.hover(inside)
            }
            .overlay(alignment: .topTrailing) {
                if state.metrics.scrollable {
                    knobLayer
                        .opacity(state.revealed ? 1 : 0)
                        .animation(.easeOut(duration: 0.16), value: state.revealed)
                }
            }
    }

    /// 轨道层。GeometryReader 本身不画东西，空的地方不挡点击；
    /// 只有滑块那 14×N 的矩形接收拖动，所以不影响列表行的点击。
    private var knobLayer: some View {
        GeometryReader { proxy in
            let track = max(proxy.size.height - inset * 2, 1)
            let knob = min(max(track * state.metrics.knobFraction, minKnob), track)
            let travel = max(track - knob, 1)
            let y = inset + travel * state.metrics.progress

            ZStack(alignment: .top) {
                Color.clear
                    .frame(width: hitWidth, height: knob + 10)

                Capsule()
                    .fill(Color.primary.opacity(state.isDragging || state.hovering ? 0.34 : 0.22))
                    .frame(width: thickness, height: knob)
                    .padding(.top, 5)
            }
            .contentShape(Rectangle())
            .offset(y: y - 5)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 1)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let target = state.dragTarget(translation: value.translation.height, travel: travel)
                        state.scrollPosition.scrollTo(y: target)
                    }
                    .onEnded { _ in
                        state.endDrag()
                    }
            )
        }
    }
}

/// 滚动条状态。`@State` 宏不可用，用 ObservableObject 承载
final class ScrollbarState: ObservableObject {
    @Published var metrics = ScrollMetrics()
    @Published var hovering = false
    @Published var revealed = false
    @Published private(set) var isDragging = false

    /// 不用 @Published：`scrollPosition` 会随每一帧滚动被 SwiftUI 写回，
    /// 走 @Published 会每帧触发一次视图重建，白白浪费
    var scrollPosition = ScrollPosition()

    /// 只给 `.scrollPosition` 用的通道，写入不触发 objectWillChange
    var positionBinding: Binding<ScrollPosition> {
        Binding(get: { self.scrollPosition }, set: { self.scrollPosition = $0 })
    }

    private var dragOrigin: CGFloat?
    private var hideTask: Task<Void, Never>?

    // MARK: - 滚动几何

    func apply(_ new: ScrollMetrics) {
        metrics = new
        guard new.scrollable else {
            revealed = false
            return
        }
        reveal(linger: 0.9)
    }

    // MARK: - 悬停

    func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            reveal(linger: nil)
        } else if !isDragging {
            scheduleHide(after: 0.3)
        }
    }

    // MARK: - 拖动

    func dragTarget(translation: CGFloat, travel: CGFloat) -> CGFloat {
        if dragOrigin == nil {
            dragOrigin = metrics.offset
            isDragging = true
        }
        revealed = true
        let base = dragOrigin ?? metrics.offset
        let target = base + (translation / max(travel, 1)) * metrics.maxOffset
        return min(max(target, 0), metrics.maxOffset)
    }

    func endDrag() {
        dragOrigin = nil
        isDragging = false
        scheduleHide(after: 0.3)
    }

    // MARK: - 显隐

    /// 显示；给了 linger 就过一会儿自动收起（鼠标停在列表里时不收）
    private func reveal(linger: Double?) {
        hideTask?.cancel()
        revealed = true
        guard let linger else { return }
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(linger * 1000)))
            guard let self, !Task.isCancelled, !self.hovering, !self.isDragging else { return }
            self.revealed = false
        }
    }

    private func scheduleHide(after delay: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self, !Task.isCancelled, !self.hovering, !self.isDragging else { return }
            self.revealed = false
        }
    }
}

/// 一次滚动几何快照。Equatable 让 `onScrollGeometryChange` 只在真正变化时回调
struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var container: CGFloat = 0

    var maxOffset: CGFloat { max(content - container, 0) }
    var scrollable: Bool { content > container + 1 }

    var progress: CGFloat {
        guard maxOffset > 0 else { return 0 }
        return min(max(offset / maxOffset, 0), 1)
    }

    /// 滑块占轨道的比例。太短不好点，给个下限
    var knobFraction: CGFloat {
        guard content > 0 else { return 1 }
        return min(max(container / content, 0.05), 1)
    }
}

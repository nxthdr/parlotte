import SwiftUI

/// Pure SwiftUI message list. Three well-known patterns, nothing exotic:
///
/// 1. **Scroll to bottom** via a stable sentinel `.id` at the end of the content.
///    Works on first appear, after sending, and after receiving — the
///    `ScrollViewReader` proxy always has an unambiguous target, independent
///    of message ids.
/// 2. **Preserve position on prepend** by scrolling to the *previously first*
///    message id with `anchor: .top` as soon as older messages are added.
///    SwiftUI keeps that anchor pinned on screen, so the user's reading
///    context survives pagination.
/// 3. **Load-older detection** with a `GeometryReader`-backed preference at
///    the top of the content. Whenever the top sentinel becomes visible we
///    fire `onScrollToTop` once (re-arming only after it leaves the viewport),
///    so the callback is not spammed while the user lingers at the top.
///
/// The `lastItemId` / `firstItemId` inputs drive the two id-based scrolls
/// declaratively — no NSScrollView, no frame observers, no manual height
/// math, and so no NSHostingView "content taller than reported height"
/// clipping bugs.
struct MessageScrollView<Content: View>: View {
    let lastItemId: String?
    let firstItemId: String?
    /// Height of any content shown *below* this scroll view (e.g. the typing
    /// indicator). When it changes the viewport resizes; if the user was at the
    /// bottom we re-scroll so the last message stays fully visible instead of
    /// being clipped under the newly-appeared row.
    let bottomInset: CGFloat
    let content: Content
    let onScrollToTop: (() -> Void)?

    init(
        lastItemId: String?,
        firstItemId: String?,
        bottomInset: CGFloat = 0,
        onScrollToTop: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.lastItemId = lastItemId
        self.firstItemId = firstItemId
        self.bottomInset = bottomInset
        self.onScrollToTop = onScrollToTop
        self.content = content()
    }

    // Stable sentinel ids so scroll-to-bottom / top-visibility always have an
    // unambiguous target even on empty rooms or during content churn.
    private static var bottomId: String { "parlotte.messageScroll.bottom" }
    private static var topId: String { "parlotte.messageScroll.top" }
    private static var coordSpace: String { "parlotte.messageScroll" }

    @State private var isNearBottom = true
    @State private var topVisible = false
    @State private var didInitialScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Top sentinel — its visibility doubles as the load-older trigger.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.topId)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: TopVisiblePreferenceKey.self,
                                    value: geo.frame(in: .named(Self.coordSpace)).minY > -1
                                )
                            }
                        )

                    content

                    // Bottom sentinel — its visibility tells us whether auto-
                    // scroll on new messages should fire. We use a 40pt slack
                    // so a brief overscroll or the typing indicator doesn't
                    // unstick us from "at bottom".
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        .background(
                            GeometryReader { geo in
                                let viewportBottom = geo.frame(in: .global).maxY
                                let anchorTop = geo.frame(in: .global).minY
                                Color.clear.preference(
                                    key: BottomVisiblePreferenceKey.self,
                                    value: anchorTop <= viewportBottom + 40
                                )
                            }
                        )
                }
            }
            // Clip scroll content to the view's bounds. Without this the last
            // message can draw past the bottom edge onto the sibling typing
            // indicator below it ("bob is typing…" overlapping the message).
            .clipped()
            .coordinateSpace(name: Self.coordSpace)
            .onAppear {
                // Defer the initial jump until after SwiftUI lays out — calling
                // `scrollTo` before the scroll view has measured is a no-op.
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    didInitialScroll = true
                }
            }
            .onChange(of: lastItemId) { _, _ in
                // Only auto-scroll when the user was already near the bottom —
                // never yank them out of scrollback to see something that just
                // arrived.
                guard isNearBottom else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: bottomInset) { _, _ in
                // A row appeared/disappeared below us (typing indicator),
                // shrinking/growing the viewport. Keep the bottom pinned so the
                // last message doesn't get clipped under it.
                guard isNearBottom else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    }
                }
            }
            .onChange(of: firstItemId) { oldValue, newValue in
                // Older messages were prepended (firstItemId moved to something
                // earlier). Pin the user's view to the message that *used* to
                // be first, so their reading context doesn't jump up to the
                // newly-loaded content. Only do this after the initial scroll,
                // since the first set-from-nil isn't a prepend.
                guard let oldValue, oldValue != newValue, didInitialScroll else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(oldValue, anchor: .top)
                }
            }
            .onPreferenceChange(TopVisiblePreferenceKey.self) { visible in
                // Edge-triggered: fire once per top visit, re-arm after leaving.
                if visible && !topVisible && didInitialScroll {
                    onScrollToTop?()
                }
                topVisible = visible
            }
            .onPreferenceChange(BottomVisiblePreferenceKey.self) { atBottom in
                isNearBottom = atBottom
            }
        }
    }
}

private struct TopVisiblePreferenceKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

private struct BottomVisiblePreferenceKey: PreferenceKey {
    static var defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

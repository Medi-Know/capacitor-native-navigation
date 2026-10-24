// swiftlint:disable file_length

import Foundation
import Capacitor
import ObjectiveC
import UIKit
import WebKit

private struct NativeNavigationTransitionContext {
    let webView: UIView
    let snapshot: UIView?
    let id: String
    let direction: String
    let duration: TimeInterval
    let durationMs: Int
    let resolve: ([String: Any]) -> Void
}

private struct NativeNavigationZoomTransitionContext {
    let transition: NativeNavigationTransitionContext
    let sourceFrame: CGRect?
    let targetFrame: CGRect?
    let cornerRadius: CGFloat
}

// swiftlint:disable type_body_length
@objc(NativeNavigationPlugin)
public class NativeNavigationPlugin: CAPPlugin, CAPBridgedPlugin, UITabBarControllerDelegate, UITabBarDelegate {
    public let identifier = "NativeNavigationPlugin"
    public let jsName = "NativeNavigation"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "configure", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setNavbar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTabbar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setToolbar", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "beginTransition", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finishTransition", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "finishTabTransition", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPluginVersion", returnType: CAPPluginReturnPromise)
    ]

    private let implementation = NativeNavigation()
    private var navContainer: UIView?
    private var navBlurView: UIVisualEffectView?
    private var navBar: UINavigationBar?
    private var tabContainer: UIView?
    private var tabEffectView: UIVisualEffectView?
    private var trailingTabEffectView: UIVisualEffectView?
    private var tabBar: UITabBar?
    private var floatingTabBar: NativeNavigationFloatingTabBar?

    // Native bottom action bar for the article screen (article-toolbar feature).
    private var toolbar: UIToolbar?
    private var toolbarVisible = false
    private var toolbarHeight: CGFloat = 50
    private var toolbarItemTitle: [String: String] = [:]
    // Hide-on-scroll: the toolbar slides out of the way while the reader scrolls
    // down and returns on scroll up. Driven by observing the web view's scroll
    // view; the inset stays put so the page never reflows mid-scroll.
    private var toolbarScrollObservation: NSKeyValueObservation?
    private var toolbarScrolledAway = false
    private var toolbarLastScrollY: CGFloat = 0
    private let toolbarScrollThreshold: CGFloat = 8
    // A gradient-masked blur behind the toolbar so its buttons do not clash with
    // the content scrolling under them. The scroll-edge effect cannot serve the
    // bottom (there is no system bottom bar for it to measure against), so this
    // stands in for it. It tracks the toolbar's visibility and hide-on-scroll.
    // No fade zone above the bar: like the bars of Apple's own apps it ends on a
    // hard edge, so the text stays readable right down to the toolbar.
    private var bottomScrim: UIVisualEffectView?
    private let bottomScrimFade: CGFloat = 0
    // The matching blur behind the transparent top navbar, so the title and back
    // button stay readable over the content. Replaces UIScrollView's top edge
    // effect, which on iOS 27 stopped covering the navbar below the notch.
    private var topScrim: UIVisualEffectView?
    private let topScrimFade: CGFloat = 48

    private var tabbarStyle = NativeNavigationTabbarStyleConfig()
    private var tabBarController: NativeNavigationTabController?
    private var tabViewControllers: [UIViewController] = []
    private weak var systemTabRootContainer: UIView?
    private weak var originalWebViewSuperview: UIView?
    private var originalWebViewIndex: Int?
    private var originalWebViewAutoresizingMask: UIView.AutoresizingMask?
    private var liftedWebViewOverlays: [NativeNavigationWeakView] = []
    private var isWebViewHostedInSystemTabController = false
    private var navbarHeight: CGFloat = 44
    private var tabbarHeight: CGFloat = NativeNavigationTabbarStyleConfig().totalHeight
    private var navbarVisible = false

    /// Whether the bar currently on screen is the hosted one (a real
    /// `UINavigationController` bar) rather than capgo's overlay.
    ///
    /// It decides who reserves the strip under the notch. The hosted bar is
    /// part of the web view's own safe area, so `env(safe-area-inset-top)`
    /// already covers it and `currentInsets()` must report 0 — reporting the
    /// height as well would reserve it twice.
    private var navbarUsesHostedController = false
    /// The last `setNavbar` that put a bar on a hosted controller, kept so a
    /// tab switch can give the new tab the same bar before its view appears.
    private var lastNavbarCall: CAPPluginCall?
    private var lastNavbarLarge = false
    private var tabbarVisible = false
    private var contentInsetMode = "css"
    private var isEnabled = true
    private var defaultTransitionDuration: TimeInterval = 0.5
    /// Whether a bar has been populated before, so the first one does not animate.
    private var hasSetNavbarItems = false

    /// Whether the tab bar has been shown before, for the same reason.
    private var hasShownTabBar = false
    private var navbarItemPlacement: [String: String] = [:]
    private var navbarItemTitle: [String: String] = [:]
    private var tabIds: [String] = []

    /// Ids behind the `UITab` objects currently assigned to the controller.
    ///
    /// Reassigning `tabs` tears the bar down and rebuilds it, which cancels
    /// anything the system is in the middle of — including the search tab's
    /// morph into a search field. The web layer re-pushes `setTabbar` right
    /// after a tap (it navigates, then syncs the selection), so without this
    /// the morph was destroyed a few milliseconds after it began.
    private var appliedSystemTabIds: [String] = []
    private var tabTitles: [String] = []
    private var tabDisplayTitles: [String?] = []
    private var tabBaseImages: [UIImage?] = []
    private var tabSelectedImages: [UIImage?] = []
    private var suppressTabSelectEvent = false

    /// Index of the tab to return to when the search cancel (X) button is
    /// tapped. Captured when the search tab is selected and restored on cancel
    /// (KAN-751 — with automaticallyActivatesSearch off, UIKit no longer
    /// returns to the previous tab for us).
    private var searchPreviousTabIndex: Int?
    private var transitionSnapshot: UIView?
    private var activeTransitionId: String?
    private var activeTransitionDirection = "forward"
    private var activeZoomSourceFrame: CGRect?
    private var activeZoomCornerRadius: CGFloat = 0
    private weak var activeTransitionContainer: UIView?
    private var activeTransitionContainerBackgroundColor: UIColor?
    private var activeTransitionContainerWasOpaque = false
    private var activeTransitionContainerBackgroundCaptured = false

    private var usesSystemLiquidGlass: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    override public func load() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleLayoutChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleKeyboardDidHide),
            name: UIResponder.keyboardDidHideNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleReduceTransparencyChange),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func configure(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.isEnabled = call.getBool("enabled", true)
            self.contentInsetMode = call.getString("contentInsetMode") ?? self.contentInsetMode
            if let duration = call.getDouble("animationDuration") {
                self.defaultTransitionDuration = duration / 1_000
            }

            if !self.isEnabled {
                self.navContainer?.isHidden = true
                self.tabContainer?.isHidden = true
                self.restoreWebViewFromSystemTabController()
                self.tabBarController?.view.isHidden = true
                self.tabBar?.isHidden = true
            }

            self.updateInsetsAndNotify()
            call.resolve(self.insetsResult())
        }
    }

    @objc func setNavbar(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.isEnabled else {
                self.navbarVisible = false
                self.updateInsetsAndNotify()
                call.resolve(self.insetsResult())
                return
            }

            let hidden = call.getBool("hidden", false)
            self.navbarVisible = !hidden
            let animated = call.getBool("animated", false)
            let large = call.getBool("large", false)
            self.navbarHeight = large ? 96 : 44

            guard !hidden else {
                self.lastNavbarCall = nil
                self.navContainer?.isHidden = true
                self.hideHostedNavigationBar(animated: animated)
                self.navbarUsesHostedController = false
                self.updateInsetsAndNotify()
                call.resolve(self.insetsResult())
                return
            }

            // Preferred path: write onto the navigation item of the controller
            // that actually displays the web view, inside its own
            // UINavigationController. UIKit draws glass, shadow and the scroll
            // edge effect only for a bar it manages above a scroll view it
            // knows about — capgo's overlay bar is a *sibling* of the web view,
            // so UIKit sees no relationship between the two and none of it
            // applies. Same reason the search tab's morph only ever worked
            // once its bar was left in place.
            if let content = self.hostedContentController(),
               let navigation = content.navigationController {
                self.lastNavbarCall = call
                self.lastNavbarLarge = large
                self.applyNavbarContents(to: content.navigationItem, options: call, large: large)
                if #available(iOS 11.0, *) {
                    navigation.navigationBar.prefersLargeTitles = large
                }
                navigation.setNavigationBarHidden(false, animated: animated)
                self.navContainer?.isHidden = true
                self.navbarUsesHostedController = true
                self.updateInsetsAndNotify()
                call.resolve(self.insetsResult())
                return
            }

            // Fallback for pre-iOS-26 shells and for the moment before the tab
            // controller exists: capgo's own overlay bar.
            let navBar = self.ensureNavBar()
            let navItem = UINavigationItem(title: "")
            self.applyNavbarContents(to: navItem, options: call, large: large)
            if #available(iOS 11.0, *) {
                navBar.prefersLargeTitles = large
            }
            navBar.setItems([navItem], animated: animated)
            self.applyNavBarAppearance(navBar: navBar, options: call)
            self.navContainer?.isHidden = false
            self.navbarUsesHostedController = false
            self.layoutChrome()
            self.updateInsetsAndNotify()
            call.resolve(self.insetsResult())
        }
    }

    /// Gives the tab being switched to the bar the current tab shows, before
    /// its view appears.
    ///
    /// Every tab has a navigation controller of its own, made with the bar
    /// hidden, and the web app pushes the bar for the new route only after
    /// NavigationEnd. Until then the web view's safe area would be a bar
    /// shorter than a moment ago: the page lost its top padding and got it
    /// back a frame later. Re-applying the last bar keeps the safe area — and
    /// the picture — identical across the switch; the web app's push then
    /// updates the same bar in place.
    ///
    /// Not for the search tab: its bar surfaces the search field and is
    /// handled on its own (see hideHostedNavigationBar).
    private func carryHostedNavbar(to content: NativeNavigationTabContentController) {
        guard navbarVisible,
              navbarUsesHostedController,
              let call = lastNavbarCall,
              let navigation = content.navigationController,
              content.navigationItem.searchController == nil else {
            return
        }

        applyNavbarContents(to: content.navigationItem, options: call, large: lastNavbarLarge)
        navigation.navigationBar.prefersLargeTitles = lastNavbarLarge
        navigation.setNavigationBarHidden(false, animated: false)
    }

    /// Takes the hosted bar off screen again.
    ///
    /// The search tab is the exception: its bar is what surfaces
    /// `navigationItem.searchController`, so hiding it takes the search field
    /// down with it — the same mistake that once cost the tab bar's morph.
    /// There the contents are cleared and the bar stays.
    ///
    /// - Parameter animated: Whether to animate the bar out.
    private func hideHostedNavigationBar(animated: Bool) {
        guard let content = hostedContentController(),
              let navigation = content.navigationController else {
            return
        }

        guard content.navigationItem.searchController == nil else {
            content.navigationItem.title = nil
            content.navigationItem.leftBarButtonItems = nil
            content.navigationItem.rightBarButtonItems = nil
            return
        }

        navigation.setNavigationBarHidden(true, animated: animated)
    }

    /// Fills a navigation item from a `setNavbar` call.
    ///
    /// Shared by both paths so the hosted bar and the overlay fallback show the
    /// same thing. Every field is assigned unconditionally: the hosted item is
    /// reused across calls, so anything left unset has to be cleared rather
    /// than inherited from the previous page.
    ///
    /// - Parameters:
    ///   - navItem: The item to fill.
    ///   - call: The originating plugin call.
    ///   - large: Whether the caller asked for a large title.
    private func applyNavbarContents(to navItem: UINavigationItem, options call: CAPPluginCall, large: Bool) {
        navItem.title = call.getString("title") ?? ""

        // `prompt` renders a small line ABOVE the title — not a subtitle.
        // iOS 26 added a real one that sits below it. Reached by selector
        // so this still compiles against an SDK that lacks the property.
        let subtitle = call.getString("subtitle")
        if #available(iOS 26.0, *), navItem.responds(to: NSSelectorFromString("setSubtitle:")) {
            navItem.setValue(subtitle, forKey: "subtitle")
        } else {
            navItem.prompt = subtitle
        }
        if #available(iOS 11.0, *) {
            navItem.largeTitleDisplayMode = large ? .always : .never
        }

        navbarItemPlacement.removeAll()
        navbarItemTitle.removeAll()

        // Not on the very first bar of a launch: there is nothing to cross-fade
        // from, and animating would show the buttons arriving over a cold start
        // that is already busy enough.
        let animated = hasSetNavbarItems
        hasSetNavbarItems = true

        if let backButton = call.getObject("backButton"), backButton["visible"] as? Bool == true {
            let title = backButton["title"] as? String
            let item = UIBarButtonItem(title: title ?? "Back", style: .plain, target: self, action: #selector(self.handleNavbarBack))
            configureGlassBarButtonItem(item, id: "back")
            navItem.setLeftBarButtonItems([item], animated: animated)
        } else {
            navItem.setLeftBarButtonItems(
                makeBarButtonItems(call.getArray("leftItems") as? [[String: Any]] ?? [], placement: "left"),
                animated: animated
            )
        }

        // The animated setters, not a plain assignment: UIKit cross-fades the
        // glass buttons in and out, which is what the material is built for.
        // Assigning the arrays swaps them between two frames instead, and a
        // button that simply ceases to exist reads as a glitch rather than as
        // something making way — most visibly when a dialog opens and the
        // page's buttons give up the bar to a close button.
        navItem.setRightBarButtonItems(
            makeBarButtonItems(call.getArray("rightItems") as? [[String: Any]] ?? [], placement: "right"),
            animated: animated
        )
    }

    /// Takes down the snapshot a tab switch left covering the web view.
    ///
    /// Called by the web app once it has navigated and drawn. A timeout guards
    /// the case where it never does — a snapshot that outlived its page would
    /// be a frozen screen, which is worse than the flicker it prevents.
    @objc func finishTabTransition(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            // The selected tab is uncovered. The tab being left keeps its
            // still until it has faded out — viewDidDisappear drops it — so
            // the dissolve ends on the new page rather than on a blank.
            // Anything already off screen is only cleaned up.
            let selected = self.hostedContentController()
            NativeNavigationTabContentController.all.forEach { controller in
                if controller === selected || controller.viewIfLoaded?.window == nil {
                    controller.revealHostedWebView()
                }
            }
            call.resolve()
        }
    }

    @objc func setTabbar(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.isEnabled else {
                self.tabbarVisible = false
                self.updateInsetsAndNotify()
                call.resolve(self.insetsResult())
                return
            }

            if let background = call.getString("contentBackground").flatMap({ UIColor(hex: $0) }) {
                NativeNavigationTabContentController.contentBackground = background
                // Controllers built by an earlier call keep the colour they were
                // created with, so they are repainted here too.
                NativeNavigationTabContentController.all
                    .forEach { $0.viewIfLoaded?.backgroundColor = background }
            }

            let hidden = call.getBool("hidden", false)
            self.tabbarVisible = !hidden

            guard !hidden else {
                self.hideTabBarChrome()
                self.updateInsetsAndNotify()
                call.resolve(self.insetsResult())
                return
            }

            self.tabbarStyle = self.makeTabbarStyle(from: call)
            self.tabbarHeight = self.tabbarStyle.totalHeight

            let tabs = call.getArray("tabs") as? [[String: Any]] ?? []
            let selectedId = call.getString("selectedId")
            let labels = call.getBool("labels", true)
            let labelVisibilityMode = call.getString("labelVisibilityMode") ?? (labels ? "labeled" : "unlabeled")
            let icons = call.getBool("icons", true)

            if self.usesSystemLiquidGlass && self.tabbarStyle.shape != .curve {
                let tabBar = self.ensureTabBar()
                self.floatingTabBar?.isHidden = true
                self.tabContainer?.isHidden = true

                // iOS 18 replaced UITabBarItem + setViewControllers with UITab,
                // and only that family can carry a UISearchTab — the thing that
                // makes the bar morph into a search field instead of leaving it
                // to the app to open a page of its own.
                var builtEmpty: Bool
                if #available(iOS 18.0, *) {
                    let (built, selectedIndex) = self.makeSystemTabs(
                        tabs,
                        selectedId: selectedId,
                        labelVisibilityMode: labelVisibilityMode,
                        icons: icons
                    )
                    self.applySystemTabs(built, selectedIndex: selectedIndex)
                    builtEmpty = built.isEmpty
                } else {
                    let (items, selectedIndex) = self.makeTabBarItems(
                        tabs,
                        selectedId: selectedId,
                        labelVisibilityMode: labelVisibilityMode,
                        icons: icons
                    )
                    self.applySystemTabBarItems(items, selectedIndex: selectedIndex, animated: call.getBool("animated", false))
                    builtEmpty = items.isEmpty
                }
                self.applyTabBarAppearance(tabBar: tabBar, options: call)
                if builtEmpty {
                    self.tabbarVisible = false
                    self.hideSystemTabBarChromeCompletely()
                } else {
                    self.showTabBarChrome(tabBar)
                }
            } else {
                self.restoreWebViewFromSystemTabController()
                self.setSystemTabBarHidden(true)
                self.tabBarController?.view.isHidden = true
                let tabBar = self.ensureFloatingTabBar()
                let (items, selectedIndex) = self.makeFloatingTabBarItems(
                    tabs,
                    selectedId: selectedId,
                    icons: icons
                )
                if items.isEmpty {
                    self.tabbarVisible = false
                    tabBar.configure(
                        items: [],
                        selectedIndex: 0,
                        labelVisibilityMode: labelVisibilityMode,
                        icons: icons,
                        style: self.tabbarStyle
                    )
                    self.tabContainer?.isHidden = true
                    tabBar.isHidden = true
                } else {
                    self.applyFloatingTabBarAppearance(tabBar: tabBar, options: call)
                    let resolvedSelectedIndex = selectedIndex ?? (items.indices.contains(tabBar.selectedIndex) ? tabBar.selectedIndex : 0)
                    tabBar.configure(
                        items: items,
                        selectedIndex: resolvedSelectedIndex,
                        labelVisibilityMode: labelVisibilityMode,
                        icons: icons,
                        style: self.tabbarStyle
                    )
                    tabBar.onSelect = { [weak self] _, item in
                        self?.notifyListeners("tabSelect", data: [
                            "id": item.id,
                            "index": item.sourceIndex,
                            "title": item.title
                        ])
                    }
                    self.showFloatingTabBarChrome(tabBar)
                }
            }
            self.layoutChrome()
            self.updateInsetsAndNotify()
            call.resolve(self.insetsResult())
        }
    }

    @objc func beginTransition(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let webView = self.webView,
                  let transitionContainer = webView.superview else {
                call.reject("WebView unavailable")
                return
            }

            let transitionId = call.getString("id") ?? "transition-\(Int(Date().timeIntervalSince1970 * 1_000))"
            let direction = call.getString("direction") ?? "forward"
            let durationMs = Int((call.getDouble("duration") ?? self.defaultTransitionDuration * 1_000).rounded())
            let zoomSourceRect = direction == "zoom" ? self.transitionRect(call.getObject("sourceRect")) : nil
            let zoomSourceFrame = zoomSourceRect.map { self.transitionFrame(for: $0, webView: webView) }
            let cornerRadius = CGFloat(call.getDouble("cornerRadius") ?? 0)

            self.transitionSnapshot?.removeFromSuperview()
            self.restoreTransitionContainerBackground()
            let transitionSurface = nativeNavigationFallbackBackground(for: webView).withAlphaComponent(1.0)
            self.prepareTransitionContainerBackground(transitionContainer, surface: transitionSurface)
            let snapshot = self.transitionSnapshotView(from: webView, sourceRect: zoomSourceRect)
            snapshot.frame = zoomSourceFrame ?? webView.frame
            snapshot.autoresizingMask = zoomSourceFrame == nil ? [.flexibleWidth, .flexibleHeight] : []
            snapshot.backgroundColor = transitionSurface
            snapshot.isOpaque = true
            snapshot.layer.cornerRadius = cornerRadius
            snapshot.clipsToBounds = cornerRadius > 0
            // On top while the route swaps underneath, whatever the direction,
            // and the web view itself is left exactly as it is: not dimmed,
            // not hidden. WebKit records the snapshot it later reveals behind
            // a back swipe at `pushState` time, by rendering the WKWebView's
            // own layer — and the router pushes the URL while this transition
            // is in flight. A web view dimmed to `alpha = 0.01` here was
            // captured at 1 % and stored in a format without alpha, so every
            // swipe revealed the previous page as a faint ghost on black. An
            // opaque sibling on top hides the swap just as well and is
            // invisible to that capture.
            //
            // Layering still decides which page appears to move over the
            // other — a push slides the incoming page in on top, a pop slides
            // the outgoing one away on top — but for a push that only matters
            // once the animation starts, so finishStandardTransition drops the
            // snapshot below the web view right before animating.
            transitionContainer.insertSubview(snapshot, aboveSubview: webView)
            self.bringChromeToFront()
            self.transitionSnapshot = snapshot
            self.activeTransitionId = transitionId
            self.activeTransitionDirection = direction
            self.activeZoomSourceFrame = zoomSourceFrame
            self.activeZoomCornerRadius = cornerRadius

            let event: [String: Any] = ["id": transitionId, "direction": direction, "duration": durationMs]
            self.notifyListeners("transitionStart", data: event)
            call.resolve(event)
        }
    }

    @objc func finishTransition(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let webView = self.webView else {
                call.reject("WebView unavailable")
                return
            }

            let transitionId = call.getString("id") ?? self.activeTransitionId ?? "transition-\(Int(Date().timeIntervalSince1970 * 1_000))"
            let direction = call.getString("direction") ?? self.activeTransitionDirection
            let duration = (call.getDouble("duration") ?? self.defaultTransitionDuration * 1_000) / 1_000
            let durationMs = Int((duration * 1_000).rounded())
            let transition = NativeNavigationTransitionContext(
                webView: webView,
                snapshot: self.transitionSnapshot,
                id: transitionId,
                direction: direction,
                duration: duration,
                durationMs: durationMs,
                resolve: { call.resolve($0) }
            )

            if direction == "zoom" {
                let sourceRect = self.transitionRect(call.getObject("sourceRect"))
                let targetRect = self.transitionRect(call.getObject("targetRect"))
                self.finishZoomTransition(NativeNavigationZoomTransitionContext(
                    transition: transition,
                    sourceFrame: sourceRect.map { self.transitionFrame(for: $0, webView: webView) },
                    targetFrame: targetRect.map { self.transitionFrame(for: $0, webView: webView) },
                    cornerRadius: CGFloat(call.getDouble("cornerRadius") ?? Double(self.activeZoomCornerRadius))
                ))
                return
            }

            self.finishStandardTransition(transition)
        }
    }

    private func finishStandardTransition(_ transition: NativeNavigationTransitionContext) {
        let width = transition.webView.bounds.width
        let transforms = standardTransitionTransforms(direction: transition.direction, width: width)
        let usesStationaryCrossfade = nativeNavigationUsesStationaryTransitionCrossfade(direction: transition.direction)

        // A push slides the incoming page in over the outgoing one, so the
        // snapshot goes underneath now — in the same transaction as the start
        // transform, so no frame shows the live page before it has moved off
        // screen. Until here it stayed on top; see beginTransition for why.
        let isPush = transition.direction != "back" && !usesStationaryCrossfade
        if isPush, let snapshot = transition.snapshot, let container = snapshot.superview {
            container.insertSubview(snapshot, belowSubview: transition.webView)
        }

        transition.webView.transform = transforms.start
        // Fully opaque while sliding. The old 0.01 start faded the incoming
        // page in, and with the outgoing snapshot also translucent both pages
        // were visible through each other for the whole animation. Only the
        // stationary directions ('none', 'tab', 'root') are a crossfade, and
        // there the snapshot does the fading.
        transition.webView.alpha = 1

        // A critically damped spring rather than `.curveEaseOut`.
        //
        // easeOut starts at full speed and coasts to a stop, which is what made
        // the push read as "a web animation" rather than as iOS. UIKit's own
        // push eases in as well as out and settles rather than stopping; a
        // spring with dampingRatio 1 is that shape without overshoot.
        let animator = UIViewPropertyAnimator(
            duration: max(transition.duration, 0.01),
            timingParameters: UISpringTimingParameters(dampingRatio: 1.0)
        )
        animator.isUserInteractionEnabled = true
        animator.addAnimations {
            transition.webView.transform = .identity
            transition.webView.alpha = 1
            transition.snapshot?.transform = transforms.snapshotEnd
            transition.snapshot?.alpha = usesStationaryCrossfade ? 0 : 0.75
        }
        animator.addCompletion { _ in
            self.finishTransitionCleanup(transition)
        }
        animator.startAnimation()
    }

    private func standardTransitionTransforms(direction: String, width: CGFloat) -> (start: CGAffineTransform, snapshotEnd: CGAffineTransform) {
        switch direction {
        case "back":
            return (CGAffineTransform(translationX: -width * 0.3, y: 0), CGAffineTransform(translationX: width, y: 0))
        case "tab", "root", "none":
            return (.identity, .identity)
        default:
            return (CGAffineTransform(translationX: width, y: 0), CGAffineTransform(translationX: -width * 0.3, y: 0))
        }
    }

    private func finishZoomTransition(_ zoom: NativeNavigationZoomTransitionContext) {
        let transition = zoom.transition
        let startFrame = zoom.sourceFrame ?? activeZoomSourceFrame ?? transition.webView.frame

        let finish = {
            self.finishTransitionCleanup(transition)
        }

        guard transition.duration > 0 else {
            finish()
            return
        }

        if let targetFrame = zoom.targetFrame {
            animateZoomToTarget(zoom, startFrame: startFrame, targetFrame: targetFrame, completion: finish)
            return
        }

        animateZoomToFullScreen(zoom, startFrame: startFrame, completion: finish)
    }

    private func animateZoomToTarget(
        _ zoom: NativeNavigationZoomTransitionContext,
        startFrame: CGRect,
        targetFrame: CGRect,
        completion: @escaping () -> Void
    ) {
        let transition = zoom.transition
        transition.webView.transform = .identity
        transition.webView.alpha = 0.01
        transition.snapshot?.frame = startFrame
        transition.snapshot?.layer.cornerRadius = zoom.cornerRadius
        transition.snapshot?.clipsToBounds = zoom.cornerRadius > 0

        UIView.animate(
            withDuration: transition.duration,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: {
                transition.webView.alpha = 1
                transition.snapshot?.frame = targetFrame
                transition.snapshot?.alpha = 0
            },
            completion: { _ in completion() }
        )
    }

    private func animateZoomToFullScreen(
        _ zoom: NativeNavigationZoomTransitionContext,
        startFrame: CGRect,
        completion: @escaping () -> Void
    ) {
        let transition = zoom.transition
        let fullFrame = transition.webView.frame
        let scaleX = max(startFrame.width / max(fullFrame.width, 1), 0.01)
        let scaleY = max(startFrame.height / max(fullFrame.height, 1), 0.01)
        let translationX = startFrame.midX - fullFrame.midX
        let translationY = startFrame.midY - fullFrame.midY
        transition.webView.transform = CGAffineTransform(translationX: translationX, y: translationY).scaledBy(x: scaleX, y: scaleY)
        transition.webView.alpha = 1
        transition.webView.layer.cornerRadius = zoom.cornerRadius
        transition.webView.clipsToBounds = zoom.cornerRadius > 0
        transition.snapshot?.frame = startFrame

        UIView.animate(
            withDuration: transition.duration,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: {
                transition.webView.transform = .identity
                transition.webView.layer.cornerRadius = 0
                transition.snapshot?.frame = fullFrame
                transition.snapshot?.alpha = 0
            },
            completion: { _ in completion() }
        )
    }

    private func finishTransitionCleanup(_ transition: NativeNavigationTransitionContext) {
        transition.snapshot?.removeFromSuperview()
        transition.webView.transform = .identity
        transition.webView.alpha = 1
        transition.webView.layer.cornerRadius = 0
        transition.webView.clipsToBounds = false
        transitionSnapshot = nil
        restoreTransitionContainerBackground()
        activeTransitionId = nil
        activeZoomSourceFrame = nil
        let event: [String: Any] = ["id": transition.id, "direction": transition.direction, "duration": transition.durationMs]
        notifyListeners("transitionEnd", data: event)
        transition.resolve(event)
    }

    private func prepareTransitionContainerBackground(_ container: UIView, surface: UIColor) {
        activeTransitionContainer = container
        activeTransitionContainerBackgroundColor = container.backgroundColor
        activeTransitionContainerWasOpaque = container.isOpaque
        activeTransitionContainerBackgroundCaptured = true
        if nativeNavigationNeedsTransitionSurface(container.backgroundColor) {
            container.backgroundColor = surface
            container.isOpaque = true
        }
    }

    private func restoreTransitionContainerBackground() {
        guard activeTransitionContainerBackgroundCaptured else {
            return
        }
        activeTransitionContainer?.backgroundColor = activeTransitionContainerBackgroundColor
        activeTransitionContainer?.isOpaque = activeTransitionContainerWasOpaque
        activeTransitionContainer = nil
        activeTransitionContainerBackgroundColor = nil
        activeTransitionContainerWasOpaque = false
        activeTransitionContainerBackgroundCaptured = false
    }

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve([
            "version": implementation.getPluginVersion()
        ])
    }

    /// Shows/updates a native bottom action bar (UIToolbar) for the article
    /// screen. `leftItems`/`rightItems` are the same button shape as the navbar;
    /// taps report through `toolbarItemTap`. `hidden:true` removes it. The bar's
    /// height is reported as a bottom content inset so the page clears it.
    @objc func setToolbar(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.isEnabled else {
                self.toolbarVisible = false
                self.stopToolbarScrollObservation()
                self.toolbar?.isHidden = true
                self.bottomScrim?.isHidden = true
                self.updateInsetsAndNotify()
                call.resolve()
                return
            }

            let hidden = call.getBool("hidden", false)
            self.toolbarVisible = !hidden
            self.toolbarItemTitle.removeAll()

            guard !hidden else {
                self.stopToolbarScrollObservation()
                self.toolbar?.isHidden = true
                self.bottomScrim?.isHidden = true
                self.updateInsetsAndNotify()
                call.resolve()
                return
            }

            let toolbar = self.ensureToolbar()
            let left = self.makeToolbarButtonItems(call.getArray("leftItems") as? [[String: Any]] ?? [])
            let right = self.makeToolbarButtonItems(call.getArray("rightItems") as? [[String: Any]] ?? [])
            let flexible = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
            if let search = call.getObject("search") {
                let barWidth = self.bridge?.viewController?.view.bounds.width ?? UIScreen.main.bounds.width
                if left.isEmpty {
                    // No leading buttons (the study-plan drawer article): left-align
                    // the field so it reaches the left edge and widen it toward the
                    // trailing actions, which the flexible space pushes to the right.
                    // Reserve generously per right item — the iOS 26 Liquid Glass
                    // capsule is much wider than the bare icon — plus the bar insets
                    // and a gap, so those buttons are never clipped off the edge.
                    let rightReserve = CGFloat(right.count) * 68 + 96
                    let searchItem = self.makeToolbarSearchItem(search, width: max(140, barWidth - rightReserve))
                    toolbar.setItems([searchItem, flexible()] + right, animated: false)
                } else {
                    // Back/forward on the left (full-screen article): the field sits
                    // centred in the free middle, flanked by the nav and tutor buttons.
                    let searchItem = self.makeToolbarSearchItem(search, width: barWidth * 0.35)
                    toolbar.setItems(left + [flexible(), searchItem, flexible()] + right, animated: false)
                }
            } else {
                toolbar.setItems(left + [flexible()] + right, animated: false)
            }
            toolbar.isHidden = false
            self.ensureBottomScrim().isHidden = false
            self.startToolbarScrollObservation()
            self.layoutChrome()
            self.updateInsetsAndNotify()
            call.resolve()
        }
    }

    @objc private func handleToolbarButton(_ sender: UIBarButtonItem) {
        guard let id = sender.accessibilityIdentifier else {
            return
        }
        notifyListeners("toolbarItemTap", data: [
            "id": id,
            "title": toolbarItemTitle[id] ?? ""
        ])
    }

    private func ensureToolbar() -> UIToolbar {
        if let toolbar = toolbar {
            return toolbar
        }
        let bar = UIToolbar()
        bar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        bar.isTranslucent = true
        bridge?.viewController?.view.addSubview(bar)
        self.toolbar = bar
        return bar
    }

    /// The blur behind the toolbar, created on first use. It never takes touches
    /// and is laid out just below the toolbar so the buttons render on top.
    private func ensureBottomScrim() -> UIVisualEffectView {
        if let scrim = bottomScrim {
            return scrim
        }
        let effect: UIVisualEffect
        if #available(iOS 13.0, *) {
            effect = UIBlurEffect(style: .systemThinMaterial)
        } else {
            effect = UIBlurEffect(style: .light)
        }
        let view = UIVisualEffectView(effect: effect)
        view.isUserInteractionEnabled = false

        // A vertical alpha ramp over `bottomScrimFade`: clear at the top edge,
        // opaque behind the bar. With a fade of 0 the blur ends on a hard line.
        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.colors = [
            UIColor(white: 1, alpha: 0).cgColor,
            UIColor(white: 1, alpha: 1).cgColor,
            UIColor(white: 1, alpha: 1).cgColor
        ]
        view.layer.mask = mask

        bridge?.viewController?.view.addSubview(view)
        bottomScrim = view
        return view
    }

    /// Positions the scrim to cover the toolbar plus a fade zone above it, and
    /// slides it away with the toolbar when it hides on scroll.
    private func layoutBottomScrim() {
        guard toolbarVisible, let rootView = bridge?.viewController?.view else {
            return
        }
        let scrim = ensureBottomScrim()
        let width = rootView.bounds.width
        let height = rootView.bounds.height
        let safeBottom = rootView.safeAreaInsets.bottom
        let scrimHeight = safeBottom + toolbarHeight + bottomScrimFade
        let top = toolbarScrolledAway ? height : (height - scrimHeight)
        scrim.frame = CGRect(x: 0, y: top, width: width, height: scrimHeight)

        if let mask = scrim.layer.mask as? CAGradientLayer {
            let fadeFraction = scrimHeight > 0 ? Double(bottomScrimFade / scrimHeight) : 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.frame = scrim.bounds
            mask.locations = [NSNumber(value: 0.0), NSNumber(value: fadeFraction), NSNumber(value: 1.0)]
            CATransaction.commit()
        }
    }

    /// The blur behind the top navbar, created on first use; a mirror of the
    /// bottom scrim with the ramp inverted. Never takes touches; the navbar
    /// renders on top of it.
    private func ensureTopScrim() -> UIVisualEffectView {
        if let scrim = topScrim {
            return scrim
        }
        let effect: UIVisualEffect
        if #available(iOS 13.0, *) {
            effect = UIBlurEffect(style: .systemThinMaterial)
        } else {
            effect = UIBlurEffect(style: .light)
        }
        let view = UIVisualEffectView(effect: effect)
        view.isUserInteractionEnabled = false

        // Opaque behind the navbar at the top, fading to clear into the content.
        let mask = CAGradientLayer()
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.colors = [
            UIColor(white: 1, alpha: 1).cgColor,
            UIColor(white: 1, alpha: 1).cgColor,
            UIColor(white: 1, alpha: 0).cgColor
        ]
        view.layer.mask = mask

        bridge?.viewController?.view.addSubview(view)
        topScrim = view
        return view
    }

    /// Covers the status bar and navbar plus a fade below, but only while a
    /// non-hosted navbar is up (the article and similar detail screens). Hidden
    /// otherwise — hosted-navbar pages reserve their own top space.
    private func layoutTopScrim() {
        guard let rootView = bridge?.viewController?.view else {
            return
        }
        let show = isEnabled && navbarVisible && !navbarUsesHostedController
        guard show else {
            topScrim?.isHidden = true
            return
        }
        let scrim = ensureTopScrim()
        scrim.isHidden = false
        let width = rootView.bounds.width
        let safeTop = rootView.safeAreaInsets.top
        let scrimHeight = safeTop + navbarHeight + topScrimFade
        scrim.frame = CGRect(x: 0, y: 0, width: width, height: scrimHeight)

        if let mask = scrim.layer.mask as? CAGradientLayer {
            let opaqueFraction = scrimHeight > 0 ? Double((scrimHeight - topScrimFade) / scrimHeight) : 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.frame = scrim.bounds
            mask.locations = [NSNumber(value: 0.0), NSNumber(value: opaqueFraction), NSNumber(value: 1.0)]
            CATransaction.commit()
        }
    }

    /// Same button shape as `makeBarButtonItems`, but reporting through
    /// `toolbarItemTap` and without the navbar's badge/menu machinery.
    private func makeToolbarButtonItems(_ rawItems: [[String: Any]]) -> [UIBarButtonItem] {
        return rawItems.map { rawItem in
            let id = rawItem["id"] as? String ?? UUID().uuidString
            let title = rawItem["title"] as? String
            let image = self.image(from: rawItem["icon"] as? [String: Any])
            let item = UIBarButtonItem(image: image, style: .plain, target: self, action: #selector(handleToolbarButton(_:)))
            if image == nil {
                item.title = title
            }
            item.isEnabled = rawItem["enabled"] as? Bool ?? true
            if let tint = rawItem["tintColor"] as? String, let colour = UIColor(hex: tint) {
                item.tintColor = colour
            }
            // The screen's main action: a filled capsule in the item's tint on
            // iOS 26, bold text before that, where bar items have no fill.
            if rawItem["prominent"] as? Bool ?? false {
                if #available(iOS 26.0, *) {
                    item.style = .prominent
                } else {
                    item.setTitleTextAttributes([.font: UIFont.boldSystemFont(ofSize: 17)], for: .normal)
                }
            }
            item.accessibilityIdentifier = id
            item.accessibilityLabel = title
            toolbarItemTitle[id] = title ?? ""
            return item
        }
    }

    /// A search-field-styled, tappable item that fills the middle of the
    /// toolbar. It does not edit inline — a tap reports through
    /// `toolbarItemTap` so the app opens its own in-article find. Sized from
    /// the current bar width, leaving room for the flanking buttons.
    private func makeToolbarSearchItem(_ raw: [String: Any], width: CGFloat) -> UIBarButtonItem {
        let id = raw["id"] as? String ?? "article-search"
        let placeholder = raw["placeholder"] as? String ?? ""
        let height: CGFloat = 36

        let field = UIButton(type: .system)
        field.accessibilityIdentifier = id
        field.accessibilityLabel = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.contentHorizontalAlignment = .leading
        field.tintColor = .secondaryLabel
        field.addTarget(self, action: #selector(handleToolbarButton(_:)), for: .touchUpInside)

        // A magnifier + placeholder only. On iOS 26 the toolbar already wraps
        // this custom view in its own Liquid Glass capsule, exactly like the
        // flanking button items — so adding an own fill produced a box inside a
        // box. We keep the background clear and let that single system capsule
        // be the field, so it reads as one native element.
        let symbol = UIImage(systemName: "magnifyingglass",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.image = symbol
            config.imagePadding = 8
            config.baseForegroundColor = .secondaryLabel
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
            var title = AttributedString(placeholder)
            title.font = .systemFont(ofSize: 15)
            config.attributedTitle = title
            field.configuration = config
        } else {
            field.setImage(symbol, for: .normal)
            field.setTitle(" \(placeholder)", for: .normal)
            field.setTitleColor(.secondaryLabel, for: .normal)
            field.titleLabel?.font = .systemFont(ofSize: 15)
            field.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        }

        // A width CONSTRAINT is required — a toolbar sizes a custom view to its
        // content otherwise. The caller decides it: a fraction of the bar when
        // it also holds back/forward + the tutor button, or a near-full fill
        // when there are no leading buttons (the drawer article).
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: max(110, width)),
            field.heightAnchor.constraint(equalToConstant: height)
        ])

        let item = UIBarButtonItem(customView: field)
        toolbarItemTitle[id] = placeholder
        return item
    }

    /// Starts observing the web view's scroll so the toolbar can slide out of
    /// the way on scroll-down and return on scroll-up. Idempotent.
    private func startToolbarScrollObservation() {
        guard toolbarScrollObservation == nil,
              let scrollView = (webView as? WKWebView)?.scrollView else {
            return
        }
        toolbarLastScrollY = scrollView.contentOffset.y
        toolbarScrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            self?.handleToolbarScroll(scrollView)
        }
    }

    /// Stops the scroll observation and returns the toolbar to its shown slot.
    private func stopToolbarScrollObservation() {
        toolbarScrollObservation?.invalidate()
        toolbarScrollObservation = nil
        toolbarScrolledAway = false
    }

    /// Slides the toolbar away on downward scroll, back on upward scroll; always
    /// shown near the top. A small threshold keeps tiny jitters from toggling it.
    private func handleToolbarScroll(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        if y <= 0 {
            toolbarLastScrollY = y
            setToolbarScrolledAway(false)
            return
        }
        let delta = y - toolbarLastScrollY
        if delta > toolbarScrollThreshold {
            toolbarLastScrollY = y
            setToolbarScrolledAway(true)
        } else if delta < -toolbarScrollThreshold {
            toolbarLastScrollY = y
            setToolbarScrolledAway(false)
        }
    }

    /// Animates the toolbar between its shown slot and just below the screen.
    /// The reported inset is left unchanged, so the page never reflows mid-scroll.
    private func setToolbarScrolledAway(_ away: Bool) {
        guard toolbarScrolledAway != away,
              toolbarVisible,
              let toolbar = toolbar,
              let rootView = bridge?.viewController?.view else {
            return
        }
        toolbarScrolledAway = away
        let height = rootView.bounds.height
        let safeInsets = rootView.safeAreaInsets
        let targetY = away ? height : (height - safeInsets.bottom - toolbarHeight)
        let scrimHeight = safeInsets.bottom + toolbarHeight + bottomScrimFade
        let scrimTargetY = away ? height : (height - scrimHeight)
        UIView.animate(withDuration: 0.25, delay: 0,
                       options: [.curveEaseInOut, .beginFromCurrentState]) {
            toolbar.frame.origin.y = targetY
            self.bottomScrim?.frame.origin.y = scrimTargetY
        }
    }

    @objc private func handleNavbarBack() {
        notifyListeners("navbarBack", data: ["source": "navbar"])
    }

    @objc private func handleNavbarButton(_ sender: UIBarButtonItem) {
        guard let id = sender.accessibilityIdentifier else {
            return
        }
        notifyListeners("navbarItemTap", data: [
            "id": id,
            "title": navbarItemTitle[id] ?? "",
            "placement": navbarItemPlacement[id] ?? "right"
        ])
    }

    public func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        notifyTabSelect(index: item.tag)
    }

    public func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        if usesSystemLiquidGlass {
            hostWebView(in: viewController)
        }
        return true
    }

    public func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        guard !suppressTabSelectEvent else {
            hostWebViewInSelectedSystemTab()
            return
        }
        // `tabBarItem.tag` is only set by the pre-iOS-18 path. Tabs built as
        // UITab carry no tag, so it reads 0 and every tap would report the
        // first tab. `selectedIndex` matches the order tabIds was built in.
        let index = appliedSystemTabIds.isEmpty ? viewController.tabBarItem.tag : tabBarController.selectedIndex
        hostWebViewInSelectedSystemTab()
        notifyTabSelect(index: index)
    }

    /// Selection callback for the iOS 18+ `tabs` API.
    ///
    /// The legacy `didSelect viewController:` above is not guaranteed to fire
    /// once a controller is driven by `tabs` rather than `viewControllers`,
    /// and when it does not fire nothing moves the WebView into the newly
    /// selected tab — every tab but the first shows an empty screen, and the
    /// web layer never learns a tab was tapped.
    @available(iOS 18.0, *)
    public func tabBarController(
        _ tabBarController: UITabBarController,
        didSelectTab selectedTab: UITab,
        previousTab: UITab?
    ) {
        hostWebViewInSelectedSystemTab()

        guard !suppressTabSelectEvent else {
            return
        }
        notifyTabSelect(index: tabBarController.selectedIndex)
        if selectedTab is UISearchTab, let previousTab {
            searchPreviousTabIndex = tabBarController.tabs.firstIndex { $0 === previousTab }
        }
        mkAutoActivateSearch(for: selectedTab)
    }

    /// KAN-751 workaround: re-adds search auto-focus without UIKit's
    /// automaticallyActivatesSearch, whose synchronous activation inside the
    /// tab-select commit strands a duplicate .integrated search bar. Activating
    /// a beat later — after the tab-select transition settles — sidesteps that
    /// race; deactivating when another tab is chosen stops the controller from
    /// leaking its active state across tabs. The delayed closure re-checks that
    /// the search tab is still selected, so a quick switch away cannot
    /// reactivate it.
    @available(iOS 18.0, *)
    private func mkAutoActivateSearch(for selectedTab: UITab) {
        let searchContent = NativeNavigationTabContentController.all.first {
            $0.navigationItem.searchController != nil
        }
        guard let searchContent,
              let searchController = searchContent.navigationItem.searchController else { return }
        if selectedTab is UISearchTab {
            // Focus on the content's next appearance (after the transition), so
            // the bar and keyboard come up together instead of the delayed
            // two-step a timer + isActive produced.
            searchContent.mkAutoActivateSearchOnAppear = true
        } else {
            searchController.isActive = false
        }
    }

    /// KAN-751: on search cancel (X), return to the tab the user came from,
    /// matching UIKit's old automaticallyActivatesSearch behaviour. A
    /// programmatic selectedIndex change does not fire the tab-select delegate,
    /// so the WebView re-host and web notification are done here explicitly.
    private func mkReturnFromSearch() {
        guard let index = searchPreviousTabIndex,
              let tabBarController = tabBarController,
              index >= 0, index < tabIds.count else { return }
        tabBarController.selectedIndex = index
        hostWebViewInSelectedSystemTab()
        notifyTabSelect(index: index)
        searchPreviousTabIndex = nil
    }

    private func notifyTabSelect(index: Int) {
        guard index >= 0,
              index < tabIds.count,
              !tabIds[index].isEmpty else {
            return
        }
        notifyListeners("tabSelect", data: [
            "id": tabIds[index],
            "index": index,
            "title": tabTitles[index]
        ])
    }

    @objc private func handleLayoutChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.layoutChrome()
            self.updateInsetsAndNotify()
        }
    }

    @objc private func handleKeyboardFrameChange() {
        DispatchQueue.main.async {
            self.layoutChrome()
        }
    }

    @objc private func handleKeyboardDidHide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.refreshChromeAfterKeyboardDismiss()
        }
    }

    @objc private func handleReduceTransparencyChange() {
        DispatchQueue.main.async {
            self.refreshTabBarBackgroundIfNeeded()
            self.layoutChrome()
            self.updateInsetsAndNotify()
        }
    }

    private func refreshChromeAfterKeyboardDismiss() {
        layoutChrome()
        refreshTabBarBackgroundIfNeeded()
        updateInsetsAndNotify()
    }

    private func refreshTabBarBackgroundIfNeeded() {
        guard tabbarVisible else {
            return
        }

        tabBarController?.view.setNeedsLayout()
        tabBarController?.view.layoutIfNeeded()

        if let tabBar = tabBar {
            tabBar.isTranslucent = !prefersOpaqueTabBarBackground()
            let standardAppearance = tabBar.standardAppearance
            tabBar.standardAppearance = standardAppearance
            if #available(iOS 15.0, *) {
                let scrollEdgeAppearance = tabBar.scrollEdgeAppearance ?? standardAppearance
                tabBar.scrollEdgeAppearance = scrollEdgeAppearance
            }
            tabBar.items?.forEach { item in
                item.standardAppearance = standardAppearance
                if #available(iOS 15.0, *) {
                    item.scrollEdgeAppearance = tabBar.scrollEdgeAppearance
                }
            }
            tabBar.setNeedsLayout()
            tabBar.layoutIfNeeded()
        }

        tabContainer?.setNeedsLayout()
        tabContainer?.layoutIfNeeded()
        floatingTabBar?.setNeedsLayout()
        floatingTabBar?.layoutIfNeeded()
    }

    private func prefersOpaqueTabBarBackground() -> Bool {
        UIAccessibility.isReduceTransparencyEnabled
    }

    private func ensureNavBar() -> UINavigationBar {
        if let navBar = navBar {
            return navBar
        }

        let container = NativeNavigationChromeContainer()
        container.hitSlop = UIEdgeInsets(top: 0, left: 0, bottom: 32, right: 0)
        container.isUserInteractionEnabled = true
        container.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]

        if !usesSystemLiquidGlass {
            let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            blurView.isUserInteractionEnabled = false
            container.addSubview(blurView)
            self.navBlurView = blurView
        }

        let bar = NativeNavigationBar()
        bar.hitSlop = UIEdgeInsets(top: 0, left: 0, bottom: 32, right: 0)
        bar.isTranslucent = true
        if !usesSystemLiquidGlass {
            bar.backgroundColor = .clear
        }
        bar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        container.addSubview(bar)

        bridge?.viewController?.view.addSubview(container)
        self.navContainer = container
        self.navBar = bar
        return bar
    }

    private func ensureTabBar() -> UITabBar {
        if usesSystemLiquidGlass {
            return ensureSystemTabBar()
        }

        if let tabBar = tabBar {
            return tabBar
        }

        let container = NativeNavigationChromeContainer()
        container.hitSlop = UIEdgeInsets(top: 32, left: 0, bottom: 24, right: 0)
        container.isUserInteractionEnabled = true
        container.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        container.backgroundColor = .clear

        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.14
        container.layer.shadowRadius = 18
        container.layer.shadowOffset = CGSize(width: 0, height: 10)

        let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        container.addSubview(effectView)
        self.tabEffectView = effectView

        let bar = UITabBar()
        bar.isTranslucent = true
        bar.backgroundColor = .clear
        bar.backgroundImage = UIImage()
        bar.shadowImage = UIImage()
        bar.clipsToBounds = true
        bar.delegate = self
        bar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        container.addSubview(bar)
        bridge?.viewController?.view.addSubview(container)
        self.tabContainer = container
        self.tabBar = bar
        return bar
    }

    private func ensureFloatingTabBar() -> NativeNavigationFloatingTabBar {
        if let floatingTabBar = floatingTabBar {
            return floatingTabBar
        }

        let container = NativeNavigationChromeContainer()
        container.hitSlop = UIEdgeInsets(top: 32, left: 0, bottom: 24, right: 0)
        container.isUserInteractionEnabled = true
        container.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        container.backgroundColor = .clear
        container.clipsToBounds = false

        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.14
        container.layer.shadowRadius = 18
        container.layer.shadowOffset = CGSize(width: 0, height: 10)

        let effectView = UIVisualEffectView(effect: liquidGlassEffect() ?? UIBlurEffect(style: .systemChromeMaterial))
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        effectView.isUserInteractionEnabled = false
        effectView.clipsToBounds = true
        container.addSubview(effectView)
        self.tabEffectView = effectView

        let trailingEffectView = UIVisualEffectView(effect: liquidGlassEffect() ?? UIBlurEffect(style: .systemChromeMaterial))
        trailingEffectView.autoresizingMask = []
        trailingEffectView.isUserInteractionEnabled = false
        trailingEffectView.clipsToBounds = true
        trailingEffectView.isHidden = true
        container.addSubview(trailingEffectView)
        self.trailingTabEffectView = trailingEffectView

        let bar = NativeNavigationFloatingTabBar()
        bar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        bar.clipsToBounds = false
        container.addSubview(bar)
        bridge?.viewController?.view.addSubview(container)
        self.tabContainer = container
        self.floatingTabBar = bar
        return bar
    }

    private func ensureSystemTabBar() -> UITabBar {
        if let tabBarController = tabBarController {
            hostWebViewInSelectedSystemTab()
            return tabBarController.tabBar
        }

        let controller = NativeNavigationTabController()
        controller.delegate = self
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.isHidden = !tabbarVisible

        if let parent = bridge?.viewController {
            let containerView = systemTabHostingContainerView(in: parent)
            parent.addChild(controller)
            insertSystemTabControllerView(controller.view, in: containerView)
            controller.didMove(toParent: parent)
        }

        self.tabBarController = controller
        self.tabBar = controller.tabBar
        liftWebViewOverlaysAboveSystemTabs()
        hostWebViewInSelectedSystemTab()
        return controller.tabBar
    }

    private func systemTabHostingContainerView(in parent: UIViewController) -> UIView {
        if let systemTabRootContainer = systemTabRootContainer {
            return systemTabRootContainer
        }

        guard let webView = webView,
              parent.view === webView else {
            return parent.view
        }

        let previousSuperview = webView.superview
        let previousIndex = previousSuperview?.subviews.firstIndex(of: webView)
        let previousFrame = webView.frame
        let previousAutoresizingMask = webView.autoresizingMask
        let container = UIView(frame: previousFrame)
        container.backgroundColor = nativeNavigationFallbackBackground(for: webView)
        container.isOpaque = true
        container.autoresizingMask = previousAutoresizingMask.isEmpty ? [.flexibleWidth, .flexibleHeight] : previousAutoresizingMask

        if let previousSuperview = previousSuperview {
            previousSuperview.insertSubview(container, at: min(previousIndex ?? previousSuperview.subviews.count, previousSuperview.subviews.count))
        }

        parent.view = container
        container.addSubview(webView)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = container.bounds
        moveNativeChrome(from: webView, to: container)

        systemTabRootContainer = container
        originalWebViewSuperview = container
        originalWebViewIndex = 0
        originalWebViewAutoresizingMask = webView.autoresizingMask
        liftWebViewOverlaysAboveSystemTabs()
        return container
    }

    private func moveNativeChrome(from webView: UIView, to container: UIView) {
        if let navContainer = navContainer,
           navContainer.superview === webView {
            container.addSubview(navContainer)
        }
    }

    private func applySystemTabBarItems(_ items: [UITabBarItem], selectedIndex: Int?, animated: Bool) {
        guard let tabBarController = tabBarController else {
            return
        }

        let previousSelectedIndex = tabBarController.selectedIndex
        let controllers = systemTabContentControllers(for: items)
        let currentControllers = tabBarController.viewControllers ?? []
        let shouldUpdateControllers = currentControllers.count != controllers.count
            || zip(currentControllers, controllers).contains { currentController, nextController in
                currentController !== nextController
            }
        let shouldAnimate = animated && tabBarController.viewControllers?.count == controllers.count

        suppressTabSelectEvent = true
        defer { suppressTabSelectEvent = false }

        guard !controllers.isEmpty else {
            restoreWebViewFromSystemTabController()
            if shouldUpdateControllers {
                tabBarController.setViewControllers([], animated: false)
            }
            tabViewControllers = []
            return
        }

        if shouldUpdateControllers {
            tabBarController.setViewControllers(controllers, animated: shouldAnimate)
        }

        let fallbackIndex = selectedIndex ?? previousSelectedIndex
        let index = min(max(fallbackIndex, 0), controllers.count - 1)
        hostWebView(in: controllers[index])
        tabBarController.selectedIndex = index
        tabViewControllers = controllers
    }

    private func systemTabContentControllers(for items: [UITabBarItem]) -> [UIViewController] {
        let existingControllers = tabViewControllers.compactMap { $0 as? NativeNavigationTabContentController }
        if existingControllers.count == items.count {
            zip(existingControllers, items).forEach { controller, item in
                controller.tabBarItem = item
            }
            return existingControllers
        }

        return items.map { item -> UIViewController in
            let controller = NativeNavigationTabContentController()
            controller.tabBarItem = item
            return controller
        }
    }

    /// How long UIKit's animated `setTabBarHidden(_:animated:)` takes.
    ///
    /// That API has no completion handler, so the teardown in
    /// `hideSystemTabBarChromeCompletely` is deferred by this much instead.
    /// Deliberately a touch generous: finishing early cuts the slide off, while
    /// finishing late costs nothing but an invisible bar staying in the
    /// hierarchy a moment longer.
    private static let animatedTabBarHideDuration: TimeInterval = 0.35

    private func setSystemTabBarHidden(_ hidden: Bool, animated: Bool = false) {
        guard let tabBarController = tabBarController else {
            return
        }

        let tabBar = tabBarController.tabBar
        if #available(iOS 18.0, *) {
            tabBarController.setTabBarHidden(hidden, animated: animated)
        } else {
            tabBar.isHidden = hidden
        }

        // iOS 26 owns the tab bar's subviews itself — the minimized pill is
        // one of them. setTabBarBackgroundSubviewsHidden walks every subview
        // and forces isHidden/alpha, which resurrected the pill's icon over
        // the first tab after a minimize. So on 26 the sweep is skipped in
        // BOTH directions: setTabBarHidden above is the whole mechanism, and
        // touching it from only one side leaves the bar permanently empty.
        guard #available(iOS 26.0, *) else {
            if hidden {
                // Skipped while animating: this zeroes the alpha of the bar
                // and of every subview, so running it now would empty the bar
                // before it has moved anywhere. The deferred teardown calls
                // this again.
                if !animated {
                    setTabBarBackgroundSubviewsHidden(true, on: tabBar)
                }
            } else {
                setTabBarBackgroundSubviewsHidden(false, on: tabBar)
                tabBar.setNeedsLayout()
                tabBar.layoutIfNeeded()
            }
            return
        }
    }

    private func setTabBarBackgroundSubviewsHidden(_ hidden: Bool, on tabBar: UITabBar) {
        tabBar.isHidden = hidden
        tabBar.alpha = hidden ? 0 : 1
        tabBar.isUserInteractionEnabled = !hidden
        tabBar.subviews.forEach { subview in
            subview.isHidden = hidden
            subview.alpha = hidden ? 0 : 1
        }
    }

    private func hideSystemTabBarChromeCompletely(animated: Bool = false) {
        // On iOS 26 the bar is hidden and nothing else: the teardown would pull
        // the web view back out of the tab controller, and with it the
        // navigation controller the article bar hangs off — so the one screen
        // that needs a real bar would be the one screen without one.
        // `setTabBarHidden` is the entire mechanism there anyway; it drops the
        // bar out of the safe area too, so nothing stays reserved.
        if usesSystemLiquidGlass, tabbarStyle.shape != .curve, tabBarController != nil {
            setSystemTabBarHidden(true, animated: animated)
            return
        }

        // The teardown below cannot simply be animated in place. Its first step
        // empties the bar AND moves the WebView back out of the tab controller,
        // so by the time UIKit would animate there is nothing left to slide.
        // Animating therefore means: slide first, tear down afterwards.
        guard animated,
              #available(iOS 18.0, *),
              let tabBarController = tabBarController,
              !tabBarController.view.isHidden else {
            tearDownSystemTabBarChrome()
            return
        }

        setSystemTabBarHidden(true, animated: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.animatedTabBarHideDuration) { [weak self] in
            // A setTabbar({hidden: false}) may have landed while the bar was
            // sliding out. `tabbarVisible` is written before the chrome is
            // touched, so it is the authority on what the caller wants now —
            // tearing down here would break a bar that is on its way back in.
            guard let self, !self.tabbarVisible else { return }
            self.tearDownSystemTabBarChrome()
        }
    }

    private func tearDownSystemTabBarChrome() {
        applySystemTabBarItems([], selectedIndex: nil, animated: false)
        setSystemTabBarHidden(true)
        tabBarController?.view.isHidden = true
        tabContainer?.isHidden = true
        floatingTabBar?.isHidden = true
    }

    private func hideTabBarChrome() {
        if usesSystemLiquidGlass && tabbarStyle.shape != .curve {
            hideSystemTabBarChromeCompletely(animated: true)
        } else {
            restoreWebViewFromSystemTabController()
            hideSystemTabBarChromeCompletely()
            tabBar?.isHidden = true
        }
    }

    private func showTabBarChrome(_ tabBar: UITabBar) {
        tabContainer?.isHidden = true
        floatingTabBar?.isHidden = true
        tabBarController?.view.isHidden = false
        if usesSystemLiquidGlass && tabbarStyle.shape != .curve {
            // Animated, to match hideTabBarChrome() on the way out: hiding slid
            // the bar away while showing snapped it back, so a dialog closing
            // looked like the dock reappearing out of nowhere. Not on the first
            // bar of a launch — there is nothing to slide back from.
            setSystemTabBarHidden(false, animated: hasShownTabBar)
            hasShownTabBar = true
            liftWebViewOverlaysAboveSystemTabs()
            hostWebViewInSelectedSystemTab()
        } else {
            tabBar.isHidden = false
        }
    }

    private func showFloatingTabBarChrome(_ tabBar: NativeNavigationFloatingTabBar) {
        restoreWebViewFromSystemTabController()
        tabBarController?.view.isHidden = true
        tabContainer?.isHidden = false
        tabBar.isHidden = false
    }

    private func captureOriginalWebViewPlacementIfNeeded(_ webView: UIView) {
        guard originalWebViewSuperview == nil, let superview = webView.superview else {
            return
        }

        originalWebViewSuperview = superview
        originalWebViewIndex = superview.subviews.firstIndex(of: webView)
        originalWebViewAutoresizingMask = webView.autoresizingMask
    }

    private func insertSystemTabControllerView(_ controllerView: UIView, in parentView: UIView) {
        guard let webView = webView else {
            parentView.addSubview(controllerView)
            return
        }

        captureOriginalWebViewPlacementIfNeeded(webView)
        let insertionIndex = systemTabControllerInsertionIndex(in: parentView, for: webView)
        parentView.insertSubview(controllerView, at: insertionIndex)
    }

    private func systemTabControllerInsertionIndex(in parentView: UIView, for webView: UIView) -> Int {
        if let directChild = directChild(of: parentView, containing: webView),
           let index = parentView.subviews.firstIndex(of: directChild) {
            return min(index, parentView.subviews.count)
        }

        if let originalWebViewSuperview = originalWebViewSuperview,
           originalWebViewSuperview === parentView {
            return min(originalWebViewIndex ?? parentView.subviews.count, parentView.subviews.count)
        }

        return parentView.subviews.count
    }

    private func directChild(of ancestor: UIView, containing descendant: UIView) -> UIView? {
        var current: UIView? = descendant
        while let view = current, let superview = view.superview {
            if superview === ancestor {
                return view
            }
            current = superview
        }

        return nil
    }

    private func hostWebViewInSelectedSystemTab() {
        hostWebView(in: tabBarController?.selectedViewController)
    }

    /// Turns on Apple's own scroll edge effect for content passing under the
    /// bars.
    ///
    /// This is the piece that makes a floating bar readable, and it belongs to
    /// the scroll view rather than to the bar: `topEdgeEffect` runs inside the
    /// scroll view's own compositing, so it needs no access to the web view's
    /// pixels from the outside.
    ///
    /// `.soft` is the fading blur; the other style is a hard line, which is
    /// what an unstyled edge looks like.
    ///
    /// - Parameter webView: The hosted web view, whose scrollView carries the
    ///   effect.
    private func applyScrollEdgeEffects(to webView: UIView) {
        // The top/bottom readability blur is now drawn by our own gradient-masked
        // scrims (see layoutTopScrim / layoutBottomScrim), not UIScrollView's edge
        // effects: the bottom has no system bar to anchor an effect against, and
        // the top effect stopped covering the navbar below the notch on iOS 27.
        // Kept as a no-op so the existing call sites need no change.
    }

    /// The content controller currently showing the web view, if the web view
    /// lives inside the tab controller at all.
    private func hostedContentController() -> NativeNavigationTabContentController? {
        return nativeNavigationTabContent(of: tabBarController?.selectedViewController)
    }

    private func hostWebView(in viewController: UIViewController?) {
        let content = nativeNavigationTabContent(of: viewController)

        guard usesSystemLiquidGlass,
              let webView = webView,
              let selectedController = content else {
            return
        }

        applyScrollEdgeEffects(to: webView)
        liftWebViewOverlaysAboveSystemTabs()
        captureOriginalWebViewPlacementIfNeeded(webView)

        // A change of host. The web view still shows the tab being left, and
        // UIKit is about to cross-dissolve to the tab being entered, whose
        // view may not even be attached yet. Three things keep that from
        // showing: the bar carries over, so the safe area — and with it the
        // page's top padding — does not jump; the new tab is covered with a
        // still of the current page until the web app reports the new one
        // painted; and the web view itself moves only once the new view is
        // on screen with real bounds (see NativeNavigationTabContentController).
        if !selectedController.isHosting(webView) {
            carryHostedNavbar(to: selectedController)
            selectedController.cover(with: webView)
        }

        clearHostedWebViews(matching: webView, except: selectedController, preservingSnapshots: true)
        guard selectedController.host(webView: webView) else {
            isWebViewHostedInSystemTabController = false
            return
        }
        clearHostedWebViews(matching: webView, except: selectedController)
        isWebViewHostedInSystemTabController = true
        bringLiftedWebViewOverlaysToFront()
    }

    private func liftWebViewOverlaysAboveSystemTabs() {
        guard usesSystemLiquidGlass,
              let webView = webView,
              let container = systemTabRootContainer else {
            return
        }

        nativeNavigationLiftWebViewOverlaySubviews(
            from: webView,
            to: container,
            tracking: &liftedWebViewOverlays,
            excluding: [navContainer, tabContainer, tabBarController?.view]
        )
    }

    private func bringLiftedWebViewOverlaysToFront() {
        guard let container = systemTabRootContainer else {
            return
        }

        liftedWebViewOverlays = liftedWebViewOverlays.filter { $0.value != nil }
        liftedWebViewOverlays
            .compactMap(\.value)
            .filter { $0.superview === container }
            .forEach { container.bringSubviewToFront($0) }
    }

    private func restoreWebViewFromSystemTabController() {
        guard isWebViewHostedInSystemTabController,
              let webView = webView,
              let targetSuperview = originalWebViewSuperview ?? bridge?.viewController?.view else {
            return
        }

        let insertionIndex = min(originalWebViewIndex ?? targetSuperview.subviews.count, targetSuperview.subviews.count)
        clearHostedWebViews(matching: webView)
        webView.removeFromSuperview()
        targetSuperview.insertSubview(webView, at: insertionIndex)
        webView.autoresizingMask = originalWebViewAutoresizingMask ?? [.flexibleWidth, .flexibleHeight]
        webView.frame = targetSuperview.bounds
        isWebViewHostedInSystemTabController = false
    }

    private func clearHostedWebViews(
        matching webView: UIView,
        except owner: NativeNavigationTabContentController? = nil,
        preservingSnapshots: Bool = false
    ) {
        NativeNavigationTabContentController.all
            .filter { $0 !== owner }
            .forEach { $0.clearHostedWebView(ifMatching: webView, preservingSnapshot: preservingSnapshots) }
    }

    private func makeBarButtonItems(_ rawItems: [[String: Any]], placement: String) -> [UIBarButtonItem] {
        return rawItems.map { rawItem in
            let id = rawItem["id"] as? String ?? UUID().uuidString
            let title = rawItem["title"] as? String
            var image = image(from: rawItem["icon"] as? [String: Any])
            let tint = (rawItem["tintColor"] as? String).flatMap { UIColor(hex: $0) }
            // A dot in the corner, for "there is something waiting here". UIKit
            // gives bar buttons no badge of their own, so it is drawn into the
            // image — which means baking the tint in as well, since a template
            // image would flatten the dot into the symbol's own colour.
            if let badge = (rawItem["badgeColor"] as? String).flatMap({ UIColor(hex: $0) }),
               let base = image {
                image = badged(base, tint: tint ?? .label, badge: badge, symbol: rawItem["badgeSymbol"] as? String)
            }
            let item = UIBarButtonItem(image: image, style: .plain, target: self, action: #selector(handleNavbarButton(_:)))
            if image == nil {
                item.title = title
            }
            item.isEnabled = rawItem["enabled"] as? Bool ?? true
            // A colour of the item's own, where inheriting the bar's tint would
            // lose meaning the colour itself carries — a streak flame reads as
            // a flame because it is orange.
            if let tint = rawItem["tintColor"] as? String, let colour = UIColor(hex: tint) {
                item.tintColor = colour
            }
            item.accessibilityIdentifier = id
            item.accessibilityLabel = title
            configureGlassBarButtonItem(item, id: id)
            navbarItemPlacement[id] = placement
            navbarItemTitle[id] = title ?? ""

            // A `menu` turns the button into an anchored UIMenu instead of a
            // plain tap. Without it the only way to offer several commands from
            // the bar is a sheet in the middle of the screen, which is not what
            // an ellipsis promises on iOS: the menu belongs at the button.
            //
            // Children report through the same navbarItemTap event as any
            // button, so the web layer handles them identically.
            if let entries = rawItem["menu"] as? [[String: Any]], !entries.isEmpty {
                item.menu = makeBarButtonMenu(entries)
                // The target/action has to go, or UIKit treats the tap as that
                // action and only opens the menu on a long press — which reads
                // as an ellipsis that does nothing, since the button's own id
                // matches no command.
                item.target = nil
                item.action = nil
            }

            return item
        }
    }

    /// Builds the menu shown by a bar button that declares `menu` entries.
    ///
    /// - Parameter entries: Raw dictionaries with `id`, `title` and optional
    ///   `icon` and `destructive` keys.
    /// - Returns: A menu whose actions each notify `navbarItemTap`.
    private func makeBarButtonMenu(_ entries: [[String: Any]]) -> UIMenu {
        return UIMenu(title: "", children: makeMenuElements(entries))
    }

    /// One `UIMenuElement` per entry: an action, or — for an entry with
    /// `children` — a submenu of them, the way the appearance picker nests in
    /// the profile menu. `checked` ticks an action, for the option in force.
    private func makeMenuElements(_ entries: [[String: Any]]) -> [UIMenuElement] {
        var elements: [UIMenuElement] = []

        // A plain loop with spelled-out types. As a map closure this stopped
        // type-checking altogether — "failed to produce diagnostic" — which is
        // the compiler giving up on inference rather than a fault in the code.
        for entry in entries {
            let id: String = entry["id"] as? String ?? UUID().uuidString
            let title: String = entry["title"] as? String ?? ""
            var iconImage: UIImage? = image(from: entry["icon"] as? [String: Any])
            // A menu tints template images with the button's colour; an entry
            // with its own tintColor keeps that colour instead, e.g. grey icons
            // under a coloured button.
            if let tint = (entry["tintColor"] as? String).flatMap({ UIColor(hex: $0) }) {
                iconImage = iconImage?.withTintColor(tint, renderingMode: .alwaysOriginal)
            }

            if let children = entry["children"] as? [[String: Any]] {
                elements.append(UIMenu(title: title, image: iconImage, children: makeMenuElements(children)))
                continue
            }

            let destructive: Bool = entry["destructive"] as? Bool ?? false
            let enabled: Bool = entry["enabled"] as? Bool ?? true
            let checked: Bool = entry["checked"] as? Bool ?? false

            var attributes: UIMenuElement.Attributes = []
            if destructive {
                attributes.insert(.destructive)
            }
            if !enabled {
                attributes.insert(.disabled)
            }
            // An attribute, not a property on UIAction. Steppers need the menu
            // to survive the tap: a font size is set by pressing repeatedly,
            // and a menu that closes each time would have to be reopened for
            // every step.
            if #available(iOS 16.0, *), entry["keepsMenuOpen"] as? Bool == true {
                attributes.insert(.keepsMenuPresented)
            }

            let handler: UIActionHandler = { [weak self] _ in
                self?.notifyListeners("navbarItemTap", data: ["id": id])
            }

            let action = UIAction(
                title: title,
                image: iconImage,
                identifier: nil,
                discoverabilityTitle: nil,
                attributes: attributes,
                state: checked ? .on : .off,
                handler: handler
            )

            elements.append(action)
        }

        return elements
    }

    /// Builds the iOS 18+ tab objects, keeping `tabIds`/`tabTitles` in the same
    /// order the old `makeTabBarItems` produced so `notifyTabSelect(index:)`
    /// and the existing delegate plumbing keep working unchanged.
    ///
    /// The `search` role becomes a real `UISearchTab` here rather than a
    /// `UITabBarItem(tabBarSystemItem: .search)` dressed up to look like one.
    /// That is the whole point: the system draws it detached and circular, and
    /// morphs it into a search field when selected.
    @available(iOS 18.0, *)
    private func makeSystemTabs(
        _ tabs: [[String: Any]],
        selectedId: String?,
        labelVisibilityMode: String,
        icons: Bool
    ) -> ([UITab], Int?) {
        tabIds = []
        tabTitles = []
        tabDisplayTitles = []
        tabBaseImages = []
        tabSelectedImages = []

        var built: [UITab] = []
        var selectedIndex: Int?

        for (sourceIndex, tab) in tabs.enumerated() {
            let id = tab["id"] as? String ?? "tab-\(sourceIndex)"
            let isHidden = tab["hidden"] as? Bool ?? false
            if isHidden && id != selectedId {
                continue
            }

            let rawTitle = tab["title"] as? String ?? ""
            let title = tabTitle(
                rawTitle,
                id: id,
                index: built.count,
                selectedId: selectedId,
                labelVisibilityMode: labelVisibilityMode
            )
            let image = icons ? self.image(from: tab["icon"] as? [String: Any]) : nil
            let role = (tab["role"] as? String)?.lowercased()

            let entry: UITab
            if role == "search" {
                // Copy comes from the web layer, where the app's German lives.
                // Without it UIKit falls back to its own localized "Search",
                // which is English here because the bundle declares no German.
                let placeholder = tab["searchPlaceholder"] as? String
                let searchTab = UISearchTab { [weak self] _ in
                    self?.makeSearchTabController(placeholder: placeholder) ?? UIViewController()
                }
                // automaticallyActivatesSearch stays OFF: with it on, UIKit
                // presents the search controller the instant the tab is
                // selected, which races with the tab-bar morph, the WebView
                // re-host, and article-open/back navigation. That race
                // intermittently strands the .integrated (bottom) search bar
                // rendered alongside the active (top) one — a dead duplicate
                // bar the user cannot type in (KAN-751). Off means the field is
                // one tap away, with no auto-present race.
                //
                // iOS 26 only, despite UISearchTab itself dating to 18.
                if #available(iOS 26.0, *) {
                    searchTab.automaticallyActivatesSearch = false
                }
                entry = searchTab
            } else {
                entry = UITab(title: title ?? "", image: image, identifier: id) { _ in
                    nativeNavigationMakeTabContent()
                }
            }

            if id == selectedId {
                selectedIndex = built.count
            }

            tabIds.append(id)
            tabTitles.append(rawTitle)
            tabDisplayTitles.append(title)
            built.append(entry)
        }

        return (built, selectedIndex)
    }

    /// The search tab's content: a normal tab content controller (so the
    /// WebView can move into it like it does for every other tab) inside a
    /// navigation controller (so it has a `navigationItem` to hang the search
    /// controller off).
    @available(iOS 18.0, *)
    private func makeSearchTabController(placeholder: String?) -> UIViewController {
        let content = NativeNavigationTabContentController()
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        if let placeholder = placeholder, !placeholder.isEmpty {
            search.searchBar.placeholder = placeholder
        }

        let updater = NativeNavigationSearchQueryForwarder(
            onQueryChange: { [weak self] query in
                self?.notifyListeners("searchQueryChanged", data: ["query": query])
            },
            onSubmit: { [weak self] query in
                self?.notifyListeners("searchSubmit", data: ["query": query])
            },
            onCancel: { [weak self] in
                self?.mkReturnFromSearch()
            }
        )
        search.searchResultsUpdater = updater
        search.searchBar.delegate = updater
        // The forwarder is only weakly held by UISearchController, so the
        // controller has to keep it alive itself.
        content.searchQueryForwarder = updater

        content.navigationItem.searchController = search
        if #available(iOS 26.0, *) {
            content.navigationItem.preferredSearchBarPlacement = .integrated
        }

        let navigation = UINavigationController(rootViewController: content)

        // The navigation bar stays. `navigationItem.searchController` is
        // surfaced BY that bar, so hiding it leaves the navigation item inert —
        // no search field, and no tab bar morphing into one. Hiding it was the
        // single difference between this and the isolated probe where the morph
        // worked, and it cost exactly that.
        //
        // Transparent and empty instead, which costs nothing visually: with
        // `.integrated` placement the field belongs at the bottom, the bar
        // carries no title, and the WebView draws straight through it.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.compactAppearance = appearance

        return navigation
    }

    /// Assigns the tabs and moves the WebView into the selected one.
    @available(iOS 18.0, *)
    private func applySystemTabs(_ built: [UITab], selectedIndex: Int?) {
        guard let tabBarController = tabBarController else {
            return
        }

        suppressTabSelectEvent = true
        defer { suppressTabSelectEvent = false }

        guard !built.isEmpty else {
            restoreWebViewFromSystemTabController()
            tabBarController.tabs = []
            appliedSystemTabIds = []
            tabViewControllers = []
            return
        }

        // Only rebuild when the set actually changed. A re-push that merely
        // moves the selection must leave the existing tabs alone.
        if tabIds != appliedSystemTabIds || tabBarController.tabs.count != built.count {
            tabBarController.tabs = built
            appliedSystemTabIds = tabIds
        }

        let index = min(max(selectedIndex ?? tabBarController.selectedIndex, 0), built.count - 1)
        tabBarController.selectedIndex = index

        // `tabs` creates its view controller lazily, so this has to happen
        // after the selection, not before it.
        hostWebView(in: tabBarController.selectedViewController)

        tabViewControllers = tabBarController.viewControllers ?? []
    }

    private func makeTabBarItems(
        _ tabs: [[String: Any]],
        selectedId: String?,
        labelVisibilityMode: String,
        icons: Bool
    ) -> ([UITabBarItem], Int?) {
        tabIds = []
        tabTitles = []
        tabDisplayTitles = []
        tabBaseImages = []
        tabSelectedImages = []
        var selectedIndex: Int?
        var items: [UITabBarItem] = []
        var trailingEntry: (item: UITabBarItem, title: String?, image: UIImage?, selectedImage: UIImage?)?

        for (sourceIndex, tab) in tabs.enumerated() {
            let id = tab["id"] as? String ?? "tab-\(sourceIndex)"
            let isHidden = tab["hidden"] as? Bool ?? false
            if isHidden && id != selectedId {
                continue
            }

            let rawTitle = tab["title"] as? String ?? ""
            let title = tabTitle(
                rawTitle,
                id: id,
                index: items.count,
                selectedId: selectedId,
                labelVisibilityMode: labelVisibilityMode
            )
            let image = icons ? self.image(from: tab["icon"] as? [String: Any]) : nil
            let selectedImage = icons ? self.image(from: tab["selectedIcon"] as? [String: Any]) : nil
            let role = (tab["role"] as? String)?.lowercased()
            let item: UITabBarItem
            if role == "search" || role == "prominent" {
                // iOS 26+ Liquid Glass renders `.search` as a detached trailing
                // circular action beside the floating tab capsule. Keep the
                // system-item title empty so UIKit treats it as icon-only.
                item = UITabBarItem(tabBarSystemItem: .search, tag: sourceIndex)
                item.title = nil
                if let image = image {
                    item.image = image
                }
                if let selectedImage = selectedImage {
                    item.selectedImage = selectedImage
                }
                item.accessibilityLabel = rawTitle.isEmpty ? id : rawTitle
            } else {
                item = UITabBarItem(title: title, image: image, selectedImage: selectedImage)
                item.tag = sourceIndex
            }
            item.isEnabled = tab["enabled"] as? Bool ?? true
            if let badge = tab["badge"] {
                item.badgeValue = String(describing: badge)
            }
            while tabIds.count <= sourceIndex {
                tabIds.append("")
                tabTitles.append("")
            }
            tabIds[sourceIndex] = id
            tabTitles[sourceIndex] = rawTitle
            if role == "search" || role == "prominent" {
                trailingEntry = (item, title, image, selectedImage ?? image)
            } else {
                items.append(item)
                tabDisplayTitles.append(title)
                tabBaseImages.append(image)
                tabSelectedImages.append(selectedImage ?? image)
            }
        }

        if let trailingEntry = trailingEntry {
            items.append(trailingEntry.item)
            tabDisplayTitles.append(trailingEntry.title)
            tabBaseImages.append(trailingEntry.image)
            tabSelectedImages.append(trailingEntry.selectedImage)
        }
        if let selectedId = selectedId {
            selectedIndex = items.firstIndex(where: { item in
                tabIds.indices.contains(item.tag) && tabIds[item.tag] == selectedId
            })
        }

        return (items, selectedIndex)
    }

    private func makeFloatingTabBarItems(
        _ tabs: [[String: Any]],
        selectedId: String?,
        icons: Bool
    ) -> ([NativeNavigationFloatingTabItem], Int?) {
        var selectedIndex: Int?
        var items: [NativeNavigationFloatingTabItem] = []

        for (sourceIndex, tab) in tabs.enumerated() {
            let id = tab["id"] as? String ?? "tab-\(sourceIndex)"
            let isHidden = tab["hidden"] as? Bool ?? false
            if isHidden && id != selectedId {
                continue
            }

            let visibleIndex = items.count
            let title = tab["title"] as? String ?? ""
            let image = icons ? self.image(from: tab["icon"] as? [String: Any]) : nil
            let selectedImage = icons ? self.image(from: tab["selectedIcon"] as? [String: Any]) : nil
            let role = (tab["role"] as? String)?.lowercased()
            let isDetachedTrailing = role == "search" || role == "prominent"
            if id == selectedId {
                selectedIndex = visibleIndex
            }
            items.append(NativeNavigationFloatingTabItem(
                id: id,
                title: title,
                accessibilityTitle: title.isEmpty ? id : title,
                image: image,
                selectedImage: selectedImage,
                badge: tab["badge"].map { String(describing: $0) },
                enabled: tab["enabled"] as? Bool ?? true,
                isDetachedTrailing: isDetachedTrailing,
                sourceIndex: sourceIndex
            ))
        }

        // Keep at most one detached trailing action and place it last so the
        // capsule + circular button layout matches the system Liquid Glass pattern.
        // Skip reordering for curve bars so center-item selection stays stable.
        if tabbarStyle.shape == .floating,
           let trailingIndex = items.lastIndex(where: { $0.isDetachedTrailing }) {
            let trailing = items.remove(at: trailingIndex)
            items.removeAll(where: { $0.isDetachedTrailing })
            items.append(trailing)
            if let selectedId = selectedId {
                selectedIndex = items.firstIndex(where: { $0.id == selectedId })
            }
        }

        return (items, selectedIndex)
    }
    private func tabTitle(
        _ title: String?,
        id: String,
        index: Int,
        selectedId: String?,
        labelVisibilityMode: String
    ) -> String? {
        let isSelected = id == selectedId || (selectedId == nil && index == 0)
        switch labelVisibilityMode {
        case "unlabeled":
            return nil
        case "selected":
            return isSelected ? title : nil
        case "auto":
            let compact = bridge?.viewController?.traitCollection.horizontalSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone
            return compact && !isSelected ? nil : title
        default:
            return title
        }
    }

    private func image(from descriptor: [String: Any]?) -> UIImage? {
        guard let descriptor = descriptor else {
            return nil
        }
        let template = descriptor["template"] as? Bool ?? true
        if let svg = svgMarkup(from: descriptor),
           let image = SVGIconRenderer.render(svg: svg, size: iconSize(from: descriptor)) {
            return template ? image.withRenderingMode(.alwaysTemplate) : image
        }
        if let ios = descriptor["ios"] as? [String: Any] {
            if let symbol = ios["sfSymbol"] as? String, let image = UIImage(systemName: symbol) {
                return template ? image.withRenderingMode(.alwaysTemplate) : image
            }
            if let imageName = ios["image"] as? String, let image = UIImage(named: imageName) {
                return template ? image.withRenderingMode(.alwaysTemplate) : image
            }
        }
        if let svg = descriptor["svg"] as? String,
           let image = SVGIconRenderer.render(svg: svg, size: iconSize(from: descriptor)) {
            return template ? image.withRenderingMode(.alwaysTemplate) : image
        }
        if let src = descriptor["src"] as? String {
            // A raster passed inline as a data: URI. The renderer above only
            // speaks SVG, and UIImage(named:) only reads what is bundled with
            // the app, so a picture the app fetched at runtime — a user's
            // avatar — had no way in at all.
            if let image = rasterImage(fromDataURI: src, descriptor: descriptor) {
                // .alwaysOriginal, not merely "not template": a UIBarButtonItem
                // treats an image whose mode is .automatic as a template and
                // fills it with the bar's tint, which turned the avatar into a
                // flat dark disc. Only the explicit mode keeps its colours.
                return template
                    ? image.withRenderingMode(.alwaysTemplate)
                    : image.withRenderingMode(.alwaysOriginal)
            }
            if let svg = inlineSVG(from: src),
               let image = SVGIconRenderer.render(svg: svg, size: iconSize(from: descriptor)) {
                return template ? image.withRenderingMode(.alwaysTemplate) : image
            }
            if let image = UIImage(named: src) {
                return template ? image.withRenderingMode(.alwaysTemplate) : image
            }
        }
        return nil
    }

    private func svgMarkup(from descriptor: [String: Any]) -> String? {
        if let ios = descriptor["ios"] as? [String: Any],
           let svg = ios["svg"] as? String {
            return svg
        }
        if let svg = descriptor["svg"] as? String {
            return svg
        }
        if let src = descriptor["src"] as? String {
            return inlineSVG(from: src)
        }
        return nil
    }

    private func inlineSVG(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<svg") {
            return trimmed
        }
        let prefix = "data:image/svg+xml"
        guard trimmed.lowercased().hasPrefix(prefix),
              let commaIndex = trimmed.firstIndex(of: ",") else {
            return nil
        }
        let payload = String(trimmed[trimmed.index(after: commaIndex)...])
        if trimmed[..<commaIndex].contains(";base64") {
            guard let data = Data(base64Encoded: payload) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
        return payload.removingPercentEncoding
    }

    /// Decodes a `data:image/...;base64,...` URI into an image sized for a bar
    /// button, optionally masked into a circle.
    ///
    /// Returns nil for anything that is not such a URI, so the caller can fall
    /// through to the SVG and bundled-asset branches unchanged.
    ///
    /// The redraw is not optional: a bar button shows an image at its natural
    /// size, and an avatar arrives at whatever resolution its source had.
    private func rasterImage(fromDataURI src: String, descriptor: [String: Any]) -> UIImage? {
        guard src.hasPrefix("data:image/"),
              let commaIndex = src.firstIndex(of: ","),
              src[src.startIndex..<commaIndex].hasSuffix(";base64") else {
            return nil
        }

        let encoded = String(src[src.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let decoded = UIImage(data: data) else {
            return nil
        }

        let size = iconSize(from: descriptor)
        let isCircular = descriptor["circular"] as? Bool ?? false
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let bounds = CGRect(origin: .zero, size: size)
            if isCircular {
                UIBezierPath(ovalIn: bounds).addClip()
            }
            decoded.draw(in: bounds)
        }
    }

    /// Draws `base` in `tint` with a filled dot in its top-right corner, or,
    /// given `symbol`, a disc in `badge` at its bottom-right corner with that
    /// SF Symbol in white on it (a check marking "your own", say).
    ///
    /// The result is an original-mode image: it carries two colours, and a
    /// template would discard both.
    private func badged(_ base: UIImage, tint: UIColor, badge: UIColor, symbol: String? = nil) -> UIImage {
        if let symbol = symbol {
            return symbolBadged(base, tint: tint, badge: badge, symbol: symbol)
        }
        let inset = base.size.width * 0.08
        let size = CGSize(width: base.size.width + inset, height: base.size.height + inset)
        let diameter = max(base.size.width * 0.34, 6)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            tint.setFill()
            base.withRenderingMode(.alwaysTemplate)
                .draw(in: CGRect(x: 0, y: inset, width: base.size.width, height: base.size.height))

            // A ring of clear around the dot, so it reads as separate from the
            // symbol rather than as part of its silhouette.
            let dot = CGRect(
                x: size.width - diameter,
                y: 0,
                width: diameter,
                height: diameter
            )
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
            context.cgContext.setBlendMode(.normal)

            badge.setFill()
            context.cgContext.fillEllipse(in: dot)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// `badged` with an SF Symbol in the bottom-right corner instead of a dot.
    private func symbolBadged(_ base: UIImage, tint: UIColor, badge: UIColor, symbol: String) -> UIImage {
        let diameter = max(base.size.width * 0.45, 8)
        let inset = diameter * 0.25
        let size = CGSize(width: base.size.width + inset, height: base.size.height + inset)
        // Tinted explicitly: a palette configuration is not applied when a
        // symbol is drawn into a context, which left a black, invisible mark.
        let configuration = UIImage.SymbolConfiguration(weight: .bold)
        let mark = UIImage(systemName: symbol, withConfiguration: configuration)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            tint.setFill()
            base.withRenderingMode(.alwaysTemplate)
                .draw(in: CGRect(x: 0, y: 0, width: base.size.width, height: base.size.height))

            let spot = CGRect(
                x: size.width - diameter,
                y: size.height - diameter,
                width: diameter,
                height: diameter
            )
            // The same clear ring as around the dot, so the mark reads as
            // separate from the glyph beneath it.
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: spot.insetBy(dx: -1.5, dy: -1.5))
            context.cgContext.setBlendMode(.normal)

            badge.setFill()
            context.cgContext.fillEllipse(in: spot)

            // The mark centred in the disc at about half its size, kept in
            // its own proportions.
            if let mark = mark {
                let side = diameter * 0.55
                let scale = min(side / max(mark.size.width, 1), side / max(mark.size.height, 1))
                let markSize = CGSize(width: mark.size.width * scale, height: mark.size.height * scale)
                mark.draw(in: CGRect(
                    x: spot.midX - markSize.width / 2,
                    y: spot.midY - markSize.height / 2,
                    width: markSize.width,
                    height: markSize.height
                ))
            }
        }.withRenderingMode(.alwaysOriginal)
    }

    private func iconSize(from descriptor: [String: Any]) -> CGSize {
        let width = number(from: descriptor["width"]) ?? 24
        let height = number(from: descriptor["height"]) ?? width
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    private func number(from value: Any?) -> CGFloat? {
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        if let value = value as? String,
           let number = Double(value) {
            return CGFloat(number)
        }
        return nil
    }

    private func transitionRect(_ rawRect: [String: Any]?) -> CGRect? {
        guard let rawRect = rawRect,
              let width = number(from: rawRect["width"]),
              let height = number(from: rawRect["height"]),
              width > 0,
              height > 0 else {
            return nil
        }

        return CGRect(
            x: number(from: rawRect["x"]) ?? 0,
            y: number(from: rawRect["y"]) ?? 0,
            width: width,
            height: height
        )
    }

    private func transitionFrame(for viewportRect: CGRect, webView: UIView) -> CGRect {
        guard let transitionContainer = webView.superview else {
            return CGRect(
                x: webView.frame.minX + viewportRect.minX,
                y: webView.frame.minY + viewportRect.minY,
                width: viewportRect.width,
                height: viewportRect.height
            )
        }
        return webView.convert(viewportRect, to: transitionContainer)
    }

    private func transitionSnapshotView(from webView: UIView, sourceRect: CGRect?) -> UIView {
        guard let sourceRect = sourceRect else {
            return webView.snapshotView(afterScreenUpdates: false) ?? nativeNavigationSnapshotPlaceholder(for: webView)
        }

        let cropRect = sourceRect.intersection(webView.bounds)
        guard cropRect.width > 0, cropRect.height > 0 else {
            return webView.snapshotView(afterScreenUpdates: false) ?? nativeNavigationSnapshotPlaceholder(for: webView)
        }

        let renderer = UIGraphicsImageRenderer(bounds: webView.bounds)
        let image = renderer.image { _ in
            webView.drawHierarchy(in: webView.bounds, afterScreenUpdates: false)
        }
        let scale = image.scale
        let scaledCropRect = CGRect(
            x: cropRect.minX * scale,
            y: cropRect.minY * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale
        ).integral

        guard let croppedImage = image.cgImage?.cropping(to: scaledCropRect) else {
            return webView.snapshotView(afterScreenUpdates: false) ?? nativeNavigationSnapshotPlaceholder(for: webView)
        }

        let imageView = UIImageView(image: UIImage(cgImage: croppedImage, scale: scale, orientation: image.imageOrientation))
        imageView.contentMode = .scaleAspectFill
        return imageView
    }

    private func makeTabbarStyle(from call: CAPPluginCall) -> NativeNavigationTabbarStyleConfig {
        let rawStyle = call.getObject("style") ?? [:]
        let requestedShape = (rawStyle["shape"] as? String)?.lowercased()
        let shape: NativeNavigationTabbarShape = requestedShape == "curve" ? .curve : .floating
        let isCurve = shape == .curve
        let centerDiameter = max(number(from: rawStyle["centerButtonDiameter"]) ?? 56, 44)
        let height = max(number(from: rawStyle["height"]) ?? (isCurve ? 76 : 64), 44)
        let centerLift = max(number(from: rawStyle["centerButtonLift"]) ?? (centerDiameter / 2), 0)
        let bottomGap = max(number(from: rawStyle["bottomGap"]) ?? (isCurve ? 0 : 10), 0)
        let horizontalMargin = max(number(from: rawStyle["horizontalMargin"]) ?? (isCurve ? 0 : 24), 0)
        let maxWidth = max(number(from: rawStyle["maxWidth"]) ?? (isCurve ? 0 : 430), 0)
        let cornerRadius = max(number(from: rawStyle["cornerRadius"]) ?? (isCurve ? 0 : height / 2), 0)
        let centerButtonColor = (rawStyle["centerButtonColor"] as? String).flatMap { UIColor(hexString: $0) }
        let centerButtonIconColor = (rawStyle["centerButtonIconColor"] as? String).flatMap { UIColor(hexString: $0) } ?? .white

        return NativeNavigationTabbarStyleConfig(
            shape: shape,
            height: height,
            horizontalMargin: horizontalMargin,
            maxWidth: maxWidth,
            bottomGap: bottomGap,
            cornerRadius: cornerRadius,
            centerItemId: rawStyle["centerItemId"] as? String,
            centerButtonDiameter: centerDiameter,
            centerButtonLift: centerLift,
            centerButtonColor: centerButtonColor,
            centerButtonIconColor: centerButtonIconColor
        )
    }
    private func applyNavBarAppearance(navBar: UINavigationBar, options call: CAPPluginCall) {
        let appearance = UINavigationBarAppearance()
        let transparent = call.getBool("transparent", false)
        if usesSystemLiquidGlass && transparent {
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = .clear
            appearance.backgroundEffect = nil
            appearance.shadowColor = .clear
            navBlurView?.isHidden = true
        } else if usesSystemLiquidGlass {
            // Still transparent, and not for lack of trying: a
            // UIVisualEffectView cannot blur WKWebView content. The web view
            // renders out of process and hands UIKit a remote layer, so there
            // is nothing behind the effect view to sample and the result is a
            // flat tint. The article page draws its own backdrop-filter scrim
            // instead, inside the web view where the blur works.
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = .clear
            appearance.backgroundEffect = nil
            appearance.shadowColor = .clear
            navBlurView?.isHidden = true
        } else if transparent {
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = .clear
            appearance.shadowColor = .clear
            if let effect = blurEffect(from: call.getString("blurEffect"), fallback: .systemChromeMaterial) {
                navBlurView?.effect = effect
                navBlurView?.isHidden = false
            } else {
                navBlurView?.isHidden = true
            }
        } else {
            appearance.configureWithDefaultBackground()
            navBlurView?.isHidden = true
        }

        if let colors = call.getObject("colors") {
            if let color = colorValue(colors["tint"]) {
                navBar.tintColor = color
            }
            if let color = colorValue(colors["foreground"]) {
                appearance.titleTextAttributes = [.foregroundColor: color]
                appearance.largeTitleTextAttributes = [.foregroundColor: color]
            }
            if let background = colors["background"] as? String,
               let color = colorValue(background),
               !usesSystemLiquidGlass,
               !transparent {
                appearance.backgroundColor = color
            }
        }

        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        navBar.compactAppearance = appearance
    }

    private func applyTabBarAppearance(tabBar: UITabBar, options call: CAPPluginCall) {
        if usesSystemLiquidGlass {
            let standardAppearance = UITabBarAppearance()
            configureSystemTabBarStandardBackground(standardAppearance)
            applyTabBarColorOptions(standardAppearance, tabBar: tabBar, options: call)
            applyTabBarBadgeOptions(standardAppearance, options: call)

            let scrollEdgeAppearance = UITabBarAppearance()
            configureSystemTabBarScrollEdgeBackground(scrollEdgeAppearance, options: call)
            applyTabBarColorOptions(scrollEdgeAppearance, tabBar: tabBar, options: call)
            applyTabBarBadgeOptions(scrollEdgeAppearance, options: call)

            tabBar.isTranslucent = !prefersOpaqueTabBarBackground()
            tabBar.standardAppearance = standardAppearance
            if #available(iOS 15.0, *) {
                tabBar.scrollEdgeAppearance = scrollEdgeAppearance
            }
            tabBar.items?.forEach { item in
                item.standardAppearance = standardAppearance
                if #available(iOS 15.0, *) {
                    item.scrollEdgeAppearance = scrollEdgeAppearance
                }
            }
            applyExperimentalBakedTintColors(tabBar: tabBar, options: call)
            return
        }

        let appearance = UITabBarAppearance()
        configureTabBarBackground(appearance, options: call)
        applyTabBarColorOptions(appearance, tabBar: tabBar, options: call)
        applyTabBarBadgeOptions(appearance, options: call)

        tabBar.standardAppearance = appearance
        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }
    }

    private func configureTabBarBackground(_ appearance: UITabBarAppearance, options call: CAPPluginCall) {
        appearance.configureWithDefaultBackground()
        if prefersOpaqueTabBarBackground() {
            tabEffectView?.isHidden = true
            return
        }
        if let effect = blurEffect(from: call.getString("blurEffect"), fallback: nil) {
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = .clear
            tabEffectView?.effect = effect
            tabEffectView?.isHidden = false
        } else {
            tabEffectView?.isHidden = true
        }
    }

    private func configureSystemTabBarStandardBackground(_ appearance: UITabBarAppearance) {
        appearance.configureWithDefaultBackground()
    }

    private func configureSystemTabBarScrollEdgeBackground(_ appearance: UITabBarAppearance, options call: CAPPluginCall) {
        if call.getBool("disableTransparentOnScrollEdge", false) || prefersOpaqueTabBarBackground() {
            configureSystemTabBarStandardBackground(appearance)
        } else {
            appearance.configureWithTransparentBackground()
            appearance.shadowColor = .clear
        }
    }

    private func applyTabBarColorOptions(
        _ appearance: UITabBarAppearance,
        tabBar: UITabBar,
        options call: CAPPluginCall
    ) {
        if let colors = call.getObject("colors") {
            if let color = colorValue(colors["tint"]) {
                tabBar.tintColor = color
                applyTabItemAppearances(appearance) { itemAppearance in
                    itemAppearance.selected.iconColor = color
                    itemAppearance.selected.titleTextAttributes = [.foregroundColor: color]
                }
            }
            if let color = colorValue(colors["inactiveTint"]), !usesSystemLiquidGlass {
                tabBar.unselectedItemTintColor = color
                applyTabItemAppearances(appearance) { itemAppearance in
                    itemAppearance.normal.iconColor = color
                    itemAppearance.normal.titleTextAttributes = [.foregroundColor: color]
                }
            }
            if let color = colorValue(colors["badgeBackground"]) {
                applyTabItemAppearances(appearance) { itemAppearance in
                    itemAppearance.normal.badgeBackgroundColor = color
                    itemAppearance.selected.badgeBackgroundColor = color
                }
            }
            if let color = colorValue(colors["badgeText"]) {
                applyTabItemAppearances(appearance) { itemAppearance in
                    itemAppearance.normal.badgeTextAttributes = [.foregroundColor: color]
                    itemAppearance.selected.badgeTextAttributes = [.foregroundColor: color]
                }
            }
            if let background = colors["background"] as? String,
               let color = colorValue(background),
               !usesSystemLiquidGlass {
                appearance.backgroundColor = color
            }
        }
    }

    private func applyFloatingTabBarAppearance(tabBar: NativeNavigationFloatingTabBar, options call: CAPPluginCall) {
        let colors = call.getObject("colors")
        let backgroundTint = colorValue(colors?["background"])
        let backgroundColor = (backgroundTint ?? .systemBackground).withAlphaComponent(tabbarStyle.shape == .curve ? 0.96 : 0.46)
        let usesLiquidGlass = liquidGlassEffect() != nil

        if tabbarStyle.shape == .curve || prefersOpaqueTabBarBackground() {
            tabEffectView?.isHidden = true
            trailingTabEffectView?.isHidden = true
        } else if let glass = liquidGlassEffect() {
            tabEffectView?.effect = glass
            tabEffectView?.isHidden = false
            tabEffectView?.contentView.backgroundColor = backgroundTint?.withAlphaComponent(0.08) ?? .clear
            trailingTabEffectView?.effect = liquidGlassEffect() ?? glass
            trailingTabEffectView?.contentView.backgroundColor = backgroundTint?.withAlphaComponent(0.08) ?? .clear
        } else if let effect = blurEffect(from: call.getString("blurEffect"), fallback: .systemChromeMaterial) {
            tabEffectView?.effect = effect
            tabEffectView?.isHidden = false
            tabEffectView?.contentView.backgroundColor = backgroundTint?.withAlphaComponent(0.12) ?? backgroundColor
            trailingTabEffectView?.effect = effect
            trailingTabEffectView?.contentView.backgroundColor = backgroundTint?.withAlphaComponent(0.12) ?? backgroundColor
        } else {
            tabEffectView?.isHidden = true
            trailingTabEffectView?.isHidden = true
        }

        let opaqueBackground = backgroundTint ?? .systemBackground
        if prefersOpaqueTabBarBackground() {
            tabBar.backgroundFillColor = opaqueBackground
        } else if usesLiquidGlass {
            // Keep the hand-drawn fill clear so UIGlassEffect can show through.
            tabBar.backgroundFillColor = .clear
        } else {
            tabBar.backgroundFillColor = backgroundColor
        }
        if let color = colorValue(colors?["tint"]) {
            tabBar.selectedTintColor = color
        }
        if let color = colorValue(colors?["inactiveTint"]) {
            tabBar.inactiveTintColor = color
        }
        if let color = colorValue(call.getString("badgeBackgroundColor")) ?? colorValue(colors?["badgeBackground"]) {
            tabBar.badgeBackgroundColor = color
        }
        if let color = colorValue(call.getString("badgeTextColor")) ?? colorValue(colors?["badgeText"]) {
            tabBar.badgeTextColor = color
        }
        tabBar.setNeedsLayout()
    }

    private func applyTabBarBadgeOptions(_ appearance: UITabBarAppearance, options call: CAPPluginCall) {
        if let color = colorValue(call.getString("badgeBackgroundColor")) {
            applyTabItemAppearances(appearance) { itemAppearance in
                itemAppearance.normal.badgeBackgroundColor = color
                itemAppearance.selected.badgeBackgroundColor = color
            }
        }
        if let color = colorValue(call.getString("badgeTextColor")) {
            applyTabItemAppearances(appearance) { itemAppearance in
                itemAppearance.normal.badgeTextAttributes = [.foregroundColor: color]
                itemAppearance.selected.badgeTextAttributes = [.foregroundColor: color]
            }
        }
    }

    private func applyExperimentalBakedTintColors(tabBar: UITabBar, options call: CAPPluginCall) {
        guard shouldUseExperimentalBakedTintColors(options: call),
              let items = tabBar.items,
              let colors = call.getObject("colors") else {
            return
        }

        let activeTint = colorValue(colors["tint"]) ?? tabBar.tintColor ?? .tintColor
        let inactiveTint = colorValue(colors["inactiveTint"]) ?? tabBar.unselectedItemTintColor ?? .secondaryLabel
        guard colorValue(colors["tint"]) != nil || colorValue(colors["inactiveTint"]) != nil else {
            return
        }

        let labelVisibilityMode = tabLabelVisibilityMode(options: call)
        for (index, item) in items.enumerated() {
            let visibleTitle = tabDisplayTitles.indices.contains(index) ? (tabDisplayTitles[index] ?? "") : (item.title ?? "")
            let rawTitle = tabTitles.indices.contains(item.tag) ? tabTitles[item.tag] : visibleTitle
            let titles = bakedTintTitles(rawTitle: rawTitle, visibleTitle: visibleTitle, labelVisibilityMode: labelVisibilityMode)
            let icon = tabBaseImages.indices.contains(index) ? (tabBaseImages[index] ?? item.image) : item.image
            let selectedIcon = tabSelectedImages.indices.contains(index)
                ? (tabSelectedImages[index] ?? icon)
                : icon
            guard !titles.normal.isEmpty || !titles.selected.isEmpty || icon != nil || selectedIcon != nil else {
                continue
            }

            let accessibilityTitle = rawTitle.isEmpty ? visibleTitle : rawTitle
            if !accessibilityTitle.isEmpty {
                item.accessibilityLabel = accessibilityTitle
            }
            item.title = ""
            item.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: 100)
            item.image = makeTabBarItemImage(icon: icon, title: titles.normal, color: inactiveTint)
            item.selectedImage = makeTabBarItemImage(icon: selectedIcon, title: titles.selected, color: activeTint)
        }
    }

    private func shouldUseExperimentalBakedTintColors(options call: CAPPluginCall) -> Bool {
        guard usesSystemLiquidGlass,
              call.getBool("experimentalBakedTintColors", false) else {
            return false
        }

        return ["auto", "selected", "labeled", "unlabeled"].contains(tabLabelVisibilityMode(options: call))
    }

    private func tabLabelVisibilityMode(options call: CAPPluginCall) -> String {
        let labels = call.getBool("labels", true)
        return call.getString("labelVisibilityMode") ?? (labels ? "labeled" : "unlabeled")
    }

    private func bakedTintTitles(rawTitle: String, visibleTitle: String, labelVisibilityMode: String) -> (normal: String, selected: String) {
        switch labelVisibilityMode {
        case "unlabeled":
            return (normal: "", selected: "")
        case "selected":
            return (normal: "", selected: rawTitle)
        case "auto":
            let compact = bridge?.viewController?.traitCollection.horizontalSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone
            return compact ? (normal: "", selected: rawTitle) : (normal: rawTitle, selected: rawTitle)
        case "labeled":
            return (normal: rawTitle, selected: rawTitle)
        default:
            return (normal: visibleTitle, selected: visibleTitle)
        }
    }

    private func makeTabBarItemImage(icon: UIImage?, title: String, color: UIColor) -> UIImage {
        let iconSize = CGSize(width: 27, height: 27)
        let font = UIFont.systemFont(ofSize: 10, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        let hasTitle = !title.isEmpty
        let titleSize = hasTitle ? (title as NSString).size(withAttributes: attributes) : .zero
        let imageSize = hasTitle
            ? CGSize(width: max(iconSize.width, ceil(titleSize.width)) + 8, height: iconSize.height + 3 + ceil(titleSize.height))
            : iconSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale

        let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
            if let icon {
                let tintedIcon = icon.withTintColor(color, renderingMode: .alwaysOriginal)
                let iconFrame = aspectFitRect(
                    size: tintedIcon.size,
                    in: CGRect(
                        x: (imageSize.width - iconSize.width) / 2,
                        y: 0,
                        width: iconSize.width,
                        height: iconSize.height
                    )
                )
                tintedIcon.draw(in: iconFrame)
            }
            if hasTitle {
                (title as NSString).draw(
                    in: CGRect(
                        x: 0,
                        y: iconSize.height + 3,
                        width: imageSize.width,
                        height: ceil(titleSize.height)
                    ),
                    withAttributes: attributes
                )
            }
        }

        return image.withRenderingMode(.alwaysOriginal)
    }

    private func aspectFitRect(size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return rect
        }

        let scale = min(rect.width / size.width, rect.height / size.height)
        let fittedSize = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: rect.minX + (rect.width - fittedSize.width) / 2,
            y: rect.minY + (rect.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func applyTabItemAppearances(
        _ appearance: UITabBarAppearance,
        update: (UITabBarItemAppearance) -> Void
    ) {
        update(appearance.stackedLayoutAppearance)
        update(appearance.inlineLayoutAppearance)
        update(appearance.compactInlineLayoutAppearance)
    }

    private func layoutChrome() {
        guard let rootView = bridge?.viewController?.view else {
            return
        }

        // Applied here rather than from hostWebView, which only runs while the
        // web view lives inside a tab's content controller. On the article page
        // the tab bar is hidden, which pulls the web view back out again — so
        // the one screen that needs the effect most was the one screen that
        // never got it. layoutChrome runs on every chrome change, and setting
        // the style is idempotent.
        if let webView = webView {
            applyScrollEdgeEffects(to: webView)
        }

        rootView.layoutIfNeeded()
        let safeInsets = rootView.safeAreaInsets
        let width = rootView.bounds.width
        let height = rootView.bounds.height

        if let container = systemTabRootContainer {
            container.frame = rootView.bounds
            webView?.frame = container.bounds
        }

        if let container = navContainer {
            container.frame = CGRect(x: 0, y: 0, width: width, height: safeInsets.top + navbarHeight)
            navBlurView?.frame = container.bounds
            navBar?.frame = CGRect(x: 0, y: safeInsets.top, width: width, height: navbarHeight)
        }

        if let container = tabContainer {
            let availableWidth = max(0, width - (tabbarStyle.horizontalMargin * 2))
            let maxWidth = tabbarStyle.maxWidth > 0 ? tabbarStyle.maxWidth : availableWidth
            let hasDetachedTrailing = floatingTabBar?.hasDetachedTrailing == true && tabbarStyle.shape == .floating
            let trailingDiameter = tabbarStyle.height
            let trailingGap: CGFloat = 10
            let trailingExtra = hasDetachedTrailing ? trailingDiameter + trailingGap : 0
            let tabbarWidth = min(availableWidth, maxWidth + trailingExtra)
            let originX = (width - tabbarWidth) / 2
            let originY = height - safeInsets.bottom - tabbarStyle.bottomGap - tabbarStyle.totalHeight
            container.frame = CGRect(x: originX, y: originY, width: tabbarWidth, height: tabbarStyle.totalHeight)
            floatingTabBar?.frame = container.bounds
            floatingTabBar?.layer.cornerRadius = 0
            floatingTabBar?.layoutIfNeeded()

            let capsuleBounds = floatingTabBar?.capsuleBounds(in: container.bounds) ?? container.bounds
            container.layer.cornerRadius = tabbarStyle.shape == .floating ? tabbarStyle.cornerRadius : 0
            container.layer.shadowPath = NativeNavigationTabbarBackgroundPath.path(in: capsuleBounds, style: tabbarStyle).cgPath
            tabEffectView?.frame = capsuleBounds
            tabEffectView?.layer.cornerRadius = tabbarStyle.shape == .floating ? tabbarStyle.cornerRadius : 0
            tabEffectView?.isHidden = tabbarStyle.shape == .curve || prefersOpaqueTabBarBackground() || tabEffectView?.effect == nil

            if let trailingBounds = floatingTabBar?.trailingActionBounds(in: container.bounds),
               hasDetachedTrailing,
               !prefersOpaqueTabBarBackground() {
                trailingTabEffectView?.frame = trailingBounds
                trailingTabEffectView?.layer.cornerRadius = trailingBounds.height / 2
                trailingTabEffectView?.isHidden = trailingTabEffectView?.effect == nil
            } else {
                trailingTabEffectView?.isHidden = true
            }
        }

        if let toolbar = toolbar, toolbarVisible {
            // When slid away for scrolling, sit fully below the screen; a layout
            // pass must honour that or it would snap the bar back into view.
            let y = toolbarScrolledAway ? height : (height - safeInsets.bottom - toolbarHeight)
            toolbar.frame = CGRect(x: 0, y: y, width: width, height: toolbarHeight)
        }
        layoutBottomScrim()
        layoutTopScrim()

        if let tabBarController = tabBarController {
            tabBarController.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            tabBarController.view.setNeedsLayout()
            tabBarController.view.layoutIfNeeded()
        }

        bringChromeToFront()
    }

    private func bringChromeToFront() {
        // Scrim first, then the toolbar on top of it, both above the web view.
        if let scrim = bottomScrim, toolbarVisible {
            bridge?.viewController?.view.bringSubviewToFront(scrim)
        }
        if let toolbar = toolbar, toolbarVisible {
            bridge?.viewController?.view.bringSubviewToFront(toolbar)
        }
        // Top scrim above the web view; the navbar container is brought forward
        // below and so ends up on top of it.
        if let topScrim = topScrim, !topScrim.isHidden {
            bridge?.viewController?.view.bringSubviewToFront(topScrim)
        }
        if usesSystemLiquidGlass && tabbarStyle.shape != .curve {
            if let navContainer = navContainer {
                bridge?.viewController?.view.bringSubviewToFront(navContainer)
            }
            bringLiftedWebViewOverlaysToFront()
            return
        }

        if let navContainer = navContainer {
            bridge?.viewController?.view.bringSubviewToFront(navContainer)
        }
        if let tabContainer = tabContainer {
            bridge?.viewController?.view.bringSubviewToFront(tabContainer)
        }
        if let tabBarController = tabBarController {
            bridge?.viewController?.view.bringSubviewToFront(tabBarController.view)
        }
    }

    private func colorValue(_ value: Any?) -> UIColor? {
        guard let value = value as? String else {
            return nil
        }

        switch value {
        case "ios:label", "system:label":
            return .label
        case "ios:secondaryLabel", "system:secondaryLabel":
            return .secondaryLabel
        case "ios:systemBackground", "system:background":
            return .systemBackground
        case "ios:secondarySystemBackground", "system:secondaryBackground":
            return .secondarySystemBackground
        default:
            return UIColor(hexString: value)
        }
    }

    private func blurEffect(from value: String?, fallback: UIBlurEffect.Style?) -> UIBlurEffect? {
        guard value != "none" else {
            return nil
        }
        guard let style = blurStyle(from: value) ?? fallback else {
            return nil
        }
        return UIBlurEffect(style: style)
    }

    private func blurStyle(from value: String?) -> UIBlurEffect.Style? {
        guard let value = value else {
            return nil
        }
        return [
            "extraLight": .extraLight,
            "light": .light,
            "dark": .dark,
            "regular": .regular,
            "prominent": .prominent,
            "systemUltraThinMaterial": .systemUltraThinMaterial,
            "systemThinMaterial": .systemThinMaterial,
            "systemMaterial": .systemMaterial,
            "systemThickMaterial": .systemThickMaterial,
            "systemUltraThinMaterialLight": .systemUltraThinMaterialLight,
            "systemThinMaterialLight": .systemThinMaterialLight,
            "systemMaterialLight": .systemMaterialLight,
            "systemThickMaterialLight": .systemThickMaterialLight,
            "systemUltraThinMaterialDark": .systemUltraThinMaterialDark,
            "systemThinMaterialDark": .systemThinMaterialDark,
            "systemMaterialDark": .systemMaterialDark,
            "systemThickMaterialDark": .systemThickMaterialDark,
            "systemDefault": .systemChromeMaterial,
            "systemChromeMaterial": .systemChromeMaterial,
            "systemChromeMaterialLight": .systemChromeMaterialLight,
            "systemChromeMaterialDark": .systemChromeMaterialDark
        ][value]
    }

    private func liquidGlassEffect() -> UIVisualEffect? {
        guard usesSystemLiquidGlass,
              let effectClass = NSClassFromString("UIGlassEffect") else {
            return nil
        }

        let styleSelector = NSSelectorFromString("effectWithStyle:")
        if let method = class_getClassMethod(effectClass, styleSelector) {
            typealias EffectWithStyle = @convention(c) (AnyClass, Selector, Int) -> AnyObject?
            let factory = unsafeBitCast(method_getImplementation(method), to: EffectWithStyle.self)
            if let effect = factory(effectClass, styleSelector, 0) as? UIVisualEffect {
                return effect
            }
        }

        if let objectType = effectClass as? NSObject.Type {
            return objectType.init() as? UIVisualEffect
        }

        return nil
    }

    private func configureGlassBarButtonItem(_ item: UIBarButtonItem, id: String) {
        guard #available(iOS 26.0, *) else {
            return
        }

        // Keep older SDK builds working while adopting the native iOS 26 bar
        // button Liquid Glass grouping APIs when the runtime exposes them.
        let object = item as NSObject
        if object.responds(to: NSSelectorFromString("setIdentifier:")) {
            object.setValue(id, forKey: "identifier")
        }
        if object.responds(to: NSSelectorFromString("setSharesBackground:")) {
            object.setValue(true, forKey: "sharesBackground")
        }
        if object.responds(to: NSSelectorFromString("setHidesSharedBackground:")) {
            object.setValue(false, forKey: "hidesSharedBackground")
        }
    }

    private func currentInsets() -> [String: Any] {
        let safeInsets = bridge?.viewController?.view.safeAreaInsets ?? .zero
        // The hosted bar is inside the web view's own safe area, so the page
        // already reserves it through env(safe-area-inset-top); reporting the
        // height here as well would reserve the strip twice.
        let navHeight = isEnabled && navbarVisible && !navbarUsesHostedController
            ? navbarHeight + safeInsets.top
            : 0
        let usesSystemTabbar = usesSystemLiquidGlass && tabbarStyle.shape != .curve
        let nativeTabHeight = max(tabBar?.frame.height ?? 0, 49 + safeInsets.bottom)
        let customTabHeight = tabbarHeight + safeInsets.bottom + tabbarStyle.bottomGap
        let tabHeight = isEnabled && tabbarVisible ? (usesSystemTabbar ? nativeTabHeight : customTabHeight) : 0
        // The article toolbar and the tab bar never share the screen (the tab
        // bar is hidden on detail), so the larger of the two is the bottom inset.
        let toolbarInset = isEnabled && toolbarVisible ? toolbarHeight + safeInsets.bottom : 0
        let bottom = max(tabHeight, toolbarInset)
        return [
            "top": navHeight,
            "right": safeInsets.right,
            "bottom": bottom,
            "left": safeInsets.left,
            "navbarHeight": navHeight,
            "tabbarHeight": tabHeight
        ]
    }

    private func insetsResult() -> [String: Any] {
        return ["insets": currentInsets()]
    }

    private func updateInsetsAndNotify() {
        layoutChrome()
        let insets = currentInsets()
        notifyListeners("safeAreaChanged", data: ["insets": insets])
        guard contentInsetMode != "none" else {
            return
        }
        let top = insets["top"] as? CGFloat ?? 0
        let right = insets["right"] as? CGFloat ?? 0
        let bottom = insets["bottom"] as? CGFloat ?? 0
        let left = insets["left"] as? CGFloat ?? 0
        let navbar = insets["navbarHeight"] as? CGFloat ?? 0
        let tabbar = insets["tabbarHeight"] as? CGFloat ?? 0
        let detailJson = jsonString(["insets": insets])
        let script = """
        (() => {
          const root = document.documentElement;
          root.style.setProperty('--cap-native-navigation-top', '\(top)px');
          root.style.setProperty('--cap-native-navigation-right', '\(right)px');
          root.style.setProperty('--cap-native-navigation-bottom', '\(bottom)px');
          root.style.setProperty('--cap-native-navigation-left', '\(left)px');
          root.style.setProperty('--cap-native-navbar-height', '\(navbar)px');
          root.style.setProperty('--cap-native-tabbar-height', '\(tabbar)px');
          window.dispatchEvent(new CustomEvent('capNativeNavigation:safeAreaChanged', { detail: \(detailJson) }));
        })();
        """
        bridge?.webView?.evaluateJavaScript(script)
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
// swiftlint:enable type_body_length

// swiftlint:disable cyclomatic_complexity function_body_length identifier_name
private struct SVGRenderStyle {
    var fill = true
    var stroke = false
    var strokeWidth: CGFloat = 2
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var opacity: CGFloat = 1

    mutating func apply(_ attributes: [String: String]) {
        if let fillValue = attributes["fill"] {
            fill = fillValue.lowercased() != "none"
        }
        if let strokeValue = attributes["stroke"] {
            stroke = strokeValue.lowercased() != "none"
        }
        if let width = SVGIconRenderer.length(attributes["stroke-width"]) {
            strokeWidth = width
        }
        if let opacityValue = SVGIconRenderer.length(attributes["opacity"]) {
            opacity = max(0, min(opacityValue, 1))
        }
        if let cap = attributes["stroke-linecap"]?.lowercased() {
            switch cap {
            case "round":
                lineCap = .round
            case "square":
                lineCap = .square
            default:
                lineCap = .butt
            }
        }
        if let join = attributes["stroke-linejoin"]?.lowercased() {
            switch join {
            case "round":
                lineJoin = .round
            case "bevel":
                lineJoin = .bevel
            default:
                lineJoin = .miter
            }
        }
    }
}
private struct NativeNavigationFloatingTabItem {
    let id: String
    let title: String
    let accessibilityTitle: String
    let image: UIImage?
    let selectedImage: UIImage?
    let badge: String?
    let enabled: Bool
    let isDetachedTrailing: Bool
    let sourceIndex: Int
}

private enum NativeNavigationTabbarShape {
    case floating
    case curve
}

private struct NativeNavigationTabbarStyleConfig {
    var shape: NativeNavigationTabbarShape = .floating
    var height: CGFloat = 64
    var horizontalMargin: CGFloat = 24
    var maxWidth: CGFloat = 430
    var bottomGap: CGFloat = 10
    var cornerRadius: CGFloat = 32
    var centerItemId: String?
    var centerButtonDiameter: CGFloat = 56
    var centerButtonLift: CGFloat = 28
    var centerButtonColor: UIColor?
    var centerButtonIconColor: UIColor = .white

    var barTop: CGFloat {
        shape == .curve ? centerButtonLift : 0
    }

    var totalHeight: CGFloat {
        height + barTop
    }
}

private enum NativeNavigationTabbarBackgroundPath {
    static func path(in bounds: CGRect, style: NativeNavigationTabbarStyleConfig) -> UIBezierPath {
        guard style.shape == .curve else {
            return UIBezierPath(roundedRect: bounds, cornerRadius: style.cornerRadius)
        }

        let barRect = CGRect(x: 0, y: style.barTop, width: bounds.width, height: max(style.height, 1))
        let cornerRadius = min(style.cornerRadius, barRect.height / 2)
        let centerX = bounds.midX
        let centerRadius = style.centerButtonDiameter / 2
        let centerTop = max(0, barRect.minY - style.centerButtonLift)
        let centerY = centerTop + centerRadius
        let dyToBarTop = barRect.minY - centerY
        let shoulderWidth = sqrt(max(0, centerRadius * centerRadius - dyToBarTop * dyToBarTop))
        let leftShoulder = max(barRect.minX + cornerRadius, centerX - shoulderWidth)
        let startAngle = atan2(dyToBarTop, -shoulderWidth)
        var endAngle = atan2(dyToBarTop, shoulderWidth)
        if endAngle <= startAngle {
            endAngle += .pi * 2
        }
        let path = UIBezierPath()

        path.move(to: CGPoint(x: barRect.minX + cornerRadius, y: barRect.minY))
        path.addLine(to: CGPoint(x: leftShoulder, y: barRect.minY))
        if shoulderWidth > 0 {
            path.addArc(withCenter: CGPoint(x: centerX, y: centerY), radius: centerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        }
        path.addLine(to: CGPoint(x: barRect.maxX - cornerRadius, y: barRect.minY))
        path.addQuadCurve(to: CGPoint(x: barRect.maxX, y: barRect.minY + cornerRadius), controlPoint: CGPoint(x: barRect.maxX, y: barRect.minY))
        path.addLine(to: CGPoint(x: barRect.maxX, y: barRect.maxY - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: barRect.maxX - cornerRadius, y: barRect.maxY), controlPoint: CGPoint(x: barRect.maxX, y: barRect.maxY))
        path.addLine(to: CGPoint(x: barRect.minX + cornerRadius, y: barRect.maxY))
        path.addQuadCurve(to: CGPoint(x: barRect.minX, y: barRect.maxY - cornerRadius), controlPoint: CGPoint(x: barRect.minX, y: barRect.maxY))
        path.addLine(to: CGPoint(x: barRect.minX, y: barRect.minY + cornerRadius))
        path.addQuadCurve(to: CGPoint(x: barRect.minX + cornerRadius, y: barRect.minY), controlPoint: CGPoint(x: barRect.minX, y: barRect.minY))
        path.close()
        return path
    }
}

private struct NativeNavigationFloatingTabStyle {
    let selected: Bool
    let labels: Bool
    let icons: Bool
    let isCenter: Bool
    let isDetachedTrailing: Bool
    let selectedTint: UIColor
    let inactiveTint: UIColor
    let centerButtonColor: UIColor
    let centerButtonIconColor: UIColor
    let badgeBackgroundColor: UIColor
    let badgeTextColor: UIColor
}

private final class NativeNavigationFloatingTabBar: UIView {
    private var items: [NativeNavigationFloatingTabItem] = []
    private var buttons: [NativeNavigationFloatingTabButton] = []
    private var labelVisibilityMode = "labeled"
    private var iconsVisible = true
    private let backgroundShapeView = NativeNavigationTabbarBackgroundView()
    private var tabbarStyle = NativeNavigationTabbarStyleConfig()

    var selectedIndex = 0
    var selectedTintColor = UIColor.systemBlue {
        didSet { updateButtons() }
    }
    var inactiveTintColor = UIColor.secondaryLabel {
        didSet { updateButtons() }
    }
    var badgeBackgroundColor = UIColor.systemRed {
        didSet { updateButtons() }
    }
    var badgeTextColor = UIColor.white {
        didSet { updateButtons() }
    }
    var backgroundFillColor = UIColor.systemBackground.withAlphaComponent(0.46) {
        didSet {
            backgroundShapeView.fillColor = backgroundFillColor
        }
    }
    var onSelect: ((Int, NativeNavigationFloatingTabItem) -> Void)?

    var hasDetachedTrailing: Bool {
        tabbarStyle.shape == .floating && items.contains(where: \.isDetachedTrailing)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundShapeView.isUserInteractionEnabled = false
        backgroundShapeView.fillColor = backgroundFillColor
        addSubview(backgroundShapeView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        items: [NativeNavigationFloatingTabItem],
        selectedIndex: Int,
        labelVisibilityMode: String,
        icons: Bool,
        style: NativeNavigationTabbarStyleConfig
    ) {
        self.items = items
        self.labelVisibilityMode = labelVisibilityMode
        self.iconsVisible = icons
        self.tabbarStyle = style
        self.selectedIndex = items.indices.contains(selectedIndex) ? selectedIndex : 0
        backgroundShapeView.style = style
        rebuildButtons()
        setNeedsLayout()
    }

    func capsuleBounds(in bounds: CGRect) -> CGRect {
        guard hasDetachedTrailing else {
            return bounds
        }
        let trailingGap: CGFloat = 10
        let trailingDiameter = tabbarStyle.height
        let capsuleWidth = max(0, bounds.width - trailingDiameter - trailingGap)
        return CGRect(x: bounds.minX, y: bounds.minY, width: capsuleWidth, height: bounds.height)
    }

    func trailingActionBounds(in bounds: CGRect) -> CGRect? {
        guard hasDetachedTrailing else {
            return nil
        }
        let trailingDiameter = tabbarStyle.height
        return CGRect(
            x: bounds.maxX - trailingDiameter,
            y: bounds.minY + (bounds.height - trailingDiameter) / 2,
            width: trailingDiameter,
            height: trailingDiameter
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let capsule = capsuleBounds(in: bounds)
        backgroundShapeView.frame = capsule
        guard !buttons.isEmpty else {
            return
        }

        if let centerIndex = centerButtonIndex(), buttons.indices.contains(centerIndex) {
            let buttonDiameter = tabbarStyle.centerButtonDiameter
            let centerGap = min(buttonDiameter + 4, bounds.width * 0.34)
            let barFrame = CGRect(x: 0, y: tabbarStyle.barTop, width: bounds.width, height: tabbarStyle.height)
            let leftWidth = max(0, bounds.midX - centerGap / 2)
            let rightX = min(bounds.width, bounds.midX + centerGap / 2)
            let centerFrame = CGRect(
                x: bounds.midX - buttonDiameter / 2,
                y: max(0, tabbarStyle.barTop - tabbarStyle.centerButtonLift),
                width: buttonDiameter,
                height: buttonDiameter
            )

            buttons[centerIndex].frame = centerFrame
            layoutButtons(Array(0..<centerIndex), in: CGRect(x: 0, y: barFrame.minY, width: leftWidth, height: barFrame.height))
            layoutButtons(
                Array((centerIndex + 1)..<buttons.count),
                in: CGRect(x: rightX, y: barFrame.minY, width: bounds.width - rightX, height: barFrame.height)
            )
            return
        }

        if let trailingIndex = detachedTrailingIndex(),
           buttons.indices.contains(trailingIndex),
           let trailingBounds = trailingActionBounds(in: bounds) {
            buttons[trailingIndex].frame = trailingBounds
            let mainIndices = buttons.indices.filter { $0 != trailingIndex }
            layoutButtons(mainIndices, in: capsule)
            return
        }

        layoutButtons(Array(buttons.indices), in: bounds)
    }

    private func layoutButtons(_ indices: [Int], in rect: CGRect) {
        guard !indices.isEmpty else {
            return
        }
        let itemWidth = rect.width / CGFloat(indices.count)
        for (position, index) in indices.enumerated() where buttons.indices.contains(index) {
            buttons[index].frame = CGRect(
                x: rect.minX + CGFloat(position) * itemWidth,
                y: rect.minY,
                width: itemWidth,
                height: rect.height
            )
        }
    }

    private func centerButtonIndex() -> Int? {
        guard tabbarStyle.shape == .curve, !items.isEmpty else {
            return nil
        }
        if let centerItemId = tabbarStyle.centerItemId,
           let index = items.firstIndex(where: { $0.id == centerItemId }) {
            return index
        }
        return items.count / 2
    }

    private func detachedTrailingIndex() -> Int? {
        guard tabbarStyle.shape == .floating else {
            return nil
        }
        return items.lastIndex(where: \.isDetachedTrailing)
    }

    private func rebuildButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.enumerated().map { index, item in
            let button = NativeNavigationFloatingTabButton()
            button.tag = index
            button.configure(
                item: item,
                style: style(for: index)
            )
            button.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)
            addSubview(button)
            return button
        }
    }

    private func updateButtons() {
        for (index, button) in buttons.enumerated() {
            guard items.indices.contains(index) else {
                continue
            }
            button.configure(
                item: items[index],
                style: style(for: index)
            )
        }
    }

    private func style(for index: Int) -> NativeNavigationFloatingTabStyle {
        let isCenter = centerButtonIndex() == index
        let isDetachedTrailing = detachedTrailingIndex() == index
        // Detached actions stay icon-only when icons are available; fall back to
        // a label when icons are disabled so the control remains discoverable.
        let detachedShowsLabel = isDetachedTrailing && !iconsVisible && showsLabel(for: index)
        return NativeNavigationFloatingTabStyle(
            selected: index == selectedIndex,
            labels: isDetachedTrailing ? detachedShowsLabel : showsLabel(for: index),
            icons: iconsVisible,
            isCenter: isCenter,
            isDetachedTrailing: isDetachedTrailing,
            selectedTint: selectedTintColor,
            inactiveTint: inactiveTintColor,
            centerButtonColor: tabbarStyle.centerButtonColor ?? selectedTintColor,
            centerButtonIconColor: tabbarStyle.centerButtonIconColor,
            badgeBackgroundColor: badgeBackgroundColor,
            badgeTextColor: badgeTextColor
        )
    }

    private func showsLabel(for index: Int) -> Bool {
        switch labelVisibilityMode {
        case "unlabeled":
            return false
        case "selected":
            return index == selectedIndex
        case "auto":
            let compact = traitCollection.horizontalSizeClass == .compact || UIDevice.current.userInterfaceIdiom == .phone
            return !compact || index == selectedIndex
        default:
            return true
        }
    }

    @objc private func handleTap(_ sender: NativeNavigationFloatingTabButton) {
        let index = sender.tag
        guard items.indices.contains(index), items[index].enabled else {
            return
        }
        selectedIndex = index
        updateButtons()
        onSelect?(index, items[index])
    }
}

private final class NativeNavigationTabbarBackgroundView: UIView {
    var style = NativeNavigationTabbarStyleConfig() {
        didSet { setNeedsDisplay() }
    }
    var fillColor = UIColor.systemBackground.withAlphaComponent(0.46) {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        fillColor.setFill()
        NativeNavigationTabbarBackgroundPath.path(in: bounds, style: style).fill()
    }
}

private final class NativeNavigationFloatingTabButton: UIControl {
    private let selectedView = UIView()
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeLabel = UILabel()
    private var hasIcon = true
    private var hasLabel = true
    private var isCenterButton = false
    private var badgeText: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true

        selectedView.isUserInteractionEnabled = false
        selectedView.alpha = 0
        addSubview(selectedView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        titleLabel.textAlignment = .center
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.78
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)

        badgeLabel.textAlignment = .center
        badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.backgroundColor = .systemRed
        badgeLabel.layer.masksToBounds = true
        badgeLabel.isUserInteractionEnabled = false
        addSubview(badgeLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        item: NativeNavigationFloatingTabItem,
        style: NativeNavigationFloatingTabStyle
    ) {
        isEnabled = item.enabled
        alpha = item.enabled ? 1 : 0.38
        isCenterButton = style.isCenter
        let isDetachedTrailing = style.isDetachedTrailing
        hasIcon = style.icons && (item.image != nil || item.selectedImage != nil)
        hasLabel = isDetachedTrailing
            ? (!hasIcon && style.labels && !item.title.isEmpty)
            : (style.isCenter ? (!hasIcon && !item.title.isEmpty) : (style.labels && !item.title.isEmpty))
        badgeText = item.badge

        let color = style.isCenter
            ? style.centerButtonIconColor
            : (style.selected ? style.selectedTint : style.inactiveTint)
        selectedView.backgroundColor = style.isCenter
            ? style.centerButtonColor
            : style.selectedTint.withAlphaComponent(style.selected && !isDetachedTrailing ? 0.16 : 0)
        selectedView.alpha = style.isCenter || (style.selected && !isDetachedTrailing) ? 1 : 0

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = style.isCenter ? 0.2 : 0
        layer.shadowRadius = style.isCenter ? 14 : 0
        layer.shadowOffset = CGSize(width: 0, height: 8)

        let image = style.selected ? (item.selectedImage ?? item.image) : item.image
        imageView.image = image
        imageView.tintColor = color
        imageView.isHidden = !hasIcon

        titleLabel.text = item.title
        titleLabel.textColor = color
        titleLabel.font = .systemFont(ofSize: style.isCenter ? 12 : 11, weight: style.selected ? .bold : .semibold)
        titleLabel.isHidden = !hasLabel

        badgeLabel.text = item.badge
        badgeLabel.textColor = style.badgeTextColor
        badgeLabel.backgroundColor = style.badgeBackgroundColor
        badgeLabel.isHidden = item.badge == nil || item.badge == "0"
        accessibilityLabel = item.accessibilityTitle
        accessibilityTraits = style.selected ? [.button, .selected] : .button
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if isCenterButton {
            selectedView.frame = bounds
        } else {
            let selectedSize: CGFloat = 58
            selectedView.frame = CGRect(x: (bounds.width - selectedSize) / 2, y: (bounds.height - selectedSize) / 2, width: selectedSize, height: selectedSize)
        }
        selectedView.layer.cornerRadius = selectedView.bounds.height / 2

        let iconSize: CGFloat = isCenterButton ? 32 : 23
        if isCenterButton || (!hasLabel && hasIcon && bounds.width <= bounds.height + 1) {
            if hasIcon {
                imageView.frame = CGRect(x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
                titleLabel.frame = .zero
            } else {
                imageView.frame = .zero
                titleLabel.frame = CGRect(x: 8, y: (bounds.height - 18) / 2, width: bounds.width - 16, height: 18)
            }
        } else if hasIcon && hasLabel {
            imageView.frame = CGRect(x: (bounds.width - iconSize) / 2, y: 10, width: iconSize, height: iconSize)
            titleLabel.frame = CGRect(x: 5, y: bounds.height - 23, width: bounds.width - 10, height: 15)
        } else if hasIcon {
            imageView.frame = CGRect(x: (bounds.width - iconSize) / 2, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            titleLabel.frame = .zero
        } else {
            imageView.frame = .zero
            titleLabel.frame = CGRect(x: 5, y: (bounds.height - 18) / 2, width: bounds.width - 10, height: 18)
        }

        let badgeHeight: CGFloat = 18
        let badgeWidth = max(badgeHeight, CGFloat((badgeText ?? "").count * 7 + 11))
        let anchor = hasIcon ? imageView.frame : CGRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20)
        badgeLabel.frame = CGRect(
            x: min(bounds.width - badgeWidth - 8, anchor.midX + 7),
            y: max(6, anchor.minY - 6),
            width: badgeWidth,
            height: badgeHeight
        )
        badgeLabel.layer.cornerRadius = badgeHeight / 2
    }
}

private final class NativeNavigationChromeContainer: UIView {
    var hitSlop = UIEdgeInsets.zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let expandedBounds = bounds.inset(by: UIEdgeInsets(
            top: -hitSlop.top,
            left: -hitSlop.left,
            bottom: -hitSlop.bottom,
            right: -hitSlop.right
        ))
        return expandedBounds.contains(point)
    }
}

private final class NativeNavigationBar: UINavigationBar {
    var hitSlop = UIEdgeInsets.zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let expandedBounds = bounds.inset(by: UIEdgeInsets(
            top: -hitSlop.top,
            left: -hitSlop.left,
            bottom: -hitSlop.bottom,
            right: -hitSlop.right
        ))
        return expandedBounds.contains(point)
    }
}

final class NativeNavigationWeakView {
    weak var value: UIView?

    init(_ value: UIView) {
        self.value = value
    }
}

func nativeNavigationLiftWebViewOverlaySubviews(
    from webView: UIView,
    to container: UIView,
    tracking liftedOverlays: inout [NativeNavigationWeakView],
    excluding excludedViews: [UIView?] = []
) {
    // WebKit's own back/forward swipe (`allowsBackForwardNavigationGestures`)
    // wraps the web view's scroll view in plain UIViews of its own for the
    // length of the gesture — direct subviews of the web view, and by class
    // name indistinguishable from an overlay. They are the page. Lifting the
    // wrapper moves the live page out of the web view for good: when the
    // gesture ends, WebKit puts the scroll view back beside the wrapper
    // wherever that now is — above the tab controller, covering both bars —
    // and the swipe recognizer, still on the web view, never sees a touch
    // again. A `setTabbar` from the route change lands in that window every
    // time, because WebKit commits the navigation on release, while the
    // completion animation is still running.
    let pageScrollView = (webView as? WKWebView)?.scrollView

    webView.subviews
        .filter { view in
            if let pageScrollView, pageScrollView.isDescendant(of: view) {
                return false
            }
            return nativeNavigationShouldLiftWebViewOverlay(view, excluding: excludedViews)
        }
        .forEach { overlay in
            let frame = overlay.convert(overlay.bounds, to: container)
            let hadParentConstraints = nativeNavigationDeactivateParentConstraints(in: webView, involving: overlay)
            overlay.removeFromSuperview()
            overlay.frame = frame
            if hadParentConstraints {
                overlay.translatesAutoresizingMaskIntoConstraints = true
            }
            overlay.autoresizingMask = overlay.autoresizingMask.isEmpty
                ? [.flexibleWidth, .flexibleHeight]
                : overlay.autoresizingMask
            container.addSubview(overlay)
            liftedOverlays.append(NativeNavigationWeakView(overlay))
        }

    liftedOverlays = liftedOverlays.filter { $0.value != nil }
    liftedOverlays
        .compactMap(\.value)
        .filter { $0.superview === container }
        .forEach { container.bringSubviewToFront($0) }
}

func nativeNavigationShouldLiftWebViewOverlay(_ view: UIView, excluding excludedViews: [UIView?] = []) -> Bool {
    if excludedViews.contains(where: { $0 === view }) {
        return false
    }

    if view is UIScrollView {
        return false
    }

    let className = NSStringFromClass(type(of: view))
    return !className.contains("WK")
}

private func nativeNavigationDeactivateParentConstraints(in parent: UIView, involving view: UIView) -> Bool {
    let constraints = parent.constraints.filter { constraint in
        constraint.firstItem === view || constraint.secondItem === view
    }
    NSLayoutConstraint.deactivate(constraints)
    return !constraints.isEmpty
}

final class NativeNavigationTabController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.isOpaque = true
        tabBar.isTranslucent = !UIAccessibility.isReduceTransparencyEnabled

        // iOS 26: the floating capsule shrinks to a pill while the content
        // scrolls down and grows back on the way up, so it stops sitting on
        // top of what you are reading. UIKit drives this off the displayed
        // content's scroll view — here the WKWebView's own.
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior = .onScrollDown
        }
    }
}

/// Turns `UISearchResultsUpdating` callbacks into a plain closure.
///
/// It exists as its own object because `UISearchController.searchResultsUpdater`
/// is weak: the plugin cannot be the updater without also owning the retain
/// cycle, and a closure alone cannot conform to the protocol.
final class NativeNavigationSearchQueryForwarder: NSObject, UISearchResultsUpdating, UISearchBarDelegate {
    private let onQueryChange: (String) -> Void
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void

    init(
        onQueryChange: @escaping (String) -> Void,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onQueryChange = onQueryChange
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    func updateSearchResults(for searchController: UISearchController) {
        onQueryChange(searchController.searchBar.text ?? "")
    }

    /// The search key on the keyboard. `UISearchResultsUpdating` reports every
    /// keystroke but never the submit, so without this the web layer could not
    /// tell "still typing" from "go" — and pressing search did nothing at all.
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        onSubmit(searchBar.text ?? "")
    }

    /// The cancel (X) button beside the search field. With UIKit's
    /// automaticallyActivatesSearch off (KAN-751), cancelling no longer returns
    /// to the previously selected tab on its own, so the plugin does it here.
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        onCancel()
    }
}

/// A tab's content controller, wrapped in a navigation controller whose bar
/// starts hidden.
///
/// The wrapper is what lets `setNavbar` produce a real iOS navigation bar
/// instead of an overlay that only looks like one. It costs nothing while the
/// bar is hidden, which is every tab except an open article.
///
/// A free function rather than a method: it is handed to `UITab` as an escaping
/// closure, and capturing the plugin there would retain it through UIKit.
func nativeNavigationMakeTabContent() -> UIViewController {
    let navigation = UINavigationController(rootViewController: NativeNavigationTabContentController())
    navigation.setNavigationBarHidden(true, animated: false)
    return navigation
}

/// Digs the content controller out of whatever a tab hands back.
///
/// Every tab's content now sits inside a `UINavigationController`, so a plain
/// cast finds nothing. Missing this unwrap once already cost a black screen
/// behind the search field.
func nativeNavigationTabContent(of viewController: UIViewController?) -> NativeNavigationTabContentController? {
    if let content = viewController as? NativeNavigationTabContentController {
        return content
    }
    return (viewController as? UINavigationController)?
        .viewControllers.first as? NativeNavigationTabContentController
}

final class NativeNavigationTabContentController: UIViewController {
    /// Every content controller ever made, weakly held. The plugin reaches all
    /// of them to clear the web view out of the tab it left and to lift the
    /// stills once the new page has painted, and it cannot take the list from
    /// the tab controller: with `tabs`, `viewControllers` does not reliably
    /// hand back the lazily created controllers, and a cast of a tab's
    /// navigation controller to this class finds nothing.
    private static let registry = NSHashTable<NativeNavigationTabContentController>.weakObjects()

    static var all: [NativeNavigationTabContentController] {
        registry.allObjects
    }

    /// Strong reference to the search forwarder, which `UISearchController`
    /// only holds weakly. Set for the search tab, nil for every other tab.
    var searchQueryForwarder: NativeNavigationSearchQueryForwarder?

    /// KAN-751: set when the search tab is selected so the search field focuses
    /// on the next appearance — after the tab transition, not on a fragile
    /// timer. Focusing the integrated bar lets UIKit bring bar + keyboard up in
    /// one motion, avoiding the delayed two-step of a manual isActive +
    /// becomeFirstResponder.
    var mkAutoActivateSearchOnAppear = false

    private weak var hostedWebView: UIView?

    /// The web view this controller takes in as soon as its view is on screen
    /// with real bounds. Taking it in any earlier — the tab delegate fires
    /// before UIKit has attached the new tab's view — moved it into a detached
    /// 0×0 view: the tab it left went blank for a few frames, and WebKit laid
    /// the page out at zero width until the first real layout.
    private weak var pendingWebView: UIView?

    /// Still of the page as it looked when the web view left this tab. Stays
    /// in the web view's place while this tab fades out.
    private var snapshotPlaceholder: UIView?
    private var snapshotTimeout: Timer?

    /// Still of the page as it looked when the web view set out for this tab,
    /// on top of it until the web app reports the new page painted.
    private var transitionCover: UIView?

    /// What shows for the frame between tabs, before the web view is re-hosted.
    ///
    /// `.systemBackground` was the default and is white in light mode, so every
    /// tab switch flashed white over a page that is not. The web app knows its
    /// own background and passes it with `setTabbar`.
    static var contentBackground: UIColor = .systemBackground

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        Self.registry.add(self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.registry.add(self)
    }

    /// Whether the web view is here or on its way here.
    func isHosting(_ webView: UIView) -> Bool {
        hostedWebView === webView || pendingWebView === webView
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = Self.contentBackground
        view.isOpaque = true
        self.view = view
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        attachPendingWebViewIfReady()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachPendingWebViewIfReady()
        guard pendingWebView == nil else {
            return
        }
        guard hostedWebView?.superview === view else {
            hostedWebView = nil
            return
        }
        hostedWebView?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // KAN-751: auto-focus the search here, once the tab transition is done
        // and the view is really on screen. Focusing the integrated bar makes
        // UIKit raise the bar and keyboard together — one motion, no lag — and
        // running after the transition sidesteps the race that a synchronous
        // automaticallyActivatesSearch caused.
        guard mkAutoActivateSearchOnAppear else { return }
        mkAutoActivateSearchOnAppear = false
        navigationItem.searchController?.searchBar.becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Off screen: the still that stood in for the web view while this tab
        // faded out has done its job, and a cover nobody lifted is stale.
        dropStills()
    }

    func clearHostedWebView(ifMatching webView: UIView? = nil, preservingSnapshot: Bool = false) {
        if let webView, !isHosting(webView) {
            return
        }

        if preservingSnapshot, let hostedWebView, hostedWebView.superview === view {
            let placeholder = hostedWebView.snapshotView(afterScreenUpdates: false) ?? nativeNavigationSnapshotPlaceholder(for: hostedWebView)
            placeholder.frame = hostedWebView.frame
            placeholder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshotPlaceholder?.removeFromSuperview()
            view.insertSubview(placeholder, belowSubview: hostedWebView)
            snapshotPlaceholder = placeholder
        }

        hostedWebView = nil
        pendingWebView = nil
    }

    @discardableResult
    func host(webView: UIView) -> Bool {
        guard view !== webView, !view.isDescendant(of: webView) else {
            hostedWebView = nil
            pendingWebView = nil
            return false
        }

        hostedWebView = webView
        guard webView.superview !== view else {
            pendingWebView = nil
            webView.frame = view.bounds
            return true
        }

        // Not on screen yet, or not laid out: the web view stays where it is
        // and comes over from viewIsAppearing / viewDidLayoutSubviews.
        guard view.window != nil, !view.bounds.isEmpty else {
            pendingWebView = webView
            return true
        }

        pendingWebView = nil
        place(webView)
        return true
    }

    /// Lays a still of `webView`, as it renders right now, over this
    /// controller's content, to be lifted by `revealHostedWebView`.
    ///
    /// Called for the tab being switched to while the web view still shows
    /// the tab being left. UIKit cross-dissolves the two tabs; with the same
    /// picture on both sides nothing visibly changes until the new page has
    /// painted, and from then on the dissolve carries the new page in over
    /// the old one — instead of an empty tab fading out and the old page
    /// fading back in under the wrong tab.
    func cover(with webView: UIView) {
        // iOS 27 (KAN-753): the cover is a synchronous UIView snapshot of the web
        // view, which iOS 27 returns BLANK — and a frame tracer showed there is
        // no cross-dissolve for it to mask and the web view stays visible the
        // whole switch. So the cover only laid a blank frame over the visible web
        // view (~60-110ms) and WAS the flicker. Skipping it lets the web view
        // stay visible and transition old→new route directly, with no blank.
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            return
        }
        guard transitionCover == nil else {
            return
        }

        let cover = webView.snapshotView(afterScreenUpdates: false) ?? nativeNavigationSnapshotPlaceholder(for: webView)
        cover.frame = view.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.isUserInteractionEnabled = false
        view.addSubview(cover)
        transitionCover = cover
        scheduleWebViewReveal()
    }

    /// Drops whatever is covering the web view.
    func revealHostedWebView() {
        dropStills()
        hostedWebView?.isHidden = false
    }

    private func attachPendingWebViewIfReady() {
        guard let webView = pendingWebView, view.window != nil, !view.bounds.isEmpty else {
            return
        }
        pendingWebView = nil
        place(webView)
    }

    /// Puts the web view into the view, under whatever still is up.
    private func place(_ webView: UIView) {
        hostedWebView = webView
        if webView.superview !== view {
            webView.removeFromSuperview()
            view.addSubview(webView)
        }
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.frame = view.bounds

        if let cover = transitionCover {
            cover.frame = view.bounds
            view.bringSubviewToFront(cover)
        }
        // A still from an earlier visit is stale; the cover, if any, is the
        // current picture.
        snapshotPlaceholder?.removeFromSuperview()
        snapshotPlaceholder = nil
    }

    private func dropStills() {
        snapshotTimeout?.invalidate()
        snapshotTimeout = nil
        snapshotPlaceholder?.removeFromSuperview()
        snapshotPlaceholder = nil
        transitionCover?.removeFromSuperview()
        transitionCover = nil
    }

    /// Uncovers even if the web app never reports back, so a missed call
    /// costs the flicker rather than a screen that stays frozen.
    private func scheduleWebViewReveal() {
        snapshotTimeout?.invalidate()
        snapshotTimeout = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.revealHostedWebView()
        }
    }
}

private func nativeNavigationFallbackBackground(for view: UIView) -> UIColor {
    if let color = view.backgroundColor,
       color.cgColor.alpha > 0 {
        return color.withAlphaComponent(1)
    }
    return UIColor.systemBackground.withAlphaComponent(1.0)
}

func nativeNavigationUsesStationaryTransitionCrossfade(direction: String) -> Bool {
    direction == "tab" || direction == "root" || direction == "none"
}

private func nativeNavigationNeedsTransitionSurface(_ color: UIColor?) -> Bool {
    guard let color else {
        return true
    }
    return color.cgColor.alpha < 1
}

private func nativeNavigationSnapshotPlaceholder(for view: UIView) -> UIView {
    let placeholder = UIView(frame: view.frame)
    placeholder.backgroundColor = nativeNavigationFallbackBackground(for: view)
    placeholder.isOpaque = true
    return placeholder
}

private final class SVGIconRenderer: NSObject, XMLParserDelegate {
    private let context: CGContext
    private var styleStack = [SVGRenderStyle()]

    init(context: CGContext) {
        self.context = context
    }

    static func render(svg: String, size: CGSize) -> UIImage? {
        guard let data = svg.data(using: .utf8) else {
            return nil
        }

        let viewBox = viewBox(in: svg) ?? CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.saveGState()
            context.scaleBy(x: size.width / max(viewBox.width, 1), y: size.height / max(viewBox.height, 1))
            context.translateBy(x: -viewBox.minX, y: -viewBox.minY)

            let parser = XMLParser(data: data)
            let delegate = SVGIconRenderer(context: context)
            parser.delegate = delegate
            parser.parse()
            context.restoreGState()
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        var style = styleStack.last ?? SVGRenderStyle()
        style.apply(attributeDict)
        styleStack.append(style)

        switch elementName.lowercased() {
        case "path":
            guard let pathData = attributeDict["d"] else {
                return
            }
            draw(SVGPathParser(pathData).parse(), style: style)
        case "line":
            let path = UIBezierPath()
            path.move(to: CGPoint(x: Self.length(attributeDict["x1"]) ?? 0, y: Self.length(attributeDict["y1"]) ?? 0))
            path.addLine(to: CGPoint(x: Self.length(attributeDict["x2"]) ?? 0, y: Self.length(attributeDict["y2"]) ?? 0))
            draw(path, style: style)
        case "polyline", "polygon":
            let points = Self.points(attributeDict["points"])
            guard let first = points.first else {
                return
            }
            let path = UIBezierPath()
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            if elementName.lowercased() == "polygon" {
                path.close()
            }
            draw(path, style: style)
        case "circle":
            let cx = Self.length(attributeDict["cx"]) ?? 0
            let cy = Self.length(attributeDict["cy"]) ?? 0
            let radius = Self.length(attributeDict["r"]) ?? 0
            draw(UIBezierPath(ovalIn: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)), style: style)
        case "rect":
            let rect = CGRect(
                x: Self.length(attributeDict["x"]) ?? 0,
                y: Self.length(attributeDict["y"]) ?? 0,
                width: Self.length(attributeDict["width"]) ?? 0,
                height: Self.length(attributeDict["height"]) ?? 0
            )
            let radius = Self.length(attributeDict["rx"]) ?? Self.length(attributeDict["ry"]) ?? 0
            let path = radius > 0 ? UIBezierPath(roundedRect: rect, cornerRadius: radius) : UIBezierPath(rect: rect)
            draw(path, style: style)
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if styleStack.count > 1 {
            styleStack.removeLast()
        }
    }

    private func draw(_ path: UIBezierPath, style: SVGRenderStyle) {
        context.saveGState()
        path.lineWidth = style.strokeWidth
        path.lineCapStyle = style.lineCap
        path.lineJoinStyle = style.lineJoin
        UIColor.black.withAlphaComponent(style.opacity).setFill()
        UIColor.black.withAlphaComponent(style.opacity).setStroke()
        if style.fill {
            path.fill()
        }
        if style.stroke {
            path.stroke()
        }
        context.restoreGState()
    }

    static func length(_ value: String?) -> CGFloat? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        let allowed = CharacterSet(charactersIn: "-+.0123456789eE")
        let prefix = String(value.unicodeScalars.prefix { allowed.contains($0) })
        guard let double = Double(prefix) else {
            return nil
        }
        return CGFloat(double)
    }

    static func points(_ value: String?) -> [CGPoint] {
        let numbers = numbers(in: value ?? "")
        var points: [CGPoint] = []
        var index = 0
        while index + 1 < numbers.count {
            points.append(CGPoint(x: numbers[index], y: numbers[index + 1]))
            index += 2
        }
        return points
    }

    private static func viewBox(in svg: String) -> CGRect? {
        if let rawViewBox = attribute("viewBox", in: svg) {
            let values = numbers(in: rawViewBox)
            if values.count >= 4 {
                return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            }
        }
        guard let width = length(attribute("width", in: svg)),
              let height = length(attribute("height", in: svg)) else {
            return nil
        }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private static func attribute(_ name: String, in svg: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(svg.startIndex..<svg.endIndex, in: svg)
        guard let match = expression.firstMatch(in: svg, range: range),
              let valueRange = Range(match.range(at: 1), in: svg) else {
            return nil
        }
        return String(svg[valueRange])
    }

    private static func numbers(in value: String) -> [CGFloat] {
        let pattern = "[-+]?(?:\\d*\\.\\d+|\\d+\\.?)(?:[eE][-+]?\\d+)?"
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var values: [CGFloat] = []
        for match in expression.matches(in: value, range: range) {
            if let valueRange = Range(match.range, in: value),
               let double = Double(value[valueRange]) {
                values.append(CGFloat(double))
            }
        }
        return values
    }
}

private final class SVGPathParser {
    private let tokens: [String]
    private var index = 0
    private var command: Character?
    private var current = CGPoint.zero
    private var subpathStart = CGPoint.zero
    private var lastCubicControl: CGPoint?
    private var lastQuadControl: CGPoint?

    init(_ data: String) {
        tokens = Self.tokenize(data)
    }

    func parse() -> UIBezierPath {
        let path = UIBezierPath()
        while index < tokens.count {
            if let nextCommand = commandToken() {
                command = nextCommand
                index += 1
            }
            guard let command = command else {
                break
            }
            consume(command, into: path)
        }
        return path
    }

    private func consume(_ command: Character, into path: UIBezierPath) {
        let relative = command.isLowercase
        switch command.uppercased() {
        case "M":
            guard let firstPoint = point(relative: relative) else {
                return
            }
            path.move(to: firstPoint)
            current = firstPoint
            subpathStart = firstPoint
            while let nextPoint = point(relative: relative) {
                path.addLine(to: nextPoint)
                current = nextPoint
            }
            resetControls()
        case "L":
            while let nextPoint = point(relative: relative) {
                path.addLine(to: nextPoint)
                current = nextPoint
            }
            resetControls()
        case "H":
            while let value = number() {
                current = CGPoint(x: relative ? current.x + value : value, y: current.y)
                path.addLine(to: current)
            }
            resetControls()
        case "V":
            while let value = number() {
                current = CGPoint(x: current.x, y: relative ? current.y + value : value)
                path.addLine(to: current)
            }
            resetControls()
        case "C":
            while let control1 = point(relative: relative),
                  let control2 = point(relative: relative),
                  let end = point(relative: relative) {
                path.addCurve(to: end, controlPoint1: control1, controlPoint2: control2)
                current = end
                lastCubicControl = control2
                lastQuadControl = nil
            }
        case "S":
            while let control2 = point(relative: relative),
                  let end = point(relative: relative) {
                let control1 = reflected(lastCubicControl)
                path.addCurve(to: end, controlPoint1: control1, controlPoint2: control2)
                current = end
                lastCubicControl = control2
                lastQuadControl = nil
            }
        case "Q":
            while let control = point(relative: relative),
                  let end = point(relative: relative) {
                path.addQuadCurve(to: end, controlPoint: control)
                current = end
                lastQuadControl = control
                lastCubicControl = nil
            }
        case "T":
            while let end = point(relative: relative) {
                let control = reflected(lastQuadControl)
                path.addQuadCurve(to: end, controlPoint: control)
                current = end
                lastQuadControl = control
                lastCubicControl = nil
            }
        case "A":
            while let end = arcEndpoint(relative: relative) {
                path.addLine(to: end)
                current = end
            }
            resetControls()
        case "Z":
            path.close()
            current = subpathStart
            resetControls()
        default:
            index += 1
        }
    }

    private func point(relative: Bool) -> CGPoint? {
        guard let x = number(),
              let y = number() else {
            return nil
        }
        return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    private func arcEndpoint(relative: Bool) -> CGPoint? {
        guard number() != nil,
              number() != nil,
              number() != nil,
              number() != nil,
              number() != nil,
              let x = number(),
              let y = number() else {
            return nil
        }
        return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
    }

    private func number() -> CGFloat? {
        guard index < tokens.count,
              commandToken() == nil,
              let value = Double(tokens[index]) else {
            return nil
        }
        index += 1
        return CGFloat(value)
    }

    private func commandToken() -> Character? {
        guard index < tokens.count,
              tokens[index].count == 1,
              let character = tokens[index].first,
              character.isLetter else {
            return nil
        }
        return character
    }

    private func reflected(_ point: CGPoint?) -> CGPoint {
        guard let point = point else {
            return current
        }
        return CGPoint(x: current.x * 2 - point.x, y: current.y * 2 - point.y)
    }

    private func resetControls() {
        lastCubicControl = nil
        lastQuadControl = nil
    }

    private static func tokenize(_ data: String) -> [String] {
        var tokens: [String] = []
        var index = data.startIndex
        while index < data.endIndex {
            let character = data[index]
            if character.isWhitespace || character == "," {
                index = data.index(after: index)
                continue
            }
            if character.isLetter {
                tokens.append(String(character))
                index = data.index(after: index)
                continue
            }

            let start = index
            var end = index
            var hasDigits = false

            if data[end] == "-" || data[end] == "+" {
                end = data.index(after: end)
            }

            while end < data.endIndex, data[end].isNumber {
                hasDigits = true
                end = data.index(after: end)
            }

            if end < data.endIndex, data[end] == "." {
                end = data.index(after: end)
                while end < data.endIndex, data[end].isNumber {
                    hasDigits = true
                    end = data.index(after: end)
                }
            }

            if hasDigits, end < data.endIndex, data[end] == "e" || data[end] == "E" {
                let exponentStart = end
                var exponentEnd = data.index(after: end)
                if exponentEnd < data.endIndex, data[exponentEnd] == "-" || data[exponentEnd] == "+" {
                    exponentEnd = data.index(after: exponentEnd)
                }
                var hasExponentDigits = false
                while exponentEnd < data.endIndex, data[exponentEnd].isNumber {
                    hasExponentDigits = true
                    exponentEnd = data.index(after: exponentEnd)
                }
                if hasExponentDigits {
                    end = exponentEnd
                } else {
                    end = exponentStart
                }
            }

            if hasDigits, end > start {
                tokens.append(String(data[start..<end]))
                index = end
            } else {
                index = data.index(after: index)
            }
        }
        return tokens
    }
}
// swiftlint:enable cyclomatic_complexity function_body_length identifier_name

private extension UIColor {
    convenience init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        var hex: UInt64 = 0
        guard Scanner(string: value).scanHexInt64(&hex) else {
            return nil
        }

        switch value.count {
        case 6:
            self.init(
                red: CGFloat((hex & 0xFF0000) >> 16) / 255,
                green: CGFloat((hex & 0x00FF00) >> 8) / 255,
                blue: CGFloat(hex & 0x0000FF) / 255,
                alpha: 1
            )
        case 8:
            self.init(
                red: CGFloat((hex & 0x00FF0000) >> 16) / 255,
                green: CGFloat((hex & 0x0000FF00) >> 8) / 255,
                blue: CGFloat(hex & 0x000000FF) / 255,
                alpha: CGFloat((hex & 0xFF000000) >> 24) / 255
            )
        default:
            return nil
        }
    }
}

extension UIColor {
    /// Builds a colour from `#RRGGBB` or `#RRGGBBAA`, returning nil for
    /// anything else so a malformed value falls back to the inherited tint
    /// rather than to an arbitrary colour.
    convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt64(digits, radix: 16) else {
            return nil
        }

        let hasAlpha = digits.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1

        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

# MediKnow fork

This is [Medi-Know/capacitor-native-navigation](https://github.com/Medi-Know/capacitor-native-navigation),
a fork of [Cap-go/capacitor-native-navigation](https://github.com/Cap-go/capacitor-native-navigation)
carrying the changes the MediKnow iOS app needs. Branch `mediknow` sits on the
upstream tag `8.3.0`; releases are tagged `8.3.0-mediknow.N` and consumed by the
app as a git dependency, so `dist/` is committed here (build: `npx tsc && npx rollup -c rollup.config.mjs`).

Upstream is MPL-2.0; so is every file here, modified files included.

## What differs from upstream

The sections below were written while the changes still lived in a
patch-package patch in the app repository; they describe the same hunks, now
applied directly.

## History of the changes (originally the patch guide)

**Status: experiment.** Applied to see whether an animated hide is worth
keeping. If it does not look right on device, delete
`patches/@capgo+capacitor-native-navigation+8.3.0.patch` and run
`npm install` — nothing in our own code depends on it.

## What it changes

Hiding the tab bar snapped. The plugin already reaches for UIKit's animated
API but hard-codes the flag off:

```swift
// setSystemTabBarHidden, before
tabBarController.setTabBarHidden(hidden, animated: false)
```

Passing `true` alone changes nothing, because of the order in
`hideSystemTabBarChromeCompletely`:

```swift
applySystemTabBarItems([], selectedIndex: nil, animated: false)  // ← empties the bar
setSystemTabBarHidden(true)
tabBarController?.view.isHidden = true
```

That first line does two destructive things before UIKit gets a chance to
animate: it clears every tab item, and — on iOS 26, where the WebView is
hosted *inside* the tab bar controller — it moves the WebView back out.
`setTabBarBackgroundSubviewsHidden` then zeroes the alpha of the bar and all
its subviews. There is nothing left to slide.

The patch inverts the order for the animated case: slide first, tear down
after. The teardown moved into its own `tearDownSystemTabBarChrome()`, and the
animated path defers it by 0.35 s, because `setTabBarHidden(_:animated:)` has
no completion handler.

The deferred block re-checks `tabbarVisible` before running. A
`setTabbar({hidden: false})` can land while the bar is sliding out, and
`tabbarVisible` is written before any chrome is touched — so it is the
authority on what the caller wants by then. Without that check the teardown
would dismantle a bar that is already on its way back in.

Only the iOS 26 / system-liquid-glass path passes `animated: true`. The curve
and pre-26 paths keep the original behaviour.

## Why the plugin compiles from here

`ios/App/CapApp-SPM/Package.swift` references every plugin by local path into
`node_modules`, so the patched source is what Xcode builds. `patch-package`
runs from `postinstall`; a rebuild in Xcode is enough, `npx cap sync ios` is
not involved.

## If it is kept

Upstream it. The plugin is MPL-2.0 and the change is small and
self-contained — carrying a Swift patch across plugin upgrades is a poor
trade for 0.35 s of polish.

## Verifying after a plugin upgrade

`patch-package` fails loudly if the hunks no longer apply. Re-check by hand
that `hideSystemTabBarChromeCompletely` still runs
`applySystemTabBarItems([], …)` first — that ordering is the whole reason this
patch exists.

## Second change: never lift WebKit's swipe wrapper (2026-09-03)

`nativeNavigationLiftWebViewOverlaySubviews` moves every direct subview of the
WKWebView that is neither a scroll view nor has "WK" in its class name into the
root container, above the tab controller. WebKit's own back swipe
(`allowsBackForwardNavigationGestures`) inserts exactly such a view for the
length of the gesture — a plain `UIView` (layer name `SwipeTransitionContainer`)
wrapping the relocated `WKScrollView`, i.e. the live page. WebKit commits the
navigation on release, while the completion animation is still running; the
`setTabbar` from the resulting route change lifts the wrapper, and when the
animation ends WebKit re-inserts the scroll view *beside* the wrapper — in the
root container, over both bars, with the swipe recognizer left behind on an
empty web view.

The hunk skips any subview that contains `webView.scrollView`
(`isDescendant(of:)`) — generic, no private layer names involved. Background,
measurements and the device check are in
`docs/native-backswipe-untersuchung.md`, section 2b.

## Third change: the transition covers the web view instead of dimming it (2026-09-03)

Upstream `beginTransition` set `webView.alpha = 0.01` and left it there until
`finishTransition`. WebKit records the snapshot a back swipe later reveals at
`pushState`, by rendering the WKWebView's own layer, and Angular pushes the
URL after guards and resolvers — while that transition is in flight. The
capture was made at 1 % and stored without alpha (YUV422), so every swipe out
of an article showed the previous page as a faint ghost on black.

The hunks leave the web view untouched and put the snapshot above it in every
direction; `finishStandardTransition` moves it underneath for a push in the
same transaction as the start transform, so the incoming page still slides in
on top. Details in `docs/native-backswipe-untersuchung.md`, section 2c.

## Fourth change: tab switches without a blank, a flash or a padding jump (2026-09-04)

Measured on device: the plugin moved the web view into the new tab's content
controller from the tab delegate, while that view was neither in the window
nor laid out — a detached 0×0 view for ~32 ms, during which the old tab went
blank and WebKit laid the page out at zero width. UIKit then cross-dissolved
(iOS 18+) with the web view still showing the old page in the new tab, and
~110 ms later the web app's `setNavbar` showed the new tab's bar, growing the
safe area and with it the page's top padding.

The hunks: `NativeNavigationTabContentController` keeps a weak registry of
every instance (with `tabs`, the tab controller's `viewControllers` did not
reliably list the lazily created ones, so the leaving tab's placeholder was
never made and `finishTabTransition` cast a navigation controller to the
content class and found nothing); it defers taking the web view in until its
view is on screen with real bounds (`pendingWebView`, attached from
`viewIsAppearing`/`viewDidLayoutSubviews`); and it covers itself with a
`snapshotView` of the current page (`cover(with:)`) until the web app reports
the new page painted, with a 1.5 s watchdog. `hostWebView(in:)` re-applies
the last hosted `setNavbar` to the new tab before its view appears
(`carryHostedNavbar`), so the safe area stays put across the switch.
`finishTabTransition` reveals the selected tab only; the leaving tab keeps
its still until `viewDidDisappear`. Details: `docs/native-backswipe-untersuchung.md`, Teil 4.

## Fifth change: submenus and checkmarks in bar button menus (2026-09-04)

`makeBarButtonMenu` built a flat list of `UIAction`s with `state: .off`. The
profile menu now carries the web user menu's appearance switch as a submenu
with the option in force ticked, so entries gained two fields, typed in
`definitions.d.ts` as `NativeNavigationMenuEntry`: `children` turns an entry
into a `UIMenu` of those entries (it reports no tap of its own), and
`checked` sets `UIMenuElement.State.on`. `makeMenuElements` recurses over
both; everything else about entries is unchanged.

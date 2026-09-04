import { WebPlugin } from '@capacitor/core';
const DEFAULT_NAVBAR_HEIGHT = 44;
const DEFAULT_TABBAR_HEIGHT = 49;
const DEFAULT_TRANSITION_DURATION = 350;
export class NativeNavigationWeb extends WebPlugin {
    constructor() {
        super(...arguments);
        this.config = {
            contentInsetMode: 'css',
            enabled: true,
            platformStyle: 'auto',
        };
        this.navbar = { hidden: true };
        this.tabbar = { hidden: true };
        this.activeTransition = null;
    }
    async configure(options = {}) {
        this.config = Object.assign(Object.assign(Object.assign({}, this.config), options), { colors: Object.assign(Object.assign({}, this.config.colors), options.colors), glass: Object.assign(Object.assign({}, this.config.glass), options.glass) });
        return this.applyInsets();
    }
    async setNavbar(options) {
        this.navbar = Object.assign(Object.assign(Object.assign({}, this.navbar), options), { colors: Object.assign(Object.assign({}, this.navbar.colors), options.colors), glass: Object.assign(Object.assign({}, this.navbar.glass), options.glass) });
        return this.applyInsets();
    }
    async setTabbar(options) {
        this.tabbar = Object.assign(Object.assign(Object.assign({}, this.tabbar), options), { colors: Object.assign(Object.assign({}, this.tabbar.colors), options.colors), style: Object.assign(Object.assign({}, this.tabbar.style), options.style), glass: Object.assign(Object.assign({}, this.tabbar.glass), options.glass) });
        return this.applyInsets();
    }
    async beginTransition(options = {}) {
        const transition = this.createTransition(options.id, options.direction, options.duration);
        this.activeTransition = transition;
        this.notifyListeners('transitionStart', transition);
        this.dispatchWindowEvent('transitionStart', transition);
        return transition;
    }
    async finishTabTransition() {
        // Nothing covers the web view on the web.
    }
    async finishTransition(options = {}) {
        var _a, _b;
        const transition = this.activeTransition && (!options.id || options.id === this.activeTransition.id)
            ? Object.assign(Object.assign({}, this.activeTransition), { direction: (_a = options.direction) !== null && _a !== void 0 ? _a : this.activeTransition.direction, duration: (_b = options.duration) !== null && _b !== void 0 ? _b : this.activeTransition.duration }) : this.createTransition(options.id, options.direction, options.duration);
        this.activeTransition = null;
        this.notifyListeners('transitionEnd', transition);
        this.dispatchWindowEvent('transitionEnd', transition);
        return transition;
    }
    async getPluginVersion() {
        return {
            version: 'web',
        };
    }
    createTransition(id, direction, duration) {
        var _a;
        if (id === void 0) { id = `transition-${Date.now()}`; }
        if (direction === void 0) { direction = 'forward'; }
        if (duration === void 0) { duration = (_a = this.config.animationDuration) !== null && _a !== void 0 ? _a : DEFAULT_TRANSITION_DURATION; }
        return { id, direction, duration };
    }
    currentTabbarHeight() {
        var _a, _b, _c, _d;
        const style = this.tabbar.style;
        if (!style) {
            return DEFAULT_TABBAR_HEIGHT;
        }
        const defaultHeight = style.shape === 'curve' ? 76 : style.shape === 'floating' ? 64 : DEFAULT_TABBAR_HEIGHT;
        const height = (_a = style.height) !== null && _a !== void 0 ? _a : defaultHeight;
        const bottomGap = (_b = style.bottomGap) !== null && _b !== void 0 ? _b : (style.shape === 'curve' ? 0 : 10);
        const centerButtonLift = style.shape === 'curve' ? ((_c = style.centerButtonLift) !== null && _c !== void 0 ? _c : ((_d = style.centerButtonDiameter) !== null && _d !== void 0 ? _d : 56) / 2) : 0;
        return Math.ceil(height + bottomGap + centerButtonLift);
    }
    applyInsets() {
        const enabled = this.config.enabled !== false;
        const navbarVisible = enabled && this.navbar.hidden !== true;
        const tabbarVisible = enabled && this.tabbar.hidden !== true;
        const tabbarHeight = tabbarVisible ? this.currentTabbarHeight() : 0;
        const insets = {
            top: navbarVisible ? DEFAULT_NAVBAR_HEIGHT : 0,
            right: 0,
            bottom: tabbarHeight,
            left: 0,
            navbarHeight: navbarVisible ? DEFAULT_NAVBAR_HEIGHT : 0,
            tabbarHeight,
        };
        if (this.config.contentInsetMode !== 'none' && typeof document !== 'undefined') {
            const root = document.documentElement;
            root.style.setProperty('--cap-native-navigation-top', `${insets.top}px`);
            root.style.setProperty('--cap-native-navigation-right', `${insets.right}px`);
            root.style.setProperty('--cap-native-navigation-bottom', `${insets.bottom}px`);
            root.style.setProperty('--cap-native-navigation-left', `${insets.left}px`);
            root.style.setProperty('--cap-native-navbar-height', `${insets.navbarHeight}px`);
            root.style.setProperty('--cap-native-tabbar-height', `${insets.tabbarHeight}px`);
        }
        const event = { insets };
        this.notifyListeners('safeAreaChanged', event);
        this.dispatchWindowEvent('safeAreaChanged', event);
        return { insets };
    }
    dispatchWindowEvent(name, detail) {
        if (typeof window === 'undefined') {
            return;
        }
        window.dispatchEvent(new CustomEvent(`capNativeNavigation:${name}`, { detail }));
    }
}
//# sourceMappingURL=web.js.map
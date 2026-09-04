var capacitorNativeNavigation = (function (exports, core) {
    'use strict';

    const createNativeNavigationWeb = () => Promise.resolve().then(function () { return web; }).then((m) => new m.NativeNavigationWeb());

    const parseBoolean = (value, defaultValue = false) => {
        if (value === null) {
            return defaultValue;
        }
        return value === '' || value === 'true' || value === '1';
    };
    const normalizeAttribute = (value) => (value ? value : undefined);
    const typedAttribute = (element, name) => normalizeAttribute(element.getAttribute(name));
    const parseJsonAttribute = (element, name, fallback) => {
        const value = element.getAttribute(name);
        if (!value) {
            return fallback;
        }
        try {
            return JSON.parse(value);
        }
        catch (_a) {
            return fallback;
        }
    };
    const getNativeNavigation = async () => (await Promise.resolve().then(function () { return index; })).NativeNavigation;
    function defineNativeNavigationElements() {
        if (typeof customElements === 'undefined' || typeof HTMLElement === 'undefined') {
            return;
        }
        class CapNativeNavigationProvider extends HTMLElement {
            static get observedAttributes() {
                return ['enabled', 'platform-style', 'content-inset-mode', 'animation-duration', 'colors', 'glass'];
            }
            connectedCallback() {
                void this.sync();
            }
            attributeChangedCallback() {
                if (this.isConnected) {
                    void this.sync();
                }
            }
            async sync() {
                var _a, _b;
                const duration = this.getAttribute('animation-duration');
                const options = {
                    enabled: parseBoolean(this.getAttribute('enabled'), true),
                    platformStyle: (_a = typedAttribute(this, 'platform-style')) !== null && _a !== void 0 ? _a : 'auto',
                    contentInsetMode: (_b = typedAttribute(this, 'content-inset-mode')) !== null && _b !== void 0 ? _b : 'css',
                    colors: parseJsonAttribute(this, 'colors', undefined),
                    glass: parseJsonAttribute(this, 'glass', undefined),
                };
                if (duration) {
                    options.animationDuration = Number(duration);
                }
                const NativeNavigation = await getNativeNavigation();
                await NativeNavigation.configure(options);
            }
        }
        class CapNativeNavbar extends HTMLElement {
            static get observedAttributes() {
                return [
                    'hidden',
                    'title',
                    'subtitle',
                    'large',
                    'transparent',
                    'blur-effect',
                    'back-button',
                    'back-title',
                    'left-items',
                    'right-items',
                    'colors',
                    'glass',
                    'animated',
                ];
            }
            connectedCallback() {
                void this.sync();
            }
            attributeChangedCallback() {
                if (this.isConnected) {
                    void this.sync();
                }
            }
            async sync() {
                var _a, _b;
                const options = {
                    hidden: parseBoolean(this.getAttribute('hidden')),
                    title: (_a = this.getAttribute('title')) !== null && _a !== void 0 ? _a : undefined,
                    subtitle: (_b = this.getAttribute('subtitle')) !== null && _b !== void 0 ? _b : undefined,
                    large: parseBoolean(this.getAttribute('large')),
                    transparent: parseBoolean(this.getAttribute('transparent')),
                    blurEffect: typedAttribute(this, 'blur-effect'),
                    backButton: {
                        visible: parseBoolean(this.getAttribute('back-button')),
                        title: normalizeAttribute(this.getAttribute('back-title')),
                    },
                    leftItems: parseJsonAttribute(this, 'left-items', []),
                    rightItems: parseJsonAttribute(this, 'right-items', []),
                    colors: parseJsonAttribute(this, 'colors', undefined),
                    glass: parseJsonAttribute(this, 'glass', undefined),
                    animated: parseBoolean(this.getAttribute('animated')),
                };
                const NativeNavigation = await getNativeNavigation();
                await NativeNavigation.setNavbar(options);
            }
        }
        class CapNativeTabbar extends HTMLElement {
            static get observedAttributes() {
                return [
                    'hidden',
                    'tabs',
                    'selected-id',
                    'labels',
                    'label-visibility-mode',
                    'icons',
                    'colors',
                    'glass',
                    'blur-effect',
                    'disable-indicator',
                    'indicator-color',
                    'ripple-color',
                    'badge-background-color',
                    'badge-text-color',
                    'experimental-baked-tint-colors',
                    'animated',
                ];
            }
            connectedCallback() {
                void this.sync();
            }
            attributeChangedCallback() {
                if (this.isConnected) {
                    void this.sync();
                }
            }
            async sync() {
                const options = {
                    hidden: parseBoolean(this.getAttribute('hidden')),
                    tabs: parseJsonAttribute(this, 'tabs', []),
                    selectedId: normalizeAttribute(this.getAttribute('selected-id')),
                    labels: parseBoolean(this.getAttribute('labels'), true),
                    labelVisibilityMode: typedAttribute(this, 'label-visibility-mode'),
                    icons: parseBoolean(this.getAttribute('icons'), true),
                    colors: parseJsonAttribute(this, 'colors', undefined),
                    glass: parseJsonAttribute(this, 'glass', undefined),
                    blurEffect: typedAttribute(this, 'blur-effect'),
                    disableIndicator: parseBoolean(this.getAttribute('disable-indicator')),
                    indicatorColor: normalizeAttribute(this.getAttribute('indicator-color')),
                    rippleColor: normalizeAttribute(this.getAttribute('ripple-color')),
                    badgeBackgroundColor: normalizeAttribute(this.getAttribute('badge-background-color')),
                    experimentalBakedTintColors: parseBoolean(this.getAttribute('experimental-baked-tint-colors')),
                    badgeTextColor: normalizeAttribute(this.getAttribute('badge-text-color')),
                    animated: parseBoolean(this.getAttribute('animated')),
                };
                const NativeNavigation = await getNativeNavigation();
                await NativeNavigation.setTabbar(options);
            }
        }
        if (!customElements.get('cap-native-navigation-provider')) {
            customElements.define('cap-native-navigation-provider', CapNativeNavigationProvider);
        }
        if (!customElements.get('cap-native-navbar')) {
            customElements.define('cap-native-navbar', CapNativeNavbar);
        }
        if (!customElements.get('cap-native-tabbar')) {
            customElements.define('cap-native-tabbar', CapNativeTabbar);
        }
    }

    const NativeNavigation = core.registerPlugin('NativeNavigation', {
        web: createNativeNavigationWeb,
    });
    const isElement = (target) => typeof Element !== 'undefined' && target instanceof Element;
    const isDomRect = (target) => typeof DOMRect !== 'undefined' && target instanceof DOMRect;
    /**
     * Convert an element or DOMRect into viewport coordinates accepted by native
     * zoom transitions.
     */
    const getNativeNavigationRect = (target) => {
        const rect = isElement(target) ? target.getBoundingClientRect() : target;
        if (isDomRect(rect)) {
            return {
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
            };
        }
        return {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        };
    };
    /**
     * Begin an Apple-Zoom-style native transition from a DOM element or rect.
     */
    const beginZoomTransition = (target, options = {}) => NativeNavigation.beginTransition(Object.assign(Object.assign({}, options), { direction: 'zoom', sourceRect: getNativeNavigationRect(target) }));
    /**
     * Finish an Apple-Zoom-style native transition into an optional DOM element or
     * rect on the destination route.
     */
    const finishZoomTransition = (target, options = {}) => NativeNavigation.finishTransition(Object.assign(Object.assign({}, options), { direction: 'zoom', targetRect: target ? getNativeNavigationRect(target) : undefined }));

    var index = /*#__PURE__*/Object.freeze({
        __proto__: null,
        NativeNavigation: NativeNavigation,
        beginZoomTransition: beginZoomTransition,
        defineNativeNavigationElements: defineNativeNavigationElements,
        finishZoomTransition: finishZoomTransition,
        getNativeNavigationRect: getNativeNavigationRect
    });

    const DEFAULT_NAVBAR_HEIGHT = 44;
    const DEFAULT_TABBAR_HEIGHT = 49;
    const DEFAULT_TRANSITION_DURATION = 350;
    class NativeNavigationWeb extends core.WebPlugin {
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

    var web = /*#__PURE__*/Object.freeze({
        __proto__: null,
        NativeNavigationWeb: NativeNavigationWeb
    });

    exports.NativeNavigation = NativeNavigation;
    exports.beginZoomTransition = beginZoomTransition;
    exports.defineNativeNavigationElements = defineNativeNavigationElements;
    exports.finishZoomTransition = finishZoomTransition;
    exports.getNativeNavigationRect = getNativeNavigationRect;

    return exports;

})({}, capacitorExports);
//# sourceMappingURL=plugin.js.map

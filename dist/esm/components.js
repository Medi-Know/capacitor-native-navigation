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
const getNativeNavigation = async () => (await import('./index')).NativeNavigation;
export function defineNativeNavigationElements() {
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
//# sourceMappingURL=components.js.map
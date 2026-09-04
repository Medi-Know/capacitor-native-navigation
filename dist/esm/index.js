import { registerPlugin } from '@capacitor/core';
import { createNativeNavigationWeb } from './plugin';
export const NativeNavigation = registerPlugin('NativeNavigation', {
    web: createNativeNavigationWeb,
});
export * from './definitions';
export { defineNativeNavigationElements } from './components';
const isElement = (target) => typeof Element !== 'undefined' && target instanceof Element;
const isDomRect = (target) => typeof DOMRect !== 'undefined' && target instanceof DOMRect;
/**
 * Convert an element or DOMRect into viewport coordinates accepted by native
 * zoom transitions.
 */
export const getNativeNavigationRect = (target) => {
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
export const beginZoomTransition = (target, options = {}) => NativeNavigation.beginTransition(Object.assign(Object.assign({}, options), { direction: 'zoom', sourceRect: getNativeNavigationRect(target) }));
/**
 * Finish an Apple-Zoom-style native transition into an optional DOM element or
 * rect on the destination route.
 */
export const finishZoomTransition = (target, options = {}) => NativeNavigation.finishTransition(Object.assign(Object.assign({}, options), { direction: 'zoom', targetRect: target ? getNativeNavigationRect(target) : undefined }));
//# sourceMappingURL=index.js.map
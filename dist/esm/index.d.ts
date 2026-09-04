import type { NativeNavigationBeginTransitionOptions, NativeNavigationFinishTransitionOptions, NativeNavigationPlugin, NativeNavigationRect, NativeNavigationTransitionResult } from './definitions';
export declare const NativeNavigation: NativeNavigationPlugin;
export * from './definitions';
export { defineNativeNavigationElements } from './components';
type NativeNavigationRectTarget = Element | DOMRect | NativeNavigationRect;
/**
 * Convert an element or DOMRect into viewport coordinates accepted by native
 * zoom transitions.
 */
export declare const getNativeNavigationRect: (target: NativeNavigationRectTarget) => NativeNavigationRect;
/**
 * Begin an Apple-Zoom-style native transition from a DOM element or rect.
 */
export declare const beginZoomTransition: (target: NativeNavigationRectTarget, options?: Omit<NativeNavigationBeginTransitionOptions, "direction" | "sourceRect">) => Promise<NativeNavigationTransitionResult>;
/**
 * Finish an Apple-Zoom-style native transition into an optional DOM element or
 * rect on the destination route.
 */
export declare const finishZoomTransition: (target?: NativeNavigationRectTarget, options?: Omit<NativeNavigationFinishTransitionOptions, "direction" | "targetRect">) => Promise<NativeNavigationTransitionResult>;

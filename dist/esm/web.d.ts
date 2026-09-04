import { WebPlugin } from '@capacitor/core';
import type { NativeNavigationBeginTransitionOptions, NativeNavigationConfigureOptions, NativeNavigationFinishTransitionOptions, NativeNavigationInsetsResult, NativeNavigationNavbarOptions, NativeNavigationPlugin, NativeNavigationTabbarOptions, NativeNavigationTransitionResult, PluginVersionResult } from './definitions';
export declare class NativeNavigationWeb extends WebPlugin implements NativeNavigationPlugin {
    private config;
    private navbar;
    private tabbar;
    private activeTransition;
    configure(options?: NativeNavigationConfigureOptions): Promise<NativeNavigationInsetsResult>;
    setNavbar(options: NativeNavigationNavbarOptions): Promise<NativeNavigationInsetsResult>;
    setTabbar(options: NativeNavigationTabbarOptions): Promise<NativeNavigationInsetsResult>;
    beginTransition(options?: NativeNavigationBeginTransitionOptions): Promise<NativeNavigationTransitionResult>;
    finishTabTransition(): Promise<void>;
    finishTransition(options?: NativeNavigationFinishTransitionOptions): Promise<NativeNavigationTransitionResult>;
    getPluginVersion(): Promise<PluginVersionResult>;
    private createTransition;
    private currentTabbarHeight;
    private applyInsets;
    private dispatchWindowEvent;
}

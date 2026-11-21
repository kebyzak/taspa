# Taspa brand guidelines

**Approved identity · 01 Splice · 18 November 2026**

Two parallel diagonal cuts give the Splice T its silhouette and recall the angled join in a strip of tape. The custom Taspa wordmark repeats the cut in its initial. Both are fixed vector artwork. Use the [approved assets](../assets/brand/) alongside the [design system](DESIGN_SYSTEM.md).

## Which mark to use

| Mark | Use | Source |
| --- | --- | --- |
| Standalone symbol | App icon, native launch screen, and compact brand placements where Taspa is already identified | [Symbol SVG](../assets/brand/symbol.svg) |
| Wordmark | Brand introductions, export surfaces, and other brand placements where the name needs to be read | [Wordmark SVG](../assets/brand/wordmark.svg) |

The wordmark contains the Splice T. Use it on its own as the full name treatment. Keep the app icon symbol-only. Use the supplied paths at their original proportions. Preserve the two cuts, internal spacing, and direction of the artwork. Use Gloock and Noto Sans for supporting typography as defined in the design system. The custom wordmark always comes from the SVG.

## Proportions, clear space, and minimum sizes

| Asset | SVG canvas and visible bounds | Minimum clear space | Minimum display size |
| --- | --- | --- | --- |
| Symbol | Square 256 × 256. Visible mark 180 × 170. | One stem width, 42 units on the master, measured from the visible edges on every side. | 16 × 16 px for the SVG canvas. Prefer 24 × 24 px or larger for regular UI placement. |
| Wordmark | 326 × 115. Visible lettering 318 × 97. | Two stem widths of the wordmark T, 26 units on the master, measured from the visible edges on every side. | 96 px wide for the SVG canvas. |

Scale clear space with the artwork. Transparent padding in the files counts toward it. The supplied launcher icon layers have their own mask-safe placement. Use those layers as delivered. On photographic surfaces, place the mark on a solid graphite or ivory field and retain clear space. Keep the artwork flat, with its original fills and without effects, outlines, rotation, cropping, or stretching.

## Color variants

| Treatment | sRGB | Background | Asset suffix |
| --- | --- | --- | --- |
| Graphite | `#141416` · 20, 20, 22 | Ivory or white | None |
| Ivory | `#F3EEE8` · 243, 238, 232 | Graphite or a solid dark surface with comparable contrast | `_ivory` |
| Fired coral | `#DB806F` · 219, 128, 111 | Graphite. The signature app icon and launch pairing. | `_coral` |
| Black or white | `#000000` or `#FFFFFF` | Opposite neutral for one-color reproduction | `_black` or `_white` |

Every treatment applies to both masters. For Flutter UI, use the matching SVG asset. Give the mark the accessible name **Taspa** when it identifies the product by itself. Omit redundant announcements when visible text already names Taspa.

## Flutter asset handoff

The platform folders under `assets/brand/` are staged resources for the Flutter project. Declare only the SVGs used by Flutter widgets in `pubspec.yaml` and render them with the project's SVG-capable renderer. The launcher and first-frame artwork are native resources. [Flutter assets and images](https://docs.flutter.dev/ui/assets/assets-and-images)

### iOS app icon

Copy the staged [AppIcon.appiconset](../assets/brand/ios/Assets.xcassets/AppIcon.appiconset/) into `ios/Runner/Assets.xcassets/` as the target's `AppIcon` set. It includes an opaque, unmasked 1024 × 1024 sRGB PNG and its single-size iOS catalog metadata. Xcode supplies derived sizes and automatic appearance treatments. Editable [foreground and background SVG layers](../assets/brand/ios/icon_layers/) are also available for Icon Composer. Keep the background square and let the system mask the icon. [Apple app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons/) · [Apple asset catalog configuration](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)

### Android launcher icon

Merge the staged [Android resources](../assets/brand/android/res/) into `android/app/src/main/res/`. Set the merged app manifest's icon reference to `@mipmap/taspa_launcher`. Point an existing round-icon reference to that same resource if one is present.

| Android path | Delivered resource |
| --- | --- |
| API 26–32 | Adaptive icon with graphite background and coral vector foreground |
| API 33+ | Adaptive icon with the same layers plus a single-color themed silhouette |
| Legacy | Five density PNGs with a baked graphite tile, from mdpi through xxxhdpi |

The adaptive vectors use a 108 dp layer and keep the artwork inside the central 66 dp safe area, including a conservative circular check. The launcher controls the final mask and optional tint. [Android adaptive icon guidance](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive)

### Native splash

Use a single coral Splice symbol centered on a graphite field. The common visual composition is a 96-unit square asset with about 68 units of visible mark width. Use system launch timing and let Flutter render the first frame as soon as it is ready. Match the initial Flutter canvas to graphite for a continuous handoff. [Flutter iOS launch screen](https://docs.flutter.dev/platform-integration/ios/launch-screen) · [Flutter Android splash screen](https://docs.flutter.dev/platform-integration/android/splash-screen)

- **iOS.** Merge `TaspaLaunchMark.imageset` and `TaspaLaunchBackground.colorset` from [Assets.xcassets](../assets/brand/ios/Assets.xcassets/) into the Runner asset catalog. In the native launch storyboard, center the image view at 96 × 96 pt with aspect fit and use the supplied named color for the background. The image set provides 1×, 2×, and 3× transparent PNGs. [Apple launch screen configuration](https://developer.apple.com/documentation/xcode/specifying-your-apps-launch-screen/)
- **Android 12 and later.** In the API 31+ launch theme, bind `android:windowSplashScreenBackground` to `@color/taspa_canvas` and `android:windowSplashScreenAnimatedIcon` to `@drawable/taspa_splash_mark_android12`. The drawable is static and padded on a 288 dp canvas for the system's no-icon-background mask. Keep the icon background unset. [Android SplashScreen sizing and themes](https://developer.android.com/develop/ui/views/launch/splash-screen)
- **Earlier Android versions.** Use `@drawable/taspa_launch_background` as the launch window background. It centers the common 96 dp vector on graphite. Keep the Flutter template's launch-to-normal-theme handoff.

The [shared splash SVG](../assets/brand/splash.svg) is available for design reference and reuse. Verify launcher masks, themed icons, and cold-start appearance on devices once the native resources are integrated into the app.

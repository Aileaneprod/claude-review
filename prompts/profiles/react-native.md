# Stack profile: React Native

Checks specific to this stack. Base rules still apply — in particular, a hook
that looks wrong is often correct once you read the custom hook it calls.

## Hooks

- **`useEffect` with a missing cleanup.** Subscriptions, `addEventListener`,
  `setInterval`/`setTimeout`, `Animated` loops, WebSockets, geolocation
  watchers, and `AppState` listeners must be torn down in the returned function.
  Leaking one leaks it per mount. *Not a finding if* teardown happens inside a
  custom hook the effect delegates to — read it before flagging.
- **State update after unmount.** An `await` in an effect followed by `setState`
  with no cancellation flag or `AbortController`. Verify there is no guard.
- **Dependency array bugs.** A value used in the effect but absent from the deps
  (stale closure — the effect reads the first render's value forever), or an
  object/array/function literal in the deps that is recreated every render
  (effect fires every render). An intentionally-empty `[]` with a comment is
  fine; an accidentally-empty one is a real bug.
- `useCallback`/`useMemo` whose deps are wrong, which is worse than not using
  them — it caches a stale value with no warning.
- Conditional hook calls, or hooks inside a loop or callback.

## Rendering and lists

- **`FlatList`/`SectionList` given `keyExtractor={(item, index) => index}`** or
  no key at all — reorders and deletions then reuse the wrong row state.
- `renderItem` defined inline as an arrow function that closes over changing
  state — recreated every render, defeats memoization.
- A `.map()` rendering a long or unbounded list instead of a virtualized list;
  a `ScrollView` where a `FlatList` is needed.
- Inline object/array/function props (`style={{...}}`, `onPress={() => ...}`) on
  a child wrapped in `React.memo` — the new identity each render defeats it
  entirely.
- Re-render storms: state held higher than it needs to be, or a context value
  built as a fresh object each render so every consumer re-renders.

## Network and data

- Fetches fired per item in a list rather than batched — check for a request
  inside `renderItem` or a per-row effect.
- No request cancellation on unmount or on a rapidly changing dependency
  (search-as-you-type without debounce or abort).
- **Missing loading and error states.** A screen that renders only the success
  path shows a blank or frozen view on slow networks and silently nothing on
  failure. Mobile networks fail constantly; this is a real defect, not polish.
- No retry or offline handling on a critical path.

## Secrets and platform

- **Any API key, token, or secret in the JS bundle.** The bundle is trivially
  extractable from a shipped app — `.env` values inlined at build time,
  `Config.SECRET`, or a literal in source are all exposed. A *publishable* or
  *anon* key designed for client use is not a finding; confirm which it is
  before flagging.
- Sensitive values in `AsyncStorage` (unencrypted) rather than Keychain/Keystore.
- `Platform.OS` branches where one branch is missing a case or where the
  fallback silently does nothing on the untested platform.
- Permission requests with no denial path — the app assumes the grant.
- Absolute pixel values where a device with a different scale or a notch will
  break the layout; missing `SafeAreaView` on a full-screen view.

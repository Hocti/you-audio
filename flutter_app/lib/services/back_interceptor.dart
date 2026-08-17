/// Routes the Android back gesture into a nested view that isn't a route.
///
/// Tabs are shown in an `IndexedStack`, not pushed onto the `Navigator`, so a
/// view *inside* a tab (the Channel tab's detail view, an open search field)
/// can't be popped the usual way — without this, back would skip straight past
/// it and quit the app.
///
/// The tab registers a [handler]; the host ([MainScaffold]) calls
/// [handleBack] first and only changes tabs / leaves the app if nothing
/// consumed the press.
class BackInterceptor {
  bool Function()? _handler;

  void register(bool Function() handler) => _handler = handler;

  /// Clears [handler] if it is still the registered one — so a tab being
  /// disposed can't unregister its replacement's handler.
  void unregister(bool Function() handler) {
    if (_handler == handler) _handler = null;
  }

  /// Runs the registered handler. Returns true if it consumed the back press.
  bool handleBack() => _handler?.call() ?? false;
}

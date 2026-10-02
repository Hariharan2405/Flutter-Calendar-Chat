import 'dart:async';

/// One upstream subscription shared by every listener, with replay.
///
/// Two problems this exists to solve, both of which bit this app:
///
/// 1. `StreamBuilder(stream: service.something())` re-evaluates `stream:` on
///    every rebuild. If the call returns a fresh `.snapshots()` each time, the
///    builder unsubscribes and resubscribes on every rebuild — so an unrelated
///    parent rebuild silently tears down and recreates a Firestore listener
///    over an entire collection.
/// 2. A plain `asBroadcastStream()` cached in a static closes permanently once
///    its last listener cancels, so the next screen to listen attaches to a
///    dead stream and waits forever.
///
/// [stream] is safe to call from `build()`: it always hands back the same
/// underlying subscription, and a new listener immediately receives the most
/// recent value instead of waiting for the next upstream change.
class SharedStream<T> {
  SharedStream(this._source);

  final Stream<T> Function() _source;

  StreamController<T>? _controller;
  StreamSubscription<T>? _sub;
  T? _last;
  bool _hasLast = false;

  /// The most recently seen value, or null if nothing has arrived yet.
  T? get lastValue => _last;

  Stream<T> stream() async* {
    final controller = _controller ??= StreamController<T>.broadcast();
    _sub ??= _source().listen(
      (v) {
        _last = v;
        _hasLast = true;
        if (!controller.isClosed) controller.add(v);
      },
      onError: (Object e, StackTrace st) {
        if (!controller.isClosed) controller.addError(e, st);
      },
    );
    // Replay so a re-entered screen paints from cache rather than showing a
    // spinner until the next upstream change.
    if (_hasLast) yield _last as T;
    yield* controller.stream;
  }

  /// Drops the upstream subscription. Only for sign-out/teardown — the point
  /// of this class is that the subscription outlives individual screens.
  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
    await _controller?.close();
    _controller = null;
    _last = null;
    _hasLast = false;
  }
}

/// A [SharedStream] per key, for streams parameterised by something stable for
/// the session (a uid, a group id).
class KeyedSharedStreams<K, T> {
  KeyedSharedStreams(this._build);

  final Stream<T> Function(K key) _build;
  final Map<K, SharedStream<T>> _byKey = {};

  Stream<T> stream(K key) =>
      (_byKey[key] ??= SharedStream<T>(() => _build(key))).stream();

  T? lastValue(K key) => _byKey[key]?.lastValue;

  Future<void> closeAll() async {
    for (final s in _byKey.values) {
      await s.close();
    }
    _byKey.clear();
  }
}

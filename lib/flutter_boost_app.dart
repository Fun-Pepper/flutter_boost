import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import 'boost_container.dart';
import 'boost_flutter_router_api.dart';
import 'boost_interceptor.dart';
import 'boost_lifecycle_binding.dart';
import 'boost_navigator.dart';
import 'logger.dart';
import 'messages.dart';
import 'overlay_entry.dart';

typedef FlutterBoostAppBuilder = Widget Function(Widget home);

class FlutterBoostApp extends StatefulWidget {
  FlutterBoostApp(
    FlutterBoostRouteFactory routeFactory, {
    FlutterBoostAppBuilder appBuilder,
    String initialRoute,

    ///interceptors is to intercept push operation now
    List<BoostInterceptor> interceptors,
  })  : appBuilder = appBuilder ?? _materialAppBuilder,
        interceptors = interceptors ?? <BoostInterceptor>[],
        initialRoute = initialRoute ?? '/' {
    BoostNavigator.instance.routeFactory = routeFactory;
  }

  final FlutterBoostAppBuilder appBuilder;
  final String initialRoute;

  ///A list of [BoostInterceptor],to intercept operations when push
  final List<BoostInterceptor> interceptors;

  static Widget _materialAppBuilder(Widget home) {
    return MaterialApp(home: home);
  }

  @override
  State<StatefulWidget> createState() => FlutterBoostAppState();
}

class FlutterBoostAppState extends State<FlutterBoostApp> {
  final Map<String, Completer<Object>> _pendingResult =
      <String, Completer<Object>>{};

  List<BoostContainer> get containers => _containers;
  final List<BoostContainer> _containers = <BoostContainer>[];

  /// All interceptors from widget
  List<BoostInterceptor> get interceptors => widget.interceptors;

  BoostContainer get topContainer => containers.last;

  NativeRouterApi get nativeRouterApi => _nativeRouterApi;
  NativeRouterApi _nativeRouterApi;

  BoostFlutterRouterApi get boostFlutterRouterApi => _boostFlutterRouterApi;
  BoostFlutterRouterApi _boostFlutterRouterApi;

  final Set<int> _activePointers = <int>{};

  @override
  void initState() {
    _containers.add(_createContainer(PageInfo(pageName: widget.initialRoute)));
    _nativeRouterApi = NativeRouterApi();
    _boostFlutterRouterApi = BoostFlutterRouterApi(this);
    super.initState();

    // Refresh the containers data to overlayKey to show the page matching
    // initialRoute. Use addPostFrameCallback is because to wait
    // overlayKey.currentState to load complete....
    WidgetsBinding.instance.addPostFrameCallback((_) {
      refresh();
    });

    // try to restore routes from host when hot restart.
    assert(() {
      _restoreStackForHotRestart();
      return true;
    }());
  }

  @override
  Widget build(BuildContext context) {
    return widget.appBuilder(WillPopScope(
        onWillPop: () async {
          final canPop = topContainer.navigator.canPop();
          if (canPop) {
            topContainer.navigator.pop();
            return true;
          }
          return false;
        },
        child: Listener(
            onPointerDown: _handlePointerDown,
            onPointerUp: _handlePointerUpOrCancel,
            onPointerCancel: _handlePointerUpOrCancel,
            child: Overlay(
              key: overlayKey,
              initialEntries: const <OverlayEntry>[],
            ))));
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
  }

  void _handlePointerUpOrCancel(PointerEvent event) {
    _activePointers.remove(event.pointer);
  }

  void _cancelActivePointers() {
    _activePointers.toList().forEach(WidgetsBinding.instance.cancelPointer);
  }

  void refresh() {
    refreshAllOverlayEntries(containers);

    // try to save routes to host.
    assert(() {
      _saveStackForHotRestart();
      return true;
    }());
  }

  String _createUniqueId(String pageName) {
    return '${DateTime.now().millisecondsSinceEpoch}_$pageName';
  }

  BoostContainer _createContainer(PageInfo pageInfo) {
    pageInfo.uniqueId ??= _createUniqueId(pageInfo.pageName);
    return BoostContainer(
        key: ValueKey<String>(pageInfo.uniqueId), pageInfo: pageInfo);
  }

  Future<void> _saveStackForHotRestart() async {
    final stack = StackInfo();
    stack.containers = <String>[];
    for (var container in containers) {
      stack.containers.add(container.pageInfo.uniqueId);
      stack.routes = <String, List<Map<String, Object>>>{};
      final params = <Map<String, Object>>[];
      for (var page in container.pages) {
        final param = <String, Object>{};
        param['pageName'] = page.pageInfo.pageName;
        param['uniqueId'] = page.pageInfo.uniqueId;
        param['arguments'] = page.pageInfo.arguments;
        params.add(param);
      }
      stack.routes[container.pageInfo.uniqueId] = params;
    }
    await nativeRouterApi.saveStackToHost(stack);
    Logger.log(
        '_saveStackForHotRestart, ${stack?.containers}, ${stack?.routes}');
  }

  Future<void> _restoreStackForHotRestart() async {
    final stack = await nativeRouterApi.getStackFromHost();
    if (stack != null && stack.containers != null) {
      for (String uniqueId in stack.containers) {
        var withContainer = true;
        final List<Object> routeList = stack.routes[uniqueId];
        if (routeList != null) {
          for (Map<Object, Object> route in routeList) {
            push(route['pageName'] as String,
                uniqueId: route['uniqueId'] as String,
                arguments: Map<String, dynamic>.from(
                    route['arguments'] ?? <String, dynamic>{}),
                withContainer: withContainer);
            withContainer = false;
          }
        }
      }
    }
    Logger.log(
        '_restoreStackForHotRestart, ${stack?.containers}, ${stack?.routes}');
  }

  Future<T> pushWithResult<T extends Object>(String pageName,
      {String uniqueId,
      Map<String, dynamic> arguments,
      bool withContainer,
      bool opaque = true}) {
    final completer = Completer<T>();
    assert(uniqueId == null);
    uniqueId = _createUniqueId(pageName);
    if (withContainer) {
      final params = CommonParams()
        ..pageName = pageName
        ..uniqueId = uniqueId
        ..opaque = opaque
        ..arguments = arguments ?? <String, dynamic>{};
      nativeRouterApi.pushFlutterRoute(params);
    } else {
      push(pageName,
          uniqueId: uniqueId, arguments: arguments, withContainer: false);
    }
    _pendingResult[uniqueId] = completer;
    return completer.future;
  }

  void push(String pageName,
      {String uniqueId, Map<String, dynamic> arguments, bool withContainer}) {
    _cancelActivePointers();
    final existed = _findContainerByUniqueId(uniqueId);
    if (existed != null) {
      if (topContainer?.pageInfo?.uniqueId != uniqueId) {
        containers.remove(existed);
        containers.add(existed);

        //move the overlayEntry which matches this existing container to the top
        refreshOnMoveToTop(existed);
      }
    } else {
      final pageInfo = PageInfo(
          pageName: pageName,
          uniqueId: uniqueId ?? _createUniqueId(pageName),
          arguments: arguments,
          withContainer: withContainer);
      if (withContainer) {
        final container = _createContainer(pageInfo);
        final previousContainer = topContainer;
        containers.add(container);
        BoostLifecycleBinding.instance
            .containerDidPush(container, previousContainer);

        // Add a new overlay entry with this container
        refreshOnPush(container);
      } else {
        // In this case , we don't need to change the overlayEntries data,
        // so we don't call any refresh method
        topContainer.pages.add(BoostPage.create(pageInfo));
        topContainer.refresh();
      }
    }
    Logger.log('push page, uniqueId=$uniqueId, existed=$existed,'
        ' withContainer=$withContainer, arguments:$arguments, $containers');
  }

  Future<bool> popWithResult<T extends Object>([T result]) async {
    final uniqueId = topContainer?.topPage?.pageInfo?.uniqueId;
    if (_pendingResult.containsKey(uniqueId)) {
      _pendingResult[uniqueId].complete(result);

      ///Need to remove this completer after calling completer.complete(result)
      /// reason: https://github.com/alibaba/flutter_boost/issues/1020
      _pendingResult.remove(uniqueId);
    }

    return await (result is Map<String, dynamic>
        ? pop(arguments: result)
        : pop());
  }

  Future<bool> pop({String uniqueId, Map<String, dynamic> arguments}) async {
    BoostContainer container;
    if (uniqueId != null) {
      container = _findContainerByUniqueId(uniqueId);
      if (container == null) {
        Logger.error('uniqueId=$uniqueId not find');
        return false;
      }
      if (container != topContainer) {
        await _removeContainer(container);
        return true;
      }
    } else {
      container = topContainer;
    }

    final currentPage = topContainer?.topPage?.pageInfo?.uniqueId;
    assert(currentPage != null);
    _completePendingResultIfNeeded(currentPage);

    final handled = await container?.navigator?.maybePop();
    if (handled != null && !handled) {
      assert(container.pageInfo.withContainer);
      final params = CommonParams()
        ..pageName = container.pageInfo.pageName
        ..uniqueId = container.pageInfo.uniqueId
        ..arguments = arguments ?? <String, dynamic>{};
      await nativeRouterApi.popRoute(params);
    }

    Logger.log(
        'pop container, uniqueId=$uniqueId, arguments:$arguments, $container');
    return true;
  }

  void _removeContainer(BoostContainer page) async {
    containers.remove(page);
    if (page.pageInfo.withContainer) {
      Logger.log('_removeContainer ,  uniqueId=${page.pageInfo.uniqueId}');
      final params = CommonParams()
        ..pageName = page.pageInfo.pageName
        ..uniqueId = page.pageInfo.uniqueId
        ..arguments = page.pageInfo.arguments;
      await _nativeRouterApi.popRoute(params);
    }
  }

  void onForeground() {
    BoostLifecycleBinding.instance.appDidEnterForeground(topContainer);
  }

  void onBackground() {
    BoostLifecycleBinding.instance.appDidEnterBackground(topContainer);
  }

  BoostContainer _findContainerByUniqueId(String uniqueId) {
    return containers.singleWhere(
        (element) => element.pageInfo.uniqueId == uniqueId,
        orElse: () => null);
  }

  void remove(String uniqueId) {
    if (uniqueId == null) {
      return;
    }

    final container = _findContainerByUniqueId(uniqueId);
    if (container != null) {
      containers.remove(container);
      BoostLifecycleBinding.instance.containerDidPop(container, topContainer);
      //remove the overlayEntry matching this container
      refreshOnRemove(container);
    } else {
      for (var container in containers) {
        final page = container.pages.singleWhere(
            (entry) => entry.pageInfo.uniqueId == uniqueId,
            orElse: () => null);

        if (page != null) {
          container.pages.remove(page);
          container.refresh();
        }
      }
    }
    Logger.log('remove,  uniqueId=$uniqueId, $containers');
  }

  Future<T> pendNativeResult<T extends Object>(String pageName) {
    final completer = Completer<T>();
    final initiatorPage = topContainer?.topPage?.pageInfo?.uniqueId;
    final key = '$initiatorPage#$pageName';
    _pendingResult[key] = completer;
    Logger.log('pendNativeResult, key:$key, size:${_pendingResult.length}');
    return completer.future;
  }

  void onNativeResult(CommonParams params) {
    final initiatorPage = topContainer?.topPage?.pageInfo?.uniqueId;
    final key = '$initiatorPage#${params.pageName}';
    if (_pendingResult.containsKey(key)) {
      _pendingResult[key].complete(params.arguments);
      _pendingResult.remove(key);
    }
    Logger.log('onNativeResult, key:$key, result:${params.arguments}');
  }

  void _completePendingNativeResultIfNeeded(String initiatorPage) {
    _pendingResult.keys
        .where((element) => element.startsWith('$initiatorPage#'))
        .toList()
        .forEach((key) {
      _pendingResult[key].complete();
      _pendingResult.remove(key);
      Logger.log('_completePendingNativeResultIfNeeded, '
          'key:$key, size:${_pendingResult.length}');
    });
  }

  void _completePendingResultIfNeeded(String uniqueId) {
    if (uniqueId != null && _pendingResult.containsKey(uniqueId)) {
      _pendingResult[uniqueId].complete();
      _pendingResult.remove(uniqueId);
    }
  }

  void onContainerShow(CommonParams params) {
    final container = _findContainerByUniqueId(params.uniqueId);
    BoostLifecycleBinding.instance.containerDidShow(container);

    // Try to complete pending native result when container closed.
    final topPage = topContainer?.topPage?.pageInfo?.uniqueId;
    assert(topPage != null);
    Future<void>.delayed(
      const Duration(seconds: 1),
      () => _completePendingNativeResultIfNeeded(topPage),
    );
  }

  void onContainerHide(CommonParams params) {
    final container = _findContainerByUniqueId(params.uniqueId);
    BoostLifecycleBinding.instance.containerDidHide(container);
  }

  PageInfo getTopPageInfo() {
    return topContainer?.topPage?.pageInfo;
  }

  int pageSize() {
    var count = 0;
    for (var container in containers) {
      count += container.size;
    }
    return count;
  }

  ///
  ///======== refresh method below ===============
  ///

  void refreshOnPush(BoostContainer container) {
    refreshSpecificOverlayEntries(container, BoostSpecificEntryRefreshMode.add);
    assert(() {
      _saveStackForHotRestart();
      return true;
    }());
  }

  void refreshOnRemove(BoostContainer container) {
    refreshSpecificOverlayEntries(
        container, BoostSpecificEntryRefreshMode.remove);
    assert(() {
      _saveStackForHotRestart();
      return true;
    }());
  }

  void refreshOnMoveToTop(BoostContainer container) {
    refreshSpecificOverlayEntries(
        container, BoostSpecificEntryRefreshMode.moveToTop);
    assert(() {
      _saveStackForHotRestart();
      return true;
    }());
  }
}

// ignore: must_be_immutable
class BoostPage<T> extends Page<T> {
  BoostPage({LocalKey key, this.pageInfo})
      : super(key: key, name: pageInfo.pageName, arguments: pageInfo.arguments);
  final PageInfo pageInfo;

  static BoostPage<dynamic> create(PageInfo pageInfo) {
    final page = BoostPage<dynamic>(key: UniqueKey(), pageInfo: pageInfo);
    page._route = BoostNavigator.instance.routeFactory(page, pageInfo.uniqueId);
    return page;
  }

  Route<T> _route;

  Route<T> get route => _route;

  @override
  String toString() => '${objectRuntimeType(this, 'BoostPage')}(name:$name,'
      ' uniqueId:${pageInfo.uniqueId}, arguments:$arguments)';

  @override
  Route<T> createRoute(BuildContext context) {
    return _route;
  }
}

class BoostNavigatorObserver extends NavigatorObserver {
  BoostNavigatorObserver();

  @override
  void didPush(Route<dynamic> route, Route<dynamic> previousRoute) {
    //handle internal route
    if (previousRoute != null) {
      BoostLifecycleBinding.instance.routeDidPush(route, previousRoute);
    }
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic> previousRoute) {
    if (previousRoute != null) {
      BoostLifecycleBinding.instance.routeDidPop(route, previousRoute);
    }
    super.didPop(route, previousRoute);
  }
}

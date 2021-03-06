library atom.console;

import 'dart:html' show ScrollAlignment;

import '../atom.dart';
import '../atom_statusbar.dart';
import '../elements.dart';
import '../launch.dart';
import '../state.dart';
import '../utils.dart';
import '../views.dart';

class ConsoleController implements Disposable {
  ConsoleView view;
  ConsoleStatusElement statusElement;

  Disposables disposables = new Disposables();

  ConsoleController() {
    view = new ConsoleView();
    statusElement = new ConsoleStatusElement(this, false);

    disposables.add(atom.commands
        .add('atom-workspace', '${pluginId}:toggle-console', (_) {
      _toggleView();
    }));
  }

  void initStatusBar(StatusBar statusBar) {
    statusElement._init(statusBar);
  }

  void _toggleView() => view.toggle();

  void dispose() {
    view.dispose();
    statusElement.dispose();
    disposables.dispose();
  }
}

// TODO: Close button somewhere?

class ConsoleView extends AtomView {
  static bool get autoShowConsole => atom.config.getValue('${pluginId}.autoShowConsole');

  CoreElement tabsElement;

  _LaunchController _activeController;
  Map<Launch, _LaunchController> _controllers = {};

  ConsoleView() : super('Console', classes: 'console-view dartlang', prefName: 'Console',
      rightPanel: false, showTitle: false) {
    //root.toggleClass('tree-view', false);

    content..add([
      div(c: 'console-title-area')..add([
        tabsElement = div(c: 'console-tabs')
      ])
    ]);

    subs.add(launchManager.onLaunchAdded.listen(_launchAdded));
    subs.add(launchManager.onLaunchActivated.listen(_launchActivated));
    subs.add(launchManager.onLaunchTerminated.listen(_launchTerminated));
    subs.add(launchManager.onLaunchRemoved.listen(_launchRemoved));
  }

  void _launchAdded(Launch launch) {
    _controllers[launch] = new _LaunchController(this, launch);

    // Auto show when a launch starts.
    if (!isVisible() && autoShowConsole) {
      show();
    }
  }

  void _launchTerminated(Launch launch) {
    _controllers[launch].handleTerminated();
  }

  void _launchActivated(Launch launch) {
    if (_activeController != null) _activeController.deactivate();
    _activeController = _controllers[launch];
    if (_activeController != null) _activeController.activate();
  }

  void _launchRemoved(Launch launch) {
    _controllers.remove(launch).dispose();

    if (_controllers.isEmpty && isVisible()) hide();
  }
}

class _LaunchController implements Disposable {
  // Only show a set amount of lines of output.
  static const _max_lines = 200;

  final ConsoleView view;
  final Launch launch;

  CoreElement container;
  CoreElement title;
  CoreElement buttons;
  CoreElement output;
  StreamSubscriptions subs = new StreamSubscriptions();

  _LaunchController(this.view, this.launch) {
    view.tabsElement.add([
      container = div(c: 'badge process-tab')..add([
        span(text: launch.launchType.type),
        span(text: ' • '),
        title = span(text: launch.title),
        span(text: ' • '),
        buttons = div(c: 'run-buttons')
      ])
    ]);
    title.click(() => launch.manager.setActiveLaunch(launch));

    _updateToggles();
    _updateButtons();

    output = new CoreElement('pre', classes: 'console-line');

    subs.add(launch.onStdout.listen((str) => _emitText(str)));
    subs.add(launch.onStderr.listen((str) => _emitText(str, true)));
  }

  void activate() {
    _updateToggles();
    _updateButtons();
    view.content.add(output.element);
  }

  void handleTerminated() {
    _updateToggles();
    _updateButtons();

    container.toggleClass('launch-terminated', true);
    title.text = '${launch.title} [${launch.exitCode}]';

    _emitText('\n');
    _emitBadge('exit code ${launch.exitCode}', launch.errored ? 'error' : 'info');
  }

  void deactivate() {
    _updateToggles();
    _updateButtons();
    output.dispose();
  }

  void _updateToggles() {
    container.toggleClass('badge-info', launch.isActive && !launch.errored);
    container.toggleClass('badge-error', launch.isActive && launch.errored);
  }

  void _updateButtons() {
    buttons.clear();

    // debug
    if (launch.isRunning && launch.canDebug()) {
      CoreElement debug = buttons.add(
          span(text: '\u200B', c: 'process-icon icon-bug'));
      debug.toggleClass('text-highlight', launch.isActive);
      debug.click(() {
        shell.openExternal('http://localhost:${launch.servicePort}/');
      });
    }

    // kill
    if (launch.canKill() && launch.isRunning) {
      CoreElement kill = buttons.add(
          span(text: '\u200B', c: 'process-icon icon-primitive-square'));
      kill.toggleClass('text-highlight', launch.isActive);
      kill.click(() => launch.kill());
    }

    // clear
    if (launch.isTerminated) {
      CoreElement clear = buttons.add(
          span(text: '\u200B', c: 'process-icon icon-x'));
      clear.toggleClass('text-highlight', launch.isActive);
      clear.click(() => launchManager.removeLaunch(launch));
    }
  }

  void dispose() {
    container.dispose();
    output.dispose();
    subs.cancel();
  }

  void _emitBadge(String text, String type) {
    output.add(span(text: text, c: 'badge badge-${type}'));

    if (output.element.parent != null) {
      output.element.scrollIntoView(ScrollAlignment.BOTTOM);
    }
  }

  void _emitText(String str, [bool error = false]) {
    CoreElement e = output.add(span(text: str));
    if (error) e.toggleClass('console-error');

    List children = output.element.children;
    if (children.length > _max_lines) {
      children.remove(children.first);
    }

    if (output.element.parent != null) {
      output.element.scrollIntoView(ScrollAlignment.BOTTOM);
    }
  }
}

class ConsoleStatusElement implements Disposable {
  final ConsoleController parent;
  bool _showing;
  StreamSubscriptions subs = new StreamSubscriptions();

  Tile statusTile;

  CoreElement _element;
  CoreElement _badgeSpan;

  ConsoleStatusElement(this.parent, this._showing) {
    subs.add(launchManager.onLaunchAdded.listen(_handleLaunchesChanged));
    subs.add(launchManager.onLaunchTerminated.listen(_handleLaunchesChanged));
    subs.add(launchManager.onLaunchRemoved.listen(_handleLaunchesChanged));
  }

  bool isShowing() => _showing;

  void show() {
    _element.element.style.display = 'inline-block';
    _showing = true;
  }

  void hide() {
    _element.element.style.display = 'none';
    _showing = false;
  }

  void dispose() {
    if (statusTile != null) statusTile.destroy();
    subs.cancel();
  }

  void _init(StatusBar statusBar) {
    _element = div(c: 'dartlang')..inlineBlock()..add([
      _badgeSpan = span(c: 'badge')
    ]);

    _element.click(parent._toggleView);

    statusTile = statusBar.addRightTile(item: _element.element, priority: 200);

    if (!isShowing()) {
      _element.element.style.display = 'none';
    }

    _handleLaunchesChanged();
  }

  void _handleLaunchesChanged([_]) {
    if (_element == null) return;

    List<Launch> launches = launchManager.launches;
    int count = launches.length;

    if (count > 0) {
      if (!isShowing()) show();
      _badgeSpan.text = '${count} application ${pluralize('process', count)}';
    } else {
      hide();
      _badgeSpan.text = 'no processes';
    }
  }
}

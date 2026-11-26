// Copyright (c) 2026 Chris Coetzee
// SPDX-License-Identifier: MIT
// The full license text is in LICENSE at the repository root.

import 'package:flutter/widgets.dart';

import '../state/home_controller.dart';

/// Hands the [HomeController] down the tree and rebuilds dependents when it
/// changes.
class HomeScope extends InheritedNotifier<HomeController> {
  const HomeScope({super.key, required HomeController home, required super.child}) : super(notifier: home);

  static HomeController of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<HomeScope>()!.notifier!;

  /// The controller without subscribing to changes, for callbacks.
  static HomeController read(BuildContext context) => context.getInheritedWidgetOfExactType<HomeScope>()!.notifier!;
}

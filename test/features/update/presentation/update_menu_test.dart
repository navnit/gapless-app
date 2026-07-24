import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/features/update/presentation/update_menu.dart';

void main() {
  test('buildAppMenus re-supplies standard menus and the update item', () {
    // Regression guard for the PlatformMenuBar-replaces-the-whole-menu risk:
    // if a standard provided item were dropped, users would lose it on launch.
    final menus = buildAppMenus(onCheckForUpdates: () {});

    final all = <PlatformMenuItem>[];
    void visit(List<PlatformMenuItem> items) {
      for (final item in items) {
        all.add(item);
        if (item is PlatformMenu) visit(item.menus);
      }
    }

    visit(menus);

    final providedTypes = all
        .whereType<PlatformProvidedMenuItem>()
        .map((item) => item.type)
        .toSet();
    expect(
      providedTypes,
      containsAll(<PlatformProvidedMenuItemType>[
        PlatformProvidedMenuItemType.about,
        PlatformProvidedMenuItemType.quit,
        PlatformProvidedMenuItemType.hide,
      ]),
    );

    expect(
      all.any((item) => item.label == 'Check for Updates…'),
      isTrue,
      reason: 'the manual check menu item must be present',
    );
  });

  test('the Check for Updates item invokes the callback', () {
    var invoked = false;
    final menus = buildAppMenus(onCheckForUpdates: () => invoked = true);

    PlatformMenuItem? found;
    void visit(List<PlatformMenuItem> items) {
      for (final item in items) {
        if (item.label == 'Check for Updates…') found = item;
        if (item is PlatformMenu) visit(item.menus);
      }
    }

    visit(menus);
    expect(found, isNotNull);
    found!.onSelected!();
    expect(invoked, isTrue);
  });
}

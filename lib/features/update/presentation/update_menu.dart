import 'package:flutter/material.dart';

List<PlatformMenuItem> buildAppMenus({
  required VoidCallback onCheckForUpdates,
}) => [
  PlatformMenu(
    label: 'Gapless',
    menus: [
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
      PlatformMenuItem(
        label: 'Check for Updates…',
        onSelected: onCheckForUpdates,
      ),
      const PlatformProvidedMenuItem(
        type: PlatformProvidedMenuItemType.servicesSubmenu,
      ),
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
      const PlatformProvidedMenuItem(
        type: PlatformProvidedMenuItemType.hideOtherApplications,
      ),
      const PlatformProvidedMenuItem(
        type: PlatformProvidedMenuItemType.showAllApplications,
      ),
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
    ],
  ),
  const PlatformMenu(
    label: 'Window',
    menus: [
      PlatformProvidedMenuItem(
        type: PlatformProvidedMenuItemType.minimizeWindow,
      ),
      PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
    ],
  ),
];

import 'package:duanju_app/sync/sync_controller.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/settings/settings_page.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final form in [FormFactor.pad, FormFactor.window]) {
    testWidgets('sync fields remain visible above the keyboard on $form', (
      tester,
    ) async {
      const size = Size(1280, 800);
      const keyboardHeight = 360.0;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final store = (await tester.runAsync(() => openStore()))!;
      final sync = SyncController(store);
      try {
        await tester.pumpWidget(
          AppScope(
            repository: FakeRepository(),
            formFactor: form,
            child: MaterialApp(home: AppShell(store: store)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('我的'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-sync')));
        await tester.pumpAndSettle();

        for (final label in ['坚果云账号（邮箱）', '应用密码', '设备名称']) {
          final field = find.byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.labelText == label,
          );
          await tester.ensureVisible(field);
          await tester.tap(field);
          tester.view.viewInsets = const FakeViewPadding(
            bottom: keyboardHeight,
          );
          await tester.pumpAndSettle();

          final viewport = find.descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(SingleChildScrollView),
          );
          // The visible form must retain usable height instead of reserving
          // another keyboard-sized gap inside an already resized app shell.
          expect(tester.getSize(viewport).height, greaterThan(300));
          final editable = find.descendant(
            of: field,
            matching: find.byType(EditableText),
          );
          final rect = tester.getRect(editable);
          expect(rect.top, greaterThanOrEqualTo(tester.getRect(viewport).top));
          expect(rect.bottom, lessThanOrEqualTo(size.height - keyboardHeight));
          expect(
            tester.widget<EditableText>(editable).focusNode.hasFocus,
            isTrue,
          );
          expect(tester.takeException(), isNull);

          await tester.enterText(
            field,
            label == '应用密码' ? 'test-password' : 'test',
          );
          tester.view.viewInsets = const FakeViewPadding();
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(field).controller!.text,
            label == '应用密码' ? 'test-password' : 'test',
          );
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        sync.dispose();
      }
    });
  }
}

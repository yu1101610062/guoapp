import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/history/history_page.dart';
import 'support/fakes.dart';

void main() {
  for (final form in [FormFactor.phone, FormFactor.window]) {
    testWidgets(
      'clear all from $form UI prevents unseen old history resurrection',
      (tester) async {
        tester.view.physicalSize = form == FormFactor.phone
            ? const Size(420, 900)
            : const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = (await tester.runAsync(() => openStore()))!;
        final remote = (await tester.runAsync(() => openStore()))!;
        await tester.runAsync(() async {
          await store.saveWatch(watching(drama('visible')));
          await remote.saveWatch(watching(drama('unseen', source: 'guipian')));
        });
        await tester.pumpWidget(
          AppScope(
            repository: FakeRepository(),
            formFactor: form,
            child: MaterialApp(home: HistoryPage(store: store)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('清空全部'));
        await tester.pumpAndSettle();
        expect(find.textContaining('包括未显示的旧记录'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '清空'));
        await tester.runAsync(() => pumpEventQueue());
        await tester.pumpAndSettle();
        expect(store.syncState.clearHistory, isNotNull);
        await tester.runAsync(
          () => store.mergeSync([
            remote.syncState.categoryJson('history'),
          ], epoch: store.profileEpoch),
        );
        expect(store.history, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('filtered clear only deletes displayed history', (tester) async {
    final store = (await tester.runAsync(() => openStore()))!;
    await tester.runAsync(() async {
      await store.saveWatch(watching(drama('alpha', title: 'Alpha')));
      await store.saveWatch(watching(drama('beta', title: 'Beta')));
    });
    await tester.pumpWidget(
      AppScope(
        repository: FakeRepository(),
        formFactor: FormFactor.phone,
        child: MaterialApp(home: HistoryPage(store: store)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Alpha');
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空当前'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpAndSettle();
    expect(store.syncState.clearHistory, isNull);
    expect(store.history.single.drama.title, 'Beta');
    await tester.pumpWidget(const SizedBox());
  });
}

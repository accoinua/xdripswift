# Збірка китайського SIBIONICS GS1 через GitHub Actions

Ця гілка призначена лише для китайського SIBIONICS GS1 з алгоритмом V115G.
Вона не додає SIBIONICS 2, європейський V120 і не змінює Trio.

## Що перевіряє CI

Workflow `0. Verify Chinese SIBIONICS`:

1. перевіряє SHA-256 вбудованого JavaScript-бандла V115G;
2. проганяє детермінований вектор із 3153 зразків;
3. перевіряє відновлення стану алгоритму зі snapshot;
4. збирає весь workspace `xdrip.xcworkspace` для iOS Simulator без сертифікатів;
5. зберігає simulator `.app.zip` і повний Xcode build log як GitHub artifacts.

Simulator artifact підтверджує, що код, Core Data model і ресурс алгоритму
компілюються разом. Це не підписаний IPA і його не можна встановити на iPhone.
BLE-роботу з реальним сенсором треба окремо перевірити на фізичному iPhone.

## 1. Створити або відкрити форк

1. Відкрийте <https://github.com/JohanDegraeve/xdripswift>.
2. Натисніть **Fork** і створіть `ВАШ_ЛОГІН/xdripswift`.
3. У форку відкрийте **Actions** і, якщо GitHub попросить, натисніть
   **I understand my workflows, go ahead and enable them**.

## 2. Прив'язати локальний репозиторій до форку

У PowerShell замініть `ВАШ_ЛОГІН` своїм GitHub username:

```powershell
Set-Location C:\gpt\xdripswift
git remote rename origin upstream
git remote add origin https://github.com/ВАШ_ЛОГІН/xdripswift.git
git remote -v
git push -u origin sibionics-chinese-v115g
```

Під час першого HTTPS push Git Credential Manager може відкрити браузер для
входу в GitHub. Не вводьте пароль GitHub як git-пароль: GitHub приймає token,
SSH або браузерну авторизацію через credential helper.

## 3. Перевірити unsigned build

Push у `sibionics-chinese-v115g` автоматично запускає workflow
**0. Verify Chinese SIBIONICS**.

1. Відкрийте форк → **Actions** → **0. Verify Chinese SIBIONICS**.
2. Відкрийте найновіший run і дочекайтеся зеленої позначки.
3. Унизу сторінки, у **Artifacts**, завантажте:
   - `xdrip-sibionics-chinese-simulator` — unsigned simulator app;
   - `xdrip-sibionics-chinese-build-log` — журнал `xcodebuild`.

Після появи workflow у default branch його також можна запускати кнопкою
**Run workflow**. До цього push-trigger уже працює без ручного запуску.

## 4. Підготувати підписаний IPA / TestFlight

Для встановлення на iPhone потрібен платний Apple Developer account та шість
GitHub Actions secrets:

- `TEAMID`
- `FASTLANE_ISSUER_ID`
- `FASTLANE_KEY_ID`
- `FASTLANE_KEY`
- `GH_PAT`
- `MATCH_PASSWORD`

Повний опис створення ключів і App Store Connect app є у
[`fastlane/testflight.md`](fastlane/testflight.md). Секрети додаються у форку:
**Settings → Secrets and variables → Actions → Secrets**.

### Обов'язково захистити кастомну гілку від upstream sync

У форку відкрийте **Settings → Secrets and variables → Actions → Variables** і
створіть repository variable:

```text
SCHEDULED_SYNC=false
```

Рекомендовано також вимкнути автоматичні build-и, доки підтримка сенсора не
пройде перевірку на реальному iPhone:

```text
SCHEDULED_BUILD=false
```

Без `SCHEDULED_SYNC=false` штатний workflow може спробувати синхронізувати
кастомну гілку з upstream, де гілки `sibionics-chinese-v115g` немає.

## 5. Запустити signed build

У вкладці **Actions** послідовно запускайте workflow-и. У dropdown **Branch**
щоразу вибирайте `sibionics-chinese-v115g`:

1. **1. Validate Secrets**
2. **2. Add Identifiers**
3. налаштуйте App Groups та App Store Connect app за `fastlane/testflight.md`;
4. **3. Create Certificates**
5. **4. Build xDrip4iOS**

Signed workflow перед архівацією повторно запускає детерміновану перевірку
V115G. Після успіху він завантажує build у TestFlight, а artifact
`build-artifacts` містить IPA, symbols і build log.

## 6. Критерій готовності релізу

Не вважайте підтримку сенсора завершеною лише через зелений CI. Мінімальна
перевірка на фізичному iPhone з китайським GS1 має підтвердити:

- знаходження та підключення до сенсора;
- приймання live-пакетів FF30/FF31/FF32;
- коректний запуск із QR-кодом або 8-символьним sensitivity code;
- відновлення після перезапуску застосунку й розриву Bluetooth;
- заповнення пропущеної історії;
- стабільну передачу отриманих значень штатним механізмом xDrip4iOS.

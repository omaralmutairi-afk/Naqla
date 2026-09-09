<p align="center">
  <img src=".github/assets/icon.png" width="120" alt="نَقْلة icon">
</p>

<h1 align="center">نَقْلة (Naqla)</h1>

<p align="center">
  عجلة تطبيقات عائمة لنظام macOS — تطبيقاتك الأخيرة، على قوس، عند زاوية شاشتك.
</p>

<p align="center">
  <a href="#العربية">العربية</a> · <a href="#english">English</a>
</p>

---

## العربية

### الغرض من التطبيق

**نَقْلة** بديل سريع لـ⌘Tab أو الـ Dock: عجلة صغيرة تختفي تمامًا عن أنظارك حتى تحتاجها، تظهر باختصار لوحة مفاتيح واحد، وتعرض آخر تطبيقاتك المستخدَمة كأيقونات منتشرة على قوس ربع دائرة. تضغط على أي أيقونة تنتقل لتطبيقها فورًا — أو تخفيه لو كان أمامك أصلًا.

مبني كملف Swift واحد بدون Xcode، ويعمل بدون أي أيقونة في الـ Dock أو شريط القوائم. الواجهة تدعم العربية والإنجليزية، قابلة للتبديل من الإعدادات.

### الاستخدام

| الإجراء | النتيجة |
|---|---|
| `⌘⇧R` | إظهار/إخفاء العجلة (قابل للتغيير من الإعدادات) |
| تمرير الماوس فوق العجلة | تنتشر آخر التطبيقات على القوس |
| نقرة على أيقونة تطبيق | ينتقل إليه — أو يخفيه لو كان أماميًا بنافذة ظاهرة |
| تمرير + ✕ على أيقونة | إنهاء قسري لذاك التطبيق |
| نقر يمين على قلب العجلة | فتح الإعدادات أو إنهاء نَقْلة |
| سحب قلب العجلة | نقل العجلة — تلتصق بأقرب زاوية شاشة |

#### الإعدادات
اختصار الإظهار، أقصى عدد تطبيقات (٤–١٤)، حجم الأيقونات، لون العجلة، شفافيتها، لغة الواجهة (عربي/إنجليزي)، والتشغيل التلقائي عند بدء الماك.

#### الصلاحيات
تحتاج **Accessibility** — ليس لتسجيل ضغطات المفاتيح (الاختصار يعمل عبر Carbon بدون أي صلاحية)، بل لتمييز نافذة التطبيق الظاهرة من المصغّرة، فتعرف العجلة متى تُظهر ومتى تُخفي.

### البناء من المصدر

```bash
git clone https://github.com/omaralmutairi-afk/Naqla.git
cd Naqla
./build.sh   # يبني Naqla.app ويثبّته على سطح المكتب، موقّعًا محليًا
```

يحتاج macOS 13 فأعلى. لا يوجد مشروع Xcode — `build.sh` يستخدم `swiftc` مباشرة.

### الحالة

مكتمل، ومختبَر بأداة اختبار هندسية تستخرج معادلاته حرفيًا من الكود نفسه (٧٧١ تأكيدًا)، ومرّ بمراجعتي كود كاملتين اكتشفتا خلل تداخل الأيقونات وخلل زر الإنهاء القسري وأصلحتاهما.

---

## English

### Purpose

**Naqla** is a fast alternative to ⌘Tab or the Dock: a small wheel that stays completely out of sight until you need it, appears with one global hotkey, and shows your recently-used apps as icons fanned along a quarter-circle arc. Click any icon to switch to it instantly — or hide it if it's already in front.

Built as a single Swift file with no Xcode project, running with no Dock icon and no menu bar item. The interface supports both Arabic and English, switchable from Settings.

### Usage

| Action | Result |
|---|---|
| `⌘⇧R` | Show/hide the wheel (changeable in Settings) |
| Hover the wheel | Recent apps fan out along the arc |
| Click an app icon | Switches to it — or hides it if it's frontmost with a visible window |
| Hover + ✕ on an icon | Force-quit that app |
| Right-click the wheel's core | Open Settings or quit Naqla |
| Drag the wheel's core | Move the wheel — it snaps to the nearest screen corner |

#### Settings
Show/hide hotkey, max app count (4–14), icon size, wheel color, opacity, interface language (Arabic/English), and launch at startup.

#### Permissions
Requires **Accessibility** — not for recording keystrokes (the hotkey works via Carbon with no permission needed), but to tell a visible app window apart from a minimized one, so the wheel knows when to show versus hide.

### Building from source

```bash
git clone https://github.com/omaralmutairi-afk/Naqla.git
cd Naqla
./build.sh   # builds Naqla.app and installs it to the Desktop, locally signed
```

Requires macOS 13 or later. No Xcode project — `build.sh` calls `swiftc` directly.

### Status

Feature-complete, verified with a geometry test harness that extracts its formulas verbatim from the source (771 assertions), and has been through two full code review passes that found and fixed an icon-overlap bug and a force-quit button bug.

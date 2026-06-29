import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class HistoryItem {
  final String id;
  final String toolId;
  final String toolName;
  final String toolIcon; // icon codepoint as string
  final String fileName;
  final String filePath;
  final int fileSizeBytes;
  final DateTime createdAt;
  final Map<String, dynamic> settings;

  HistoryItem({
    required this.id,
    required this.toolId,
    required this.toolName,
    required this.toolIcon,
    required this.fileName,
    required this.filePath,
    required this.fileSizeBytes,
    required this.createdAt,
    this.settings = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'toolId': toolId,
        'toolName': toolName,
        'toolIcon': toolIcon,
        'fileName': fileName,
        'filePath': filePath,
        'fileSizeBytes': fileSizeBytes,
        'createdAt': createdAt.toIso8601String(),
        'settings': settings,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> json) => HistoryItem(
        id: json['id'] ?? '',
        toolId: json['toolId'] ?? '',
        toolName: json['toolName'] ?? '',
        toolIcon: json['toolIcon'] ?? '0xe3ae',
        fileName: json['fileName'] ?? '',
        filePath: json['filePath'] ?? '',
        fileSizeBytes: json['fileSizeBytes'] ?? 0,
        createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
        settings: Map<String, dynamic>.from(json['settings'] ?? {}),
      );

  String get formattedSize {
    if (fileSizeBytes > 1024 * 1024) {
      return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSizeBytes / 1024).toStringAsFixed(0)} KB';
  }

  String get formattedDate {
    final now = DateTime.now();
    final diff = now.difference(createdAt);
    if (diff.inMinutes < 1) return 'الآن';
    if (diff.inHours < 1) return 'منذ ${diff.inMinutes} دقيقة';
    if (diff.inDays < 1) return 'منذ ${diff.inHours} ساعة';
    if (diff.inDays < 30) return 'منذ ${diff.inDays} يوم';
    return '${createdAt.day}/${createdAt.month}/${createdAt.year}';
  }
}

class HistoryService {
  static const _key = 'pdf_master_history';
  static const _maxItems = 100;

  // ── إصلاح: تسلسل العمليات (queue) ───────────────────────────────────────
  // SharedPreferences لا يضمن atomicity لعمليات "اقرأ ثم عدّل ثم اكتب".
  // كانت add()/remove() كلاهما: تقرأ القائمة كاملة، تعدّلها، ثم تكتبها
  // كاملة. عند استدعاءين متزامنين (مثل انتهاء تحويلين تقريباً في نفس
  // اللحظة) كان كلاهما يقرأ نفس الحالة القديمة قبل أن يكتب أي منهما،
  // فيُفقَد أحد السجلّين بصمت (Lost Update). هذا القفل البسيط يضمن تنفيذ
  // كل عملية بالكامل قبل بدء التالية.
  static Future<void> _queue = Future.value();

  static Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    // نتابع السلسلة حتى لو فشلت هذه العملية، حتى لا تتعطّل كل العمليات
    // اللاحقة بسبب خطأ واحد غير متوقع.
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  static Future<List<HistoryItem>> getAll() => _enqueue(_getAllUnsafe);

  /// القراءة الفعلية، بدون المرور بالقفل — تُستخدم داخلياً من add/remove
  /// التي تعمل هي نفسها بداخل القفل (تجنّباً للجمود/deadlock الذي يحدث
  /// لو استدعت عملية مُسجَّلة في القفل نفس القفل من جديد).
  static Future<List<HistoryItem>> _getAllUnsafe() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_key);
    if (jsonStr == null) return [];

    try {
      final list = jsonDecode(jsonStr) as List;
      final items = <HistoryItem>[];

      // ── إصلاح: مرونة لكل عنصر على حدة ─────────────────────────────────
      // سابقاً: أي عنصر واحد تالف في القائمة (بيانات JSON غير متوقعة من
      // نسخة قديمة من التطبيق مثلاً) كان يرمي استثناءً يُمسَك بواسطة
      // try/catch الخارجي، فيُعيد السجل كاملاً فارغاً — أي يفقد المستخدم
      // كل سجل التحويلات بسبب عنصر واحد فقط. الآن نتجاهل العنصر التالف
      // فقط ونحتفظ بالباقي.
      for (final e in list) {
        try {
          items.add(HistoryItem.fromJson(e as Map<String, dynamic>));
        } catch (_) {
          // عنصر سجل تالف منفرد — يُتجاهَل فقط، لا يُفقَد بسببه باقي السجل.
        }
      }

      items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return items;
    } catch (_) {
      // فشل في فكّ القائمة بأكملها (JSON تالف كلياً) — سجل فارغ كاحتياط
      // آمن لا أكثر، أفضل من تعطّل الشاشة.
      return [];
    }
  }

  static Future<void> add(HistoryItem item) {
    return _enqueue(() async {
      final prefs = await SharedPreferences.getInstance();
      final items = await _getAllUnsafe();
      items.insert(0, item);
      if (items.length > _maxItems) {
        items.removeRange(_maxItems, items.length);
      }
      await prefs.setString(
          _key, jsonEncode(items.map((e) => e.toJson()).toList()));
    });
  }

  static Future<void> remove(String id) {
    return _enqueue(() async {
      final prefs = await SharedPreferences.getInstance();
      final items = await _getAllUnsafe();
      items.removeWhere((e) => e.id == id);
      await prefs.setString(
          _key, jsonEncode(items.map((e) => e.toJson()).toList()));
    });
  }

  static Future<void> clearAll() {
    return _enqueue(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    });
  }

  static Future<void> addEntry({required String toolId, required String toolName, required List<String> inputFiles, required String outputPath, required int outputSize}) async {}
}

import 'dart:convert';
import 'dart:html' as html; // web-only helpers
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart' as hive;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await hive.Hive.initFlutter();     // IndexedDB on Web
  await boxRepo.init();              // load saved data (if any)
  runApp(const BoxApp());
}

/// ===== MODELS =====
class Box {
  final String barcode; // e.g., "BOX:demo-123"
  String name;
  String van;
  Box({required this.barcode, required this.name, required this.van});

  Map<String, dynamic> toMap() => {'barcode': barcode, 'name': name, 'van': van};
  static Box fromMap(Map m) => Box(
    barcode: m['barcode'] as String,
    name: m['name'] as String,
    van: m['van'] as String,
  );
}

class Item {
  final String barcode;
  String name;
  int unitPriceCents;
  DateTime? expiresOn;
  int? expiryWarningDays;
  Item({
    required this.barcode,
    required this.name,
    required this.unitPriceCents,
    this.expiresOn,
    this.expiryWarningDays,
  });
  Map<String, dynamic> toMap() => {
    'barcode': barcode,
    'name': name,
    'unitPriceCents': unitPriceCents,
    'expiresOn': expiresOn?.toIso8601String(),
    'expiryWarningDays': expiryWarningDays,
  };
  static Item fromMap(Map m) => Item(
    barcode: m['barcode'] as String,
    name: m['name'] as String,
    unitPriceCents: (m['unitPriceCents'] as num).toInt(),
    expiresOn: (m['expiresOn'] as String?) == null ? null : DateTime.tryParse(m['expiresOn'] as String),
    expiryWarningDays: (m['expiryWarningDays'] as num?)?.toInt(),
  );
}

class BoxLine {
  final Item item;
  final int qty;
  BoxLine(this.item, this.qty);
}

/// ===== REPO (in-memory + JSON-in-Hive persistence) =====
class BoxRepo extends ChangeNotifier {
  final Map<String, Box> _boxes = {};                // box barcode -> Box
  final Map<String, Item> _items = {};               // item barcode -> Item
  final Map<String, Map<String, int>> _boxInv = {};  // box -> (item -> qty)

  late hive.Box _store; // Hive storage
  DateTime? lastLoadedAt;
  DateTime? lastSavedAt;

  Future<void> init() async {
    _store = await hive.Hive.openBox('box_manager');
    await _loadFromDisk();
  }

  // Build a pure-JSON snapshot of state
  Map<String, dynamic> _snapshotMap() => {
    'boxes': _boxes.values.map((b) => b.toMap()).toList(),
    'items': _items.values.map((i) => i.toMap()).toList(),
    'inv': _boxInv, // Map<String, Map<String,int>>
  };
  String snapshotJson() => jsonEncode(_snapshotMap());

  Future<void> _loadFromDisk() async {
    try {
      // Prefer JSON string key
      final s = _store.get('state_json');
      if (s is String && s.isNotEmpty) {
        final data = jsonDecode(s) as Map<String, dynamic>;
        _applyLoadedMap(data);
        lastLoadedAt = DateTime.now();
        debugPrint('Loaded JSON from Hive: boxes=${_boxes.length}');
        notifyListeners();
        return;
      }

      // Fallback: legacy Map key (if any)
      final legacy = _store.get('state');
      if (legacy is Map) {
        _applyLoadedMap(Map<String, dynamic>.from(legacy));
        lastLoadedAt = DateTime.now();
        debugPrint('Loaded legacy Map from Hive: boxes=${_boxes.length}');
        notifyListeners();
        // Also convert to JSON storage
        await _store.put('state_json', snapshotJson());
        await _store.flush();
        return;
      }

      debugPrint('No saved state found.');
      lastLoadedAt = DateTime.now();
      notifyListeners();
    } catch (e) {
      debugPrint('Load error: $e');
      lastLoadedAt = DateTime.now();
      notifyListeners();
    }
  }

  void _applyLoadedMap(Map<String, dynamic> data) {
    // boxes
    _boxes.clear();
    for (final b in (data['boxes'] as List? ?? [])) {
      final bx = Box.fromMap(Map<String, dynamic>.from(b as Map));
      _boxes[bx.barcode] = bx;
    }
    // items
    _items.clear();
    for (final it in (data['items'] as List? ?? [])) {
      final item = Item.fromMap(Map<String, dynamic>.from(it as Map));
      _items[item.barcode] = item;
    }
    // inventory
    _boxInv.clear();
    final invMap = Map<String, dynamic>.from((data['inv'] as Map?) ?? {});
    invMap.forEach((boxBarcode, itemMap) {
      _boxInv[boxBarcode] = Map<String, int>.from(
        (itemMap as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
      );
    });
  }

  Future<void> _saveToDisk() async {
    try {
      final jsonStr = snapshotJson();
      await _store.put('state_json', jsonStr);
      await _store.flush(); // ensure write completes
      lastSavedAt = DateTime.now();
      debugPrint('Saved JSON to Hive: boxes=${_boxes.length}');
      notifyListeners();
    } catch (e) {
      debugPrint('Save error: $e');
    }
  }

  // Public controls
  Future<void> saveNow() => _saveToDisk();
  Future<void> reloadNow() => _loadFromDisk();
  Future<void> wipeAll() async {
    _boxes.clear();
    _items.clear();
    _boxInv.clear();
    await _store.delete('state_json');
    await _store.delete('state'); // legacy
    await _store.flush();
    lastSavedAt = DateTime.now();
    notifyListeners();
  }

  Future<void> restoreFromJson(String jsonStr) async {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      _applyLoadedMap(data);
      notifyListeners();
      await _store.put('state_json', jsonStr);
      await _store.flush();
      lastSavedAt = DateTime.now();
    } catch (e) {
      debugPrint('Import error: $e');
    }
  }

  // queries
  List<Box> get allBoxes => _boxes.values.toList();
  Box? findBox(String barcode) => _boxes[barcode];
  Item? findItem(String barcode) => _items[barcode];
  List<BoxLine> contents(String boxBarcode) {
    final inv = _boxInv[boxBarcode];
    if (inv == null || inv.isEmpty) return [];
    final lines = <BoxLine>[];
    inv.forEach((itemBarcode, qty) {
      final item = _items[itemBarcode];
      if (item != null && qty > 0) lines.add(BoxLine(item, qty));
    });
    lines.sort((a, b) => a.item.name.toLowerCase().compareTo(b.item.name.toLowerCase()));
    return lines;
  }
  int getQuantity(String boxBarcode, String itemBarcode) => _boxInv[boxBarcode]?[itemBarcode] ?? 0;

  // mutations (await saves)
  Future<void> createBox({required String barcode, required String name, required String van}) async {
    if (_boxes.containsKey(barcode)) return;
    _boxes[barcode] = Box(barcode: barcode, name: name, van: van);
    _boxInv.putIfAbsent(barcode, () => {});
    notifyListeners();
    await _saveToDisk();
  }

  Future<void> renameBox(String barcode, String newName) async {
    final b = _boxes[barcode]; if (b == null) return;
    b.name = newName;
    notifyListeners();
    await _saveToDisk();
  }

  Future<void> moveBoxToVan(String barcode, String newVan) async {
    final b = _boxes[barcode]; if (b == null) return;
    b.van = newVan;
    notifyListeners();
    await _saveToDisk();
  }

  Future<Item> upsertItem({
    required String barcode,
    required String name,
    required int unitPriceCents,
    DateTime? expiresOn,
    int? expiryWarningDays,
  }) async {
    final ex = _items[barcode];
    if (ex != null) {
      ex.name = name;
      ex.unitPriceCents = unitPriceCents;
      ex.expiresOn = expiresOn;
      ex.expiryWarningDays = expiryWarningDays;
      notifyListeners();
      await _saveToDisk();
      return ex;
    } else {
      final it = Item(
        barcode: barcode,
        name: name,
        unitPriceCents: unitPriceCents,
        expiresOn: expiresOn,
        expiryWarningDays: expiryWarningDays,
      );
      _items[barcode] = it;
      notifyListeners();
      await _saveToDisk();
      return it;
    }
  }

  Future<void> addToBox({required String boxBarcode, required String itemBarcode, required int quantity}) async {
    if (quantity <= 0) return;
    final inv = _boxInv.putIfAbsent(boxBarcode, () => {});
    inv.update(itemBarcode, (q) => q + quantity, ifAbsent: () => quantity);
    notifyListeners();
    await _saveToDisk();
  }

  Future<void> removeFromBox({required String boxBarcode, required String itemBarcode, required int quantity}) async {
    if (quantity <= 0) return;
    final inv = _boxInv[boxBarcode];
    if (inv == null) return;
    final current = inv[itemBarcode] ?? 0;
    final next = current - quantity;
    if (next <= 0) inv.remove(itemBarcode); else inv[itemBarcode] = next;
    notifyListeners();
    await _saveToDisk();
  }

  Future<bool> moveBetweenBoxes({
    required String srcBoxBarcode,
    required String destBoxBarcode,
    required String itemBarcode,
    required int quantity,
  }) async {
    if (quantity <= 0) return false;
    if (srcBoxBarcode == destBoxBarcode) return false;
    final available = getQuantity(srcBoxBarcode, itemBarcode);
    if (available < quantity) return false;
    await removeFromBox(boxBarcode: srcBoxBarcode, itemBarcode: itemBarcode, quantity: quantity);
    await addToBox(boxBarcode: destBoxBarcode, itemBarcode: itemBarcode, quantity: quantity);
    await _saveToDisk();
    return true;
  }
}

final boxRepo = BoxRepo();

/// ===== APP ROOT =====
class BoxApp extends StatelessWidget {
  const BoxApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Box Manager (Persistent)',
      theme: ThemeData(useMaterial3: true),
      home: const ScanHomePage(),
    );
  }
}

/// ===== HOME (scan / list / save controls) =====
class ScanHomePage extends StatefulWidget {
  const ScanHomePage({super.key});
  @override
  State<ScanHomePage> createState() => _ScanHomePageState();
}

class _ScanHomePageState extends State<ScanHomePage> {
  final FocusNode _focusNode = FocusNode();
  final StringBuffer _buffer = StringBuffer();
  final TextEditingController _manual = TextEditingController();
  static const Duration _timeout = Duration(milliseconds: 500);
  DateTime _lastKeyTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
    RawKeyboard.instance.addListener(_onKey);
  }

  @override
  void dispose() {
    RawKeyboard.instance.removeListener(_onKey);
    _focusNode.dispose();
    _manual.dispose();
    super.dispose();
  }

  void _onKey(RawKeyEvent event) {
    if (event is! RawKeyDownEvent) return;
    final now = DateTime.now();
    if (now.difference(_lastKeyTime) > _timeout) _buffer.clear();
    _lastKeyTime = now;

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final code = _buffer.toString().trim();
      _buffer.clear();
      if (code.isNotEmpty) _handleScan(code);
      return;
    }

    final ch = event.character;
    if (ch != null && ch.isNotEmpty) _buffer.write(ch);
  }

  Future<void> _handleScan(String code) async {
    if (code.startsWith('BOX:')) {
      await _openOrCreateBox(code);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Item-like scan ($code). Open a box first to add items.')),
      );
    }
  }

  Future<void> _openOrCreateBox(String barcode) async {
    final existing = boxRepo.findBox(barcode);
    if (existing != null) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BoxDetailsPage(boxBarcode: barcode),
      ));
      return;
    }

    final created = await showDialog<bool>(
      context: context,
      builder: (_) => CreateBoxDialog(barcode: barcode),
    );

    if (created == true && mounted) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BoxDetailsPage(boxBarcode: barcode),
      ));
    }
  }

  String _fmtTime(DateTime? t) {
    if (t == null) return '—';
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hh:$mm';
  }

  void _exportJson() {
    final data = boxRepo.snapshotJson();
    final bytes = utf8.encode(data);
    final blob = html.Blob([bytes], 'application/json');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final a = html.AnchorElement(href: url)..download = 'box_manager_backup.json';
    a.click();
    html.Url.revokeObjectUrl(url);
  }

  Future<void> _importJson() async {
    final input = html.FileUploadInputElement()..accept = '.json,application/json';
    input.onChange.listen((_) async {
      final file = input.files?.first;
      if (file == null) return;
      final reader = html.FileReader();
      reader.readAsText(file);
      await reader.onLoad.first;
      final txt = reader.result as String;
      await boxRepo.restoreFromJson(txt);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Imported JSON')));
    });
    input.click();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan a Box (Persistent)'),
        actions: [
          IconButton(
            tooltip: 'Reload from disk',
            onPressed: () async {
              await boxRepo.reloadNow();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reloaded from disk')));
            },
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Save Now',
            onPressed: () async {
              await boxRepo.saveNow();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
            },
            icon: const Icon(Icons.save),
          ),
          IconButton(
            tooltip: 'Export JSON',
            onPressed: _exportJson,
            icon: const Icon(Icons.download),
          ),
          IconButton(
            tooltip: 'Import JSON',
            onPressed: _importJson,
            icon: const Icon(Icons.upload),
          ),
          IconButton(
            tooltip: 'Wipe All',
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Wipe everything?'),
                  content: const Text('This deletes all boxes/items.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Wipe')),
                  ],
                ),
              );
              if (ok == true) {
                await boxRepo.wipeAll();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All data wiped')));
              }
            },
            icon: const Icon(Icons.delete_forever),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => _focusNode.requestFocus(),
        child: Focus(
          focusNode: _focusNode,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text('Last loaded: ${_fmtTime(boxRepo.lastLoadedAt)}   •   Last saved: ${_fmtTime(boxRepo.lastSavedAt)}'),
                ),
              ]),
              const SizedBox(height: 12),
              const Text('Scan a box (BOX:...) or type below and press Enter.'),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _manual,
                    decoration: const InputDecoration(
                      labelText: 'Type e.g. BOX:demo-123 then Enter or Add',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) async {
                      await _handleScan(v.trim());
                      _manual.clear();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    await _handleScan(_manual.text.trim());
                    _manual.clear();
                  },
                  child: const Text('Add'),
                ),
              ]),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => _handleScan('BOX:demo-123'),
                    child: const Text('Test Box (BOX:demo-123)'),
                  ),
                  OutlinedButton(
                    onPressed: () => _handleScan('BOX:van2-001'),
                    child: const Text('Test Box (BOX:van2-001)'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(),
              const Text('Existing boxes:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Expanded(
                child: AnimatedBuilder(
                  animation: boxRepo,
                  builder: (context, _) {
                    final boxes = boxRepo.allBoxes;
                    if (boxes.isEmpty) return const Center(child: Text('No boxes yet.'));
                    return ListView.separated(
                      itemCount: boxes.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final b = boxes[i];
                        return ListTile(
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text(b.name),
                          subtitle: Text('Barcode: ${b.barcode}   •   Van: ${b.van}'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => BoxDetailsPage(boxBarcode: b.barcode)),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// ===== CREATE BOX DIALOG =====
class CreateBoxDialog extends StatefulWidget {
  final String barcode;
  const CreateBoxDialog({super.key, required this.barcode});
  @override
  State<CreateBoxDialog> createState() => _CreateBoxDialogState();
}

class _CreateBoxDialogState extends State<CreateBoxDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  String _van = 'Van 1';
  final _vans = const ['Van 1', 'Van 2', 'Van 3'];

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Box'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Barcode: ${widget.barcode}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Box name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _van,
              items: _vans.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: (v) => setState(() => _van = v ?? 'Van 1'),
              decoration: const InputDecoration(labelText: 'Van', border: OutlineInputBorder()),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () async {
            if (_formKey.currentState!.validate()) {
              await boxRepo.createBox(barcode: widget.barcode, name: _nameCtrl.text.trim(), van: _van);
              if (!mounted) return;
              Navigator.pop(context, true);
            }
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// ===== BOX DETAILS (items + MOVE + EXPIRY + PRINT) =====
class BoxDetailsPage extends StatefulWidget {
  final String boxBarcode;
  const BoxDetailsPage({super.key, required this.boxBarcode});
  @override
  State<BoxDetailsPage> createState() => _BoxDetailsPageState();
}

class _BoxDetailsPageState extends State<BoxDetailsPage> {
  final TextEditingController _itemScanCtrl = TextEditingController();
  @override
  void dispose() {
    _itemScanCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleItemScan(String code) async {
    final box = boxRepo.findBox(widget.boxBarcode);
    if (box == null) return;
    final trimmed = code.trim();
    if (trimmed.isEmpty) return;

    final existing = boxRepo.findItem(trimmed);
    if (existing != null) {
      final qty = await showDialog<int>(
        context: context,
        builder: (_) => _QtyDialog(title: 'Add quantity', initial: 1),
      );
      if (qty != null && qty > 0) {
        await boxRepo.addToBox(boxBarcode: box.barcode, itemBarcode: existing.barcode, quantity: qty);
      }
    } else {
      final created = await showDialog<_NewItemResult>(
        context: context,
        builder: (_) => _NewItemDialog(itemBarcode: trimmed),
      );
      if (created != null) {
        await boxRepo.upsertItem(
          barcode: trimmed,
          name: created.name,
          unitPriceCents: created.unitPriceCents,
          expiresOn: created.expiresOn,
          expiryWarningDays: created.expiryWarningDays,
        );
        await boxRepo.addToBox(
          boxBarcode: box.barcode,
          itemBarcode: trimmed,
          quantity: created.quantity,
        );
      }
    }
    _itemScanCtrl.clear();
  }

  Future<void> _moveItem(Item item) async {
    final srcBox = boxRepo.findBox(widget.boxBarcode);
    if (srcBox == null) return;
    final currentQty = boxRepo.getQuantity(srcBox.barcode, item.barcode);

    final result = await showDialog<_MoveResult>(
      context: context,
      builder: (_) => _MoveItemDialog(
        srcBox: srcBox,
        item: item,
        currentQty: currentQty,
        allBoxes: boxRepo.allBoxes,
      ),
    );
    if (result == null) return;

    // Ensure destination exists (create if needed)
    Box? dest = boxRepo.findBox(result.destBoxBarcode);
    if (dest == null && result.destBoxBarcode.startsWith('BOX:')) {
      final created = await showDialog<bool>(
        context: context,
        builder: (_) => CreateBoxDialog(barcode: result.destBoxBarcode),
      );
      if (created == true) dest = boxRepo.findBox(result.destBoxBarcode);
    }
    if (dest == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Destination box not found.')));
      return;
    }
    if (dest.barcode == srcBox.barcode) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cannot move to the same box.')));
      return;
    }

    final ok = await boxRepo.moveBetweenBoxes(
      srcBoxBarcode: srcBox.barcode,
      destBoxBarcode: dest.barcode,
      itemBarcode: item.barcode,
      quantity: result.quantity,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Not enough quantity to move. Available: $currentQty')),
      );
    }
  }

  void _openPrintLabel(Box box) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PrintLabelPage(box: box),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final box = boxRepo.findBox(widget.boxBarcode);
    if (box == null) {
      return Scaffold(appBar: AppBar(title: const Text('Box not found')), body: const Center(child: Text('Missing box')));
    }

    final lines = boxRepo.contents(box.barcode);

    return Scaffold(
      appBar: AppBar(title: Text(box.name)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Barcode: ${box.barcode}'),
          Text('Van: ${box.van}'),
          const SizedBox(height: 8),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: () => _showEditBoxDialog(context, box),
                icon: const Icon(Icons.edit),
                label: const Text('Edit Box'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _openPrintLabel(box),
                icon: const Icon(Icons.print),
                label: const Text('Print QR'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Back'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Add item area
          Row(children: [
            Expanded(
              child: TextField(
                controller: _itemScanCtrl,
                decoration: const InputDecoration(
                  labelText: 'Scan/Type item barcode, then Enter or Add',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (v) => _handleItemScan(v),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () => _handleItemScan(_itemScanCtrl.text),
              child: const Text('Add'),
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => _handleItemScan('4006381333931'),
                child: const Text('Test Item (EAN-13)'),
              ),
              OutlinedButton(
                onPressed: () => _handleItemScan('CODE128-ABC123'),
                child: const Text('Test Item (Code128-like)'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          const Text('Items in this box:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Expanded(
            child: lines.isEmpty
                ? const Center(child: Text('No items yet. Add one above.'))
                : ListView.separated(
                    itemCount: lines.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final line = lines[i];

                      // expiry text + badge
                      final expText = (line.item.expiresOn != null)
                          ? ' • Exp: ${fmtYmd(line.item.expiresOn!)}'
                          : '';
                      final d = daysUntil(line.item.expiresOn);
                      Widget? badge;
                      if (d != null) {
                        if (d < 0) {
                          badge = const Chip(label: Text('Expired'));
                        } else if (line.item.expiryWarningDays != null && d <= line.item.expiryWarningDays!) {
                          badge = Chip(label: Text('Expiring in ${d}d'));
                        }
                      }

                      return ListTile(
                        leading: const Icon(Icons.qr_code_2),
                        title: Text(line.item.name),
                        subtitle: Text('Barcode: ${line.item.barcode} • Unit: ${fmtEuro(line.item.unitPriceCents)}$expText'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (badge != null) ...[badge, const SizedBox(width: 8)],
                            IconButton(
                              tooltip: 'Move',
                              onPressed: () => _moveItem(line.item),
                              icon: const Icon(Icons.drive_file_move_outlined),
                            ),
                            IconButton(
                              tooltip: 'Remove 1',
                              onPressed: () => boxRepo.removeFromBox(
                                boxBarcode: box.barcode,
                                itemBarcode: line.item.barcode,
                                quantity: 1,
                              ),
                              icon: const Icon(Icons.remove),
                            ),
                            Text('${line.qty}', style: const TextStyle(fontWeight: FontWeight.bold)),
                            IconButton(
                              tooltip: 'Add 1',
                              onPressed: () => boxRepo.addToBox(
                                boxBarcode: box.barcode,
                                itemBarcode: line.item.barcode,
                                quantity: 1,
                              ),
                              icon: const Icon(Icons.add),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }

  void _showEditBoxDialog(BuildContext context, Box box) {
    showDialog(context: context, builder: (_) => _EditBoxDialog(box: box));
  }
}

/// ===== PRINT LABEL PAGE =====
class PrintLabelPage extends StatelessWidget {
  final Box box;
  const PrintLabelPage({super.key, required this.box});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Print Box QR')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(box.name, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              QrImageView(data: box.barcode, size: 240),
              const SizedBox(height: 8),
              Text('Barcode: ${box.barcode}'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => html.window.print(),
                icon: const Icon(Icons.print),
                label: const Text('Print (Web)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
            ],
          ),
        ),
      ),
    );
  }
}

/// ===== EDIT BOX DIALOG =====
class _EditBoxDialog extends StatefulWidget {
  final Box box;
  const _EditBoxDialog({required this.box});
  @override
  State<_EditBoxDialog> createState() => _EditBoxDialogState();
}
class _EditBoxDialogState extends State<_EditBoxDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  String _van = 'Van 1';
  final _vans = const ['Van 1', 'Van 2', 'Van 3'];
  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.box.name);
    _van = widget.box.van;
  }
  @override
  void dispose() { _nameCtrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Box'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Barcode: ${widget.box.barcode}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Box name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _van,
              items: _vans.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: (v) => setState(() => _van = v ?? 'Van 1'),
              decoration: const InputDecoration(labelText: 'Van', border: OutlineInputBorder()),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () async {
            if (_formKey.currentState!.validate()) {
              await boxRepo.renameBox(widget.box.barcode, _nameCtrl.text.trim());
              await boxRepo.moveBoxToVan(widget.box.barcode, _van);
              if (!mounted) return;
              Navigator.pop(context);
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// ===== ITEM DIALOGS (with expiry) =====
class _NewItemResult {
  final String name;
  final int unitPriceCents;
  final int quantity;
  final DateTime? expiresOn;
  final int? expiryWarningDays;
  _NewItemResult({
    required this.name,
    required this.unitPriceCents,
    required this.quantity,
    this.expiresOn,
    this.expiryWarningDays,
  });
}
class _NewItemDialog extends StatefulWidget {
  final String itemBarcode;
  const _NewItemDialog({required this.itemBarcode});
  @override
  State<_NewItemDialog> createState() => _NewItemDialogState();
}
class _NewItemDialogState extends State<_NewItemDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');
  final _expiryCtrl = TextEditingController(); // YYYY-MM-DD
  final _warnCtrl = TextEditingController();   // days (int)
  @override
  void dispose() { _nameCtrl.dispose(); _priceCtrl.dispose(); _qtyCtrl.dispose(); _expiryCtrl.dispose(); _warnCtrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create New Item'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Barcode: ${widget.itemBarcode}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Item name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Unit price (€) e.g. 10 or 10.50', border: OutlineInputBorder()),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Enter price';
                return _parseEuroToCents(v) == null ? 'Invalid price' : null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Quantity', border: OutlineInputBorder()),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n <= 0) return 'Enter a positive number';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _expiryCtrl,
              decoration: const InputDecoration(
                labelText: 'Expiry date (YYYY-MM-DD) — optional',
                border: OutlineInputBorder(),
                suffixIcon: Icon(Icons.calendar_today),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                return _tryParseYMD(v.trim()) == null ? 'Use format YYYY-MM-DD' : null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _warnCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Warn me N days before (optional)', border: OutlineInputBorder()),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                final n = int.tryParse(v.trim());
                if (n == null || n < 0) return 'Enter a non-negative number';
                return null;
              },
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              final cents = _parseEuroToCents(_priceCtrl.text.trim())!;
              final qty = int.parse(_qtyCtrl.text.trim());
              final expires = _expiryCtrl.text.trim().isEmpty ? null : _tryParseYMD(_expiryCtrl.text.trim());
              final warnDays = _warnCtrl.text.trim().isEmpty ? null : int.parse(_warnCtrl.text.trim());
              Navigator.pop(context, _NewItemResult(
                name: _nameCtrl.text.trim(),
                unitPriceCents: cents,
                quantity: qty,
                expiresOn: expires,
                expiryWarningDays: warnDays,
              ));
            }
          },
          child: const Text('Create & Add'),
        ),
      ],
    );
  }
}

class _QtyDialog extends StatefulWidget {
  final String title;
  final int initial;
  const _QtyDialog({required this.title, this.initial = 1});
  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}
class _QtyDialogState extends State<_QtyDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _qtyCtrl;
  @override
  void initState() { super.initState(); _qtyCtrl = TextEditingController(text: widget.initial.toString()); }
  @override
  void dispose() { _qtyCtrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 240,
          child: TextFormField(
            controller: _qtyCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Quantity', border: OutlineInputBorder()),
            validator: (v) {
              final n = int.tryParse(v ?? '');
              if (n == null || n <= 0) return 'Enter a positive number';
              return null;
            },
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(context, int.parse(_qtyCtrl.text.trim()));
            }
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// ===== MOVE DIALOG =====
class _MoveResult {
  final String destBoxBarcode;
  final int quantity;
  _MoveResult({required this.destBoxBarcode, required this.quantity});
}
class _MoveItemDialog extends StatefulWidget {
  final Box srcBox;
  final Item item;
  final int currentQty;
  final List<Box> allBoxes;
  const _MoveItemDialog({
    required this.srcBox,
    required this.item,
    required this.currentQty,
    required this.allBoxes,
  });
  @override
  State<_MoveItemDialog> createState() => _MoveItemDialogState();
}
class _MoveItemDialogState extends State<_MoveItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _qtyCtrl;
  String? _selectedDest; // barcode of selected box
  final TextEditingController _destBarcodeCtrl = TextEditingController();
  @override
  void initState() {
    super.initState();
    _qtyCtrl = TextEditingController(text: '1');
    final others = widget.allBoxes.where((b) => b.barcode != widget.srcBox.barcode).toList();
    if (others.isNotEmpty) _selectedDest = others.first.barcode;
  }
  @override
  void dispose() { _qtyCtrl.dispose(); _destBarcodeCtrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final otherBoxes = widget.allBoxes.where((b) => b.barcode != widget.srcBox.barcode).toList();
    return AlertDialog(
      title: const Text('Move Item'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('From: ${widget.srcBox.name} (${widget.srcBox.barcode})', style: const TextStyle(fontSize: 12)),
            Text('Item: ${widget.item.name} • Available: ${widget.currentQty}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _qtyCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Quantity to move', border: OutlineInputBorder()),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n <= 0) return 'Enter a positive number';
                if (n > widget.currentQty) return 'Cannot move more than available (${widget.currentQty})';
                return null;
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedDest,
              items: otherBoxes.map((b) => DropdownMenuItem(
                value: b.barcode,
                child: Text('${b.name} • ${b.van} (${b.barcode})', overflow: TextOverflow.ellipsis),
              )).toList(),
              onChanged: (v) => setState(() => _selectedDest = v),
              decoration: const InputDecoration(labelText: 'Choose destination (existing box)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _destBarcodeCtrl,
              decoration: const InputDecoration(
                labelText: 'OR type/scan destination barcode (e.g., BOX:new-001)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            const Text('If typed barcode starts with BOX: and doesn’t exist, you will be asked to create it.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              final dest = _destBarcodeCtrl.text.trim().isNotEmpty ? _destBarcodeCtrl.text.trim() : (_selectedDest ?? '');
              if (dest.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a destination or type a barcode.')));
                return;
              }
              final qty = int.parse(_qtyCtrl.text.trim());
              Navigator.pop(context, _MoveResult(destBoxBarcode: dest, quantity: qty));
            }
          },
          child: const Text('Move'),
        ),
      ],
    );
  }
}

/// ===== HELPERS =====
String fmtEuro(int cents) {
  final euros = cents ~/ 100;
  final rem = (cents % 100).abs();
  final two = rem.toString().padLeft(2, '0');
  return '€$euros.$two';
}
String fmtYmd(DateTime d) {
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${d.year}-$m-$day';
}
int? daysUntil(DateTime? d) {
  if (d == null) return null;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(d.year, d.month, d.day);
  return target.difference(today).inDays;
}
DateTime? _tryParseYMD(String s) {
  try {
    final parts = s.split('-');
    if (parts.length != 3) return null;
    final y = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    final d = int.parse(parts[2]);
    return DateTime(y, m, d);
  } catch (_) {
    return null;
  }
}
int? _parseEuroToCents(String input) {
  final s = input.trim().replaceAll(',', '.');
  final r = RegExp(r'^\d+(\.\d{1,2})?$');
  if (!r.hasMatch(s)) return null;
  final parts = s.split('.');
  if (parts.length == 1) return int.parse(parts[0]) * 100;
  final whole = int.parse(parts[0]);
  final frac = int.parse(parts[1].padRight(2, '0'));
  return whole * 100 + frac;
}

import 'dart:convert';
import 'dart:html' as html; // Web-only helpers (download/upload/print)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart' as hive;
import 'package:csv/csv.dart';

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
        expiresOn: (m['expiresOn'] as String?) == null
            ? null
            : DateTime.tryParse(m['expiresOn'] as String),
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
  final Map<String, Box> _boxes = {}; // box barcode -> Box
  final Map<String, Item> _items = {}; // item barcode -> Item
  final Map<String, Map<String, int>> _boxInv = {}; // box -> (item -> qty)

  // persisted list of vans (editable)
  List<String> _vans = ['Van 1', 'Van 2', 'Van 3'];
  List<String> get vans => List.unmodifiable(_vans);

  late hive.Box _store; // Hive storage
  DateTime? lastLoadedAt;
  DateTime? lastSavedAt;

  Future<void> init() async {
    _store = await hive.Hive.openBox('box_manager');
    await _loadFromDisk();
  }

  Map<String, dynamic> _snapshotMap() => {
        'boxes': _boxes.values.map((b) => b.toMap()).toList(),
        'items': _items.values.map((i) => i.toMap()).toList(),
        'inv': _boxInv, // Map<String, Map<String,int>>
        'vans': _vans,
      };
  String snapshotJson() => jsonEncode(_snapshotMap());

  Future<void> _loadFromDisk() async {
    try {
      final s = _store.get('state_json');
      if (s is String && s.isNotEmpty) {
        final data = jsonDecode(s) as Map<String, dynamic>;
        _applyLoadedMap(data);
        lastLoadedAt = DateTime.now();
        notifyListeners();
        return;
      }
      final legacy = _store.get('state');
      if (legacy is Map) {
        _applyLoadedMap(Map<String, dynamic>.from(legacy));
        lastLoadedAt = DateTime.now();
        await _store.put('state_json', snapshotJson());
        await _store.flush();
        notifyListeners();
        return;
      }
      lastLoadedAt = DateTime.now();
      notifyListeners();
    } catch (_) {
      lastLoadedAt = DateTime.now();
      notifyListeners();
    }
  }

  void _applyLoadedMap(Map<String, dynamic> data) {
    _boxes.clear();
    for (final b in (data['boxes'] as List? ?? [])) {
      final bx = Box.fromMap(Map<String, dynamic>.from(b as Map));
      _boxes[bx.barcode] = bx;
    }
    _items.clear();
    for (final it in (data['items'] as List? ?? [])) {
      final item = Item.fromMap(Map<String, dynamic>.from(it as Map));
      _items[item.barcode] = item;
    }
    _boxInv.clear();
    final invMap = Map<String, dynamic>.from((data['inv'] as Map?) ?? {});
    invMap.forEach((boxBarcode, itemMap) {
      _boxInv[boxBarcode] = Map<String, int>.from(
        (itemMap as Map).map(
          (k, v) => MapEntry(k as String, (v as num).toInt()),
        ),
      );
    });

    final vansList = (data['vans'] as List?)?.map((e) => e.toString()).toList();
    _vans = (vansList == null || vansList.isEmpty)
        ? ['Van 1', 'Van 2', 'Van 3']
        : vansList;
  }

  Future<void> _saveToDisk() async {
    try {
      final jsonStr = snapshotJson();
      await _store.put('state_json', jsonStr);
      await _store.flush();
      lastSavedAt = DateTime.now();
      notifyListeners();
    } catch (_) {}
  }

  // Public controls
  Future<void> saveNow() => _saveToDisk();
  Future<void> reloadNow() => _loadFromDisk();
  Future<void> wipeAll() async {
    _boxes.clear();
    _items.clear();
    _boxInv.clear();
    _vans = ['Van 1', 'Van 2', 'Van 3']; // reset vans to defaults
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
    } catch (_) {}
  }

  Future<void> addVan(String name) async {
    final nm = name.trim();
    if (nm.isEmpty) return;
    if (!_vans.contains(nm)) {
      _vans.add(nm);
      _vans.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      notifyListeners();
      await _saveToDisk();
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
    lines.sort((a, b) =>
        a.item.name.toLowerCase().compareTo(b.item.name.toLowerCase()));
    return lines;
  }

  int getQuantity(String boxBarcode, String itemBarcode) =>
      _boxInv[boxBarcode]?[itemBarcode] ?? 0;

  // mutations (await saves)
  Future<void> createBox(
      {required String barcode,
      required String name,
      required String van}) async {
    if (_boxes.containsKey(barcode)) return;
    _boxes[barcode] = Box(barcode: barcode, name: name, van: van);
    _boxInv.putIfAbsent(barcode, () => {});
    await addVan(van);
    notifyListeners();
    await _saveToDisk();
  }

  Future<void> renameBox(String barcode, String newName) async {
    final b = _boxes[barcode];
    if (b == null) return;
    b.name = newName;
    notifyListeners();
    await _saveToDisk();
  }

  Future<void> moveBoxToVan(String barcode, String newVan) async {
    final b = _boxes[barcode];
    if (b == null) return;
    b.van = newVan;
    await addVan(newVan);
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
      ex
        ..name = name
        ..unitPriceCents = unitPriceCents
        ..expiresOn = expiresOn
        ..expiryWarningDays = expiryWarningDays;
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

  Future<void> addToBox(
      {required String boxBarcode,
      required String itemBarcode,
      required int quantity}) async {
    if (quantity <= 0) return;
    final inv = _boxInv.putIfAbsent(boxBarcode, () => {});
    inv.update(itemBarcode, (q) => q + quantity, ifAbsent: () => quantity);
    notifyListeners();
    await _saveToDisk();
  }

  Future<void> removeFromBox(
      {required String boxBarcode,
      required String itemBarcode,
      required int quantity}) async {
    if (quantity <= 0) return;
    final inv = _boxInv[boxBarcode];
    if (inv == null) return;
    final current = inv[itemBarcode] ?? 0;
    final next = current - quantity;
    if (next <= 0) {
      inv.remove(itemBarcode);
    } else {
      inv[itemBarcode] = next;
    }
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
    await removeFromBox(
        boxBarcode: srcBoxBarcode, itemBarcode: itemBarcode, quantity: quantity);
    await addToBox(
        boxBarcode: destBoxBarcode, itemBarcode: itemBarcode, quantity: quantity);
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
      title: 'Box Manager',
      theme: ThemeData(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// ===== HOME (unified scan/search) =====
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FocusNode _focusNode = FocusNode();
  final StringBuffer _buffer = StringBuffer();
  final TextEditingController _input = TextEditingController();
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
    _input.dispose();
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
      if (code.isNotEmpty) _handleGo(code);
      return;
    }

    final ch = event.character;
    if (ch != null && ch.isNotEmpty) _buffer.write(ch);
  }

  Future<void> _handleGo(String code) async {
    final v = code.trim();
    if (v.isEmpty) return;

    if (v.startsWith('BOX:')) {
      // Open or create a box
      final existing = boxRepo.findBox(v);
      if (existing != null) {
        if (!mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BoxDetailsPage(boxBarcode: v),
        ));
      } else {
        final created = await showDialog<bool>(
          context: context,
          builder: (_) => CreateBoxDialog(barcode: v),
        );
        if (created == true && mounted) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => BoxDetailsPage(boxBarcode: v),
          ));
        }
      }
    } else {
      // Treat as ITEM barcode -> show where it is
      final item = boxRepo.findItem(v);
      if (item == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Item not found: $v')),
        );
        return;
      }
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ItemWherePage(itemBarcode: v),
      ));
    }
  }

  String _fmtTime(DateTime? t) {
    if (t == null) return '—';
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hh:$mm';
  }

  // ==== JSON Export/Import (kept in code; UI buttons removed) ====
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

  // ==== CSV Export/Import ====
  void _exportCsv() {
    final rows = <List<dynamic>>[
      ['BoxBarcode','BoxName','Van','ItemBarcode','ItemName','UnitPriceEUR','Quantity','ExpiryDate','WarnDays'],
    ];

    final boxes = boxRepo.allBoxes;
    if (boxes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No data to export.')));
      return;
    }

    for (final b in boxes) {
      final lines = boxRepo.contents(b.barcode);
      if (lines.isEmpty) {
        rows.add([b.barcode, b.name, b.van, '', '', '', 0, '', '']);
        continue;
      }
      for (final line in lines) {
        final item = line.item;
        final priceStr = _euroString(item.unitPriceCents);
        final expStr = item.expiresOn == null ? '' : fmtYmd(item.expiresOn!);
        final warn = item.expiryWarningDays?.toString() ?? '';
        rows.add([
          b.barcode, b.name, b.van,
          item.barcode, item.name,
          priceStr,
          line.qty,
          expStr,
          warn,
        ]);
      }
    }

    final csvText = ListToCsvConverter().convert(rows);
    final bytes = utf8.encode(csvText);
    final blob = html.Blob([bytes], 'text/csv');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final a = html.AnchorElement(href: url)..download = 'box_manager_inventory.csv';
    a.click();
    html.Url.revokeObjectUrl(url);

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV exported.')));
  }

  Future<void> _importCsv() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Import CSV'),
        content: const Text('This will replace your current data with the CSV contents. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Import')),
        ],
      ),
    );
    if (ok != true) return;

    final input = html.FileUploadInputElement()..accept = '.csv,text/csv';
    input.onChange.listen((_) async {
      final file = input.files?.first;
      if (file == null) return;
      final reader = html.FileReader();
      reader.readAsText(file);
      await reader.onLoad.first;
      final txt = reader.result as String;

      final rows = CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(txt);
      if (rows.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV is empty.')));
        return;
      }

      final header = rows.first.map((e) => (e?.toString() ?? '').trim().toLowerCase()).toList();
      int col(String name) {
        final i = header.indexOf(name.toLowerCase());
        if (i < 0) {
          throw 'Missing column "$name". Expected header: BoxBarcode,BoxName,Van,ItemBarcode,ItemName,UnitPriceEUR,Quantity,ExpiryDate,WarnDays';
        }
        return i;
      }

      try {
        final iBoxBc  = col('boxbarcode');
        final iBoxNm  = col('boxname');
        final iVan    = col('van');
        final iItBc   = col('itembarcode');
        final iItNm   = col('itemname');
        final iPrice  = col('unitpriceeur');
        final iQty    = col('quantity');
        final iExp    = col('expirydate');
        final iWarn   = col('warndays');

        await boxRepo.wipeAll();

        for (var r = 1; r < rows.length; r++) {
          final row = rows[r].map((e) => (e?.toString() ?? '').trim()).toList();
          if (row.every((cell) => cell.isEmpty)) continue;

          final boxBc = row[iBoxBc];
          if (boxBc.isEmpty) continue;

          final boxName = row[iBoxNm].isEmpty ? boxBc : row[iBoxNm];
          final van     = row[iVan].isEmpty ? 'Van 1' : row[iVan];

          if (boxRepo.findBox(boxBc) == null) {
            await boxRepo.createBox(barcode: boxBc, name: boxName, van: van);
          } else {
            await boxRepo.renameBox(boxBc, boxName);
            await boxRepo.moveBoxToVan(boxBc, van);
          }

          final itemBc = row[iItBc];
          if (itemBc.isEmpty) continue;

          final itemName = row[iItNm].isEmpty ? itemBc : row[iItNm];
          final priceCents = _parseEuroToCents(row[iPrice]) ?? 0;
          final qty = int.tryParse(row[iQty]) ?? 0;
          final exp = row[iExp].isEmpty ? null : _tryParseYMD(row[iExp]);
          final warnDays = row[iWarn].isEmpty ? null : int.tryParse(row[iWarn]);

          await boxRepo.upsertItem(
            barcode: itemBc,
            name: itemName,
            unitPriceCents: priceCents,
            expiresOn: exp,
            expiryWarningDays: warnDays,
          );
          if (qty > 0) {
            await boxRepo.addToBox(boxBarcode: boxBc, itemBarcode: itemBc, quantity: qty);
          }
        }

        await boxRepo.saveNow();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV imported.')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import error: $e')));
      }
    });
    input.click();
  }

  Future<void> _onAddBox() async {
    final res = await showDialog<_NewBoxResult>(
      context: context,
      builder: (_) => const NewBoxDialog(),
    );
    if (res == null) return;

    var bc = res.barcode.trim();
    if (bc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Barcode is required')));
      return;
    }
    if (!bc.startsWith('BOX:')) bc = 'BOX:$bc';

    if (boxRepo.findBox(bc) != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('A box with this barcode already exists')));
      return;
    }

    await boxRepo.createBox(barcode: bc, name: res.name.trim(), van: res.van);
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BoxDetailsPage(boxBarcode: bc),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Box Manager'),
        actions: [
          IconButton(
            tooltip: 'Save Now',
            onPressed: () async {
              await boxRepo.saveNow();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Saved')),
              );
            },
            icon: const Icon(Icons.save),
          ),
          IconButton(
            tooltip: 'Export CSV',
            onPressed: _exportCsv,
            icon: const Icon(Icons.table_view),
          ),
          IconButton(
            tooltip: 'Import CSV',
            onPressed: _importCsv,
            icon: const Icon(Icons.upload_file),
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('All data wiped')),
                );
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
              Text('Last loaded: ${_fmtTime(boxRepo.lastLoadedAt)}   •   Last saved: ${_fmtTime(boxRepo.lastSavedAt)}'),
              const SizedBox(height: 16),

              // Big Add Box button
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _onAddBox,
                    icon: const Icon(Icons.add_box),
                    label: const Text('Add Box'),
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              const Text('Scan/Type ANY barcode (box or item), then press Enter or Go.'),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    decoration: const InputDecoration(
                      labelText: 'Example: BOX:van1-001  or  4006381333931',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) async {
                      await _handleGo(v.trim());
                      _input.clear();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () async {
                    await _handleGo(_input.text.trim());
                    _input.clear();
                  },
                  child: const Text('Go'),
                ),
              ]),

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

                        // Inventory lines for this box
                        final lines = boxRepo.contents(b.barcode);

                        // Total quantity = sum of all item quantities
                        final totalQty = lines.fold<int>(0, (sum, line) => sum + line.qty);

                        // Expiry by QUANTITY
                        int expSoonQty = 0, expiredQty = 0;
                        for (final line in lines) {
                          final d = daysUntil(line.item.expiresOn);
                          if (d != null) {
                            if (d < 0) {
                              expiredQty += line.qty;
                            } else if (line.item.expiryWarningDays != null &&
                                       d <= line.item.expiryWarningDays!) {
                              expSoonQty += line.qty;
                            }
                          }
                        }
                        final expTotalQty = expSoonQty + expiredQty;

                        return ListTile(
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text(b.name),
                          subtitle: Text('Van: ${b.van} • Box: ${b.barcode}'),
                          trailing: Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Chip(label: Text('Qty $totalQty')),
                              if (expTotalQty > 0)
                                Chip(
                                  label: Text('Exp $expTotalQty (${expiredQty}✖)'),
                                ),
                            ],
                          ),
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

/// ===== CREATE-BOX (for unknown BOX:...) =====
class CreateBoxDialog extends StatefulWidget {
  final String barcode;
  const CreateBoxDialog({super.key, required this.barcode});
  @override
  State<CreateBoxDialog> createState() => _CreateBoxDialogState();
}

class _CreateBoxDialogState extends State<CreateBoxDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  late String _van;

  @override
  void initState() {
    super.initState();
    _van = (boxRepo.vans.isNotEmpty ? boxRepo.vans.first : 'Van 1');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _promptAddVan() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add van'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Van name (e.g., Van 4)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await boxRepo.addVan(name);
    setState(() => _van = name.trim());
  }

  @override
  Widget build(BuildContext context) {
    final vans = boxRepo.vans;
    return AlertDialog(
      title: const Text('Create Box'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Barcode: ${widget.barcode}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Box name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: vans.contains(_van) ? _van : (vans.isNotEmpty ? vans.first : 'Van 1'),
                    items: vans.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                    onChanged: (v) => setState(() => _van = v ?? _van),
                    decoration: const InputDecoration(labelText: 'Van', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Add van',
                  onPressed: _promptAddVan,
                  icon: const Icon(Icons.add),
                ),
              ],
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

/// ===== MANUAL “ADD BOX” DIALOG =====
class _NewBoxResult {
  final String barcode;
  final String name;
  final String van;
  const _NewBoxResult({required this.barcode, required this.name, required this.van});
}

class NewBoxDialog extends StatefulWidget {
  const NewBoxDialog({super.key});
  @override
  State<NewBoxDialog> createState() => _NewBoxDialogState();
}

class _NewBoxDialogState extends State<NewBoxDialog> {
  final _formKey = GlobalKey<FormState>();
  final _barcodeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  late String _van;

  @override
  void initState() {
    super.initState();
    _van = (boxRepo.vans.isNotEmpty ? boxRepo.vans.first : 'Van 1');
  }

  @override
  void dispose() {
    _barcodeCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _promptAddVan() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add van'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Van name (e.g., Van 4)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await boxRepo.addVan(name);
    setState(() => _van = name.trim());
  }

  @override
  Widget build(BuildContext context) {
    final vans = boxRepo.vans;
    return AlertDialog(
      title: const Text('Add Box'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _barcodeCtrl,
              decoration: const InputDecoration(
                labelText: 'Box Barcode (auto-add BOX: if missing)',
                border: OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a barcode' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Box name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: vans.contains(_van) ? _van : (vans.isNotEmpty ? vans.first : 'Van 1'),
                    items: vans.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                    onChanged: (v) => setState(() => _van = v ?? _van),
                    decoration: const InputDecoration(labelText: 'Van', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Add van',
                  onPressed: _promptAddVan,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              final bc = _barcodeCtrl.text.trim();
              final nm = _nameCtrl.text.trim();
              Navigator.pop(context, _NewBoxResult(barcode: bc, name: nm, van: _van));
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

  Future<void> _editItem(Item item) async {
    final res = await showDialog<_EditItemResult>(
      context: context,
      builder: (_) => _EditItemDialog(item: item),
    );
    if (res == null) return;
    await boxRepo.upsertItem(
      barcode: item.barcode,
      name: res.name,
      unitPriceCents: res.unitPriceCents,
      expiresOn: res.expiresOn,
      expiryWarningDays: res.expiryWarningDays,
    );
  }

  @override
  Widget build(BuildContext context) {
    // LISTEN to repo so +/- reflects immediately
    return AnimatedBuilder(
      animation: boxRepo,
      builder: (context, _) {
        final box = boxRepo.findBox(widget.boxBarcode);
        if (box == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Box not found')),
            body: const Center(child: Text('Missing box')),
          );
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
                            onTap: () => _editItem(line.item), // tap to edit
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
      },
    );
  }

  void _showEditBoxDialog(BuildContext context, Box box) {
    showDialog(context: context, builder: (_) => _EditBoxDialog(box: box));
  }
}

/// ===== ITEM WHERE PAGE (search results) =====
class ItemWherePage extends StatelessWidget {
  final String itemBarcode;
  const ItemWherePage({super.key, required this.itemBarcode});

  @override
  Widget build(BuildContext context) {
    final item = boxRepo.findItem(itemBarcode);
    final boxes = boxRepo.allBoxes;
    final results = <_ItemLocation>[];
    for (final b in boxes) {
      final q = boxRepo.getQuantity(b.barcode, itemBarcode);
      if (q > 0) results.add(_ItemLocation(box: b, qty: q));
    }
    results.sort((a, b) => a.box.name.toLowerCase().compareTo(b.box.name.toLowerCase()));

    return Scaffold(
      appBar: AppBar(title: const Text('Where is this item?')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: item == null
            ? const Center(child: Text('Item not found.'))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Item: ${item.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('Barcode: ${item.barcode} • Unit: ${fmtEuro(item.unitPriceCents)}'),
                if (item.expiresOn != null) Text('Expiry: ${fmtYmd(item.expiresOn!)}'),
                const SizedBox(height: 16),
                const Divider(),
                Text(results.isEmpty
                    ? 'No boxes currently hold this item.'
                    : 'Found in ${results.length} box(es):',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Expanded(
                  child: results.isEmpty
                      ? const SizedBox.shrink()
                      : ListView.separated(
                          itemCount: results.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final r = results[i];
                            return ListTile(
                              leading: const Icon(Icons.inventory_2_outlined),
                              title: Text(r.box.name),
                              subtitle: Text('Van: ${r.box.van} • Box barcode: ${r.box.barcode}'),
                              trailing: Text('Qty: ${r.qty}', style: const TextStyle(fontWeight: FontWeight.bold)),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => BoxDetailsPage(boxBarcode: r.box.barcode)),
                              ),
                            );
                          },
                        ),
                ),
              ]),
      ),
    );
  }
}

class _ItemLocation {
  final Box box;
  final int qty;
  _ItemLocation({required this.box, required this.qty});
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
  late String _van;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.box.name);
    _van = widget.box.van;
  }
  @override
  void dispose() { _nameCtrl.dispose(); super.dispose(); }

  Future<void> _promptAddVan() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add van'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Van name (e.g., Van 4)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await boxRepo.addVan(name);
    setState(() => _van = name.trim());
  }

  @override
  Widget build(BuildContext context) {
    final vans = boxRepo.vans;
    return AlertDialog(
      title: const Text('Edit Box'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Barcode: ${widget.box.barcode}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Box name', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: vans.contains(_van) ? _van : (vans.isNotEmpty ? vans.first : 'Van 1'),
                    items: vans.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                    onChanged: (v) => setState(() => _van = v ?? _van),
                    decoration: const InputDecoration(labelText: 'Van', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Add van',
                  onPressed: _promptAddVan,
                  icon: const Icon(Icons.add),
                ),
              ],
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

/// ===== NEW ITEM DIALOG =====
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

/// ===== EDIT ITEM DIALOG =====
class _EditItemResult {
  final String name;
  final int unitPriceCents;
  final DateTime? expiresOn;
  final int? expiryWarningDays;
  _EditItemResult({
    required this.name,
    required this.unitPriceCents,
    this.expiresOn,
    this.expiryWarningDays,
  });
}

class _EditItemDialog extends StatefulWidget {
  final Item item;
  const _EditItemDialog({required this.item});
  @override
  State<_EditItemDialog> createState() => _EditItemDialogState();
}

class _EditItemDialogState extends State<_EditItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _expiryCtrl; // YYYY-MM-DD
  late final TextEditingController _warnCtrl;   // days (int)

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.item.name);
    _priceCtrl = TextEditingController(text: _euroString(widget.item.unitPriceCents));
    _expiryCtrl = TextEditingController(text: widget.item.expiresOn == null ? '' : fmtYmd(widget.item.expiresOn!));
    _warnCtrl = TextEditingController(text: widget.item.expiryWarningDays?.toString() ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    _expiryCtrl.dispose();
    _warnCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Item'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Barcode: ${widget.item.barcode}', style: const TextStyle(fontSize: 12)),
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
              decoration: const InputDecoration(labelText: 'Unit price (€)', border: OutlineInputBorder()),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Enter price';
                return _parseEuroToCents(v) == null ? 'Invalid price' : null;
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
              final expires = _expiryCtrl.text.trim().isEmpty ? null : _tryParseYMD(_expiryCtrl.text.trim());
              final warnDays = _warnCtrl.text.trim().isEmpty ? null : int.parse(_warnCtrl.text.trim());
              Navigator.pop(context, _EditItemResult(
                name: _nameCtrl.text.trim(),
                unitPriceCents: cents,
                expiresOn: expires,
                expiryWarningDays: warnDays,
              ));
            }
          },
          child: const Text('Save'),
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

/// ===== SIMPLE QTY DIALOG =====
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
// For CSV export: 1234 -> "12.34", 1000 -> "10"
String _euroString(int cents) {
  final euros = cents ~/ 100;
  final rem = (cents % 100).abs();
  if (rem == 0) return euros.toString();
  return '$euros.${rem.toString().padLeft(2, '0')}';
}

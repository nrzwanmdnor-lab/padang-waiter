import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const brandGreen = Color(0xFF005A2B);
const brandLight = Color(0xFFE6F2EC);
const gstRate = 0.09; // prices INCLUDE GST
const cats = ['Hidang', 'Set', 'Desserts', 'Drinks'];
const orderModes = ['Dine in', 'Takeaway', 'Delivery', 'Catering'];
const payMethods = ['PayNow', 'Cash', 'Card', 'Unpaid'];
const mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String fmtDate(DateTime d) => '${d.day} ${mon[d.month - 1]} ${d.year}';
String dayKey(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
String f(double v) => v.toStringAsFixed(2);
Future<T?> go<T>(BuildContext c, Widget w) =>
    Navigator.push<T>(c, MaterialPageRoute(builder: (_) => w));

// ---------- settings (saved on the phone) ----------
final cfg = <String, String>{
  'ip': '192.168.1.50',
  'port': '9100',
  'cols': '42',
  'autoPrint': 'true',
  'company': 'HJH MAIMUNAH RESTAURANT PTE LTD',
  'uen': '199705733D',
  'gstNo': '',
  'defaultDelivery': '0',
  'address': '',
  'phone': '',
  'menuUrl': '', // paste the Google Sheet "Publish to web > CSV" link here
};

Future<void> loadCfg() async {
  final p = await SharedPreferences.getInstance();
  for (final k in cfg.keys.toList()) {
    cfg[k] = p.getString(k) ?? cfg[k]!;
  }
}

Future<void> saveCfg() async {
  final p = await SharedPreferences.getInstance();
  for (final e in cfg.entries) {
    await p.setString(e.key, e.value);
  }
}

// ---------- menu ----------
double? _d(dynamic v) => v == null || v.toString().trim().isEmpty
    ? null
    : double.tryParse(v.toString().trim());

class Item {
  final String id, cat, sub, name, note;
  final double? price, dM, tM, dL, tL;
  final bool available;

  Item(List r)
      : id = r[0].toString(),
        cat = r[1].toString(),
        sub = r[2].toString(),
        name = r[3].toString(),
        price = _d(r[4]),
        dM = _d(r[5]),
        tM = _d(r[6]),
        dL = _d(r[7]),
        tL = _d(r[8]),
        note = r[9].toString(),
        available = r[10].toString() == 'Yes';

  Item.custom({
    required this.id,
    required this.cat,
    required this.name,
    required double customPrice,
    this.sub = 'Custom',
    this.note = '',
  })  : price = customPrice,
        dM = null,
        tM = null,
        dL = null,
        tL = null,
        available = true;

  double? priceFor(String s, bool dine) => s == 'M'
      ? (dine ? (dM ?? tM) : (tM ?? dM))
      : s == 'L'
          ? (dine ? (dL ?? tL) : (tL ?? dL))
          : price;

  List<String> sizes(bool dine) => [
        if (price != null) 'Std',
        if (priceFor('M', dine) != null) 'M',
        if (priceFor('L', dine) != null) 'L',
      ];
}

List<Item> menu = [];

Future<void> loadMenu() async {
  final p = await SharedPreferences.getInstance();
  String t;
  try {
    if (cfg['menuUrl']!.isEmpty) throw 'no url';
    t = (await http
            .get(Uri.parse(cfg['menuUrl']!))
            .timeout(const Duration(seconds: 6)))
        .body;
    await p.setString('menuCache', t);
  } catch (_) {
    t = p.getString('menuCache') ??
        await rootBundle.loadString('assets/menu_all.csv');
  }
  final rows = const CsvToListConverter(eol: '\n').convert(t.replaceAll('\r', ''));
  menu = rows
      .skip(1)
      .where((r) => r.length >= 11)
      .map((r) => Item(r))
      .where((i) => i.available)
      .toList();
}

// ---------- order ----------
class Line {
  Item item;
  String size;
  int qty;
  Line(this.item, this.size, this.qty);
  double unit(bool d) => item.priceFor(size, d) ?? item.price ?? 0;
}

class Order {
  String name = '',
      mobile = '',
      inv = '',
      table = '',
      time = '12:30',
      notes = '',
      mode = 'Dine in',
      payMethod = 'PayNow';
  DateTime date = DateTime.now();
  int pax = 2;
  double deliveryFee = 0.0;
  double discount = 0.0;
  double deposit = 0.0;
  final Map<String, Line> lines = {};

  bool get dineIn => mode == 'Dine in';
  bool get isDeliveryOrCatering => mode == 'Delivery' || mode == 'Catering';

  int qty(Item i, String s) => lines['${i.id}|$s']?.qty ?? 0;

  void setQty(Item i, String s, int q) {
    if (q <= 0) {
      lines.remove('${i.id}|$s');
    } else {
      lines['${i.id}|$s'] = Line(i, s, q);
    }
  }

  double get rawTotal =>
      lines.values.fold(0.0, (a, l) => a + l.unit(dineIn) * l.qty);
  double get total =>
      (rawTotal + deliveryFee - discount).clamp(0.0, double.infinity);
  double get gst =>
      double.parse((total * gstRate / (1 + gstRate)).toStringAsFixed(2));
  double get balanceDue => (total - deposit).clamp(0.0, double.infinity);
  double get collectedAmount =>
      payMethod == 'Unpaid' ? deposit : (deposit > 0 ? deposit : total);
  int get count => lines.values.fold(0, (a, l) => a + l.qty);

  Map<String, dynamic> toJson() => {
        'inv': inv,
        'name': name,
        'mobile': mobile,
        'table': table,
        'time': time,
        'notes': notes,
        'mode': mode,
        'payMethod': payMethod,
        'date': date.toIso8601String(),
        'pax': pax,
        'dineIn': dineIn,
        'deliveryFee': deliveryFee,
        'discount': discount,
        'deposit': deposit,
        'lines': lines.values
            .map((l) => [
                  l.item.id,
                  l.size,
                  l.qty,
                  l.item.name,
                  l.unit(dineIn),
                  l.item.cat,
                ])
            .toList(),
      };

  static Order fromJson(Map<String, dynamic> j) {
    final bool legacyDine = j['dineIn'] ?? true;
    String loadedMode =
        (j['mode'] ?? (legacyDine ? 'Dine in' : 'Takeaway')).toString();
    if (!orderModes.contains(loadedMode)) {
      loadedMode = 'Catering';
    }
    final o = Order()
      ..inv = (j['inv'] ?? '').toString()
      ..name = (j['name'] ?? '').toString()
      ..mobile = (j['mobile'] ?? '').toString()
      ..table = (j['table'] ?? '').toString()
      ..time = (j['time'] ?? '12:30').toString()
      ..notes = (j['notes'] ?? '').toString()
      ..mode = loadedMode
      ..payMethod = (j['payMethod'] ?? 'PayNow').toString()
      ..date = DateTime.tryParse((j['date'] ?? '').toString()) ?? DateTime.now()
      ..pax = (j['pax'] is int) ? j['pax'] as int : int.tryParse('${j['pax']}') ?? 2
      ..deliveryFee = _d(j['deliveryFee']) ?? 0.0
      ..discount = _d(j['discount']) ?? 0.0
      ..deposit = _d(j['deposit']) ?? 0.0;

    for (final l in (j['lines'] as List? ?? [])) {
      final id = l[0].toString();
      final sz = l[1].toString();
      final q = (l[2] is int) ? l[2] as int : int.tryParse('${l[2]}') ?? 1;
      Item? it = menu.where((i) => i.id == id).firstOrNull;
      if (it == null && l.length >= 5) {
        final cPrice = _d(l[4]) ?? 0.0;
        final cCat = l.length >= 6 ? l[5].toString() : 'Hidang';
        it = Item.custom(
          id: id,
          cat: cCat,
          name: l[3].toString(),
          customPrice: cPrice,
        );
        menu.add(it);
      }
      if (it != null) o.setQty(it, sz, q);
    }
    return o;
  }
}

String lname(Line l) => l.item.name + (l.size == 'Std' ? '' : ' (${l.size})');

Future<String> nextInv(DateTime d) async {
  final p = await SharedPreferences.getInstance();
  final day = dayKey(d);
  final n = (p.getInt('cnt_$day') ?? 0) + 1;
  await p.setInt('cnt_$day', n);
  return 'INV-$day-${n.toString().padLeft(3, '0')}';
}

Future<void> saveOrder(Order o) async {
  final p = await SharedPreferences.getInstance();
  final rawList = p.getStringList('orders') ?? [];
  final encoded = jsonEncode(o.toJson());
  int existingIdx = -1;
  for (int i = 0; i < rawList.length; i++) {
    try {
      final m = jsonDecode(rawList[i]) as Map<String, dynamic>;
      if (m['inv'] == o.inv && o.inv.isNotEmpty) {
        existingIdx = i;
        break;
      }
    } catch (_) {}
  }
  if (existingIdx >= 0) {
    rawList[existingIdx] = encoded;
  } else {
    rawList.add(encoded);
  }
  await p.setStringList(
    'orders',
    rawList.length > 300 ? rawList.sublist(rawList.length - 300) : rawList,
  );
}

Future<void> deleteOrder(String inv) async {
  final p = await SharedPreferences.getInstance();
  final rawList = p.getStringList('orders') ?? [];
  rawList.removeWhere((s) {
    try {
      return (jsonDecode(s) as Map<String, dynamic>)['inv'] == inv;
    } catch (_) {
      return false;
    }
  });
  await p.setStringList('orders', rawList);
}

// ---------- 80mm receipt (ESC/POS over LAN, port 9100) ----------
int get printWidth => int.tryParse(cfg['cols'] ?? '42') ?? 42;

String lr(String a, String b) {
  final w = printWidth;
  final maxLeft = (w - b.length - 1).clamp(1, w);
  return (a.length > maxLeft ? a.substring(0, maxLeft) : a).padRight(w - b.length) + b;
}

String ctr(String s) {
  final w = printWidth;
  return ' ' * (((w - s.length) / 2).floor().clamp(0, w)) + s;
}

List<(String, bool)> receiptLines(Order o) {
  final w = printWidth;
  final locLabel = o.isDeliveryOrCatering ? 'Addr' : 'Table';
  final L = <(String, bool)>[
    (ctr(cfg['company']!), true),
    (ctr(cfg['address']!.isEmpty ? '[Address]' : cfg['address']!), false),
    (ctr('Tel: ${cfg['phone']!.isEmpty ? '[Phone]' : cfg['phone']}'), false),
    (ctr('UEN: ${cfg['uen']}'), false),
    (ctr('GST Reg: ${cfg['gstNo']!.isEmpty ? '[GST No.]' : cfg['gstNo']}'), false),
    ('-' * w, false),
    ('TAX INVOICE  ${o.inv}', true),
    ('Date: ${fmtDate(o.date)} ${o.time}', false),
    ('${o.mode} | Pax ${o.pax}', true),
    if (o.table.trim().isNotEmpty) ('$locLabel: ${o.table.trim()}', false),
    ('Cust: ${o.name} (${o.mobile})', false),
    if (o.notes.trim().isNotEmpty) ('Remarks: ${o.notes.trim()}', false),
    ('-' * w, false),
  ];
  for (final c in cats) {
    final ls = o.lines.values.where((l) => l.item.cat == c).toList();
    if (ls.isEmpty) continue;
    L.add((c.toUpperCase(), true));
    for (final l in ls) {
      L.add((lr('${l.qty}x ${lname(l)}', f(l.unit(o.dineIn) * l.qty)), false));
      if (l.qty > 1) L.add(('   @ ${f(l.unit(o.dineIn))}', false));
    }
  }
  L.addAll([
    ('-' * w, false),
    (lr('Items Subtotal', f(o.rawTotal)), false),
    if (o.deliveryFee > 0) (lr('Delivery Charge', f(o.deliveryFee)), false),
    if (o.discount > 0) (lr('Discount', '-${f(o.discount)}'), false),
    (lr('Subtotal (excl. GST)', f(o.total - o.gst)), false),
    (lr('GST 9% (included)', f(o.gst)), false),
    (lr('TOTAL (SGD)', f(o.total)), true),
    if (o.deposit > 0) (lr('Deposit Paid (${o.payMethod})', '-${f(o.deposit)}'), false),
    if (o.deposit > 0 || o.payMethod == 'Unpaid')
      (lr('BALANCE DUE', f(o.balanceDue)), true)
    else
      (lr('Paid via ${o.payMethod}', f(o.total)), false),
    ('-' * w, false),
    ('', false),
    (ctr('Thank you! Terima kasih!'), false),
  ]);
  return L;
}

Future<void> printLan(Order o) async {
  final s = await Socket.connect(
    cfg['ip']!,
    int.parse(cfg['port']!),
    timeout: const Duration(seconds: 5),
  );
  final b = BytesBuilder()..add([0x1b, 0x40]);
  for (final (t, bold) in receiptLines(o)) {
    b.add([0x1b, 0x45, bold ? 1 : 0]);
    b.add(latin1.encode(t.replaceAll(RegExp(r'[^\x00-\x7F]'), '?')));
    b.add([0x0a]);
  }
  b.add([0x0a, 0x0a, 0x0a, 0x1d, 0x56, 0x42, 0x00]);
  s.add(b.takeBytes());
  await s.flush();
  await s.close();
}

Future<String?> tryPrint(Order o) async {
  try {
    await printLan(o);
    return null;
  } catch (e) {
    return e.toString();
  }
}

// ---------- A4 invoice PDF ----------
Future<void> shareInvoice(Order o) async {
  final d = pw.Document();
  final rows = <List<String>>[];
  for (final c in cats) {
    for (final l in o.lines.values.where((l) => l.item.cat == c)) {
      rows.add([
        lname(l),
        '${l.qty}',
        '\$${f(l.unit(o.dineIn))}',
        '\$${f(l.unit(o.dineIn) * l.qty)}',
      ]);
    }
  }
  final locLabel = o.isDeliveryOrCatering ? 'Address' : 'Table';
  d.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            cfg['company']!,
            style: pw.TextStyle(
              fontSize: 18,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#005A2B'),
            ),
          ),
          pw.Text('UEN ${cfg['uen']}   GST Reg ${cfg['gstNo']}'),
          if (cfg['address']!.isNotEmpty || cfg['phone']!.isNotEmpty)
            pw.Text('${cfg['address']}  Tel: ${cfg['phone']}'),
          pw.SizedBox(height: 12),
          pw.Text(
            'TAX INVOICE  ${o.inv}',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text(
            '${fmtDate(o.date)} ${o.time}  |  ${o.mode}  |  Pax ${o.pax}${o.table.trim().isEmpty ? '' : '  |  $locLabel: ${o.table.trim()}'}',
          ),
          pw.Text('Billed to: ${o.name}  ${o.mobile}'),
          if (o.notes.trim().isNotEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4),
              child: pw.Text(
                'Remarks: ${o.notes.trim()}',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
            ),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: ['Item', 'Qty', 'Price', 'Amount'],
            data: rows,
            headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#E6F2EC')),
            cellAlignments: {
              1: pw.Alignment.center,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
            },
          ),
          pw.SizedBox(height: 10),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text('Items Subtotal: \$${f(o.rawTotal)}'),
                if (o.deliveryFee > 0)
                  pw.Text('Delivery Charge: +\$${f(o.deliveryFee)}'),
                if (o.discount > 0) pw.Text('Discount: -\$${f(o.discount)}'),
                pw.Text('Subtotal (excl. GST): \$${f(o.total - o.gst)}'),
                pw.Text('GST 9% (included): \$${f(o.gst)}'),
                pw.Text(
                  'TOTAL (SGD): \$${f(o.total)}',
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromHex('#005A2B'),
                  ),
                ),
                if (o.deposit > 0)
                  pw.Text('Deposit Paid (${o.payMethod}): -\$${f(o.deposit)}'),
                pw.Text(
                  'Balance Due (${o.payMethod}): \$${f(o.balanceDue)}',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  await Printing.sharePdf(bytes: await d.save(), filename: '${o.inv}.pdf');
}

// ---------- app ----------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCfg();
  await loadMenu();
  runApp(
    MaterialApp(
      title: 'Padang Waiter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandGreen,
          primary: brandGreen,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: brandGreen,
          foregroundColor: Colors.white,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: brandGreen,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(50),
          ),
        ),
      ),
      home: const CustomerScreen(),
    ),
  );
}

// ---------- Screen 1: Customer, Order Type & Quick Pax Setup ----------
class CustomerScreen extends StatefulWidget {
  final Order? existingOrder;
  const CustomerScreen({super.key, this.existingOrder});
  @override
  State<CustomerScreen> createState() => _CustomerState();
}

class _CustomerState extends State<CustomerScreen> {
  late final Order o;
  late final TextEditingController n, m, tbl, notesCtl, paxCtl;

  @override
  void initState() {
    super.initState();
    o = widget.existingOrder ?? Order();
    n = TextEditingController(text: o.name);
    m = TextEditingController(text: o.mobile);
    tbl = TextEditingController(text: o.table);
    notesCtl = TextEditingController(text: o.notes);
    paxCtl = TextEditingController(text: '${o.pax}');
  }

  void setPaxValue(int val) {
    final clamped = val < 1 ? 1 : val;
    setState(() {
      o.pax = clamped;
      paxCtl.text = '$clamped';
      paxCtl.selection = TextSelection.fromPosition(
        TextPosition(offset: paxCtl.text.length),
      );
    });
  }

  void addQuickNote(String tag) {
    final cur = notesCtl.text.trim();
    notesCtl.text = cur.isEmpty ? tag : '$cur, $tag';
    setState(() {});
  }

  Future<void> pickTime() async {
    final parts = o.time.split(':');
    final init = TimeOfDay(
      hour: int.tryParse(parts.firstOrNull ?? '12') ?? 12,
      minute: int.tryParse(parts.length > 1 ? parts[1] : '30') ?? 30,
    );
    final picked = await showTimePicker(context: context, initialTime: init);
    if (picked != null) {
      setState(() {
        o.time =
            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  @override
  Widget build(BuildContext c) {
    final isEdit = o.inv.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit ${o.inv}' : 'New Order'),
        actions: [
          IconButton(
            tooltip: 'Orders & Sales',
            icon: const Icon(Icons.receipt_long),
            onPressed: () => go(c, const HistoryScreen()),
          ),
          IconButton(
            tooltip: 'App & Printer Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => go(c, const SettingsScreen()),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 4 Order Types: Dine in | Takeaway | Delivery | Catering
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              for (final mode in orderModes)
                ButtonSegment(
                  value: mode,
                  label: Text(mode, style: const TextStyle(fontSize: 12)),
                ),
            ],
            selected: {o.mode},
            onSelectionChanged: (s) {
              setState(() {
                o.mode = s.first;
                if (o.isDeliveryOrCatering && o.deliveryFee == 0) {
                  o.deliveryFee = _d(cfg['defaultDelivery']) ?? 0.0;
                }
              });
            },
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final d = await showDatePicker(
                      context: c,
                      initialDate: o.date,
                      firstDate: DateTime(2024),
                      lastDate: DateTime(2035),
                    );
                    if (d != null) setState(() => o.date = d);
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today, size: 18),
                    ),
                    child: Text(
                      fmtDate(o.date),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: pickTime,
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Time',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.access_time, size: 18),
                    ),
                    child: Text(
                      o.time,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Quick Pax Input Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: brandLight.withValues(alpha: 0.5),
              border: Border.all(color: brandGreen.withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Pax (Type directly or tap quick buttons)',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: brandGreen,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    IconButton.outlined(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setPaxValue(o.pax - 1),
                      icon: const Icon(Icons.remove),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 72,
                      child: TextField(
                        controller: paxCtl,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onChanged: (v) {
                          final parsed = int.tryParse(v.trim());
                          if (parsed != null && parsed > 0) {
                            o.pax = parsed;
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton.filled(
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(backgroundColor: brandGreen),
                      onPressed: () => setPaxValue(o.pax + 1),
                      icon: const Icon(Icons.add, color: Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset in [2, 4, 6, 10, 20, 30, 50, 100])
                      ChoiceChip(
                        label: Text(
                          '$preset',
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: o.pax == preset,
                        selectedColor: brandGreen,
                        labelStyle: TextStyle(
                          color: o.pax == preset ? Colors.white : brandGreen,
                          fontWeight: FontWeight.bold,
                        ),
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setPaxValue(preset),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          TextField(
            controller: tbl,
            decoration: InputDecoration(
              labelText: o.isDeliveryOrCatering
                  ? 'Delivery / Catering Address'
                  : 'Table No. (e.g. T-12)',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: n,
                  decoration: const InputDecoration(
                    labelText: 'Customer Name',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: m,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Mobile',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: notesCtl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Order / Delivery Remarks',
              hintText: 'e.g. Less spicy, separate gravy, call on arrival',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final tag in [
                'Less Spicy',
                'Separate Gravy',
                'No Peanuts',
                'Call on Arrival',
              ])
                ActionChip(
                  backgroundColor: brandLight,
                  label: Text(
                    '+ $tag',
                    style: const TextStyle(fontSize: 12, color: brandGreen),
                  ),
                  onPressed: () => addQuickNote(tag),
                ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.restaurant_menu),
            label: Text(
              isEdit
                  ? 'Continue to Menu (${o.count} items)'
                  : 'Next: Choose Menu',
            ),
            onPressed: () {
              final typedPax = int.tryParse(paxCtl.text.trim());
              if (typedPax != null && typedPax > 0) o.pax = typedPax;
              o.name = n.text.trim();
              o.mobile = m.text.trim();
              o.table = tbl.text.trim();
              o.notes = notesCtl.text.trim();
              go(c, MenuScreen(o));
            },
          ),
        ],
      ),
    );
  }
}

// ---------- Screen 2: Menu with Quick Quantity Input, Search & Custom Item ----------
class MenuScreen extends StatefulWidget {
  final Order o;
  const MenuScreen(this.o, {super.key});
  @override
  State<MenuScreen> createState() => _MenuState();
}

class _MenuState extends State<MenuScreen> {
  Order get o => widget.o;
  final sel = <String, String>{};
  final searchCtl = TextEditingController();
  String query = '';
  final selectedSub = <String, String>{for (final c in cats) c: 'All'};

  Future<void> showQuickQtyDialog(Item item, String size) async {
    final current = o.qty(item, size);
    final qtyCtl = TextEditingController(text: current > 0 ? '$current' : '');
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '${item.name}${size == 'Std' ? '' : ' ($size)'}',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: qtyCtl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Enter Quantity',
                hintText: '0 to remove',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) {
                final q = int.tryParse(v.trim()) ?? 0;
                setState(() => o.setQty(item, size, q));
                Navigator.pop(ctx);
              },
            ),
            const SizedBox(height: 12),
            const Text(
              'Quick Select:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: brandGreen,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  backgroundColor: Colors.red.shade50,
                  label: const Text(
                    'Clear (0)',
                    style: TextStyle(color: Colors.red, fontSize: 12),
                  ),
                  onPressed: () {
                    setState(() => o.setQty(item, size, 0));
                    Navigator.pop(ctx);
                  },
                ),
                for (final q in [1, 2, 5, 10, 15, 20, 30, 50, 100])
                  ActionChip(
                    backgroundColor: brandLight,
                    label: Text(
                      '$q',
                      style: const TextStyle(
                        color: brandGreen,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                    onPressed: () {
                      setState(() => o.setQty(item, size, q));
                      Navigator.pop(ctx);
                    },
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(90, 40)),
            onPressed: () {
              final q = int.tryParse(qtyCtl.text.trim()) ?? 0;
              setState(() => o.setQty(item, size, q));
              Navigator.pop(ctx);
            },
            child: const Text('Set Qty'),
          ),
        ],
      ),
    );
  }

  Future<void> showCustomItemDialog(String currentCat) async {
    final nameCtl = TextEditingController();
    final priceCtl = TextEditingController();
    final qtyCtl = TextEditingController(text: '1');
    String chosenCat = currentCat;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('Add Custom / Open-Price Item'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: chosenCat,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final c in cats)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setSt(() => chosenCat = v ?? currentCat),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(
                  labelText: 'Item Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: priceCtl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Price (SGD)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 80,
                    child: TextField(
                      controller: qtyCtl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Qty',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(100, 42)),
              onPressed: () {
                final nm = nameCtl.text.trim();
                final pr = double.tryParse(priceCtl.text.trim());
                final q = int.tryParse(qtyCtl.text.trim()) ?? 1;
                if (nm.isEmpty || pr == null) return;
                final custom = Item.custom(
                  id: 'CUST_${DateTime.now().millisecondsSinceEpoch}',
                  cat: chosenCat,
                  name: nm,
                  customPrice: pr,
                );
                setState(() {
                  menu.insert(0, custom);
                  o.setQty(custom, 'Std', q);
                });
                Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildCategoryTab(String cat) {
    final allCatItems = menu
        .where((i) =>
            (query.isNotEmpty || i.cat == cat) &&
            i.sizes(o.dineIn).isNotEmpty &&
            (query.isEmpty ||
                i.name.toLowerCase().contains(query) ||
                i.sub.toLowerCase().contains(query)))
        .toList();

    final subs = <String>{'All', for (final i in allCatItems) i.sub}.toList();
    final activeSub =
        subs.contains(selectedSub[cat]) ? selectedSub[cat]! : 'All';
    final filtered = allCatItems
        .where((i) => activeSub == 'All' || i.sub == activeSub)
        .toList();

    final w = <Widget>[];
    String? sub;
    for (final i in filtered) {
      if (i.sub != sub) {
        sub = i.sub;
        w.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              sub.toUpperCase(),
              style: const TextStyle(
                color: brandGreen,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      }
      final sz = i.sizes(o.dineIn);
      final s = sz.contains(sel[i.id]) ? sel[i.id]! : sz.first;
      final curQty = o.qty(i, s);
      w.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          i.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          '\$${f(i.priceFor(s, o.dineIn)!)}${i.note.isEmpty ? '' : ' · ${i.note}'}',
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  IconButton.outlined(
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => o.setQty(i, s, curQty - 1)),
                    icon: const Icon(Icons.remove),
                  ),
                  const SizedBox(width: 4),
                  // Tappable Quick Quantity Badge
                  InkWell(
                    onTap: () => showQuickQtyDialog(i, s),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 44),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: curQty > 0 ? brandLight : Colors.grey.shade100,
                        border: Border.all(
                          color: curQty > 0 ? brandGreen : Colors.grey.shade400,
                          width: curQty > 0 ? 1.5 : 1,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$curQty',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: curQty > 0 ? brandGreen : Colors.black87,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.outlined(
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => o.setQty(i, s, curQty + 1)),
                    icon: const Icon(Icons.add, color: brandGreen),
                  ),
                ],
              ),
              if (sz.length > 1)
                Wrap(
                  spacing: 8,
                  children: [
                    for (final z in sz)
                      ChoiceChip(
                        label: Text('$z \$${f(i.priceFor(z, o.dineIn)!)}'),
                        selected: z == s,
                        selectedColor: brandLight,
                        onSelected: (_) => setState(() => sel[i.id] = z),
                      ),
                  ],
                ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        if (subs.length > 2)
          Container(
            color: brandLight,
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                for (final sc in subs)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(sc, style: const TextStyle(fontSize: 12)),
                      selected: activeSub == sc,
                      selectedColor: brandGreen,
                      labelStyle: TextStyle(
                        color: activeSub == sc ? Colors.white : brandGreen,
                        fontWeight: FontWeight.w600,
                      ),
                      onSelected: (_) => setState(() => selectedSub[cat] = sc),
                    ),
                  ),
              ],
            ),
          ),
        Container(
          width: double.infinity,
          color: Colors.amber.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: const Text(
            'Tip: Tap any quantity box to type a number or pick 5, 10, 20, 30, 50, 100',
            style: TextStyle(fontSize: 12, color: Colors.black87),
          ),
        ),
        Expanded(
          child: w.isEmpty
              ? const Center(child: Text('No matching dishes found'))
              : ListView(children: w),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext c) => DefaultTabController(
        length: cats.length,
        child: Builder(
          builder: (tabCtx) => Scaffold(
            appBar: AppBar(
              title: Text(
                '${o.mode} · ${o.pax} pax${o.name.isEmpty ? '' : ' · ${o.name}'}',
                style: const TextStyle(fontSize: 15),
              ),
              actions: [
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.amberAccent,
                  ),
                  icon: const Icon(Icons.add_box_outlined, size: 18),
                  label: const Text('Custom'),
                  onPressed: () {
                    final idx = DefaultTabController.of(tabCtx).index;
                    showCustomItemDialog(cats[idx]);
                  },
                ),
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(96),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      child: TextField(
                        controller: searchCtl,
                        onChanged: (v) =>
                            setState(() => query = v.trim().toLowerCase()),
                        decoration: InputDecoration(
                          hintText:
                              'Search 150 dishes (e.g. Rendang, Siakap)...',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    searchCtl.clear();
                                    setState(() => query = '');
                                  },
                                ),
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    TabBar(
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white70,
                      indicatorColor: Colors.white,
                      tabs: [for (final cat in cats) Tab(text: cat)],
                    ),
                  ],
                ),
              ),
            ),
            body: TabBarView(
              children: [for (final cat in cats) buildCategoryTab(cat)],
            ),
            bottomNavigationBar: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${o.count} items selected',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '\$${f(o.rawTotal)}',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: brandGreen,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed:
                          o.count == 0 ? null : () => go(c, ReviewScreen(o)),
                      child: const Text('Review Order & Payment →'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

// ---------- Screen 3: Review, Delivery Charge, Discount, Deposit & Payment ----------
class ReviewScreen extends StatefulWidget {
  final Order o;
  const ReviewScreen(this.o, {super.key});
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  Order get o => widget.o;
  late final TextEditingController delivCtl, discCtl, depCtl;

  @override
  void initState() {
    super.initState();
    delivCtl = TextEditingController(
      text: o.deliveryFee > 0 ? f(o.deliveryFee) : '',
    );
    discCtl = TextEditingController(
      text: o.discount > 0 ? f(o.discount) : '',
    );
    depCtl = TextEditingController(
      text: o.deposit > 0 ? f(o.deposit) : '',
    );
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Review & Payment')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: brandLight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '${o.name.isEmpty ? 'Walk-in' : o.name}${o.mobile.isEmpty ? '' : ' · ${o.mobile}'}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        Chip(
                          label: Text(
                            '${o.mode} · ${o.pax} Pax',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                          backgroundColor: brandGreen,
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    Text('${fmtDate(o.date)} at ${o.time}'),
                    if (o.table.trim().isNotEmpty)
                      Text(
                        '${o.isDeliveryOrCatering ? 'Address' : 'Table'}: ${o.table}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    if (o.notes.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Remarks: ${o.notes}',
                          style: const TextStyle(
                            color: brandGreen,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            for (final cat in cats) ...[
              if (o.lines.values.any((l) => l.item.cat == cat))
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text(
                    cat.toUpperCase(),
                    style: const TextStyle(
                      color: brandGreen,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              for (final l in o.lines.values.where((l) => l.item.cat == cat))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${l.qty} × ${lname(l)}'),
                  trailing: Text(
                    '\$${f(l.unit(o.dineIn) * l.qty)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
            ],
            const Divider(height: 24),
            const Text(
              'Delivery Charge, Discount & Deposit',
              style: TextStyle(
                color: brandGreen,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: delivCtl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Delivery (\$)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(
                      () => o.deliveryFee = double.tryParse(v.trim()) ?? 0.0,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: discCtl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Discount (\$)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(
                      () => o.discount = double.tryParse(v.trim()) ?? 0.0,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: depCtl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Deposit (\$)',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(
                      () => o.deposit = double.tryParse(v.trim()) ?? 0.0,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'Payment Method',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final pm in payMethods)
                  ChoiceChip(
                    label: Text(pm),
                    selected: o.payMethod == pm,
                    selectedColor: brandGreen,
                    labelStyle: TextStyle(
                      color: o.payMethod == pm ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w600,
                    ),
                    onSelected: (_) => setState(() => o.payMethod = pm),
                  ),
              ],
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Items Subtotal'),
                    Text('\$${f(o.rawTotal)}'),
                  ],
                ),
                if (o.deliveryFee > 0)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Delivery Charge'),
                      Text('+\$${f(o.deliveryFee)}'),
                    ],
                  ),
                if (o.discount > 0)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Discount'),
                      Text('-\$${f(o.discount)}'),
                    ],
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Subtotal (excl. GST)'),
                    Text('\$${f(o.total - o.gst)}'),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('GST 9% (included)'),
                    Text('\$${f(o.gst)}'),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Grand Total (SGD)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '\$${f(o.total)}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: brandGreen,
                      ),
                    ),
                  ],
                ),
                if (o.deposit > 0) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Deposit Paid (${o.payMethod})'),
                      Text('-\$${f(o.deposit)}'),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Balance Due',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '\$${f(o.balanceDue)}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton(
                  child: const Text('Confirm Order & Tax Invoice'),
                  onPressed: () async {
                    if (o.inv.isEmpty) {
                      o.inv = await nextInv(o.date);
                    }
                    await saveOrder(o);
                    String? err;
                    if (cfg['autoPrint'] == 'true') {
                      err = await tryPrint(o);
                    }
                    if (c.mounted) {
                      Navigator.pushAndRemoveUntil(
                        c,
                        MaterialPageRoute(builder: (_) => DoneScreen(o, err)),
                        (r) => false,
                      );
                    }
                  },
                ),
                TextButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('Edit Items'),
                ),
              ],
            ),
          ),
        ),
      );
}

// ---------- Screen 4: Confirmed Order + 80mm Tax Invoice & PDF (No KOT) ----------
class DoneScreen extends StatefulWidget {
  final Order o;
  final String? err;
  const DoneScreen(this.o, this.err, {super.key});
  @override
  State<DoneScreen> createState() => _DoneState();
}

class _DoneState extends State<DoneScreen> {
  String? err;

  @override
  void initState() {
    super.initState();
    err = widget.err;
  }

  @override
  Widget build(BuildContext c) {
    final o = widget.o;
    final previewLines = receiptLines(o);
    return Scaffold(
      appBar: AppBar(
        title: Text('Confirmed · ${o.inv}'),
        actions: [
          IconButton(
            tooltip: 'Orders & Sales',
            icon: const Icon(Icons.receipt_long),
            onPressed: () => go(c, const HistoryScreen()),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle, size: 36, color: brandGreen),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${o.mode} (${o.pax} Pax) · Total \$${f(o.total)} (Bal \$${f(o.balanceDue)})',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (err != null)
                          Text(
                            'Printer notice: $err',
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 12,
                            ),
                          )
                        else
                          Text(
                            cfg['autoPrint'] == 'true'
                                ? 'Receipt sent to 80mm LAN printer'
                                : 'Order saved (tap below to print or share PDF)',
                            style: const TextStyle(
                              color: brandGreen,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      previewLines.map((e) => e.$1).join('\n'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                icon: const Icon(Icons.print),
                label: const Text('Print 80mm Tax Invoice'),
                onPressed: () async {
                  final e = await tryPrint(o);
                  setState(() => err = e);
                  if (c.mounted && e == null) {
                    ScaffoldMessenger.of(c).showSnackBar(
                      const SnackBar(content: Text('Receipt sent to printer')),
                    );
                  }
                },
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: const Icon(Icons.picture_as_pdf),
                onPressed: () => shareInvoice(o),
                label: const Text('Share A4 Invoice PDF'),
              ),
              TextButton(
                onPressed: () => Navigator.pushAndRemoveUntil(
                  c,
                  MaterialPageRoute(builder: (_) => const CustomerScreen()),
                  (r) => false,
                ),
                child: const Text('+ Start New Order'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- Screen 5: Order History (Edit/Reopen) & Daily Sales CSV ----------
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Order> allOrders = [];
  bool loading = true;
  String search = '';
  bool todayOnly = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    final p = await SharedPreferences.getInstance();
    final list = (p.getStringList('orders') ?? [])
        .reversed
        .map((s) => Order.fromJson(jsonDecode(s)))
        .toList();
    if (mounted) {
      setState(() {
        allOrders = list;
        loading = false;
      });
    }
  }

  List<Order> get filteredOrders {
    final todayStr = dayKey(DateTime.now());
    return allOrders.where((o) {
      if (todayOnly && dayKey(o.date) != todayStr) return false;
      if (search.isNotEmpty) {
        final q = search.toLowerCase();
        return o.name.toLowerCase().contains(q) ||
            o.mobile.toLowerCase().contains(q) ||
            o.table.toLowerCase().contains(q) ||
            o.mode.toLowerCase().contains(q) ||
            o.inv.toLowerCase().contains(q);
      }
      return true;
    }).toList();
  }

  Future<void> exportCsv(List<Order> list) async {
    final rows = <List<dynamic>>[
      [
        'Invoice',
        'Date',
        'Time',
        'Order Type',
        'Table / Address',
        'Customer',
        'Mobile',
        'Pax',
        'Items Subtotal',
        'Delivery Charge',
        'Discount',
        'Total SGD',
        'GST 9%',
        'Deposit',
        'Balance Due',
        'Payment Method',
        'Remarks',
      ],
      for (final o in list)
        [
          o.inv,
          fmtDate(o.date),
          o.time,
          o.mode,
          o.table,
          o.name,
          o.mobile,
          o.pax,
          f(o.rawTotal),
          f(o.deliveryFee),
          f(o.discount),
          f(o.total),
          f(o.gst),
          f(o.deposit),
          f(o.balanceDue),
          o.payMethod,
          o.notes,
        ],
    ];
    final csvStr = const ListToCsvConverter().convert(rows);
    await Clipboard.setData(ClipboardData(text: csvStr));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Sales CSV copied to clipboard & opening share dialog...'),
        ),
      );
    }
    await Printing.sharePdf(
      bytes: Uint8List.fromList(utf8.encode(csvStr)),
      filename: 'padang_orders_${dayKey(DateTime.now())}.csv',
    );
  }

  @override
  Widget build(BuildContext c) {
    final list = filteredOrders;
    final totalSales = list.fold(0.0, (a, o) => a + o.total);
    final totalCollected = list.fold(0.0, (a, o) => a + o.collectedAmount);
    final totalBalance = list.fold(0.0, (a, o) => a + o.balanceDue);
    final totalPax = list.fold(0, (a, o) => a + o.pax);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Orders & Daily Sales'),
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Colors.amberAccent),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Export CSV'),
            onPressed: list.isEmpty ? null : () => exportCsv(list),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  margin: const EdgeInsets.all(12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: brandGreen,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            todayOnly ? 'Today\'s Summary' : 'Sales Summary',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '${list.length} Orders · $totalPax Pax',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          Column(
                            children: [
                              const Text(
                                'Total Sales',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                '\$${f(totalSales)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                          Column(
                            children: [
                              const Text(
                                'Collected',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                '\$${f(totalCollected)}',
                                style: const TextStyle(
                                  color: Colors.greenAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                          Column(
                            children: [
                              const Text(
                                'Balance Due',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                '\$${f(totalBalance)}',
                                style: const TextStyle(
                                  color: Colors.amberAccent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          onChanged: (v) => setState(() => search = v.trim()),
                          decoration: const InputDecoration(
                            hintText: 'Search name, mode, mobile or INV...',
                            prefixIcon: Icon(Icons.search, size: 18),
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Today Only'),
                        selected: todayOnly,
                        selectedColor: brandLight,
                        onSelected: (v) => setState(() => todayOnly = v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: list.isEmpty
                      ? const Center(child: Text('No orders found'))
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: list.length,
                          itemBuilder: (_, idx) {
                            final o = list[idx];
                            return Card(
                              margin: const EdgeInsets.only(bottom: 10),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            '${o.name.isEmpty ? 'Walk-in' : o.name} · ${o.mode}',
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          '\$${f(o.total)}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                            color: brandGreen,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      '${o.inv} · ${o.pax} pax · ${fmtDate(o.date)} ${o.time}${o.table.isEmpty ? '' : ' · ${o.table}'}',
                                      style: const TextStyle(
                                        color: Colors.black54,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      'Payment: ${o.payMethod}${o.deliveryFee > 0 ? ' · Delivery \$${f(o.deliveryFee)}' : ''}${o.deposit > 0 ? ' · Deposit \$${f(o.deposit)} (Bal \$${f(o.balanceDue)})' : ''}',
                                      style: const TextStyle(
                                        color: brandGreen,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (o.notes.isNotEmpty)
                                      Text(
                                        'Remarks: ${o.notes}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    const Divider(height: 14),
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        FilledButton.tonalIcon(
                                          icon: const Icon(Icons.edit, size: 16),
                                          label: const Text('Edit Order'),
                                          onPressed: () async {
                                            await go(
                                              c,
                                              CustomerScreen(existingOrder: o),
                                            );
                                            reload();
                                          },
                                        ),
                                        TextButton.icon(
                                          icon: const Icon(Icons.print, size: 16),
                                          onPressed: () async {
                                            final e = await tryPrint(o);
                                            if (c.mounted) {
                                              ScaffoldMessenger.of(c)
                                                  .showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    e ?? 'Receipt printed',
                                                  ),
                                                ),
                                              );
                                            }
                                          },
                                          label: const Text('Print Bill'),
                                        ),
                                        TextButton.icon(
                                          icon: const Icon(
                                            Icons.picture_as_pdf,
                                            size: 16,
                                          ),
                                          onPressed: () => shareInvoice(o),
                                          label: const Text('Invoice PDF'),
                                        ),
                                        IconButton(
                                          tooltip: 'Delete Order',
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            color: Colors.red,
                                            size: 20,
                                          ),
                                          onPressed: () async {
                                            await deleteOrder(o.inv);
                                            reload();
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

// ---------- Screen 6: App & Printer Settings ----------
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsScreen> {
  late final Map<String, TextEditingController> ctl;
  late String selectedCols;
  late bool autoPrint;

  @override
  void initState() {
    super.initState();
    ctl = {
      for (final k in cfg.keys) k: TextEditingController(text: cfg[k]),
    };
    selectedCols = ['32', '42', '48'].contains(cfg['cols']) ? cfg['cols']! : '42';
    autoPrint = cfg['autoPrint'] != 'false';
  }

  Future<void> save() async {
    for (final k in ctl.keys) {
      cfg[k] = ctl[k]!.text.trim();
    }
    cfg['cols'] = selectedCols;
    cfg['autoPrint'] = autoPrint ? 'true' : 'false';
    await saveCfg();
    await loadMenu();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('App & Printer Settings')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Section 1: LAN Thermal Printer Settings
            Card(
              color: brandLight.withValues(alpha: 0.45),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: brandGreen.withValues(alpha: 0.3)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.print, color: brandGreen),
                        SizedBox(width: 8),
                        Text(
                          'LAN Thermal Receipt Printer',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: brandGreen,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: ctl['ip'],
                            decoration: const InputDecoration(
                              labelText: 'Printer IP Address',
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: ctl['port'],
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Port',
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: selectedCols,
                      decoration: const InputDecoration(
                        labelText: 'Paper Width (Characters per Line)',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: '42',
                          child: Text('80mm Standard (42 columns)'),
                        ),
                        DropdownMenuItem(
                          value: '48',
                          child: Text('80mm Wide Font B (48 columns)'),
                        ),
                        DropdownMenuItem(
                          value: '32',
                          child: Text('58mm Compact (32 columns)'),
                        ),
                      ],
                      onChanged: (v) =>
                          setState(() => selectedCols = v ?? '42'),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      activeColor: brandGreen,
                      title: const Text(
                        'Auto-Print Receipt on Order Confirm',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text(
                        'Automatically send tax invoice to printer when confirming order',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: autoPrint,
                      onChanged: (v) => setState(() => autoPrint = v),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        backgroundColor: Colors.white,
                      ),
                      icon: const Icon(Icons.receipt),
                      label: const Text('Save & Print Test Receipt'),
                      onPressed: () async {
                        await save();
                        final e = await tryPrint(
                          Order()
                            ..name = 'TEST PRINT'
                            ..inv = 'TEST-001'
                            ..mode = 'Dine in'
                            ..table = 'T-1',
                        );
                        if (c.mounted) {
                          ScaffoldMessenger.of(c).showSnackBar(
                            SnackBar(
                              content: Text(e ?? 'Test receipt sent to printer'),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Section 2: App, Company & Menu Settings
            Card(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.grey.shade300),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.storefront, color: brandGreen),
                        SizedBox(width: 8),
                        Text(
                          'Company, Invoice & Menu Settings',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: brandGreen,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: ctl['company'],
                      decoration: const InputDecoration(
                        labelText: 'Company Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: ctl['uen'],
                            decoration: const InputDecoration(
                              labelText: 'UEN',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: ctl['gstNo'],
                            decoration: const InputDecoration(
                              labelText: 'GST Reg. No.',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: ctl['defaultDelivery'],
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Default Delivery Charge (\$)',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: ctl['phone'],
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              labelText: 'Restaurant Phone',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: ctl['address'],
                      decoration: const InputDecoration(
                        labelText: 'Restaurant Address',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: ctl['menuUrl'],
                      decoration: const InputDecoration(
                        labelText: 'Live Menu Link (Google Sheet CSV)',
                        hintText: 'Leave blank to use built-in offline menu',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Loaded dishes: ${menu.length} items (GST 9% incl.)',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.sync, size: 16),
                          label: const Text('Reload Menu'),
                          onPressed: () async {
                            await save();
                            setState(() {});
                            if (c.mounted) {
                              ScaffoldMessenger.of(c).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Menu reloaded (${menu.length} items)',
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('Save All Settings'),
              onPressed: () async {
                await save();
                if (c.mounted) Navigator.pop(c);
              },
            ),
          ],
        ),
      );
}

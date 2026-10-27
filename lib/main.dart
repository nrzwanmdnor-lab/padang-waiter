import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const red = Color(0xFF9F1D14);
const gstRate = 0.09; // prices INCLUDE GST
const cats = ['Hidang', 'Set', 'Desserts', 'Drinks'];
const mon = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
String fmtDate(DateTime d) => '${d.day} ${mon[d.month - 1]} ${d.year}';
String f(double v) => v.toStringAsFixed(2);
Future<T?> go<T>(BuildContext c, Widget w) => Navigator.push<T>(c, MaterialPageRoute(builder: (_) => w));

// ---------- settings (saved on the phone) ----------
final cfg = <String, String>{
  'ip': '192.168.1.50', 'port': '9100', 'company': 'HJH MAIMUNAH RESTAURANT PTE LTD',
  'uen': '199705733D', 'gstNo': '', 'address': '', 'phone': '',
  'menuUrl': '', // paste the Google Sheet "Publish to web > CSV" link here
};
Future<void> loadCfg() async {
  final p = await SharedPreferences.getInstance();
  for (final k in cfg.keys.toList()) { cfg[k] = p.getString(k) ?? cfg[k]!; }
}
Future<void> saveCfg() async {
  final p = await SharedPreferences.getInstance();
  for (final e in cfg.entries) { await p.setString(e.key, e.value); }
}

// ---------- menu ----------
double? _d(dynamic v) => v.toString().isEmpty ? null : double.tryParse(v.toString());
class Item {
  final String id, cat, sub, name, note;
  final double? price, dM, tM, dL, tL;
  final bool available;
  Item(List r)
      : id = r[0].toString(), cat = r[1].toString(), sub = r[2].toString(), name = r[3].toString(),
        price = _d(r[4]), dM = _d(r[5]), tM = _d(r[6]), dL = _d(r[7]), tL = _d(r[8]),
        note = r[9].toString(), available = r[10].toString() == 'Yes';
  double? priceFor(String s, bool dine) => s == 'M' ? (dine ? dM : tM) : s == 'L' ? (dine ? dL : tL) : price;
  List<String> sizes(bool dine) => [if (price != null) 'Std', if ((dine ? dM : tM) != null) 'M', if ((dine ? dL : tL) != null) 'L'];
}
List<Item> menu = [];
Future<void> loadMenu() async {
  final p = await SharedPreferences.getInstance();
  String t;
  try {
    if (cfg['menuUrl']!.isEmpty) throw 'no url';
    t = (await http.get(Uri.parse(cfg['menuUrl']!)).timeout(const Duration(seconds: 6))).body;
    await p.setString('menuCache', t);
  } catch (_) {
    t = p.getString('menuCache') ?? await rootBundle.loadString('assets/menu_all.csv');
  }
  final rows = const CsvToListConverter(eol: '\n').convert(t.replaceAll('\r', ''));
  menu = rows.skip(1).where((r) => r.length >= 11).map((r) => Item(r)).where((i) => i.available).toList();
}

// ---------- order ----------
class Line { Item item; String size; int qty; Line(this.item, this.size, this.qty);
  double unit(bool d) => item.priceFor(size, d) ?? 0; }
class Order {
  String name = '', mobile = '', inv = ''; DateTime date = DateTime.now(); int pax = 2; bool dineIn = true;
  final Map<String, Line> lines = {};
  int qty(Item i, String s) => lines['${i.id}|$s']?.qty ?? 0;
  void setQty(Item i, String s, int q) { q <= 0 ? lines.remove('${i.id}|$s') : lines['${i.id}|$s'] = Line(i, s, q); }
  double get total => lines.values.fold(0.0, (a, l) => a + l.unit(dineIn) * l.qty);
  double get gst => double.parse((total * gstRate / (1 + gstRate)).toStringAsFixed(2));
  int get count => lines.values.fold(0, (a, l) => a + l.qty);
  Map<String, dynamic> toJson() => {'inv': inv, 'name': name, 'mobile': mobile, 'date': date.toIso8601String(), 'pax': pax,
    'dineIn': dineIn, 'lines': lines.values.map((l) => [l.item.id, l.size, l.qty]).toList()};
  static Order fromJson(Map<String, dynamic> j) {
    final o = Order()..inv = j['inv']..name = j['name']..mobile = j['mobile']..date = DateTime.parse(j['date'])..pax = j['pax']..dineIn = j['dineIn'];
    for (final l in j['lines']) { final it = menu.where((i) => i.id == l[0]).firstOrNull; if (it != null) o.setQty(it, l[1], l[2]); }
    return o;
  }
}
String lname(Line l) => l.item.name + (l.size == 'Std' ? '' : ' (${l.size})');
Future<String> nextInv(DateTime d) async {
  final p = await SharedPreferences.getInstance();
  final day = '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  final n = (p.getInt('cnt_$day') ?? 0) + 1; await p.setInt('cnt_$day', n);
  return 'INV-$day-${n.toString().padLeft(3, '0')}';
}
Future<void> saveOrder(Order o) async {
  final p = await SharedPreferences.getInstance();
  final l = p.getStringList('orders') ?? [];
  l.add(jsonEncode(o.toJson())); await p.setStringList('orders', l.length > 200 ? l.sublist(l.length - 200) : l);
}

// ---------- 80mm receipt (ESC/POS over LAN, port 9100) ----------
const W = 42; // use 48 if your printer prints 48 columns
String lr(String a, String b) => (a.length > W - b.length - 1 ? a.substring(0, W - b.length - 1) : a).padRight(W - b.length) + b;
String ctr(String s) => ' ' * (((W - s.length) / 2).floor().clamp(0, W)) + s;
List<(String, bool)> receiptLines(Order o) {
  final L = <(String, bool)>[(ctr(cfg['company']!), true), (ctr(cfg['address']!.isEmpty ? '[Address]' : cfg['address']!), false),
    (ctr('Tel: ${cfg['phone']!.isEmpty ? '[Phone]' : cfg['phone']}'), false), (ctr('UEN: ${cfg['uen']}'), false),
    (ctr('GST Reg: ${cfg['gstNo']!.isEmpty ? '[GST No.]' : cfg['gstNo']}'), false), ('-' * W, false),
    ('TAX INVOICE  ${o.inv}', true), ('Date: ${fmtDate(o.date)}', false), ('Name: ${o.name}', false), ('Tel: ${o.mobile}', false),
    ('${o.dineIn ? 'Dine in' : 'Takeaway'} | Pax ${o.pax}', false), ('-' * W, false)];
  for (final c in cats) {
    final ls = o.lines.values.where((l) => l.item.cat == c).toList();
    if (ls.isEmpty) continue;
    L.add((c.toUpperCase(), true));
    for (final l in ls) {
      L.add((lr('${l.qty}x ${lname(l)}', f(l.unit(o.dineIn) * l.qty)), false));
      if (l.qty > 1) L.add(('   @ ${f(l.unit(o.dineIn))}', false));
    }
  }
  L.addAll([('-' * W, false), (lr('Subtotal (excl. GST)', f(o.total - o.gst)), false), (lr('GST 9% (included)', f(o.gst)), false),
    (lr('TOTAL (SGD)', f(o.total)), true), ('-' * W, false), ('', false), (ctr('Thank you! Terima kasih!'), false)]);
  return L;
}
Future<void> printLan(Order o) async {
  final s = await Socket.connect(cfg['ip']!, int.parse(cfg['port']!), timeout: const Duration(seconds: 5));
  final b = BytesBuilder()..add([0x1b, 0x40]);
  for (final (t, bold) in receiptLines(o)) {
    b.add([0x1b, 0x45, bold ? 1 : 0]); b.add(latin1.encode(t.replaceAll(RegExp(r'[^\x00-\x7F]'), '?'))); b.add([0x0a]);
  }
  b.add([0x0a, 0x0a, 0x0a, 0x1d, 0x56, 0x42, 0x00]);
  s.add(b.takeBytes()); await s.flush(); await s.close();
}
Future<String?> tryPrint(Order o) async { try { await printLan(o); return null; } catch (e) { return e.toString(); } }

// ---------- A4 invoice PDF ----------
Future<void> shareInvoice(Order o) async {
  final d = pw.Document();
  final rows = <List<String>>[];
  for (final c in cats) { for (final l in o.lines.values.where((l) => l.item.cat == c)) {
    rows.add([lname(l), '${l.qty}', '\$${f(l.unit(o.dineIn))}', '\$${f(l.unit(o.dineIn) * l.qty)}']); } }
  d.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.all(40), build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Text(cfg['company']!, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#9F1D14'))),
    pw.Text('UEN ${cfg['uen']}   GST Reg ${cfg['gstNo']}'),
    pw.SizedBox(height: 12), pw.Text('TAX INVOICE  ${o.inv}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
    pw.Text('${fmtDate(o.date)}  |  ${o.dineIn ? 'Dine in' : 'Takeaway'}  |  Pax ${o.pax}'),
    pw.Text('Billed to: ${o.name}  ${o.mobile}'), pw.SizedBox(height: 14),
    pw.TableHelper.fromTextArray(headers: ['Item', 'Qty', 'Price', 'Amount'], data: rows,
      cellAlignments: {1: pw.Alignment.center, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight}),
    pw.SizedBox(height: 10),
    pw.Align(alignment: pw.Alignment.centerRight, child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
      pw.Text('Subtotal (excl. GST): \$${f(o.total - o.gst)}'), pw.Text('GST 9% (included): \$${f(o.gst)}'),
      pw.Text('TOTAL (SGD): \$${f(o.total)}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold))])),
  ])));
  await Printing.sharePdf(bytes: await d.save(), filename: '${o.inv}.pdf');
}

// ---------- app ----------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadCfg(); await loadMenu();
  runApp(MaterialApp(title: 'Padang Waiter', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: red),
      filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)))),
    home: const CustomerScreen()));
}

class CustomerScreen extends StatefulWidget { const CustomerScreen({super.key}); @override State<CustomerScreen> createState() => _CustomerState(); }
class _CustomerState extends State<CustomerScreen> {
  final o = Order(); final n = TextEditingController(), m = TextEditingController();
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('New Order'), actions: [
      IconButton(tooltip: 'Orders', icon: const Icon(Icons.receipt_long), onPressed: () => go(c, const HistoryScreen())),
      IconButton(tooltip: 'Settings', icon: const Icon(Icons.settings), onPressed: () => go(c, const SettingsScreen()))]),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      ListTile(contentPadding: EdgeInsets.zero, title: const Text('Date'), subtitle: Text(fmtDate(o.date)), trailing: const Icon(Icons.calendar_today),
        onTap: () async { final d = await showDatePicker(context: c, initialDate: o.date, firstDate: DateTime(2024), lastDate: DateTime(2035)); if (d != null) setState(() => o.date = d); }),
      TextField(controller: n, decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder())),
      const SizedBox(height: 14),
      Row(children: [const Text('Pax', style: TextStyle(fontSize: 16)), const Spacer(),
        IconButton.outlined(onPressed: () => setState(() => o.pax = o.pax > 1 ? o.pax - 1 : 1), icon: const Icon(Icons.remove)),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Text('${o.pax}', style: const TextStyle(fontSize: 20))),
        IconButton.outlined(onPressed: () => setState(() => o.pax++), icon: const Icon(Icons.add))]),
      const SizedBox(height: 14),
      TextField(controller: m, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Mobile', border: OutlineInputBorder())),
      const SizedBox(height: 14),
      SegmentedButton<bool>(segments: const [ButtonSegment(value: true, label: Text('Dine in')), ButtonSegment(value: false, label: Text('Takeaway'))],
        selected: {o.dineIn}, onSelectionChanged: (s) => setState(() => o.dineIn = s.first)),
      const SizedBox(height: 24),
      FilledButton(onPressed: () { o.name = n.text; o.mobile = m.text; go(c, MenuScreen(o)); }, child: const Text('Next: Choose menu')),
    ]));
}

class MenuScreen extends StatefulWidget { final Order o; const MenuScreen(this.o, {super.key}); @override State<MenuScreen> createState() => _MenuState(); }
class _MenuState extends State<MenuScreen> {
  Order get o => widget.o; final sel = <String, String>{};
  Widget list(String cat) {
    final items = menu.where((i) => i.cat == cat && i.sizes(o.dineIn).isNotEmpty).toList();
    final w = <Widget>[]; String? sub;
    for (final i in items) {
      if (i.sub != sub) { sub = i.sub; w.add(Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 4), child: Text(sub.toUpperCase(), style: const TextStyle(color: red, fontWeight: FontWeight.bold)))); }
      final sz = i.sizes(o.dineIn); final s = sz.contains(sel[i.id]) ? sel[i.id]! : sz.first;
      w.add(Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(i.name, style: const TextStyle(fontSize: 16)), Text('\$${f(i.priceFor(s, o.dineIn)!)}${i.note.isEmpty ? '' : ' · ${i.note}'}', style: const TextStyle(color: Colors.black54))])),
          IconButton.outlined(onPressed: () => setState(() => o.setQty(i, s, o.qty(i, s) - 1)), icon: const Icon(Icons.remove)),
          SizedBox(width: 30, child: Text('${o.qty(i, s)}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18))),
          IconButton.outlined(onPressed: () => setState(() => o.setQty(i, s, o.qty(i, s) + 1)), icon: const Icon(Icons.add))]),
        if (sz.length > 1) Wrap(spacing: 8, children: [for (final z in sz) ChoiceChip(label: Text('$z \$${f(i.priceFor(z, o.dineIn)!)}'), selected: z == s, onSelected: (_) => setState(() => sel[i.id] = z))]),
      ])));
    }
    return ListView(children: w);
  }
  @override Widget build(BuildContext c) => DefaultTabController(length: cats.length, child: Scaffold(
    appBar: AppBar(title: Text('${o.name} · ${o.pax} pax · ${o.dineIn ? 'Dine in' : 'Takeaway'}', style: const TextStyle(fontSize: 16)),
      bottom: TabBar(tabs: [for (final c in cats) Tab(text: c)])),
    body: TabBarView(children: [for (final c in cats) list(c)]),
    bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('${o.count} items'), Text('\$${f(o.total)}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: red))]),
      const SizedBox(height: 8), FilledButton(onPressed: o.count == 0 ? null : () => go(c, ReviewScreen(o)), child: const Text('Review order'))])))));
}

class ReviewScreen extends StatelessWidget {
  final Order o; const ReviewScreen(this.o, {super.key});
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Review Order')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: ListTile(title: Text('${o.name} · ${o.mobile}'), subtitle: Text('${fmtDate(o.date)} · ${o.pax} pax · ${o.dineIn ? 'Dine in' : 'Takeaway'}'))),
      for (final cat in cats) ...[
        if (o.lines.values.any((l) => l.item.cat == cat)) Padding(padding: const EdgeInsets.only(top: 12), child: Text(cat.toUpperCase(), style: const TextStyle(color: red, fontWeight: FontWeight.bold))),
        for (final l in o.lines.values.where((l) => l.item.cat == cat)) ListTile(dense: true, title: Text('${l.qty} × ${lname(l)}'), trailing: Text(f(l.unit(o.dineIn) * l.qty)))]]),
    bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Subtotal (excl. GST)'), Text('\$${f(o.total - o.gst)}')]),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('GST 9% (included)'), Text('\$${f(o.gst)}')]),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Total', style: TextStyle(fontWeight: FontWeight.bold)), Text('\$${f(o.total)}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: red))]),
      const SizedBox(height: 8),
      FilledButton(child: const Text('Confirm & send to kitchen'), onPressed: () async {
        o.inv = await nextInv(o.date); await saveOrder(o); final err = await tryPrint(o);
        if (c.mounted) Navigator.pushAndRemoveUntil(c, MaterialPageRoute(builder: (_) => DoneScreen(o, err)), (r) => false);
      }),
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('Edit order'))]))));
}

class DoneScreen extends StatefulWidget { final Order o; final String? err; const DoneScreen(this.o, this.err, {super.key}); @override State<DoneScreen> createState() => _DoneState(); }
class _DoneState extends State<DoneScreen> {
  String? err; @override void initState() { super.initState(); err = widget.err; }
  @override Widget build(BuildContext c) { final o = widget.o; return Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
    const Spacer(), Icon(Icons.check_circle, size: 72, color: Colors.green[800]),
    const Text('Order confirmed', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), Text(o.inv),
    const SizedBox(height: 8), Text('Total \$${f(o.total)} (GST \$${f(o.gst)} included)'),
    if (err != null) Padding(padding: const EdgeInsets.all(8), child: Text('Printer error: $err', style: const TextStyle(color: red))) else const Text('Receipt printed'),
    const Spacer(),
    FilledButton(onPressed: () async { final e = await tryPrint(o); setState(() => err = e); }, child: const Text('Print receipt (80mm)')),
    const SizedBox(height: 8), OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: () => shareInvoice(o), child: const Text('Download invoice PDF')),
    TextButton(onPressed: () => Navigator.pushAndRemoveUntil(c, MaterialPageRoute(builder: (_) => const CustomerScreen()), (r) => false), child: const Text('New order'))]))));
  }
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});
  Future<List<Order>> load() async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList('orders') ?? []).reversed.map((s) => Order.fromJson(jsonDecode(s))).toList();
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Orders')), body: FutureBuilder<List<Order>>(future: load(), builder: (_, s) {
    if (!s.hasData) return const Center(child: CircularProgressIndicator());
    return ListView(padding: const EdgeInsets.all(12), children: [for (final o in s.data!) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(o.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)), Text('\$${f(o.total)}', style: const TextStyle(fontWeight: FontWeight.bold, color: red))]),
      Text('${o.inv} · ${o.dineIn ? 'Dine in' : 'Takeaway'} · ${fmtDate(o.date)}'),
      Row(children: [TextButton(onPressed: () async { final e = await tryPrint(o); if (c.mounted && e != null) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(e))); }, child: const Text('Reprint receipt')),
        TextButton(onPressed: () => shareInvoice(o), child: const Text('Invoice PDF'))])])))]);
  }));
}

class SettingsScreen extends StatefulWidget { const SettingsScreen({super.key}); @override State<SettingsScreen> createState() => _SettingsState(); }
class _SettingsState extends State<SettingsScreen> {
  final ctl = {for (final k in cfg.keys) k: TextEditingController(text: cfg[k])};
  static const labels = {'ip': 'Printer IP address', 'port': 'Printer port', 'company': 'Company name', 'uen': 'UEN', 'gstNo': 'GST Reg. No.',
    'address': 'Address', 'phone': 'Phone', 'menuUrl': 'Menu link (Google Sheet CSV)'};
  Future<void> save() async { for (final k in ctl.keys) { cfg[k] = ctl[k]!.text.trim(); } await saveCfg(); await loadMenu(); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Settings')), body: ListView(padding: const EdgeInsets.all(20), children: [
    for (final k in ctl.keys) Padding(padding: const EdgeInsets.only(bottom: 14), child: TextField(controller: ctl[k], decoration: InputDecoration(labelText: labels[k], border: const OutlineInputBorder()))),
    const Text('GST 9% is included in menu prices.'), const SizedBox(height: 14),
    OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)), onPressed: () async { await save(); final e = await tryPrint(Order()..name = 'TEST'..inv = 'TEST'); if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(e ?? 'Test sent'))); }, child: const Text('Save & print test receipt')),
    const SizedBox(height: 10), FilledButton(onPressed: () async { await save(); if (c.mounted) Navigator.pop(c); }, child: const Text('Save settings'))]));
}

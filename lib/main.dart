import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';

// ==================== LANGUAGE ====================
bool isHebrew = true;
String tr(String he, String en) => isHebrew ? he : en;

// ==================== CONFIG ====================
const String superAdminEmail    = 'admin@gmail.com';
const String md9AdminEmail      = 'admin.md9@gmail.com';
const String yStadiumAdminEmail = 'admin.ystadium@gmail.com';

const List<Map<String, dynamic>> allStadiums = [
  {'id': 'md9_main',  'name': 'MD9 MAIN',  'type': 'Football', 'price': 300, 'location': 'נצרת', 'admin': md9AdminEmail},
  {'id': 'md9_2',     'name': 'MD9 2',     'type': 'Football', 'price': 300, 'location': 'נצרת', 'admin': md9AdminEmail},
  {'id': 'y_stadium', 'name': 'Y STADIUM', 'type': 'Football', 'price': 300, 'location': 'נצרת', 'admin': yStadiumAdminEmail},
];

final List<Map<String, String>> defaultSlots = [
  {'start': '08:00', 'end': '10:00'},
  {'start': '10:00', 'end': '12:00'},
  {'start': '12:00', 'end': '14:00'},
  {'start': '14:00', 'end': '16:00'},
  {'start': '16:00', 'end': '18:00'},
  {'start': '18:00', 'end': '20:00'},
  {'start': '20:00', 'end': '22:00'},
  {'start': '22:00', 'end': '00:00'},
];

final List<String> allStartTimes = [
  '08:00','08:30','09:00','09:30','10:00','10:30','11:00','11:30',
  '12:00','12:30','13:00','13:30','14:00','14:30','15:00','15:30',
  '16:00','16:30','17:00','17:30','18:00','18:30','19:00','19:30',
  '20:00','20:30','21:00','21:30','22:00','22:30','23:00','23:30',
];

String _addTwoHours(String start) {
  final parts = start.split(':');
  int h = int.parse(parts[0]) + 2;
  if (h >= 24) h -= 24;
  return '${h.toString().padLeft(2,'0')}:${parts[1]}';
}

String _slotLabel(Map<String, String> slot) => '${slot['start']} - ${slot['end']}';

// ==================== COLORS ====================
const Color bgColor       = Color(0xFF0D0D0D);
const Color cardColor     = Color(0xFF1A1A1A);
const Color accentGreen   = Color(0xFF00E676);
const Color textPrimary   = Colors.white;
const Color textSecondary = Color(0xFF9E9E9E);
const Color borderColor   = Color(0xFF2A2A2A);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  try {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    final token = await messaging.getToken();
    if (token != null) {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await FirebaseFirestore.instance.collection('users').doc(uid).set(
          {'fcmToken': token}, SetOptions(merge: true));
      }
    }
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('FCM: ${message.notification?.title}');
    });
  } catch (e) {
    print('FCM not supported on this platform: $e');
  }
  runApp(const StadiumApp());
}

class StadiumApp extends StatefulWidget {
  const StadiumApp({super.key});
  static _StadiumAppState? of(BuildContext context) => context.findAncestorStateOfType<_StadiumAppState>();
  @override State<StadiumApp> createState() => _StadiumAppState();
}

class _StadiumAppState extends State<StadiumApp> {
  void toggleLanguage() => setState(() => isHebrew = !isHebrew);
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'STADIUM', debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: bgColor, colorScheme: const ColorScheme.dark(primary: accentGreen, surface: cardColor)),
    home: StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const SplashScreen();
        if (snap.hasData) {
          final email = snap.data!.email ?? '';
          if (email == superAdminEmail)    return const SuperAdminScreen();
          if (email == md9AdminEmail)      return const MD9AdminScreen();
          if (email == yStadiumAdminEmail) return const SingleAdminScreen(stadiumId: 'y_stadium');
          return const HomeScreen();
        }
        return const LoginScreen();
      },
    ),
  );
}

// ==================== LANGUAGE BUTTON ====================
Widget _langButton(BuildContext context) => TextButton(
  onPressed: () => StadiumApp.of(context)?.toggleLanguage(),
  child: Text(isHebrew ? 'EN' : 'עב', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, fontSize: 13)),
);

// ==================== SPLASH ====================
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: bgColor,
    body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.sports_soccer, color: accentGreen, size: 72),
      SizedBox(height: 20),
      Text('STADIUM', style: TextStyle(color: textPrimary, fontSize: 40, fontWeight: FontWeight.w900, letterSpacing: 10)),
      SizedBox(height: 8),
      Text('BOOK YOUR GAME', style: TextStyle(color: accentGreen, fontSize: 12, letterSpacing: 4)),
      SizedBox(height: 40),
      CircularProgressIndicator(color: accentGreen, strokeWidth: 2),
    ])),
  );
}

// ==================== LOGIN ====================
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override State<LoginScreen> createState() => _LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen> {
  final _e = TextEditingController(), _p = TextEditingController();
  bool _loading = false; String _error = '';

  Future<void> _login() async {
    setState(() { _loading = true; _error = ''; });
    try { await FirebaseAuth.instance.signInWithEmailAndPassword(email: _e.text.trim(), password: _p.text.trim()); }
    on FirebaseAuthException catch (e) { setState(() { _error = e.message ?? tr('שגיאה בכניסה', 'Login failed'); }); }
    setState(() { _loading = false; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Column(children: [
        const Icon(Icons.sports_soccer, color: accentGreen, size: 64),
        const SizedBox(height: 16),
        const Text('STADIUM', style: TextStyle(color: textPrimary, fontSize: 36, fontWeight: FontWeight.w900, letterSpacing: 8)),
        const SizedBox(height: 4),
        Text(tr('הזמן את המשחק שלך', 'BOOK YOUR GAME'), style: const TextStyle(color: accentGreen, fontSize: 11, letterSpacing: 4)),
        const SizedBox(height: 8),
        _langButton(context),
        const SizedBox(height: 24),
        _tf(_e, tr('אימייל', 'Email'), Icons.email_outlined),
        const SizedBox(height: 14),
        _tf(_p, tr('סיסמה', 'Password'), Icons.lock_outline, obs: true),
        const SizedBox(height: 10),
        if (_error.isNotEmpty) _errBox(_error),
        const SizedBox(height: 24),
        SizedBox(width: double.infinity, height: 52,
          child: ElevatedButton(onPressed: _loading ? null : _login,
            style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: _loading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: bgColor, strokeWidth: 2))
                : Text(tr('כניסה', 'SIGN IN'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, letterSpacing: 2)))),
        const SizedBox(height: 16),
        TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
          child: Text(tr('אין לך חשבון? הירשם עכשיו', "Don't have an account? Register"), style: const TextStyle(color: accentGreen))),
      ]),
    ))),
  );

  Widget _tf(TextEditingController c, String hint, IconData icon, {bool obs = false}) => TextField(
    controller: c, obscureText: obs, style: const TextStyle(color: textPrimary),
    decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(color: textSecondary), prefixIcon: Icon(icon, color: textSecondary, size: 20), filled: true, fillColor: cardColor,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: accentGreen, width: 1.5))));
}

// ==================== REGISTER ====================
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override State<RegisterScreen> createState() => _RegisterScreenState();
}
class _RegisterScreenState extends State<RegisterScreen> {
  final _n = TextEditingController(), _phone = TextEditingController(), _e = TextEditingController(), _p = TextEditingController();
  bool _loading = false; String _error = '';

  Future<void> _register() async {
    if (_n.text.trim().isEmpty) { setState(() { _error = tr('הכנס שם מלא', 'Enter your full name'); }); return; }
    setState(() { _loading = true; _error = ''; });
    try {
      final c = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: _e.text.trim(), password: _p.text.trim());
      await c.user?.updateDisplayName(_n.text.trim());
      await FirebaseFirestore.instance.collection('users').doc(c.user?.uid).set({
        'name': _n.text.trim(),
        'phone': _phone.text.trim(),
        'email': _e.text.trim(),
      }, SetOptions(merge: true));
      await c.user?.reload();
      await FirebaseAuth.instance.currentUser?.reload();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(tr('ההרשמה הצליחה! ברוך הבא 🎉', 'Registration successful! Welcome 🎉')),
          backgroundColor: accentGreen,
          duration: const Duration(seconds: 3),
        ));
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } on FirebaseAuthException catch (e) { setState(() { _error = e.message ?? tr('שגיאה בהרשמה', 'Registration failed'); }); }
    setState(() { _loading = false; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor, appBar: _appBar(tr('יצירת חשבון', 'CREATE ACCOUNT'), context),
    body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Column(children: [
        const Icon(Icons.person_add_outlined, color: accentGreen, size: 56), const SizedBox(height: 24),
        _tf(_n, tr('שם מלא', 'Full Name'), Icons.person_outline),
        const SizedBox(height: 14),
        _tf(_phone, tr('מספר טלפון', 'Phone Number'), Icons.phone_outlined, type: TextInputType.phone),
        const SizedBox(height: 14),
        _tf(_e, tr('אימייל', 'Email'), Icons.email_outlined),
        const SizedBox(height: 14),
        _tf(_p, tr('סיסמה (מינימום 6 תווים)', 'Password (min 6 chars)'), Icons.lock_outline, obs: true),
        const SizedBox(height: 10),
        if (_error.isNotEmpty) _errBox(_error),
        const SizedBox(height: 24),
        SizedBox(width: double.infinity, height: 52,
          child: ElevatedButton(onPressed: _loading ? null : _register,
            style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: _loading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: bgColor, strokeWidth: 2))
                : Text(tr('הירשם', 'CREATE ACCOUNT'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, letterSpacing: 2)))),
      ]),
    ))),
  );

  Widget _tf(TextEditingController c, String hint, IconData icon, {bool obs = false, TextInputType? type}) => TextField(
    controller: c, obscureText: obs, keyboardType: type, style: const TextStyle(color: textPrimary),
    decoration: InputDecoration(hintText: hint, hintStyle: const TextStyle(color: textSecondary), prefixIcon: Icon(icon, color: textSecondary, size: 20), filled: true, fillColor: cardColor,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: accentGreen, width: 1.5))));
}

// ==================== SUPER ADMIN ====================
class SuperAdminScreen extends StatelessWidget {
  const SuperAdminScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    appBar: AppBar(backgroundColor: bgColor,
      title: Row(children: [const Icon(Icons.shield_outlined, color: Colors.amber, size: 20), const SizedBox(width: 8), Text(tr('סופר אדמין', 'SUPER ADMIN'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, letterSpacing: 2))]),
      actions: [_langButton(context), IconButton(icon: const Icon(Icons.logout, color: textSecondary), onPressed: () => FirebaseAuth.instance.signOut())]),
    body: StreamBuilder(
      stream: FirebaseFirestore.instance.collection('bookings').snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
        final docs = snap.data!.docs;
        int totalP = 0; Map<String, int> sCount = {}, sRev = {};
        for (final d in docs) {
          final b = d.data();
          totalP += ((b['players'] as List?) ?? []).length;
          final s = b['stadiumName'] as String? ?? '';
          sCount[s] = (sCount[s] ?? 0) + 1;
          final pr = int.tryParse((b['price'] as String? ?? '0').replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
          sRev[s] = (sRev[s] ?? 0) + pr;
        }
        return ListView(padding: const EdgeInsets.all(16), children: [
          _secTitle(tr('סקירה כללית', 'OVERVIEW')), const SizedBox(height: 12),
          Row(children: [Expanded(child: _statCard(tr('הזמנות', 'BOOKINGS'), '${docs.length}', Icons.calendar_month, accentGreen)), const SizedBox(width: 12), Expanded(child: _statCard(tr('שחקנים', 'PLAYERS'), '$totalP', Icons.people_outline, Colors.blue))]),
          const SizedBox(height: 12),
          Row(children: [Expanded(child: _statCard(tr('מגרשים', 'STADIUMS'), '${allStadiums.length}', Icons.sports_soccer, Colors.orange)), const SizedBox(width: 12), Expanded(child: _statCard(tr('הכנסות', 'REVENUE'), '₪${sRev.values.fold(0, (a, b) => a + b)}', Icons.attach_money, Colors.amber))]),
          const SizedBox(height: 24), _secTitle(tr('ביצועי מגרשים', 'STADIUMS PERFORMANCE')), const SizedBox(height: 12),
          ...allStadiums.map((s) => _perfCard(s['name'], sCount[s['name']] ?? 0, sRev[s['name']] ?? 0)),
          const SizedBox(height: 24), _secTitle(tr('כל ההזמנות', 'ALL BOOKINGS')), const SizedBox(height: 12),
          ...docs.map((d) => _bookCard(d.data())),
        ]);
      },
    ),
  );
  Widget _perfCard(String name, int b, int r) => Container(
    margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
    child: Row(children: [Container(width: 44, height: 44, decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.sports_soccer, color: accentGreen, size: 22)), const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold, fontSize: 14)), Text('$b ${tr('הזמנות', 'bookings')}', style: const TextStyle(color: textSecondary, fontSize: 12))])),
      Text('₪$r', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold, fontSize: 16))]),
  );
}

// ==================== MD9 ADMIN ====================
class MD9AdminScreen extends StatefulWidget {
  const MD9AdminScreen({super.key});
  @override State<MD9AdminScreen> createState() => _MD9AdminScreenState();
}
class _MD9AdminScreenState extends State<MD9AdminScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;
  @override void initState() { super.initState(); _tab = TabController(length: 3, vsync: this); }
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: bgColor,
    appBar: AppBar(backgroundColor: bgColor,
      title: Row(children: [const Icon(Icons.shield_outlined, color: Colors.amber, size: 20), const SizedBox(width: 8), Text(tr('אדמין MD9', 'MD9 ADMIN'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, letterSpacing: 2))]),
      actions: [_langButton(context), IconButton(icon: const Icon(Icons.logout, color: textSecondary), onPressed: () => FirebaseAuth.instance.signOut())],
      bottom: TabBar(controller: _tab, indicatorColor: accentGreen, labelColor: accentGreen, unselectedLabelColor: textSecondary,
        tabs: [Tab(text: tr('השוואה', 'OVERVIEW')), const Tab(text: 'MD9 MAIN'), const Tab(text: 'MD9 2')])),
    body: TabBarView(controller: _tab, children: const [
      MD9OverviewTab(),
      AdminStadiumTab(stadiumName: 'MD9 MAIN', stadiumId: 'md9_main', price: 80),
      AdminStadiumTab(stadiumName: 'MD9 2',    stadiumId: 'md9_2',    price: 60),
    ]),
  );
}

class MD9OverviewTab extends StatelessWidget {
  const MD9OverviewTab({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder(
    stream: FirebaseFirestore.instance.collection('bookings').where('stadiumName', whereIn: ['MD9 MAIN', 'MD9 2']).snapshots(),
    builder: (context, snap) {
      if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
      final docs = snap.data!.docs;
      int mB=0,m2B=0,mP=0,m2P=0,mR=0,m2R=0;
      for (final d in docs) {
        final b = d.data(); final p = ((b['players'] as List?) ?? []).length;
        if (b['stadiumName'] == 'MD9 MAIN') { mB++; mP+=p; mR+=80; } else { m2B++; m2P+=p; m2R+=60; }
      }
      return ListView(padding: const EdgeInsets.all(16), children: [
        _secTitle(tr('השוואה', 'COMPARISON')), const SizedBox(height: 16),
        _cmpRow(tr('הזמנות', 'BOOKINGS'), mB, m2B), const SizedBox(height: 10),
        _cmpRow(tr('שחקנים', 'PLAYERS'), mP, m2P), const SizedBox(height: 10),
        _cmpRow(tr('הכנסות ₪', 'REVENUE ₪'), mR, m2R), const SizedBox(height: 24),
        _secTitle(tr('כל ההזמנות', 'ALL BOOKINGS')), const SizedBox(height: 12),
        ...docs.map((d) => _bookCard(d.data())),
      ]);
    },
  );
  Widget _cmpRow(String label, int v1, int v2) {
    final total = v1+v2; final pct = total==0?0.5:v1/total; final w = v1>v2?1:(v2>v1?2:0);
    return Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: textSecondary, fontSize: 11, letterSpacing: 2)), const SizedBox(height: 10),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Text('MD9 MAIN', style: TextStyle(color: w==1?accentGreen:textPrimary, fontWeight: FontWeight.bold, fontSize: 13)), if(w==1)...[const SizedBox(width:4),const Icon(Icons.emoji_events,color:Colors.amber,size:14)]]),
            Text('$v1', style: TextStyle(color: w==1?accentGreen:textSecondary, fontSize: 22, fontWeight: FontWeight.w900))
          ])),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [if(w==2)...[const Icon(Icons.emoji_events,color:Colors.amber,size:14),const SizedBox(width:4)],Text('MD9 2',style:TextStyle(color:w==2?accentGreen:textPrimary,fontWeight:FontWeight.bold,fontSize:13))]),
            Text('$v2', style: TextStyle(color: w==2?accentGreen:textSecondary, fontSize: 22, fontWeight: FontWeight.w900))
          ])),
        ]),
        const SizedBox(height: 10),
        ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: pct.toDouble(), backgroundColor: Colors.blue.withValues(alpha: 0.4), valueColor: const AlwaysStoppedAnimation<Color>(accentGreen), minHeight: 6)),
      ]));
  }
}

// ==================== ADMIN STADIUM TAB ====================
class AdminStadiumTab extends StatefulWidget {
  final String stadiumName, stadiumId;
  final int price;
  const AdminStadiumTab({super.key, required this.stadiumName, required this.stadiumId, required this.price});
  @override State<AdminStadiumTab> createState() => _AdminStadiumTabState();
}
class _AdminStadiumTabState extends State<AdminStadiumTab> {
  int _selDay = 0;
  late List<Map<String, String>> _days;
  @override void initState() { super.initState(); _buildDays(); }

  void _buildDays() {
    final now = DateTime.now();
    final names = isHebrew ? ['אח','ב','ג','ד','ה','ו','ש'] : ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    _days = List.generate(14, (i) {
      final d = now.add(Duration(days: i));
      return {'name': names[d.weekday%7], 'date': '${d.day}/${d.month}', 'full': '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}' };
    });
  }

  String get _docId => '${widget.stadiumId}_${_days[_selDay]['full']}';

  List<Map<String, String>> _getDaySlots(Map<String, dynamic>? schedData) {
    if (schedData != null && schedData['slots'] != null) {
      final raw = schedData['slots'] as List;
      return raw.map((s) => {'start': s['start'] as String, 'end': s['end'] as String}).toList();
    }
    return List.from(defaultSlots);
  }

  Future<void> _editSlot(Map<String, String> slot, int index, Set<String> bookedLabels, List<Map<String,String>> currentSlots) async {
    final label = _slotLabel(slot);
    if (bookedLabels.contains(label)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('לא ניתן לערוך שעה תפוסה', 'Cannot edit a booked slot')), backgroundColor: Colors.red));
      return;
    }
    String selectedStart = slot['start']!;
    await showDialog(context: context, builder: (_) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        backgroundColor: cardColor,
        title: Text(tr('עריכת שעה', 'Edit Slot'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('שנה שעת התחלה:', 'Change start time:'), style: const TextStyle(color: textSecondary, fontSize: 13)),
          const SizedBox(height: 12),
          DropdownButton<String>(value: selectedStart, dropdownColor: cardColor, isExpanded: true,
            items: allStartTimes.map((t) => DropdownMenuItem(value: t, child: Text(t, style: const TextStyle(color: textPrimary)))).toList(),
            onChanged: (v) => setS(() => selectedStart = v!)),
          const SizedBox(height: 8),
          Text('${tr('סיום', 'End')}: ${_addTwoHours(selectedStart)}', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('ביטול', 'Cancel'), style: const TextStyle(color: textSecondary))),
          ElevatedButton(
            onPressed: () async {
              final newSlots = List<Map<String,String>>.from(currentSlots);
              newSlots[index] = {'start': selectedStart, 'end': _addTwoHours(selectedStart)};
              await FirebaseFirestore.instance.collection('admin_schedule').doc(_docId).set(
                {'slots': newSlots.map((s) => {'start': s['start'], 'end': s['end']}).toList()}, SetOptions(merge: true));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor),
            child: Text(tr('שמור', 'SAVE'), style: const TextStyle(fontWeight: FontWeight.w900))),
        ],
      ),
    ));
  }

  Future<void> _toggleBlock(Map<String,String> slot, bool isBlocked, Set<String> bookedLabels) async {
    final label = _slotLabel(slot);
    if (bookedLabels.contains(label)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('לא ניתן לחסום שעה תפוסה', 'Cannot block a booked slot')), backgroundColor: Colors.red));
      return;
    }
    final ref = FirebaseFirestore.instance.collection('admin_schedule').doc(_docId);
    if (isBlocked) {
      await ref.set({'blocked': FieldValue.arrayRemove([label])}, SetOptions(merge: true));
    } else {
      await ref.set({'blocked': FieldValue.arrayUnion([label])}, SetOptions(merge: true));
    }
  }

  Future<void> _resetDay() async => FirebaseFirestore.instance.collection('admin_schedule').doc(_docId).delete();

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      SizedBox(height: 80, child: ListView.builder(
        scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: _days.length,
        itemBuilder: (ctx, i) {
          final isSel = _selDay == i;
          return GestureDetector(
            onTap: () => setState(() => _selDay = i),
            child: Container(
              margin: const EdgeInsets.only(right: 8), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(color: isSel ? accentGreen : cardColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: isSel ? accentGreen : i==0 ? accentGreen.withValues(alpha: 0.4) : borderColor)),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(_days[i]['name']!, style: TextStyle(color: isSel?bgColor:textSecondary, fontWeight: FontWeight.bold, fontSize: 11)),
                Text(_days[i]['date']!, style: TextStyle(color: isSel?bgColor.withValues(alpha: 0.7):const Color(0xFF555555), fontSize: 10)),
                if (i==0) Text(tr('היום', 'TODAY'), style: TextStyle(color: isSel?bgColor:accentGreen, fontSize: 8, fontWeight: FontWeight.w900)),
              ]),
            ),
          );
        },
      )),
      Expanded(child: StreamBuilder(
        stream: FirebaseFirestore.instance.collection('bookings').where('stadiumName', isEqualTo: widget.stadiumName).where('date', isEqualTo: _days[_selDay]['date']).snapshots(),
        builder: (ctx, bookSnap) => StreamBuilder(
          stream: FirebaseFirestore.instance.collection('admin_schedule').doc(_docId).snapshots(),
          builder: (ctx, schedSnap) {
            final bookedDocs = bookSnap.data?.docs ?? [];
            final bookedLabels = bookedDocs.map((d) => d.data()['time'] as String).toSet();
            final schedData = schedSnap.hasData && schedSnap.data!.exists ? schedSnap.data!.data() : null;
            final blockedLabels = schedData != null ? Set<String>.from(schedData['blocked'] ?? []) : <String>{};
            final slots = _getDaySlots(schedData);
            final totalBookings = bookedDocs.length;
            final totalPlayers = bookedDocs.fold(0, (s, d) => s + ((d.data()['players'] as List?) ?? []).length);
            final isToday = _selDay == 0;
            final now = DateTime.now();

            return ListView(padding: const EdgeInsets.all(12), children: [
              Row(children: [
                Expanded(child: _statCard(tr('הזמנות','BOOKINGS'), '$totalBookings', Icons.calendar_month, accentGreen)),
                const SizedBox(width: 8),
                Expanded(child: _statCard(tr('שחקנים','PLAYERS'), '$totalPlayers', Icons.people_outline, Colors.blue)),
                const SizedBox(width: 8),
                Expanded(child: _statCard(tr('הכנסות','REVENUE'), '₪${totalBookings * widget.price}', Icons.attach_money, Colors.amber)),
              ]),
              const SizedBox(height: 16),
              Row(children: [
                _secTitle('${tr('לוח זמנים', 'SCHEDULE')} — ${_days[_selDay]['date']}'),
                const Spacer(),
                if (schedData != null && schedData['slots'] != null)
                  TextButton(onPressed: _resetDay, child: Text(tr('איפוס', 'RESET'), style: const TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.w900))),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                _dot(accentGreen, tr('פנוי','Free')), const SizedBox(width: 12),
                _dot(Colors.orange, tr('תפוס','Booked')), const SizedBox(width: 12),
                _dot(Colors.red, tr('חסום','Blocked')),
              ]),
              const SizedBox(height: 12),
              ...slots.map((slot) {
                final label = _slotLabel(slot);
                final isBooked  = bookedLabels.contains(label);
                final isBlocked = blockedLabels.contains(label);
                if (isToday) {
                  final h = int.parse(slot['start']!.split(':')[0]);
                  if (h < now.hour) return const SizedBox.shrink();
                }
                Color bg, border, textClr;
                if (isBooked)       { bg = Colors.orange.withValues(alpha: 0.1); border = Colors.orange.withValues(alpha: 0.5); textClr = Colors.orange; }
                else if (isBlocked) { bg = Colors.red.withValues(alpha: 0.08);   border = Colors.red.withValues(alpha: 0.4);    textClr = Colors.red; }
                else                { bg = cardColor; border = accentGreen.withValues(alpha: 0.3); textClr = textPrimary; }
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12), border: Border.all(color: border)),
                  child: Row(children: [
                    SizedBox(width: 120, child: Text(label, style: TextStyle(color: textClr, fontWeight: FontWeight.w900, fontSize: 15))),
                    if (isBooked)  _badge(tr('תפוס','BOOKED'), Colors.orange)
                    else if (isBlocked) _badge(tr('חסום','BLOCKED'), Colors.red)
                    else _badge(tr('פנוי','FREE'), accentGreen),
                    const Spacer(),
                    if (!isBooked) ...[
                      IconButton(icon: const Icon(Icons.edit_outlined, size: 18), color: textSecondary, onPressed: () => _editSlot(slot, slots.indexOf(slot), bookedLabels, slots)),
                      IconButton(icon: Icon(isBlocked ? Icons.lock_open_outlined : Icons.block_outlined, size: 18), color: isBlocked ? accentGreen : Colors.red, onPressed: () => _toggleBlock(slot, isBlocked, bookedLabels)),
                    ] else ...[
                      Builder(builder: (ctx) {
                        try {
                          final match = bookedDocs.where((d) => d.data()['time'] == label);
                          final count = match.isNotEmpty ? ((match.first.data()['players'] as List?) ?? []).length : 0;
                          return Text('$count/18 ${tr('שחקנים','players')}', style: const TextStyle(color: textSecondary, fontSize: 12));
                        } catch (_) { return Text(tr('תפוס','booked'), style: const TextStyle(color: textSecondary, fontSize: 12)); }
                      }),
                    ],
                  ]),
                );
              }),
              const SizedBox(height: 8),
              Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.blue.withValues(alpha: 0.2))),
                child: Row(children: [const Icon(Icons.info_outline, color: Colors.blue, size: 14), const SizedBox(width: 8), Expanded(child: Text('✏️ ${tr('ערוך שעה','Edit')}  🚫 ${tr('חסום/בטל','Block/Unblock')}  ${tr('שעה תפוסה לא ניתן לשנות','Booked slots cannot be changed.')}', style: const TextStyle(color: Colors.blue, fontSize: 11)))])),
              if (bookedDocs.isNotEmpty) ...[
                const SizedBox(height: 20),
                _secTitle(tr('הזמנות היום','BOOKINGS FOR THIS DAY')), const SizedBox(height: 10),
                ...bookedDocs.map((d) => _bookCard(d.data())),
              ],
            ]);
          },
        ),
      )),
    ]);
  }
  Widget _dot(Color c, String l) => Row(children: [Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)), const SizedBox(width: 3), Text(l, style: const TextStyle(color: textSecondary, fontSize: 10))]);
  Widget _badge(String t, Color c) => Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withValues(alpha: 0.4))), child: Text(t, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w900)));
}

// ==================== SINGLE ADMIN ====================
class SingleAdminScreen extends StatelessWidget {
  final String stadiumId;
  const SingleAdminScreen({super.key, required this.stadiumId});
  @override
  Widget build(BuildContext context) {
    final s = allStadiums.firstWhere((x) => x['id'] == stadiumId);
    return Scaffold(backgroundColor: bgColor,
      appBar: AppBar(backgroundColor: bgColor,
        title: Row(children: [const Icon(Icons.shield_outlined, color: Colors.amber, size: 20), const SizedBox(width: 8), Text('${s['name']} ${tr('אדמין','ADMIN')}', style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900))]),
        actions: [_langButton(context), IconButton(icon: const Icon(Icons.logout, color: textSecondary), onPressed: () => FirebaseAuth.instance.signOut())]),
      body: AdminStadiumTab(stadiumName: s['name'], stadiumId: s['id'], price: s['price']),
    );
  }
}

// ==================== HOME ====================
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
          backgroundColor: cardColor,
          title: Text(tr('יציאה מהאפליקציה', 'Exit App'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
          content: Text(tr('האם אתה בטוח שרוצה לצאת?', 'Are you sure you want to exit?'), style: const TextStyle(color: textSecondary)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('ביטול','Cancel'), style: const TextStyle(color: textSecondary))),
            ElevatedButton(onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor),
              child: Text(tr('יציאה','Exit'), style: const TextStyle(fontWeight: FontWeight.w900))),
          ],
        ));
        if (ok == true) {
          // ignore: use_build_context_synchronously
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(backgroundColor: bgColor,
        appBar: AppBar(backgroundColor: bgColor, elevation: 0,
          title: const Text('STADIUM', style: TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: 22, letterSpacing: 6)), centerTitle: true,
          actions: [
            StreamBuilder(
              stream: FirebaseFirestore.instance.collection('notifications').where('userId', isEqualTo: user?.uid).where('read', isEqualTo: false).snapshots(),
              builder: (context, snap) {
                final count = snap.data?.docs.length ?? 0;
                return Stack(children: [
                  IconButton(icon: const Icon(Icons.notifications_outlined, color: textSecondary),
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsScreen()))),
                  if (count > 0) Positioned(right: 8, top: 8, child: Container(width: 16, height: 16,
                    decoration: const BoxDecoration(color: accentGreen, shape: BoxShape.circle),
                    child: Center(child: Text('$count', style: const TextStyle(color: bgColor, fontSize: 10, fontWeight: FontWeight.w900))))),
                ]);
              },
            ),
            _langButton(context),
            IconButton(icon: const Icon(Icons.person_outline, color: textSecondary), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()))),
            IconButton(icon: const Icon(Icons.calendar_month_outlined, color: textSecondary), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBookingsScreen()))),
          ]),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Container(padding: const EdgeInsets.all(20), margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [accentGreen.withValues(alpha: 0.2), accentGreen.withValues(alpha: 0.05)]), borderRadius: BorderRadius.circular(16), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
            child: Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${tr('היי','Hey')}, ${user?.displayName ?? tr('שחקן','Player')} 👋', style: const TextStyle(color: textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(tr('מוכן לשחק? הזמן את המגרש שלך', 'Ready to play? Book your court.'), style: const TextStyle(color: textSecondary, fontSize: 13)),
            ])), const Icon(Icons.sports_soccer, color: accentGreen, size: 44)])),
          GestureDetector(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const JoinByCodeScreen())),
            child: Container(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16), margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.blue.withValues(alpha: 0.3))),
              child: Row(children: [const Icon(Icons.group_add_outlined, color: Colors.blue, size: 20), const SizedBox(width: 12), Text(tr('יש לך קוד הזמנה? הצטרף למשחק', 'Have a booking code? Join the game'), style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)), const Spacer(), const Icon(Icons.arrow_forward_ios, color: Colors.blue, size: 12)]))),
          _secTitle(tr('מגרשים', 'STADIUMS')), const SizedBox(height: 14),
          ...allStadiums.map((s) => StadiumCard(stadium: s)),
        ]),
      ),
    );
  }
}

// ==================== STADIUM CARD ====================
class StadiumCard extends StatelessWidget {
  final Map<String, dynamic> stadium;
  const StadiumCard({super.key, required this.stadium});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BookingScreen(stadium: stadium))),
    child: Container(margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(16), border: Border.all(color: borderColor)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 130, decoration: BoxDecoration(borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [accentGreen.withValues(alpha: 0.25), const Color(0xFF0D0D0D)])),
          child: Stack(children: [
            Center(child: Icon(stadium['type']=='Tennis'?Icons.sports_tennis:Icons.sports_soccer, color: accentGreen.withValues(alpha: 0.6), size: 64)),
            Positioned(top: 12, left: 12, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: bgColor.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(8), border: Border.all(color: accentGreen.withValues(alpha: 0.5))), child: Text(stadium['type'], style: const TextStyle(color: accentGreen, fontSize: 11, fontWeight: FontWeight.bold)))),
            Positioned(top: 12, right: 12, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), decoration: BoxDecoration(color: accentGreen, borderRadius: BorderRadius.circular(8)), child: Text('₪${stadium['price']}/2hr', style: const TextStyle(color: bgColor, fontSize: 11, fontWeight: FontWeight.w900)))),
          ])),
        Padding(padding: const EdgeInsets.all(14), child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(stadium['name'], style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: 17, letterSpacing: 1)),
            const SizedBox(height: 4),
            Row(children: [const Icon(Icons.location_on_outlined, color: textSecondary, size: 14), const SizedBox(width: 2), Text(stadium['location'], style: const TextStyle(color: textSecondary, fontSize: 13))]),
          ])),
          ElevatedButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BookingScreen(stadium: stadium))),
            style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
            child: Text(tr('הזמן','BOOK'), style: const TextStyle(fontWeight: FontWeight.w900))),
        ])),
      ])),
  );
}

// ==================== BOOKING SCREEN ====================
class BookingScreen extends StatefulWidget {
  final Map<String, dynamic> stadium;
  const BookingScreen({super.key, required this.stadium});
  @override State<BookingScreen> createState() => _BookingScreenState();
}
class _BookingScreenState extends State<BookingScreen> {
  int _selDay = 0; int? _selSlot; bool _booking = false;
  late List<Map<String, String>> _days;
  Set<String> _bookedSlots = {}, _blockedSlots = {};
  List<Map<String, String>> _slots = List.from(defaultSlots);

  @override void initState() { super.initState(); _buildDays(); _loadData(); }

  void _buildDays() {
    final now = DateTime.now();
    final names = isHebrew ? ['אח','ב','ג','ד','ה','ו','ש'] : ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
    _days = List.generate(14, (i) {
      final d = now.add(Duration(days: i));
      return {'name': names[d.weekday%7], 'date': '${d.day}/${d.month}', 'full': '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}' };
    });
  }

  String get _docId => '${widget.stadium['id']}_${_days[_selDay]['full']}';

  Future<void> _loadData() async {
    final date = _days[_selDay]['date']!;
    final bSnap = await FirebaseFirestore.instance.collection('bookings').where('stadiumName', isEqualTo: widget.stadium['name']).where('date', isEqualTo: date).get();
    final sSnap = await FirebaseFirestore.instance.collection('admin_schedule').doc(_docId).get();
    setState(() {
      _bookedSlots = bSnap.docs.map((d) => d.data()['time'] as String).toSet();
      if (sSnap.exists) {
        _blockedSlots = Set<String>.from(sSnap.data()?['blocked'] ?? []);
        if (sSnap.data()?['slots'] != null) {
          final raw = sSnap.data()!['slots'] as List;
          _slots = raw.map((s) => {'start': s['start'] as String, 'end': s['end'] as String}).toList();
        } else { _slots = List.from(defaultSlots); }
      } else { _blockedSlots = {}; _slots = List.from(defaultSlots); }
    });
  }

  String _status(String label) {
    if (_blockedSlots.contains(label)) return 'blocked';
    if (_bookedSlots.contains(label))  return 'booked';
    return 'available';
  }

  List<Map<String,String>> get _visibleSlots {
    final now = DateTime.now();
    return _slots.where((s) {
      if (_selDay != 0) return true;
      final h = int.parse(s['start']!.split(':')[0]);
      return h > now.hour;
    }).toList();
  }

  Future<void> _book() async {
    if (_selSlot == null) return;
    setState(() { _booking = true; });
    final user = FirebaseAuth.instance.currentUser;
    final myName = user?.displayName ?? user?.email ?? '';
    final slot = _visibleSlots[_selSlot!];
    final label = _slotLabel(slot);
    final date = _days[_selDay]['date']!;

    final existing = await FirebaseFirestore.instance.collection('bookings').where('stadiumName', isEqualTo: widget.stadium['name']).where('date', isEqualTo: date).where('time', isEqualTo: label).get();
    if (existing.docs.isNotEmpty) {
      setState(() { _booking = false; });
      if (context.mounted) _dlg(tr('שעה תפוסה ❌','Slot Taken ❌'), tr('$label כבר תפוס. בחר שעה אחרת.','$label is already booked.'), err: true);
      return;
    }

    final code = (1000 + DateTime.now().millisecondsSinceEpoch % 9000).toString();
    await FirebaseFirestore.instance.collection('bookings').add({
      'userId': user?.uid, 'userName': myName,
      'stadiumName': widget.stadium['name'], 'stadiumId': widget.stadium['id'],
      'day': _days[_selDay]['name'], 'date': date, 'time': label,
      'price': '₪${widget.stadium['price']}/2hr',
      'bookingCode': code, 'players': [myName],
      'createdAt': DateTime.now().toIso8601String(),
    });
    await FirebaseFirestore.instance.collection('notifications').add({
      'userId': user?.uid,
      'title': tr('ההזמנה אושרה ✅','Booking Confirmed ✅'),
      'body': tr('ההזמנה שלך ב-${widget.stadium['name']} ב-${_days[_selDay]['name']} $date • $label', 'Your booking at ${widget.stadium['name']} on ${_days[_selDay]['name']} $date • $label'),
      'read': false, 'createdAt': DateTime.now().toIso8601String(),
    });

    await _loadData();
    setState(() { _booking = false; _selSlot = null; });
    if (!mounted) return;
    showDialog(context: context, builder: (dialogContext) => AlertDialog(
      backgroundColor: cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(tr('ההזמנה אושרה! 🎉','Booking Confirmed! 🎉'), style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
          child: Column(children: [Text(widget.stadium['name'], style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)), Text('${_days[_selDay]['name']} $date • $label', style: const TextStyle(color: textSecondary, fontSize: 13))])),
        const SizedBox(height: 20),
        Text(tr('שלח קוד לחברים','SHARE CODE WITH FRIENDS'), style: const TextStyle(color: textSecondary, fontSize: 11, letterSpacing: 2)),
        const SizedBox(height: 8),
        // קוד עם כפתור העתקה
        GestureDetector(
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (dialogContext.mounted) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(
                content: Text(tr('הקוד הועתק! 📋', 'Code copied! 📋')),
                backgroundColor: accentGreen,
                duration: const Duration(seconds: 2),
              ));
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(code, style: const TextStyle(color: accentGreen, fontSize: 48, fontWeight: FontWeight.w900, letterSpacing: 12)),
              const SizedBox(width: 12),
              const Icon(Icons.copy_outlined, color: accentGreen, size: 22),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Text(tr('לחץ על הקוד להעתקה', 'Tap code to copy'), style: const TextStyle(color: textSecondary, fontSize: 11)),
      ]),
      actions: [ElevatedButton(onPressed: () => Navigator.pop(dialogContext), style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), child: Text(tr('הבנתי','GOT IT'), style: const TextStyle(fontWeight: FontWeight.w900)))],
    ));
  }

  void _dlg(String t, String msg, {bool err = false}) => showDialog(context: context, builder: (_) => AlertDialog(
    backgroundColor: cardColor, title: Text(t, style: TextStyle(color: err?Colors.red:accentGreen, fontWeight: FontWeight.bold)),
    content: Text(msg, style: const TextStyle(color: textSecondary)),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('אישור','OK'), style: const TextStyle(color: accentGreen)))],
  ));

  @override
  Widget build(BuildContext context) {
    final visible = _visibleSlots;
    return Scaffold(backgroundColor: bgColor, appBar: _appBar(widget.stadium['name'], context),
      body: Column(children: [
        SizedBox(height: 80, child: ListView.builder(
          scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          itemCount: _days.length,
          itemBuilder: (ctx, i) {
            final isSel = _selDay == i;
            return GestureDetector(onTap: () { setState(() { _selDay = i; _selSlot = null; }); _loadData(); },
              child: Container(margin: const EdgeInsets.only(right: 8), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: isSel?accentGreen:cardColor, borderRadius: BorderRadius.circular(10), border: Border.all(color: isSel?accentGreen:i==0?accentGreen.withValues(alpha: 0.4):borderColor)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(_days[i]['name']!, style: TextStyle(color: isSel?bgColor:textSecondary, fontWeight: FontWeight.bold, fontSize: 11)),
                  Text(_days[i]['date']!, style: TextStyle(color: isSel?bgColor.withValues(alpha: 0.7):const Color(0xFF555555), fontSize: 10)),
                  if (i==0) Text(tr('היום','TODAY'), style: TextStyle(color: isSel?bgColor:accentGreen, fontSize: 8, fontWeight: FontWeight.w900)),
                ])));
          },
        )),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [_lgnd(accentGreen, tr('פנוי','Available')), const SizedBox(width:14), _lgnd(Colors.orange, tr('תפוס','Booked')), const SizedBox(width:14), _lgnd(Colors.red, tr('חסום','Closed'))])),
        Padding(padding: const EdgeInsets.fromLTRB(16,10,16,6), child: _secTitle(tr('בחר שעה — 2 שעות','SELECT TIME — 2 HOURS'))),
        if (visible.isEmpty)
          Expanded(child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.schedule, color: textSecondary, size: 48), const SizedBox(height: 12),
            Text(tr('אין שעות פנויות היום','No more slots today'), style: const TextStyle(color: textSecondary)),
            const SizedBox(height: 8),
            TextButton(onPressed: () { setState(() { _selDay=1; _selSlot=null; }); _loadData(); }, child: Text(tr('צפה במחר ←','View tomorrow →'), style: const TextStyle(color: accentGreen))),
          ])))
        else
          Expanded(child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 3.0, crossAxisSpacing: 10, mainAxisSpacing: 10),
            itemCount: visible.length,
            itemBuilder: (ctx, i) {
              final slot = visible[i]; final label = _slotLabel(slot);
              final st = _status(label); final isSel = _selSlot == i;
              Color bg, border, tc;
              if (isSel)              { bg=accentGreen; border=accentGreen; tc=bgColor; }
              else if (st=='booked')  { bg=Colors.orange.withValues(alpha: 0.1); border=Colors.orange.withValues(alpha: 0.4); tc=Colors.orange; }
              else if (st=='blocked') { bg=Colors.red.withValues(alpha: 0.08); border=Colors.red.withValues(alpha: 0.3); tc=Colors.red.withValues(alpha: 0.7); }
              else                    { bg=cardColor; border=borderColor; tc=textPrimary; }
              return GestureDetector(
                onTap: st=='available' ? () => setState(() => _selSlot=i) : null,
                child: Container(decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: border)),
                  child: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(label, textAlign: TextAlign.center, style: TextStyle(color: tc, fontSize: 12, fontWeight: isSel?FontWeight.w900:FontWeight.normal)),
                    if (st == 'booked')  Text(tr('תפוס','BOOKED'), style: TextStyle(color: tc, fontSize: 9, fontWeight: FontWeight.w900)),
                    if (st == 'blocked') Text(tr('חסום','CLOSED'), style: TextStyle(color: tc, fontSize: 9, fontWeight: FontWeight.w900)),
                  ]))));
            },
          )),
        Padding(padding: const EdgeInsets.all(16), child: SizedBox(width: double.infinity, height: 54,
          child: ElevatedButton(onPressed: (_selSlot!=null&&!_booking)?_book:null,
            style: ElevatedButton.styleFrom(backgroundColor: accentGreen, disabledBackgroundColor: const Color(0xFF1A1A1A), foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: _booking ? const SizedBox(width:20,height:20,child:CircularProgressIndicator(color:bgColor,strokeWidth:2)) : Text(tr('אשר הזמנה (2 שעות)','CONFIRM BOOKING (2 HRS)'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14))))),
      ]),
    );
  }
  Widget _lgnd(Color c, String l) => Row(children: [Container(width:10,height:10,decoration:BoxDecoration(color:c,borderRadius:BorderRadius.circular(2))),const SizedBox(width:4),Text(l,style:const TextStyle(color:textSecondary,fontSize:11))]);
}

// ==================== JOIN BY CODE ====================
class JoinByCodeScreen extends StatefulWidget {
  const JoinByCodeScreen({super.key});
  @override State<JoinByCodeScreen> createState() => _JoinByCodeScreenState();
}
class _JoinByCodeScreenState extends State<JoinByCodeScreen> {
  final _ctrl = TextEditingController();
  bool _loading=false; String _error='',_success='';
  Map<String,dynamic>? _booking; bool _joined=false;
  String get _myName => FirebaseAuth.instance.currentUser?.displayName ?? FirebaseAuth.instance.currentUser?.email ?? '';

  Future<void> _find() async {
    setState(() { _loading=true; _error=''; _booking=null; _success=''; });
    final s = await FirebaseFirestore.instance.collection('bookings').where('bookingCode', isEqualTo: _ctrl.text.trim()).limit(1).get();
    if (s.docs.isEmpty) { setState(() { _error=tr('קוד לא תקין','Invalid code.'); _loading=false; }); return; }
    final data = {'id': s.docs.first.id, ...s.docs.first.data()};
    setState(() { _booking=data; _joined=((data['players'] as List?)??[]).contains(_myName); _loading=false; });
  }

  Future<void> _join() async {
    final p=(_booking!['players'] as List?)??[];
    if (p.length>=18) { setState(() { _error=tr('הקבוצה מלאה (18/18)','Team full (18/18)'); }); return; }
    setState(() { _loading=true; });
    await FirebaseFirestore.instance.collection('bookings').doc(_booking!['id']).update({'players': FieldValue.arrayUnion([_myName])});
    final user = FirebaseAuth.instance.currentUser;
    await FirebaseFirestore.instance.collection('notifications').add({
      'userId': user?.uid,
      'title': tr('הצטרפת למשחק! ⚽','You joined a game! ⚽'),
      'body': tr('הצטרפת ל-${_booking!['stadiumName']} ב-${_booking!['day']} ${_booking!['date']} • ${_booking!['time']}', 'You joined ${_booking!['stadiumName']} on ${_booking!['day']} ${_booking!['date']} • ${_booking!['time']}'),
      'read': false, 'createdAt': DateTime.now().toIso8601String(),
    });
    await FirebaseFirestore.instance.collection('notifications').add({
      'userId': _booking!['userId'],
      'title': tr('שחקן חדש הצטרף! 👥','New player joined! 👥'),
      'body': tr('$_myName הצטרף למשחק שלך ב-${_booking!['stadiumName']}', '$_myName joined your game at ${_booking!['stadiumName']}'),
      'read': false, 'createdAt': DateTime.now().toIso8601String(),
    });
    setState(() { _success=tr('הצטרפת! 🎉',"You're in! 🎉"); _loading=false; _joined=true; });
  }

  Future<void> _leave() async {
    setState(() { _loading=true; });
    await FirebaseFirestore.instance.collection('bookings').doc(_booking!['id']).update({'players': FieldValue.arrayRemove([_myName])});
    setState(() { _success=tr('הוסרת מההזמנה ✓','Removed ✓'); _loading=false; _joined=false; _booking=null; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: bgColor, appBar: _appBar(tr('הצטרף למשחק','JOIN GAME'), context),
    body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: Column(children: [
      const Icon(Icons.group_add_outlined, color: accentGreen, size: 56), const SizedBox(height: 16),
      Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.person_outline, color: accentGreen, size: 16), const SizedBox(width: 6), Text('${tr('מצטרף כ','Joining as')}: $_myName', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold, fontSize: 13))])),
      const SizedBox(height: 28),
      Text(tr('הכנס קוד הזמנה','ENTER BOOKING CODE'), style: const TextStyle(color: textSecondary, fontSize: 11, letterSpacing: 3)), const SizedBox(height: 12),
      TextField(controller: _ctrl, textAlign: TextAlign.center, style: const TextStyle(color: accentGreen, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 12), keyboardType: TextInputType.number, maxLength: 4,
        decoration: InputDecoration(hintText: '0000', hintStyle: const TextStyle(color: Color(0xFF333333), fontSize: 32, letterSpacing: 12), filled: true, fillColor: cardColor, counterText: '',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: borderColor)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: accentGreen, width: 1.5)))),
      const SizedBox(height: 16),
      if (_error.isNotEmpty) _errBox(_error),
      if (_success.isNotEmpty) Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)), child: Text(_success, style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold))),
      if (_booking==null&&_success.isEmpty) ...[
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, height: 52, child: ElevatedButton(onPressed: _loading?null:_find,
          style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: _loading?const SizedBox(width:20,height:20,child:CircularProgressIndicator(color:bgColor,strokeWidth:2)):Text(tr('חפש הזמנה','FIND BOOKING'), style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)))),
      ],
      if (_booking!=null) ...[
        const SizedBox(height: 20),
        Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_booking!['stadiumName']??'', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 4),
            Text('${_booking!['day']} ${_booking!['date']} • ${_booking!['time']}', style: const TextStyle(color: textSecondary, fontSize: 13)),
            Text('${tr('מארגן','Organizer')}: ${_booking!['userName']??''}', style: const TextStyle(color: textSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            Text('${tr('שחקנים','Players')}: ${(_booking!['players'] as List?)?.length??0}/18', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold)),
          ])),
        const SizedBox(height: 14),
        if (_success.isEmpty) ...[
          if (!_joined) SizedBox(width: double.infinity, height: 52, child: ElevatedButton(onPressed: _loading?null:_join,
            style: ElevatedButton.styleFrom(backgroundColor: accentGreen, foregroundColor: bgColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(tr('הצטרף לקבוצה','JOIN TEAM'), style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)))),
          if (_joined) ...[
            Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: accentGreen.withValues(alpha: 0.3))),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.check_circle_outline, color: accentGreen), const SizedBox(width: 8), Text(tr('אתה בתוך המשחק',"You're in this game"), style: const TextStyle(color: accentGreen, fontWeight: FontWeight.bold))])),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, height: 46, child: TextButton(onPressed: _loading?null:_leave,
              style: TextButton.styleFrom(backgroundColor: Colors.red.withValues(alpha: 0.08), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: Colors.red.withValues(alpha: 0.3)))),
              child: Text(tr('עזוב משחק','LEAVE GAME'), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w900)))),
          ],
        ],
      ],
    ])))),
  );
}

// ==================== PROFILE ====================
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final init = (user?.displayName??'P').substring(0,1).toUpperCase();
    return Scaffold(backgroundColor: bgColor, appBar: _appBar(tr('פרופיל','PROFILE'), context),
      body: FutureBuilder(
        future: FirebaseFirestore.instance.collection('bookings').where('userId', isEqualTo: user?.uid).get(),
        builder: (ctx, snap) {
          final total = snap.data?.docs.length ?? 0;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Container(padding: const EdgeInsets.all(24), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(20), border: Border.all(color: borderColor)),
              child: Column(children: [
                Container(width: 80, height: 80, decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.15), shape: BoxShape.circle, border: Border.all(color: accentGreen.withValues(alpha: 0.4), width: 2)), child: Center(child: Text(init, style: const TextStyle(color: accentGreen, fontSize: 34, fontWeight: FontWeight.w900)))),
                const SizedBox(height: 12),
                Text(user?.displayName??tr('שחקן','Player'), style: const TextStyle(color: textPrimary, fontSize: 20, fontWeight: FontWeight.w900)),
                Text(user?.email??'', style: const TextStyle(color: textSecondary, fontSize: 13)),
              ])),
            const SizedBox(height: 20), _secTitle(tr('סטטיסטיקות','STATS')), const SizedBox(height: 12),
            Row(children: [Expanded(child: _statCard(tr('הזמנות','BOOKINGS'), '$total', Icons.calendar_month, accentGreen)), const SizedBox(width: 12), Expanded(child: _statCard(tr('מגרשים','STADIUMS'), '${allStadiums.length}', Icons.sports_soccer, Colors.blue))]),
            const SizedBox(height: 24), _secTitle(tr('חשבון','ACCOUNT')), const SizedBox(height: 12),
            _menuItem(Icons.calendar_month_outlined, tr('הלוח זמנים שלי','My Schedule'), accentGreen, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MyBookingsScreen()))),
            const SizedBox(height: 10),
            _menuItem(Icons.logout, tr('יציאה','Sign Out'), Colors.red, () => FirebaseAuth.instance.signOut()),
          ]);
        },
      ),
    );
  }
  Widget _menuItem(IconData icon, String label, Color color, VoidCallback onTap) => GestureDetector(onTap: onTap,
    child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: borderColor)),
      child: Row(children: [Icon(icon, color: color, size: 20), const SizedBox(width: 14), Text(label, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.bold)), const Spacer(), const Icon(Icons.arrow_forward_ios, color: Color(0xFF444444), size: 12)])));
}

// ==================== MY BOOKINGS ====================
class MyBookingsScreen extends StatelessWidget {
  const MyBookingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final myName = user?.displayName ?? user?.email ?? '';
    return Scaffold(backgroundColor: bgColor, appBar: _appBar(tr('הלוח זמנים שלי','MY SCHEDULE'), context),
      body: FutureBuilder(
        future: Future.wait([
          FirebaseFirestore.instance.collection('bookings').where('userId', isEqualTo: user?.uid).get(),
          FirebaseFirestore.instance.collection('bookings').where('players', arrayContains: myName).get(),
        ]),
        builder: (ctx, AsyncSnapshot<List<QuerySnapshot>> snap) {
          if (snap.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: accentGreen));
          if (!snap.hasData) return Center(child: Text(tr('שגיאה','Error'), style: const TextStyle(color: Colors.red)));
          final Map<String, QueryDocumentSnapshot> map = {};
          for (final d in snap.data![0].docs) map[d.id]=d;
          for (final d in snap.data![1].docs) map[d.id]=d;
          final docs = map.values.toList();
          if (docs.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.calendar_today_outlined, color: Color(0xFF333333), size: 64), const SizedBox(height: 16), Text(tr('אין הזמנות עדיין','No bookings yet'), style: const TextStyle(color: textSecondary, fontSize: 16))]));
          return ListView.builder(padding: const EdgeInsets.all(16), itemCount: docs.length, itemBuilder: (ctx, i) {
            final doc = docs[i]; final b = doc.data() as Map<String,dynamic>;
            final players = (b['players'] as List?)??[]; final isOrg = b['userId']==user?.uid;
            bool canCancel = true;
            try { final parts=(b['date'] as String).split('/'); final h=int.parse((b['time'] as String).split(':')[0]); final now=DateTime.now(); canCancel=DateTime(now.year,int.parse(parts[1]),int.parse(parts[0]),h).difference(now).inHours>=3; } catch(_) {}
            return Container(margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(16), border: Border.all(color: isOrg?accentGreen.withValues(alpha: 0.3):Colors.blue.withValues(alpha: 0.2))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: isOrg?accentGreen.withValues(alpha: 0.08):Colors.blue.withValues(alpha: 0.06), borderRadius: const BorderRadius.vertical(top: Radius.circular(16))),
                  child: Row(children: [Icon(isOrg?Icons.star_outline:Icons.sports_soccer, color: isOrg?Colors.amber:Colors.blue, size: 14), const SizedBox(width: 6),
                    Text(isOrg?tr('מארגן','ORGANIZER'):tr('שחקן','PLAYER'), style: TextStyle(color: isOrg?Colors.amber:Colors.blue, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 2)), const Spacer(),
                    if (isOrg) Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)), child: Text(b['bookingCode']??'', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, letterSpacing: 3, fontSize: 13)))])),
                Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b['stadiumName']??'', style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, fontSize: 16)),
                  const SizedBox(height: 6),
                  Row(children: [const Icon(Icons.calendar_today_outlined,color:textSecondary,size:13),const SizedBox(width:4),Text('${b['day']} ${b['date']}',style:const TextStyle(color:textSecondary,fontSize:12)),const SizedBox(width:12),const Icon(Icons.access_time_outlined,color:textSecondary,size:13),const SizedBox(width:4),Text(b['time']??'',style:const TextStyle(color:textSecondary,fontSize:12))]),
                  const SizedBox(height: 4),
                  Text(b['price']??'', style: const TextStyle(color: accentGreen, fontSize: 13, fontWeight: FontWeight.bold)),
                  if (players.isNotEmpty) ...[const SizedBox(height:12),const Divider(color:borderColor,height:1),const SizedBox(height:10),
                    Row(children:[Text(tr('שחקנים','PLAYERS'),style:const TextStyle(color:textSecondary,fontSize:10,letterSpacing:2)),const SizedBox(width:8),Text('${players.length}/18',style:const TextStyle(color:accentGreen,fontSize:10,fontWeight:FontWeight.bold))]),const SizedBox(height:6),
                    Wrap(spacing:6,runSpacing:6,children:players.map((p)=>Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:4),decoration:BoxDecoration(color:p==myName?accentGreen.withValues(alpha:0.15):const Color(0xFF222222),borderRadius:BorderRadius.circular(20),border:p==myName?Border.all(color:accentGreen.withValues(alpha:0.4)):null),child:Text(p.toString(),style:TextStyle(color:p==myName?accentGreen:textSecondary,fontSize:11,fontWeight:p==myName?FontWeight.bold:FontWeight.normal)))).toList())],
                  const SizedBox(height: 12),
                  if (isOrg) SizedBox(width: double.infinity, child: TextButton(onPressed: canCancel?() async {
                    final ok=await showDialog<bool>(context:context,builder:(_)=>AlertDialog(backgroundColor:cardColor,
                      title:Text(tr('ביטול הזמנה?','Cancel Booking?'),style:const TextStyle(color:textPrimary,fontWeight:FontWeight.bold)),
                      content:Text(tr('זה יבטל את ההזמנה לכל השחקנים.','This cancels for all players.'),style:const TextStyle(color:textSecondary)),
                      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:Text(tr('השאר','KEEP'),style:const TextStyle(color:textSecondary))),TextButton(onPressed:()=>Navigator.pop(context,true),child:Text(tr('בטל','CANCEL'),style:const TextStyle(color:Colors.red,fontWeight:FontWeight.bold)))]));
                    if (ok==true) await FirebaseFirestore.instance.collection('bookings').doc(doc.id).delete();
                  }:null,
                    style:TextButton.styleFrom(backgroundColor:canCancel?Colors.red.withValues(alpha:0.08):const Color(0xFF111111),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(8),side:BorderSide(color:canCancel?Colors.red.withValues(alpha:0.3):borderColor))),
                    child:Text(canCancel?tr('בטל הזמנה','CANCEL BOOKING'):tr('לא ניתן לבטל (פחות מ-3 שעות)','CANNOT CANCEL (< 3 HRS)'),style:TextStyle(color:canCancel?Colors.red:const Color(0xFF444444),fontSize:12,fontWeight:FontWeight.w900))))
                  else SizedBox(width:double.infinity,child:TextButton(onPressed:canCancel?()async{await FirebaseFirestore.instance.collection('bookings').doc(doc.id).update({'players':FieldValue.arrayRemove([myName])}); }:null,
                    style:TextButton.styleFrom(backgroundColor:canCancel?Colors.orange.withValues(alpha:0.08):const Color(0xFF111111),shape:RoundedRectangleBorder(borderRadius:BorderRadius.circular(8),side:BorderSide(color:canCancel?Colors.orange.withValues(alpha:0.3):borderColor))),
                    child:Text(canCancel?tr('עזוב משחק','LEAVE GAME'):tr('לא ניתן לעזוב (פחות מ-3 שעות)','CANNOT LEAVE (< 3 HRS)'),style:TextStyle(color:canCancel?Colors.orange:const Color(0xFF444444),fontSize:12,fontWeight:FontWeight.w900)))),
                ])),
              ]));
          });
        },
      ),
    );
  }
}

// ==================== NOTIFICATIONS ====================
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(backgroundColor: bgColor, appBar: _appBar(tr('התראות','NOTIFICATIONS'), context),
      body: StreamBuilder(
        stream: FirebaseFirestore.instance.collection('notifications').where('userId', isEqualTo: uid).orderBy('createdAt', descending: true).snapshots(),
        builder: (ctx, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: accentGreen));
          final docs = snap.data!.docs;
          if (docs.isEmpty) return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.notifications_none, color: Color(0xFF333333), size: 64), const SizedBox(height: 16),
            Text(tr('אין התראות','No notifications'), style: const TextStyle(color: textSecondary, fontSize: 16)),
          ]));
          return ListView.builder(padding: const EdgeInsets.all(16), itemCount: docs.length, itemBuilder: (ctx, i) {
            final n = docs[i].data(); final isRead = n['read'] == true;
            return GestureDetector(
              onTap: () => FirebaseFirestore.instance.collection('notifications').doc(docs[i].id).update({'read': true}),
              child: Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: isRead ? cardColor : accentGreen.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12), border: Border.all(color: isRead ? borderColor : accentGreen.withValues(alpha: 0.3))),
                child: Row(children: [
                  Container(width: 36, height: 36, decoration: BoxDecoration(color: accentGreen.withValues(alpha: 0.1), shape: BoxShape.circle), child: const Icon(Icons.notifications_outlined, color: accentGreen, size: 18)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(n['title'] ?? '', style: TextStyle(color: isRead ? textSecondary : textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(n['body'] ?? '', style: const TextStyle(color: textSecondary, fontSize: 12)),
                  ])),
                  if (!isRead) Container(width: 8, height: 8, decoration: const BoxDecoration(color: accentGreen, shape: BoxShape.circle)),
                ]),
              ),
            );
          });
        },
      ),
    );
  }
}

// ==================== HELPERS ====================
AppBar _appBar(String t, BuildContext context) => AppBar(
  backgroundColor: bgColor, elevation: 0, iconTheme: const IconThemeData(color: textSecondary),
  title: Text(t, style: const TextStyle(color: textPrimary, fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 16)),
  actions: [_langButton(context)],
);

Widget _secTitle(String t) => Text(t, style: const TextStyle(color: textSecondary, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 3));

Widget _statCard(String label, String value, IconData icon, Color color) => Container(
  padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.2))),
  child: Row(children: [Icon(icon, color: color, size: 22), const SizedBox(width: 10), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: textSecondary, fontSize: 10, letterSpacing: 1)), Text(value, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w900))])]));

Widget _bookCard(Map<String,dynamic> b) {
  final players=(b['players'] as List?)??[];
  return Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: borderColor)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(b['stadiumName']??'', style: const TextStyle(color: accentGreen, fontWeight: FontWeight.w900, fontSize: 14))), Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.amber.withValues(alpha: 0.3))), child: Text(b['bookingCode']??'', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 12)))]),
      const SizedBox(height: 6),
      Text('${b['userName']??''} • ${b['day']} ${b['date']} • ${b['time']}', style: const TextStyle(color: textSecondary, fontSize: 12)),
      const SizedBox(height: 4),
      Text('${players.length}/18 ${tr('שחקנים','players')}${players.isNotEmpty?': ${players.join(', ')}':''}', style: const TextStyle(color: textSecondary, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
    ]));
}

Widget _errBox(String msg) => Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.red.withValues(alpha: 0.3))),
  child: Row(children: [const Icon(Icons.error_outline, color: Colors.red, size: 16), const SizedBox(width: 8), Expanded(child: Text(msg, style: const TextStyle(color: Colors.red, fontSize: 13)))]));
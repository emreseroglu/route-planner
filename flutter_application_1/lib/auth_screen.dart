import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'waypoint.dart'; // Waypoint sınıfının olduğu dosya

// ==========================================
// 1. GİRİŞ VE KAYIT EKRANI (AuthScreen)
// ==========================================
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isLogin = true;
  bool _isLoading = false;
  String? _selectedGender; // Cinsiyet
  final _ageController = TextEditingController(); // Yaş

  Future<void> _submit() async {
    setState(() => _isLoading = true);
    try {
      if (_isLogin) {
        // GİRİŞ YAP
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _emailController.text.trim(),
          password: _passwordController.text.trim(),
        );
      } else {
        // KAYIT OL
        // Validasyonlar
        if (_ageController.text.isEmpty || _selectedGender == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Lütfen yaş ve cinsiyet seçiniz.")),
          );
          setState(() => _isLoading = false);
          return;
        }

        UserCredential userCred = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(
              email: _emailController.text.trim(),
              password: _passwordController.text.trim(),
            );

        if (userCred.user != null) {
          await userCred.user!.updateDisplayName(_nameController.text.trim());

          // Firestore'a DETAYLI kaydet
          await FirebaseFirestore.instance
              .collection('users')
              .doc(userCred.user!.uid)
              .set({
                'email': _emailController.text.trim(),
                'name': _nameController.text.trim(),
                'age':
                    int.tryParse(_ageController.text.trim()) ??
                    0, // Yaşı kaydet
                'gender': _selectedGender, // Cinsiyeti kaydet
                'createdAt': Timestamp.now(),
                'preferences': {
                  'safety_priority':
                      _selectedGender == "Kadin", // Kadınsa güvenlik öncelikli
                  'comfort_priority':
                      (int.tryParse(_ageController.text.trim()) ?? 0) >
                      60, // 60 yaş üstü ise konfor öncelikli
                },
              });
        }
      }
      if (mounted) Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? "Bir hata oluştu"),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 1),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isLogin ? "Giriş Yap" : "Kayıt Ol")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.lock, size: 80, color: Colors.blue),
                const SizedBox(height: 20),
                if (!_isLogin)
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: "Ad Soyad",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                    ),
                  ),
                if (!_isLogin) const SizedBox(height: 10),
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: "E-posta",
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.email),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: "Şifre",
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.key),
                  ),
                  obscureText: true,
                ),

                // ... Şifre alanı bittikten sonra ...
                if (!_isLogin) ...[
                  const SizedBox(height: 10),
                  // YAŞ ALANI
                  TextField(
                    controller: _ageController,
                    decoration: const InputDecoration(
                      labelText: "Yaş",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.calendar_today),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 10),

                  // CİNSİYET SEÇİMİ (Dropdown)
                  DropdownButtonFormField<String>(
                    value: _selectedGender,
                    decoration: const InputDecoration(
                      labelText: "Cinsiyet",
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.wc),
                    ),
                    items: const [
                      DropdownMenuItem(value: "Kadin", child: Text("Kadın")),
                      DropdownMenuItem(value: "Erkek", child: Text("Erkek")),
                      DropdownMenuItem(
                        value: "BelirtmekIstemiyorum",
                        child: Text("Belirtmek İstemiyorum"),
                      ),
                    ],
                    onChanged: (val) {
                      setState(() => _selectedGender = val);
                    },
                  ),
                ],
                // ... Butonlar devam ediyor ...
                const SizedBox(height: 20),
                if (_isLoading)
                  const CircularProgressIndicator()
                else
                  ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                    ),
                    child: Text(_isLogin ? "Giriş Yap" : "Kayıt Ol"),
                  ),
                TextButton(
                  onPressed: () {
                    setState(() => _isLogin = !_isLogin);
                  },
                  child: Text(
                    _isLogin
                        ? "Hesabın yok mu? Kayıt Ol"
                        : "Zaten hesabın var mı? Giriş Yap",
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 2. KAYITLI ROTALAR EKRANI (SavedRoutesScreen) - HATA DÜZELTİLDİ
// ==========================================
class SavedRoutesScreen extends StatelessWidget {
  const SavedRoutesScreen({super.key});

  // Rota Silme Fonksiyonu
  Future<void> _deleteRoute(BuildContext context, String docId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('routes')
          .doc(docId)
          .delete();

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Rota silindi"),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Hata: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Hata")),
        body: const Center(child: Text("Lütfen önce giriş yapın.")),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Kayıtlı Rotalarım"),
        backgroundColor: Colors.orange,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('routes')
            .orderBy('date', descending: true)
            .snapshots(),
        builder: (context, AsyncSnapshot<QuerySnapshot> snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.map_outlined, size: 80, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    "Henüz kayıtlı rota yok.",
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          final docs = snapshot.data!.docs;

          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, index) {
              var routeData = docs[index];
              var stopsData = routeData['stops'] as List;
              String docId = routeData.id;

              final dataMap = routeData.data() as Map<String, dynamic>;

              // Tarih formatlama
              Timestamp? dateTs = dataMap['date'];
              String dateStr = "-";
              if (dateTs != null) {
                var date = dateTs.toDate();
                dateStr =
                    "${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}";
              }

              // --- KAYDIRARAK SİLME (Dismissible) ---
              return Dismissible(
                key: Key(docId),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: const Icon(
                    Icons.delete,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                confirmDismiss: (direction) async {
                  return await showDialog(
                    context: context,
                    builder: (BuildContext context) {
                      return AlertDialog(
                        title: const Text("Rotayı Sil"),
                        content: const Text(
                          "Bu rotayı kalıcı olarak silmek istediğinize emin misiniz?",
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text("İptal"),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text(
                              "Sil",
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
                onDismissed: (direction) {
                  _deleteRoute(context, docId);
                },
                child: Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  elevation: 3,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(12),
                    leading: CircleAvatar(
                      backgroundColor: Colors.orange.shade100,
                      child: Text(
                        "${stopsData.length}",
                        style: TextStyle(
                          color: Colors.orange.shade800,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      "$dateStr Rotası",
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text("Mesafe: ${dataMap['distance'] ?? '-'}"),
                        Text("Süre: ${dataMap['duration'] ?? '-'}"),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // --- BUTON İLE SİLME (Burada hata düzeltildi) ---
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                          ),
                          onPressed: () async {
                            // 1. ÖNEMLİ: Hata almamak için arayüzün kilitlenmesini bekle
                            await Future.delayed(Duration.zero);
                            if (!context.mounted) return;

                            // 2. Şimdi Dialogu aç
                            bool confirm =
                                await showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text("Silinsin mi?"),
                                    content: const Text("Bu rota silinecek."),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text("Hayır"),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text("Evet"),
                                      ),
                                    ],
                                  ),
                                ) ??
                                false;

                            if (confirm && context.mounted) {
                              _deleteRoute(context, docId);
                            }
                          },
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    onTap: () {
                      final data = docs[index].data() as Map<String, dynamic>;
                      List<Waypoint> waypoints = (data['stops'] as List).map((
                        item,
                      ) {
                        return Waypoint(
                          name: item['name'],
                          location: LatLng(item['lat'], item['lng']),
                        );
                      }).toList();

                      String mode = data['mode'] ?? 'driving';

                      Navigator.pop(context, {
                        'stops': waypoints,
                        'mode': mode,
                      });
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

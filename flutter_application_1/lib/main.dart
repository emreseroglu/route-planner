import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'museum_data.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:external_app_launcher/external_app_launcher.dart';

// --- HARİCİ DOSYALAR ---
import 'auth_screen.dart'; // AuthScreen ve SavedRoutesScreen
import 'waypoint.dart'; // Waypoint modeli
// -----------------------

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const RoutePlannerApp());
}

class RoutePlannerApp extends StatelessWidget {
  const RoutePlannerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Route Planner',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MapScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});
  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  // ⚠️ API KEY'İNİZ
  static const String googleApiKey = 'SILINMIS_ANAHTAR';

  Map<String, dynamic>? lastRouteInfo;
  String currentMode = 'driving';
  GoogleMapController? mapController;
  LatLng? currentLocation;
  bool chooseOnMapActive = false;
  bool isSearching = false;
  bool areNearbyPlacesVisible = false;
  MapType _currentMapType = MapType.normal;

  List<Waypoint> stops = [];
  List<Marker> markers = [];
  List<Map<String, dynamic>> searchResults = [];
  Set<Polyline> polylines = {};
  TextEditingController searchController = TextEditingController();

  // --- YENİ EKLENEN DEĞİŞKENLER ---
  List<dynamic> nearbyPlacesRawData =
      []; // API'den gelen ham veriyi burada tutacağız
  bool isMapFilterActive = false; // Haritadaki filtre açık mı?

  // --- YENİ EKLENEN DEĞİŞKEN ---
  bool isCityGuideVisible = false; // Şehir rehberi markerları açık mı?

  // --- ŞEHİR REHBERİNİ KAPATAN FONKSİYON ---
  void _clearCityMarkers() {
    setState(() {
      markers.removeWhere((m) {
        // Konum, Rota durakları ve Elle eklenenler kalsın, diğerlerini sil
        bool isStop = stops.any((s) => s.name == m.markerId.value);
        bool isUserPos =
            m.markerId.value == "current_pos" ||
            m.markerId.value == "current_pos_start";
        bool isManual = m.markerId.value.startsWith("manual_");
        return !isStop && !isUserPos && !isManual;
      });

      isCityGuideVisible = false; // Modu kapat
    });
  }

  LatLngBounds _boundsFromLatLngList(List<LatLng> list) {
    double? x0, x1, y0, y1;
    for (var latlng in list) {
      if (x0 == null) {
        x0 = x1 = latlng.latitude;
        y0 = y1 = latlng.longitude;
      } else {
        if (latlng.latitude > x1!) x1 = latlng.latitude;
        if (latlng.latitude < x0) x0 = latlng.latitude;
        if (latlng.longitude > y1!) y1 = latlng.longitude;
        if (latlng.longitude < y0!) y0 = latlng.longitude;
      }
    }
    return LatLngBounds(
      southwest: LatLng(x0!, y0!),
      northeast: LatLng(x1!, y1!),
    );
  }

  @override
  void initState() {
    super.initState();
    _determinePosition();
  }

  Future<void> _determinePosition() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) return;

    Position pos = await Geolocator.getCurrentPosition();
    setState(() {
      currentLocation = LatLng(pos.latitude, pos.longitude);
    });
  }

  void _safeAddStop(String name, LatLng location) {
    bool alreadyExists = stops.any(
      (s) =>
          (s.location.latitude - location.latitude).abs() < 0.000001 &&
          (s.location.longitude - location.longitude).abs() < 0.000001,
    );

    if (alreadyExists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Bu konum zaten rotanızda ekli!"),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 2),
        ),
      );
    } else {
      setState(() {
        stops.add(Waypoint(name: name, location: location));
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("$name rotaya eklendi!"),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _showMarkerActionDialog(String markerId, String name, LatLng pos) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(name),
        content: const Text("Bu konumla ne yapmak istersiniz?"),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.delete, color: Colors.red),
            label: const Text(
              "Haritadan Sil",
              style: TextStyle(color: Colors.red),
            ),
            onPressed: () {
              setState(() {
                markers.removeWhere((m) => m.markerId.value == markerId);
                stops.removeWhere(
                  (s) =>
                      s.location.latitude == pos.latitude &&
                      s.location.longitude == pos.longitude,
                );
                if (stops.length < 2) {
                  _clearRoute();
                }
              });
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("İşaretleyici silindi")),
              );
            },
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.add_location_alt),
            label: const Text("Rotaya Ekle"),
            onPressed: () {
              Navigator.pop(context);
              _safeAddStop(name, pos);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _searchPlace(String query) async {
    if (query.isEmpty) {
      setState(() => searchResults = []);
      return;
    }
    setState(() => isSearching = true);

    String urlString =
        'https://maps.googleapis.com/maps/api/place/autocomplete/json'
        '?input=$query'
        '&types=point_of_interest'
        '&key=$googleApiKey';

    if (currentLocation != null) {
      urlString +=
          '&location=${currentLocation!.latitude},${currentLocation!.longitude}&radius=50000';
    }

    final url = Uri.parse(urlString);

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['status'] == 'OK' || data['status'] == 'ZERO_RESULTS') {
          final predictions = data['predictions'] as List<dynamic>;
          setState(() {
            searchResults = predictions
                .map(
                  (p) => {
                    'description': p['description'],
                    'place_id': p['place_id'],
                  },
                )
                .toList();
          });
        } else {
          setState(() => searchResults = []);
        }
      } else {
        setState(() => searchResults = []);
      }
    } catch (e) {
      print("Arama Hatası: $e");
      setState(() => searchResults = []);
    }
  }

  Future<void> _fetchPlaceDetails(String placeId, String name) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/details/json'
      '?place_id=$placeId'
      '&key=$googleApiKey',
    );

    final res = await http.get(url);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      final loc = data['result']['geometry']['location'];
      final lat = (loc['lat'] as num).toDouble();
      final lng = (loc['lng'] as num).toDouble();

      // Müzekart Kontrolü (Arama sonucunda da yeşil görünsün diye)
      bool isPassValid = checkIfMuseumPassValid(name);
      final double markerHue = isPassValid
          ? BitmapDescriptor.hueGreen
          : BitmapDescriptor.hueRed; // Aranan yerler Kırmızı olsun

      final marker = Marker(
        markerId: MarkerId(placeId),
        position: LatLng(lat, lng),
        icon: BitmapDescriptor.defaultMarkerWithHue(markerHue),
        infoWindow: InfoWindow(
          title: name,
          snippet: isPassValid
              ? "✅ Müzekart Geçerli! Tıkla"
              : "Detaylar ve Ekleme İçin Tıkla",

          // --- BURASI DEĞİŞTİ: ARTIK DETAY EKRANINA GİDİYOR ---
          onTap: () async {
            final bool? shouldAdd = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => PlaceDetailsScreen(
                  placeId: placeId,
                  placeName: name,
                  apiKey: googleApiKey,
                  location: LatLng(lat, lng),
                ),
              ),
            );

            // Eğer detay ekranında "Rotaya Ekle" butonuna basılırsa
            if (shouldAdd == true) {
              _safeAddStop(name, LatLng(lat, lng));
            }
          },
          // ----------------------------------------------------
        ),
      );

      setState(() {
        markers.add(marker);
        mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(lat, lng), 15),
        );
        searchResults = [];
        searchController.clear();
        isSearching = false;
      });
    }
  }

  Future<void> _handleNearbyPlacesButton() async {
    // --- KAPATMA MANTIĞI ---
    if (areNearbyPlacesVisible) {
      setState(() {
        areNearbyPlacesVisible = false;
        nearbyPlacesRawData = []; // Veriyi temizle

        // Başlangıç noktasını temizle
        if (stops.isNotEmpty && stops.first.name == "Başlangıç: Konumum") {
          stops.removeAt(0);
        }
        if (stops.length < 2) {
          polylines.clear();
          lastRouteInfo = null;
        }
      });
      // Haritayı güncelle (bu fonksiyon temizliği yapacak)
      _updateMapMarkers();
      return;
    }

    // --- AÇMA MANTIĞI ---
    if (currentLocation == null) return;

    // *** YENİ EKLENEN KISIM BURASI ***
    // Eğer Şehir Rehberi açıksa, "Yakınımdaki Yerler"e basınca o modu ve butonunu kapat.
    setState(() {
      isCityGuideVisible = false;
    });

    // Başlangıç noktası ekle
    bool isStartAdded =
        stops.isNotEmpty && stops.first.name == "Başlangıç: Konumum";
    if (!isStartAdded) {
      setState(() {
        stops.insert(
          0,
          Waypoint(name: "Başlangıç: Konumum", location: currentLocation!),
        );
        // Konum marker'ı ekle
        markers.add(
          Marker(
            markerId: const MarkerId("current_pos_start"),
            position: currentLocation!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueAzure,
            ),
            infoWindow: const InfoWindow(title: "Başlangıç: Konumum"),
          ),
        );
      });
    }

    // API İSTEĞİ
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
      '?location=${currentLocation!.latitude},${currentLocation!.longitude}'
      '&radius=5000'
      '&type=tourist_attraction'
      '&key=$googleApiKey',
    );

    try {
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final results = data['results'] as List<dynamic>;

        // Filtreleme (ATM, Banka vs. at)
        final cleanResults = results.where((p) {
          final types = (p['types'] as List<dynamic>).cast<String>();
          const excludedTypes = [
            'atm',
            'bank',
            'finance',
            'school',
            'hospital',
            'doctor',
            'dentist',
            'pharmacy',
            'gym',
            'spa',
            'gas_station',
            'parking',
            'store',
            'supermarket',
            'lodging',
            'hotel',
            'restaurant',
            'food',
            'local_government_office',
            'post_office',
            'police',
          ];
          return !types.any((t) => excludedTypes.contains(t));
        }).toList();

        setState(() {
          nearbyPlacesRawData = cleanResults; // 1. Veriyi Hafızaya At
          areNearbyPlacesVisible = true; // 2. Modu Aç
        });

        // 3. Haritayı Çiz
        _updateMapMarkers();
      }
    } catch (e) {
      print("Hata: $e");
    }
  }

  void _addCityGuideMarkers(List<dynamic> places) {
    setState(() {
      // 1. Önceki markerları temizle
      markers.removeWhere(
        (m) =>
            !stops.any((s) => s.name == m.markerId.value) &&
            m.markerId.value != "current_pos" &&
            m.markerId.value != "current_pos_start",
      );

      double? minLat, maxLat, minLng, maxLng;

      for (var place in places) {
        final double lat = place['lat'];
        final double lng = place['lng'];
        final String name = place['name'];
        final String uniqueId = "city_guide_${place['name']}";

        // Müzekart Kontrolü
        bool isPassValid = checkIfMuseumPassValid(name);
        final double markerHue = isPassValid
            ? BitmapDescriptor.hueGreen
            : BitmapDescriptor.hueViolet;
        final String snippetText = isPassValid
            ? "✅ Müzekart Geçerli! Ekle"
            : "Detaylar ve Ekleme İçin Tıkla";

        if (minLat == null || lat < minLat!) minLat = lat;
        if (maxLat == null || lat > maxLat!) maxLat = lat;
        if (minLng == null || lng < minLng!) minLng = lng;
        if (maxLng == null || lng > maxLng!) maxLng = lng;

        markers.add(
          Marker(
            markerId: MarkerId(uniqueId),
            position: LatLng(lat, lng),
            icon: BitmapDescriptor.defaultMarkerWithHue(markerHue),
            infoWindow: InfoWindow(
              title: name,
              snippet: snippetText,
              onTap: () {
                _handleCityGuideMarkerTap(name, lat, lng);
              },
            ),
          ),
        );
      }

      // Kamerayı ayarla
      if (minLat != null && mapController != null) {
        mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(minLat!, minLng!),
              northeast: LatLng(maxLat!, maxLng!),
            ),
            50,
          ),
        );
      }

      // --- MOD AYARLARI ---
      areNearbyPlacesVisible = false; // Yakın yerler modunu kapat
      isCityGuideVisible = true; // Şehir rehberi modunu AÇ
    });
  }

  Future<Map<String, dynamic>?> _calculateRoute() async {
    if (stops.length < 2) return null;

    final url = Uri.parse('http://192.168.1.3:8000/route'); // IP'ni kontrol et!

    String apiMode = 'driving-car';
    if (currentMode == 'walking') {
      apiMode = 'foot-walking';
    }

    final body = jsonEncode({
      "locations": stops
          .map(
            (s) => {
              "lat": s.location.latitude,
              "lng": s.location.longitude,
              "name": s.name,
            },
          )
          .toList(),
      "transport_mode": apiMode,
      "initial_temp": 10000.0,
      "cooling_rate": 0.995,
      "stopping_temp": 0.001,
      "max_iter": 500000,
    });

    try {
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: body,
      );

      if (response.statusCode == 200) {
        return jsonDecode(utf8.decode(response.bodyBytes));
      } else {
        print("API Hatası: ${response.statusCode}");
        return null;
      }
    } catch (e) {
      print("Bağlantı Hatası: $e");
      return null;
    }
  }

  Future<Map<String, dynamic>?> _drawRealRoute({
    required List<Waypoint> stops,
    String mode = 'driving',
  }) async {
    if (stops.length < 2) return null;

    final origin = stops.first.location;
    final destination = stops.last.location;

    String waypoints = '';
    if (stops.length > 2) {
      waypoints = stops
          .sublist(1, stops.length - 1)
          .map((w) => '${w.location.latitude},${w.location.longitude}')
          .join('|');
    }

    String trafficParams = "";
    if (mode == 'driving') {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      trafficParams = "&departure_time=$now&traffic_model=best_guess";
    }

    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
      '?origin=${origin.latitude},${origin.longitude}'
      '&destination=${destination.latitude},${destination.longitude}'
      '${waypoints.isNotEmpty ? '&waypoints=$waypoints' : ''}'
      '&mode=$mode'
      '$trafficParams'
      '&key=$googleApiKey',
    );

    final res = await http.get(url);
    if (res.statusCode == 200) {
      final data = json.decode(res.body);
      if ((data['routes'] as List).isEmpty) return null;

      final route = data['routes'][0];
      final encodedPoly = route['overview_polyline']['points'];
      final points = _decodePolyline(encodedPoly);

      int totalDurationSeconds = 0;
      int totalDistanceMeters = 0;
      List<String> instructions = [];

      for (var leg in route['legs']) {
        totalDurationSeconds += (leg['duration']['value'] as num).toInt();
        totalDistanceMeters += (leg['distance']['value'] as num).toInt();
        for (var step in leg['steps']) {
          instructions.add(step['html_instructions']);
        }
      }

      setState(() {
        polylines.clear();
        polylines.add(
          Polyline(
            polylineId: const PolylineId("real_route"),
            points: points,
            color: Colors.blue,
            width: 5,
          ),
        );

        if (points.isNotEmpty) {
          LatLngBounds bounds = _boundsFromLatLngList(points);
          mapController?.animateCamera(
            CameraUpdate.newLatLngBounds(bounds, 50),
          );
        }
      });

      return {
        "duration_text": _formatDuration(totalDurationSeconds),
        "distance_text":
            "${(totalDistanceMeters / 1000).toStringAsFixed(1)} km",
        "steps": instructions,
      };
    }
    return null;
  }

  String _formatDuration(int seconds) {
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) return "$hours sa $minutes dk";
    return "$minutes dk";
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> points = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1F) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

  void _clearRoute() {
    setState(() {
      polylines.clear();
      lastRouteInfo = null;
      if (currentLocation != null && mapController != null) {
        mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(currentLocation!, 15),
        );
      }
    });
  }

  // --- GÜNCELLENMİŞ MARKER YENİLEME (Sayılarla) ---
  Future<void> _refreshMarkers() async {
    final newMarkers = <Marker>[];

    for (int i = 0; i < stops.length; i++) {
      final stop = stops[i];

      // Her durak için özel numaralı ikon oluştur (1, 2, 3...)
      final BitmapDescriptor customIcon = await _createCustomMarkerBitmap(
        "${i + 1}",
      );

      newMarkers.add(
        Marker(
          markerId: MarkerId(stop.name),
          position: stop.location,
          icon: customIcon, // <-- Özel ikon burada kullanılıyor
          // infoWindow içine yine isim yazalım
          infoWindow: InfoWindow(
            title: "${i + 1}. ${stop.name}",
            snippet: "Detaylar için tıkla",
          ),
        ),
      );
    }

    setState(() {
      markers = newMarkers;
    });
  }

  Future<void> _optimizeAndDrawRoute(String mode) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("En kısa rota hesaplanıyor...")),
    );

    final optimizedData = await _calculateRoute();

    if (optimizedData != null) {
      final routeList = optimizedData['route'] as List;

      setState(() {
        stops.clear();
        for (var item in routeList) {
          stops.add(
            Waypoint(
              name: item['name'] ?? "Bilinmeyen Durak",
              location: LatLng(item['lat'], item['lng']),
            ),
          );
        }
      });

      await _refreshMarkers();

      // 3. ADIM: Rotayı çiz
      final routeInfo = await _drawRealRoute(stops: stops, mode: mode);

      setState(() {
        lastRouteInfo = routeInfo;
      });

      if (routeInfo != null && mounted) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          List<Map<String, dynamic>> stopsData = stops
              .map(
                (s) => {
                  'name': s.name,
                  'lat': s.location.latitude,
                  'lng': s.location.longitude,
                },
              )
              .toList();

          FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('routes')
              .add({
                'stops': stopsData,
                'date': Timestamp.now(),
                'duration': routeInfo['duration_text'],
                'distance': routeInfo['distance_text'],
                'mode': mode,
              })
              .then((_) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Rota kaydedildi!"),
                    backgroundColor: Colors.green,
                    duration: Duration(seconds: 1),
                  ),
                );
              });
        }

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RouteDirectionsScreen(
              duration: routeInfo['duration_text'],
              distance: routeInfo['distance_text'],
              steps: routeInfo['steps'],
            ),
          ),
        );
      }
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Optimizasyon yapılamadı.")));
      _drawRealRoute(stops: stops, mode: mode);
    }
  }

  Widget _buildDrawer() {
    final user = FirebaseAuth.instance.currentUser;

    return Drawer(
      child: Column(
        children: [
          UserAccountsDrawerHeader(
            decoration: const BoxDecoration(color: Colors.blueAccent),
            accountName: Text(
              user != null
                  ? (user.displayName ?? "Kullanıcı")
                  : "Misafir Kullanıcı",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            accountEmail: Text(user != null ? user.email! : "Giriş yapınız"),
            currentAccountPicture: CircleAvatar(
              backgroundColor: Colors.white,
              child:
                  user != null &&
                      user.displayName != null &&
                      user.displayName!.isNotEmpty
                  ? Text(
                      user.displayName![0].toUpperCase(),
                      style: const TextStyle(fontSize: 30, color: Colors.blue),
                    )
                  : const Icon(Icons.person, size: 40, color: Colors.grey),
            ),
          ),

          // ... Diğer menü elemanları (Giriş Yap, Yakın Yerler vb.) aynı kalabilir ...
          if (user == null)
            ListTile(
              leading: const Icon(Icons.login, color: Colors.green),
              title: const Text('Giriş Yap / Kayıt Ol'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const AuthScreen()),
                ).then((_) {
                  setState(() {});
                });
              },
            ),

          ListTile(
            leading: const Icon(Icons.explore, color: Colors.blue),
            title: const Text('Yakın Yerler Listesi'),
            onTap: () async {
              Navigator.pop(context);
              if (currentLocation != null) {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => NearbyPlacesListScreen(
                      userLocation: currentLocation!,
                      apiKey: _MapScreenState.googleApiKey, // Statik çağırdık
                    ),
                  ),
                );
                if (result != null && result is Map) {
                  _safeAddStop(
                    result['name'],
                    LatLng(result['lat'], result['lng']),
                  );
                }
              }
            },
          ),

          ListTile(
            leading: const Icon(Icons.menu_book, color: Colors.redAccent),
            title: const Text('Türkiye Şehir Rehberi'),
            onTap: () async {
              Navigator.pop(context);
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const CityGuideScreen(),
                ),
              );
              if (result != null &&
                  result is Map &&
                  result.containsKey('foundPlaces')) {
                final places = result['foundPlaces'] as List;
                _addCityGuideMarkers(places);
              }
            },
          ),

          // --- İŞTE DÜZELTİLEN KISIM BURASI ---
          if (user != null)
            ListTile(
              leading: const Icon(Icons.history, color: Colors.orange),
              title: const Text('Kayıtlı Rotalarım'),
              onTap: () async {
                Navigator.pop(context); // Menüyü kapat

                // BURASI DEĞİŞTİ: Artık tip belirtmiyoruz (dynamic alıyoruz)
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const SavedRoutesScreen(),
                  ),
                );

                // Gelen verinin MAP (Paket) olup olmadığını kontrol et
                if (result != null && result is Map) {
                  // 1. Önce eski rotayı temizle
                  _clearRoute();

                  // 2. Paketi aç: Durakları ve Modu al
                  final List<Waypoint> loadedStops = result['stops'];
                  final String loadedMode = result['mode'] ?? 'driving';

                  // 3. Değişkenleri güncelle
                  setState(() {
                    stops = loadedStops;
                    currentMode = loadedMode; // <--- MODU GÜNCELLEDİK
                  });

                  // 4. Markerları (Mavi topları) oluştur
                  await _refreshMarkers();

                  // 5. Rotayı KAYDEDİLEN MODA GÖRE çiz
                  // ScaffoldMessenger ile bilgi verelim
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("Rota yükleniyor... Mod: $loadedMode"),
                    ),
                  );

                  final routeInfo = await _drawRealRoute(
                    stops: stops,
                    mode: loadedMode, // <--- DOĞRU MOD İLE ÇİZİM
                  );

                  // 6. Paneli aç
                  setState(() {
                    lastRouteInfo = routeInfo;
                  });
                }
              },
            ),

          // ------------------------------------
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('Harita Modları'),
            onTap: () {
              Navigator.pop(context);
              _showMapTypeSelector();
            },
          ),

          const Divider(),

          if (user != null)
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('Çıkış Yap'),
              onTap: () async {
                await FirebaseAuth.instance.signOut();
                Navigator.pop(context);
                setState(() {});
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text("Çıkış yapıldı.")));
              },
            ),
        ],
      ),
    );
  }

  void _showMapTypeSelector() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          height: 220,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Harita Görünümü",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMapTypeItem(
                    "Varsayılan",
                    MapType.normal,
                    Icons.map_outlined,
                  ),
                  _buildMapTypeItem(
                    "Uydu",
                    MapType.satellite,
                    Icons.satellite_alt,
                  ),
                  _buildMapTypeItem("Arazi", MapType.terrain, Icons.terrain),
                  _buildMapTypeItem("Hibrit", MapType.hybrid, Icons.layers),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMapTypeItem(String label, MapType type, IconData icon) {
    bool isSelected = _currentMapType == type;
    return InkWell(
      onTap: () {
        setState(() => _currentMapType = type);
        Navigator.pop(context);
      },
      child: Column(
        children: [
          Container(
            height: 60,
            width: 60,
            decoration: BoxDecoration(
              border: Border.all(
                color: isSelected ? Colors.blueAccent : Colors.grey.shade300,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(12),
              color: isSelected ? Colors.blue.withOpacity(0.1) : Colors.white,
            ),
            child: Icon(
              icon,
              color: isSelected ? Colors.blueAccent : Colors.grey.shade700,
              size: 30,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.blueAccent : Colors.black87,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransportButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 16),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Icon(
              Icons.arrow_forward_ios,
              size: 16,
              color: color.withOpacity(0.5),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleCityGuideMarkerTap(
    String name,
    double lat,
    double lng,
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/findplacefromtext/json?input=$name&inputtype=textquery&fields=place_id&locationbias=circle:500@$lat,$lng&key=$googleApiKey',
      );
      final response = await http.get(url);
      final data = json.decode(response.body);
      if (mounted) Navigator.pop(context);

      if (data['status'] == 'OK' && data['candidates'].isNotEmpty) {
        final placeId = data['candidates'][0]['place_id'];
        if (mounted) {
          final bool? shouldAdd = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PlaceDetailsScreen(
                placeId: placeId,
                placeName: name,
                apiKey: googleApiKey,
                location: LatLng(lat, lng),
              ),
            ),
          );
          if (shouldAdd == true) _safeAddStop(name, LatLng(lat, lng));
        }
      } else {
        _showMarkerActionDialog("json_$name", name, LatLng(lat, lng));
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      print("Hata: $e");
    }
  }

  @override
  @override
  Widget build(BuildContext context) {
    if (currentLocation == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      drawer: _buildDrawer(),
      body: Stack(
        children: [
          // 1. HARİTA (EN ALT KATMAN)
          GoogleMap(
            onMapCreated: (controller) => mapController = controller,
            myLocationEnabled: true,
            mapType: _currentMapType,
            initialCameraPosition: CameraPosition(
              target: currentLocation!,
              zoom: 15,
            ),
            markers: markers.toSet(),
            polylines: polylines,
            onTap: (pos) {
              FocusScope.of(context).unfocus();
              if (isSearching || searchResults.isNotEmpty) {
                setState(() {
                  isSearching = false;
                  searchResults = [];
                  searchController.clear();
                });
                return;
              }
              if (chooseOnMapActive) {
                final markerIdVal = "manual_${pos.latitude}_${pos.longitude}";
                final marker = Marker(
                  markerId: MarkerId(markerIdVal),
                  position: pos,
                  icon: BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueRed,
                  ),
                  infoWindow: InfoWindow(
                    title: "Seçilen Konum",
                    snippet: "İşlem yapmak için buraya dokunun",
                    onTap: () => _showMarkerActionDialog(
                      markerIdVal,
                      "Seçilen Konum",
                      pos,
                    ),
                  ),
                );
                setState(() => markers.add(marker));
              }
            },
          ),

          // 2. ARAMA ÇUBUĞU
          Positioned(
            top: 40,
            left: 12,
            right: 12,
            child: Column(
              children: [
                Row(
                  children: [
                    Builder(
                      builder: (context) => FloatingActionButton(
                        heroTag: 'menu',
                        mini: true,
                        backgroundColor: Colors.white,
                        child: const Icon(Icons.menu, color: Colors.black87),
                        onPressed: () => Scaffold.of(context).openDrawer(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: searchController,
                        onChanged: (val) => _searchPlace(val),
                        decoration: InputDecoration(
                          hintText: "Durak Ara",
                          filled: true,
                          fillColor: Colors.white,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 0,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          suffixIcon: searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.clear,
                                    color: Colors.grey,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      searchController.clear();
                                      searchResults = [];
                                      isSearching = false;
                                    });
                                    FocusScope.of(context).unfocus();
                                  },
                                )
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: chooseOnMapActive ? "Vazgeç" : "Haritadan seç",
                      icon: Icon(
                        chooseOnMapActive
                            ? Icons.close
                            : Icons.add_location_alt,
                        color: chooseOnMapActive ? Colors.red : Colors.black87,
                      ),
                      onPressed: () => setState(
                        () => chooseOnMapActive = !chooseOnMapActive,
                      ),
                    ),
                  ],
                ),
                if (searchResults.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    constraints: const BoxConstraints(maxHeight: 200),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(blurRadius: 6, color: Colors.black26),
                      ],
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: searchResults.length,
                      itemBuilder: (context, index) {
                        final r = searchResults[index];
                        return ListTile(
                          title: Text(r['description']),
                          onTap: () => _fetchPlaceDetails(
                            r['place_id'],
                            r['description'],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

          // 3. SOL ÜST: MÜZEKART FİLTRESİ (SABİT YÜKSEKLİK - HİZALI)
          if (areNearbyPlacesVisible)
            Positioned(
              top: 90,
              left: 12,
              child: SizedBox(
                height: 40,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.card_membership,
                        color: Colors.green,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        "Müzekart",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Colors.black87,
                        ),
                      ),
                      Transform.scale(
                        scale: 0.7,
                        child: Switch(
                          value: isMapFilterActive,
                          activeColor: Colors.green,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: (val) {
                            setState(() {
                              isMapFilterActive = val;
                              _updateMapMarkers();
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 4. SAĞ ÜST: YAKINIMDAKİ YERLER BUTONU (SABİT YÜKSEKLİK - HİZALI)
          if (!isSearching)
            Positioned(
              top: 90,
              right: 12,
              child: SizedBox(
                height: 40,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: areNearbyPlacesVisible
                        ? Colors.redAccent
                        : Colors.white,
                    foregroundColor: areNearbyPlacesVisible
                        ? Colors.white
                        : Colors.black87,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 4,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  onPressed: _handleNearbyPlacesButton,
                  icon: Icon(
                    areNearbyPlacesVisible ? Icons.close : Icons.place,
                    size: 18,
                  ),
                  label: Text(
                    areNearbyPlacesVisible ? 'Gizle' : 'Yakınımdaki Yerler',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),

          // 5. ORTA ÜST: ŞEHİR REHBERİNİ TEMİZLE BUTONU
          if (isCityGuideVisible)
            Positioned(
              top: 130,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  height: 40,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.redAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: const BorderSide(color: Colors.redAccent),
                      ),
                      elevation: 4,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: _clearCityMarkers,
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: const Text(
                      "Rehberi Kapat",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // 6. DRAGGABLE SHEET (DURAK LİSTESİ VE OPTİMİZASYON - DİNAMİK YÜKSEKLİK)
          DraggableScrollableSheet(
            // --- DÜZELTME 1: Rota varsa listeyi panelin üzerine çıkar ---
            minChildSize: lastRouteInfo != null ? 0.30 : 0.15,
            initialChildSize: lastRouteInfo != null ? 0.30 : 0.25,
            // -----------------------------------------------------------
            maxChildSize: 0.75,
            snap: true,
            snapSizes: lastRouteInfo != null
                ? const [0.30, 0.6, 0.75] // Rota varken yapışma noktaları
                : const [0.15, 0.5, 0.75], // Rota yokken yapışma noktaları

            builder: (context, scrollController) {
              return Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 15,
                          spreadRadius: 5,
                          offset: const Offset(0, -5),
                        ),
                      ],
                    ),
                    child: CustomScrollView(
                      controller: scrollController,
                      physics: const ClampingScrollPhysics(),
                      slivers: [
                        // --- TUTMA ÇUBUĞU ---
                        SliverToBoxAdapter(
                          child: Center(
                            child: Container(
                              margin: const EdgeInsets.only(top: 12, bottom: 8),
                              width: 60,
                              height: 6,
                              decoration: BoxDecoration(
                                color: Colors.grey[400],
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                        // --- BAŞLIK ---
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  "Eklenen Duraklar (${stops.length})",
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                    color: Colors.black87,
                                  ),
                                ),
                                const Spacer(),
                              ],
                            ),
                          ),
                        ),
                        // --- LİSTE ---
                        SliverList(
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final stop = stops[index];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 4,
                              ),
                              leading: CircleAvatar(
                                backgroundColor: Colors.blue.shade50,
                                foregroundColor: Colors.blue.shade700,
                                child: Text(
                                  "${index + 1}",
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Text(
                                stop.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  color: Colors.redAccent,
                                ),
                                onPressed: () {
                                  setState(() {
                                    markers.removeWhere(
                                      (m) => m.markerId.value == stop.name,
                                    );
                                    stops.removeAt(index);
                                    polylines.clear();
                                    lastRouteInfo = null; // Rotayı sıfırla
                                  });
                                },
                              ),
                            );
                          }, childCount: stops.length),
                        ),

                        // --- DÜZELTME 2: ALT BOŞLUK (PADDING) ---
                        // Eğer rota varsa panel için çok boşluk bırak (250px)
                        // Yoksa sadece buton için az boşluk bırak (100px)
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: lastRouteInfo != null ? 250 : 100,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // --- HESAPLA BUTONU (Sadece Rota Yokken Görünür) ---
                  if (lastRouteInfo == null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.white,
                              Colors.white.withOpacity(0.9),
                              Colors.white.withOpacity(0.0),
                            ],
                            stops: const [0.0, 0.6, 1.0],
                          ),
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueAccent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                              elevation: 4,
                              shadowColor: Colors.blueAccent.withOpacity(0.4),
                            ),
                            onPressed: stops.length >= 2
                                ? () {
                                    showModalBottomSheet(
                                      context: context,
                                      shape: const RoundedRectangleBorder(
                                        borderRadius: BorderRadius.vertical(
                                          top: Radius.circular(20),
                                        ),
                                      ),
                                      builder: (_) => Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Text(
                                              "Ulaşım Yöntemi Seçin",
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 20),
                                            _buildTransportButton(
                                              icon: Icons.directions_car,
                                              label: "Araç ile Optimize Et",
                                              color: Colors.blue,
                                              onTap: () {
                                                Navigator.pop(context);
                                                setState(
                                                  () => currentMode = 'driving',
                                                );
                                                _optimizeAndDrawRoute(
                                                  'driving',
                                                );
                                              },
                                            ),
                                            const SizedBox(height: 12),
                                            _buildTransportButton(
                                              icon: Icons.directions_walk,
                                              label: "Yaya Olarak Optimize Et",
                                              color: Colors.green,
                                              onTap: () {
                                                Navigator.pop(context);
                                                setState(
                                                  () => currentMode = 'walking',
                                                );
                                                _optimizeAndDrawRoute(
                                                  'walking',
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }
                                : null,
                            icon: const Icon(
                              Icons.directions,
                              color: Colors.white,
                            ),
                            label: Text(
                              stops.length < 2
                                  ? "En az 2 durak ekleyin"
                                  : "Rotayı Hesapla",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),

          // -----------------------------------------------------------
          // ALT PANEL: ROTA İŞLEMLERİ (DÜZELTİLMİŞ BOYUTLAR)
          // -----------------------------------------------------------
          if (lastRouteInfo != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 30),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black12,
                      blurRadius: 10,
                      spreadRadius: 2,
                      offset: Offset(0, -2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Rota Özeti
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          lastRouteInfo!['duration_text'],
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          "(${lastRouteInfo!['distance_text']})",
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.grey,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // --- BUTON GRUBU ---
                    Row(
                      children: [
                        // 1. TEMİZLE (Genişletildi: flex 3)
                        Expanded(
                          flex: 3,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.grey.shade200,
                              foregroundColor: Colors.red,
                              elevation: 0,
                              // Dikey boşluğu biraz azalttık ki sığsın
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _clearRoute,
                            icon: const Icon(
                              Icons.close,
                              size: 20,
                            ), // İkon boyutu sabitlendi
                            label: const Text(
                              "Temizle",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1, // Alt satıra geçmesin
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(
                          width: 8,
                        ), // Aradaki boşluk biraz kısıldı
                        // 2. TARİF (Eşitlendi: flex 3)
                        Expanded(
                          flex: 3,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue.shade50,
                              foregroundColor: Colors.blue.shade800,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => RouteDirectionsScreen(
                                    duration: lastRouteInfo!['duration_text'],
                                    distance: lastRouteInfo!['distance_text'],
                                    steps: lastRouteInfo!['steps'],
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.format_list_bulleted,
                              size: 20,
                            ),
                            label: const Text(
                              "Tarif",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),

                        // 3. BAŞLAT (En Geniş: flex 4)
                        Expanded(
                          flex: 4,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueAccent,
                              foregroundColor: Colors.white,
                              elevation: 4,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _startGoogleMapsNavigation,
                            icon: const Icon(Icons.navigation, size: 20),
                            label: const Text(
                              "Başlat",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // --- ÖZEL MARKER OLUŞTURUCU (Mavi Yuvarlak + Sayı) ---
  Future<BitmapDescriptor> _createCustomMarkerBitmap(String text) async {
    // 1. Çizim alanı oluştur (Canvas)
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    const int size = 100; // Marker'ın boyutu (Piksel cinsinden)

    // 2. Mavi Daireyi Çiz
    final Paint paint = Paint()..color = Colors.blueAccent;
    final double radius = size / 2;
    canvas.drawCircle(Offset(radius, radius), radius, paint);

    // 3. İçine Beyaz Sayıyı Yaz
    TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
    painter.text = TextSpan(
      text: text,
      style: const TextStyle(
        fontSize: 50.0, // Yazı büyüklüğü
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
    );
    painter.layout();

    // Yazıyı tam ortaya hizala
    painter.paint(
      canvas,
      Offset((size - painter.width) / 2, (size - painter.height) / 2),
    );

    // 4. Resmi BitmapDescriptor'a çevir
    final ui.Image img = await pictureRecorder.endRecording().toImage(
      size,
      size,
    );
    final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
  }

  // --- HARİTA MARKERLARINI GÜNCELLEYEN FONKSİYON ---
  void _updateMapMarkers() {
    setState(() {
      // 1. Önce haritadaki "Yer" markerlarını temizle (Konum ve Rota durakları kalsın)
      markers.removeWhere((m) {
        // 'current_pos' (konumum) veya rotaya eklenmiş duraklar (stops) SİLİNMESİN.
        bool isStop = stops.any((s) => s.name == m.markerId.value);
        bool isUserPos =
            m.markerId.value == "current_pos" ||
            m.markerId.value == "current_pos_start";
        bool isManual = m.markerId.value.startsWith("manual_");

        // Bunların dışındakileri (yani turuncu/yeşil yerleri) sil
        return !isStop && !isUserPos && !isManual;
      });

      // 2. Eğer mod kapalıysa (nearby places gizliyse) fonksiyondan çık, çizim yapma
      if (!areNearbyPlacesVisible) return;

      // 3. Listeyi Tara ve Markerları Ekle
      for (var p in nearbyPlacesRawData) {
        final name = p['name'];

        // Müzekart kontrolü
        bool isPassValid = checkIfMuseumPassValid(name);

        // --- FİLTRE KONTROLÜ ---
        // Eğer filtre açıksa VE burası Müzekartlı değilse -> ATLAMA YAP (Gösterme)
        if (isMapFilterActive && !isPassValid) continue;

        // Marker Rengi
        final markerHue = isPassValid
            ? BitmapDescriptor.hueGreen
            : BitmapDescriptor.hueOrange;
        final snippetText = isPassValid
            ? "✅ Müzekart Geçerli! Ekle"
            : "Detaylar için tıkla";

        final loc = p['geometry']['location'];
        final placeId = p['place_id'];

        markers.add(
          Marker(
            markerId: MarkerId(placeId),
            position: LatLng(loc['lat'], loc['lng']),
            icon: BitmapDescriptor.defaultMarkerWithHue(markerHue),
            infoWindow: InfoWindow(
              title: name,
              snippet: snippetText,
              onTap: () async {
                final bool? shouldAdd = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PlaceDetailsScreen(
                      placeId: placeId,
                      placeName: name,
                      apiKey: googleApiKey,
                      location: LatLng(loc['lat'], loc['lng']),
                    ),
                  ),
                );
                if (shouldAdd == true) {
                  _safeAddStop(name, LatLng(loc['lat'], loc['lng']));
                }
              },
            ),
          ),
        );
      }
    });
  }

  // --- GOOGLE MAPS CANLI SÜRÜŞÜNÜ BAŞLATAN FONKSİYON (MOD DÜZELTİLDİ) ---
  Future<void> _startGoogleMapsNavigation() async {
    if (stops.length < 2) return;

    // 1. Koordinatları al
    final origin =
        "${stops.first.location.latitude},${stops.first.location.longitude}";
    final destination =
        "${stops.last.location.latitude},${stops.last.location.longitude}";

    // 2. Ara durakları hazırla
    String waypointsParam = "";
    if (stops.length > 2) {
      final waypointsList = stops
          .sublist(1, stops.length - 1)
          .map((w) => "${w.location.latitude},${w.location.longitude}")
          .join("|");
      waypointsParam = "&waypoints=$waypointsList";
    }

    // 3. MODU BELİRLE (ÖNEMLİ KISIM)
    // Senin uygulandaki 'walking' modunu Google Maps'in anlayacağı dile çeviriyoruz.
    String mapMode = 'driving';
    if (currentMode == 'walking') {
      mapMode = 'walking';
    }

    // 4. Linki Oluştur
    // travelmode: Ulaşım türü (driving/walking)
    // dir_action=navigate: Navigasyonu otomatik başlat
    final String urlString =
        "https://www.google.com/maps/dir/?api=1&origin=$origin&destination=$destination$waypointsParam&travelmode=$mapMode&dir_action=navigate";

    final Uri googleMapsUrl = Uri.parse(urlString);

    // 5. Aç
    try {
      if (!await launchUrl(
        googleMapsUrl,
        mode: LaunchMode.externalApplication,
      )) {
        throw 'Could not launch maps';
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Haritalar uygulaması açılamadı.")),
        );
      }
    }
  }
}

// ==========================================
// GÜNCELLENMİŞ DETAY EKRANI (MÜZEKART YÖNLENDİRMELİ)
// ==========================================

class PlaceDetailsScreen extends StatelessWidget {
  final String placeId;
  final String placeName;
  final String apiKey;
  final LatLng location;

  const PlaceDetailsScreen({
    super.key,
    required this.placeId,
    required this.placeName,
    required this.apiKey,
    required this.location,
  });

  Future<Map<String, dynamic>?> _getPlaceDetails() async {
    if (placeId.startsWith('json_')) {
      return {
        'formatted_address': 'Konum haritada işaretlendi.',
        'rating': 'Görülmeye Değer',
        'formatted_phone_number': '-',
        'website': 'Web sitesi yok',
        'photos': [],
      };
    }
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&fields=formatted_address,rating,formatted_phone_number,website,photos&key=$apiKey',
    );
    try {
      final response = await http.get(url);
      if (response.statusCode == 200)
        return json.decode(response.body)['result'];
    } catch (e) {
      print("Detay hatası: $e");
    }
    return null;
  }

  String? _getPhotoUrl(List<dynamic>? photos) {
    if (photos == null || photos.isEmpty) return null;
    return 'https://maps.googleapis.com/maps/api/place/photo?maxwidth=600&photo_reference=${photos[0]['photo_reference']}&key=$apiKey';
  }

  // --- MÜZEKART UYGULAMASINI AÇAN FONKSİYON (DÜZELTİLDİ) ---
  // --- AKILLI MÜZEKART YÖNLENDİRMESİ ---
  Future<void> _openMuzeKartApp() async {
    // Bu tek satırlık kod şunu yapar:
    // 1. Telefonda 'com.mas.muze' yüklü mü bakar.
    // 2. Yüklüyse DİREKT UYGULAMAYI AÇAR.
    // 3. Yüklü değilse PLAY STORE sayfasına götürür.

    await LaunchApp.openApp(
      androidPackageName: 'com.muzekart.app',
      openStore: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Sayfa açılırken Müzekart geçerli mi kontrol et
    bool isMuseumPassValid = checkIfMuseumPassValid(placeName);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Container(
          margin: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white54,
            borderRadius: BorderRadius.circular(20),
          ),
          child: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.black),
            onPressed: () => Navigator.pop(context),
          ),
        ),
      ),
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _getPlaceDetails(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting)
            return const Center(child: CircularProgressIndicator());

          final details = snapshot.data ?? {};
          final photoUrl = _getPhotoUrl(details['photos']);

          return Column(
            children: [
              // ÜST FOTOĞRAF ALANI
              Expanded(
                flex: 2,
                child: photoUrl != null
                    ? Image.network(
                        photoUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (ctx, err, stack) => Container(
                          color: Colors.grey[300],
                          child: const Icon(Icons.image_not_supported),
                        ),
                      )
                    : Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.image_not_supported),
                      ),
              ),

              // DETAY ALANI
              Expanded(
                flex: 3,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(30),
                    ),
                    boxShadow: [
                      BoxShadow(color: Colors.black26, blurRadius: 10),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // BAŞLIK
                      Text(
                        placeName,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ADRES
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.location_on,
                            color: Colors.grey,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              "${details['formatted_address'] ?? '-'}",
                              style: const TextStyle(color: Colors.black87),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // PUAN
                      Row(
                        children: [
                          const Icon(Icons.star, color: Colors.amber, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            "Puan: ${details['rating'] ?? '-'}",
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 20),

                      // --- YENİ EKLENEN KISIM: MÜZEKART YÖNLENDİRMESİ ---
                      if (isMuseumPassValid)
                        InkWell(
                          onTap:
                              _openMuzeKartApp, // Tıklayınca Play Store'a git
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.green.shade50, // Açık yeşil zemin
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.green),
                            ),
                            child: Row(
                              children: [
                                Image.network(
                                  // Resmi Müzekart logosu (veya benzeri)
                                  'https://play-lh.googleusercontent.com/9CWA7rCgq8XGvBwXkC7vC7x6y5yKzJvE8o_Hk1g_Xk5x_C5_x_X_X_X.png',
                                  // Not: Logo linki kırılırsa Icon kullanacağız, aşağıda yedeği var.
                                  width: 40,
                                  height: 40,
                                  errorBuilder: (c, e, s) => const Icon(
                                    Icons.card_membership,
                                    color: Colors.green,
                                    size: 40,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: const [
                                      Text(
                                        "Müzekart Burada Geçerli!",
                                        style: TextStyle(
                                          color: Colors.green,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                      Text(
                                        "Uygulamaya gitmek için dokun",
                                        style: TextStyle(
                                          color: Colors.black54,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(
                                  Icons.arrow_forward_ios,
                                  size: 16,
                                  color: Colors.green,
                                ),
                              ],
                            ),
                          ),
                        ),

                      // ----------------------------------------------------
                      const Spacer(),

                      // ROTAYA EKLE BUTONU
                      SizedBox(
                        width: double.infinity,
                        height: 55,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(15),
                            ),
                          ),
                          onPressed: () => Navigator.pop(context, true),
                          icon: const Icon(
                            Icons.add_location_alt_outlined,
                            color: Colors.white,
                          ),
                          label: const Text(
                            "ROTAYA EKLE",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class RouteDirectionsScreen extends StatelessWidget {
  final String duration;
  final String distance;
  final List<String> steps;
  const RouteDirectionsScreen({
    super.key,
    required this.duration,
    required this.distance,
    required this.steps,
  });
  String _removeHtmlTags(String htmlString) => htmlString.replaceAll(
    RegExp(r"<[^>]*>", multiLine: true, caseSensitive: true),
    '',
  );
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Yol Tarifi"),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Container(
            color: Colors.blue.shade50,
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                Column(
                  children: [
                    const Icon(Icons.timer, color: Colors.blue, size: 30),
                    Text(
                      duration,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text("Toplam Süre"),
                  ],
                ),
                Container(height: 40, width: 1, color: Colors.grey),
                Column(
                  children: [
                    const Icon(Icons.timeline, color: Colors.green, size: 30),
                    Text(
                      distance,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text("Toplam Mesafe"),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: steps.length,
              separatorBuilder: (context, index) => const Divider(),
              itemBuilder: (context, index) => ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.blue,
                  radius: 14,
                  child: Text(
                    "${index + 1}",
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
                title: Text(
                  _removeHtmlTags(steps[index]),
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CityData {
  final String name;
  final String description;
  final String imageUrl;
  final List<PlaceInfo> placesToVisit;
  CityData({
    required this.name,
    required this.description,
    required this.imageUrl,
    required this.placesToVisit,
  });
  factory CityData.fromJson(Map<String, dynamic> json) {
    return CityData(
      name: json['name'] ?? '',
      description: json['description'] ?? '',
      imageUrl: json['imageUrl'] ?? '',
      placesToVisit: (json['placesToVisit'] as List)
          .map((i) => PlaceInfo.fromJson(i))
          .toList(),
    );
  }
}

class PlaceInfo {
  final String name;
  final double lat;
  final double lng;
  PlaceInfo({required this.name, required this.lat, required this.lng});
  factory PlaceInfo.fromJson(Map<String, dynamic> json) => PlaceInfo(
    name: json['name'] ?? '',
    lat: (json['lat'] as num).toDouble(),
    lng: (json['lng'] as num).toDouble(),
  );
}

class CityGuideScreen extends StatefulWidget {
  const CityGuideScreen({super.key});
  @override
  State<CityGuideScreen> createState() => _CityGuideScreenState();
}

class _CityGuideScreenState extends State<CityGuideScreen> {
  List<CityData> allCities = [];
  List<CityData> filteredCities = [];
  TextEditingController searchController = TextEditingController();
  bool isLoading = true;

  // --- YENİ: FİLTRE ANAHTARI ---
  bool showOnlyMuseumPass = false;

  @override
  void initState() {
    super.initState();
    _loadCitiesData();
  }

  Future<void> _loadCitiesData() async {
    try {
      final String response = await rootBundle.loadString('assets/cities.json');
      final List<dynamic> data = json.decode(response);
      setState(() {
        allCities = data.map((json) => CityData.fromJson(json)).toList();
        allCities.sort((a, b) => a.name.compareTo(b.name));
        _applyFilter(); // Yüklenince filtreyi çalıştır
        isLoading = false;
      });
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  // --- GELİŞMİŞ FİLTRELEME MANTIĞI ---
  void _applyFilter() {
    String query = searchController.text.toLowerCase();

    setState(() {
      filteredCities = allCities.where((city) {
        // 1. İsim Araması
        bool matchesName = city.name.toLowerCase().contains(query);

        // 2. Müzekart Filtresi
        bool matchesMuseumPass = true;
        if (showOnlyMuseumPass) {
          // Şehrin içindeki yerlerden EN AZ BİRİ Müzekart listesinde mi?
          // museum_data.dart dosyasındaki fonksiyonu kullanıyoruz.
          matchesMuseumPass = city.placesToVisit.any(
            (place) => checkIfMuseumPassValid(place.name),
          );
        }

        return matchesName && matchesMuseumPass;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Türkiye Şehir Rehberi"),
        backgroundColor: Colors.redAccent,
        foregroundColor: Colors.white,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // --- ARAMA VE FİLTRE PANELİ ---
                Container(
                  padding: const EdgeInsets.all(16.0),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 10,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: searchController,
                        onChanged: (val) => _applyFilter(),
                        decoration: InputDecoration(
                          hintText: "Şehir Ara",
                          prefixIcon: const Icon(Icons.search),
                          filled: true,
                          fillColor: Colors.grey.shade100,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // --- FİLTRE SWITCH ---
                      Row(
                        children: [
                          const Icon(
                            Icons.card_membership,
                            color: Colors.green,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            "Sadece Müzekart Geçenler",
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const Spacer(),
                          Switch(
                            value: showOnlyMuseumPass,
                            activeColor: Colors.green,
                            onChanged: (val) {
                              setState(() {
                                showOnlyMuseumPass = val;
                                _applyFilter();
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // --- LİSTE ---
                Expanded(
                  child: ListView.builder(
                    itemCount: filteredCities.length,
                    itemBuilder: (context, index) {
                      final city = filteredCities[index];

                      // Şehirdeki müzekartlı yer sayısını hesaplayalım
                      int museumCount = city.placesToVisit
                          .where((p) => checkIfMuseumPassValid(p.name))
                          .length;

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(10),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: city.imageUrl.isNotEmpty
                                ? (city.imageUrl.startsWith('http')
                                      ? Image.network(
                                          city.imageUrl,
                                          width: 60,
                                          height: 60,
                                          fit: BoxFit.cover,
                                          errorBuilder: (ctx, err, stack) =>
                                              const Icon(Icons.error),
                                        )
                                      : Image.asset(
                                          city.imageUrl,
                                          width: 60,
                                          height: 60,
                                          fit: BoxFit.cover,
                                          errorBuilder: (ctx, err, stack) =>
                                              const Icon(Icons.error),
                                        ))
                                : Container(
                                    width: 60,
                                    height: 60,
                                    color: Colors.red.shade100,
                                    child: Center(
                                      child: Text(city.name.substring(0, 1)),
                                    ),
                                  ),
                          ),
                          title: Text(
                            city.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                city.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              // Eğer filtre açıksa veya şehirde müzekartlı yer varsa göster
                              if (museumCount > 0)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4.0),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.verified,
                                        size: 14,
                                        color: Colors.green,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        "$museumCount Müzekart Noktası",
                                        style: const TextStyle(
                                          color: Colors.green,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          trailing: const Icon(
                            Icons.arrow_forward_ios,
                            size: 16,
                          ),
                          onTap: () async {
                            final result = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    CityGuideDetailScreen(city: city),
                              ),
                            );
                            if (result != null && mounted)
                              Navigator.pop(context, result);
                          },
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

class CityGuideDetailScreen extends StatelessWidget {
  final CityData city;
  const CityGuideDetailScreen({super.key, required this.city});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          List<Map<String, dynamic>> placesData = city.placesToVisit
              .map(
                (place) => {
                  'name': place.name,
                  'lat': place.lat,
                  'lng': place.lng,
                  'place_id': 'json_${place.name}',
                },
              )
              .toList();
          Navigator.pop(context, {'foundPlaces': placesData});
        },
        label: const Text("Haritada Göster"),
        icon: const Icon(Icons.map),
        backgroundColor: Colors.blueAccent,
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 250.0,
            pinned: true,
            backgroundColor: Colors.redAccent,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                city.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(color: Colors.black, blurRadius: 10)],
                ),
              ),
              background: city.imageUrl.isNotEmpty
                  ? (city.imageUrl.startsWith('http')
                        ? Image.network(city.imageUrl, fit: BoxFit.cover)
                        : Image.asset(city.imageUrl, fit: BoxFit.cover))
                  : Container(color: Colors.redAccent),
            ),
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Şehir Hakkında",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      city.description,
                      style: const TextStyle(fontSize: 16),
                    ),
                    const Divider(height: 30),
                    Row(
                      children: const [
                        Icon(Icons.camera_alt, color: Colors.blue),
                        SizedBox(width: 8),
                        Text(
                          "Gezilecek Yerler",
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ...city.placesToVisit.map((place) {
                      // Buradaki her yer için kontrol yapıyoruz
                      bool hasPass = checkIfMuseumPassValid(place.name);

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.place,
                              size: 20,
                              color: Colors.redAccent,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    place.name,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),

                                  // --- ROZET KISMI ---
                                  if (hasPass)
                                    Container(
                                      margin: const EdgeInsets.only(top: 4),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.green.shade50,
                                        border: Border.all(color: Colors.green),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: const [
                                          Icon(
                                            Icons.verified,
                                            size: 12,
                                            color: Colors.green,
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            "Müzekart Geçerli",
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.green,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  // -------------------
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 80),
                  ],
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class NearbyPlacesListScreen extends StatefulWidget {
  final LatLng userLocation;
  final String apiKey;

  const NearbyPlacesListScreen({
    super.key,
    required this.userLocation,
    required this.apiKey,
  });

  @override
  State<NearbyPlacesListScreen> createState() => _NearbyPlacesListScreenState();
}

class _NearbyPlacesListScreenState extends State<NearbyPlacesListScreen> {
  // Tüm yerler (filtresiz)
  List<dynamic> allPlaces = [];
  // Ekranda gösterilecek yerler (filtrelenmiş)
  List<dynamic> displayedPlaces = [];

  bool isLoading = true;
  bool showOnlyMuseumPass = false; // FİLTRE DEĞİŞKENİ

  @override
  void initState() {
    super.initState();
    _fetchNearbyPlaces();
  }

  Future<void> _fetchNearbyPlaces() async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
      '?location=${widget.userLocation.latitude},${widget.userLocation.longitude}'
      '&radius=5000'
      '&type=tourist_attraction'
      '&key=${widget.apiKey}',
    );

    try {
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);

        setState(() {
          // 1. Ham veriyi filtrele (Gereksizleri at)
          var rawResults = (data['results'] as List).where((p) {
            final types = (p['types'] as List).cast<String>();
            const excludedTypes = [
              'atm',
              'bank',
              'finance',
              'school',
              'hospital',
              'doctor',
              'dentist',
              'pharmacy',
              'gym',
              'spa',
              'gas_station',
              'parking',
              'store',
              'supermarket',
              'lodging',
              'hotel',
              'restaurant',
              'food',
              'local_government_office',
              'post_office',
              'police',
            ];
            return !types.any((t) => excludedTypes.contains(t));
          }).toList();

          // 2. MÜZEKART KONTROLÜ VE VERİ HAZIRLAMA
          allPlaces = rawResults.map((place) {
            final name = place['name'].toString();

            // museum_data.dart içindeki fonksiyonu çağırıyoruz
            bool isOfficialMuseum = checkIfMuseumPassValid(name);

            // Ayrıca Google "Museum" dediyse de şans verelim
            final types = (place['types'] as List).cast<String>();
            bool isGoogleTypeMuseum = types.contains('museum');

            // Müzekart geçerli mi?
            place['isMuseumPassLikely'] =
                isOfficialMuseum || isGoogleTypeMuseum;

            return place;
          }).toList();

          // İlk açılışta hepsini göster
          displayedPlaces = List.from(allPlaces);
          isLoading = false;
        });
      }
    } catch (e) {
      setState(() => isLoading = false);
    }
  }

  // Filtre Switch'i değişince çalışır
  void _applyFilter() {
    setState(() {
      if (showOnlyMuseumPass) {
        // Sadece müzekartlı olanları al
        displayedPlaces = allPlaces
            .where((p) => p['isMuseumPassLikely'] == true)
            .toList();
      } else {
        // Hepsini göster
        displayedPlaces = List.from(allPlaces);
      }
    });
  }

  String? _getPhotoUrl(List<dynamic>? photos) {
    if (photos == null || photos.isEmpty) return null;
    final ref = photos[0]['photo_reference'];
    return 'https://maps.googleapis.com/maps/api/place/photo?maxwidth=200&photo_reference=$ref&key=${widget.apiKey}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Yakındaki Gezilecek Yerler"),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Column(
        // <--- BU COLUMN ÇOK ÖNEMLİ
        children: [
          // ==============================
          // --- FİLTRE PANELİ BAŞLANGIÇ ---
          // ==============================
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50, // Mavi arka plan
              border: Border(bottom: BorderSide(color: Colors.blue.shade200)),
            ),
            child: Row(
              children: [
                const Icon(Icons.card_membership, color: Colors.blue, size: 28),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    "Sadece Müzekart Geçenler",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                Switch(
                  value: showOnlyMuseumPass,
                  activeColor: Colors.green,
                  onChanged: (val) {
                    setState(() {
                      showOnlyMuseumPass = val;
                      _applyFilter(); // Filtreyi uygula
                    });
                  },
                ),
              ],
            ),
          ),
          // --- FİLTRE PANELİ BİTİŞ ---

          // LİSTE ALANI
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : displayedPlaces.isEmpty
                ? const Center(
                    child: Text(
                      "Gösterilecek yer bulunamadı.",
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: displayedPlaces.length,
                    itemBuilder: (context, index) {
                      final place = displayedPlaces[index];
                      final photoUrl = _getPhotoUrl(place['photos']);
                      final loc = place['geometry']['location'];

                      return Card(
                        elevation: 3,
                        margin: const EdgeInsets.only(bottom: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: InkWell(
                          onTap: () async {
                            final bool? shouldAdd = await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => PlaceDetailsScreen(
                                  placeId: place['place_id'],
                                  placeName: place['name'],
                                  apiKey: widget.apiKey,
                                  location: LatLng(loc['lat'], loc['lng']),
                                ),
                              ),
                            );

                            if (shouldAdd == true) {
                              Navigator.pop(context, {
                                'name': place['name'],
                                'lat': loc['lat'],
                                'lng': loc['lng'],
                              });
                            }
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(12),
                                ),
                                child: photoUrl != null
                                    ? Image.network(
                                        photoUrl,
                                        height: 150,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                        errorBuilder: (ctx, err, stack) =>
                                            Container(
                                              height: 150,
                                              color: Colors.grey[300],
                                              child: const Icon(
                                                Icons.image_not_supported,
                                              ),
                                            ),
                                      )
                                    : Container(
                                        height: 150,
                                        width: double.infinity,
                                        color: Colors.grey[200],
                                        child: const Icon(
                                          Icons.museum,
                                          size: 50,
                                          color: Colors.grey,
                                        ),
                                      ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      place['name'],
                                      style: const TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),

                                    // MÜZEKART ROZETİ (FİLTRELENMİŞ OLSA BİLE GÖSTERİR)
                                    if (place['isMuseumPassLikely'] == true)
                                      Container(
                                        margin: const EdgeInsets.only(
                                          top: 6,
                                          bottom: 4,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.green.shade50,
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          border: Border.all(
                                            color: Colors.green,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: const [
                                            Icon(
                                              Icons.verified,
                                              size: 14,
                                              color: Colors.green,
                                            ),
                                            SizedBox(width: 4),
                                            Text(
                                              "Müzekart Geçerli",
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.green,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                    const SizedBox(height: 6),
                                    Text(
                                      place['vicinity'] ?? "Adres yok",
                                      style: TextStyle(color: Colors.grey[600]),
                                    ),
                                  ],
                                ),
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

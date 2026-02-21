import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';

// ------------------------------------------------------------------
// DATA MODELS
// ------------------------------------------------------------------
class GraphNode {
  final int id;
  final LatLng point;
  GraphNode({required this.id, required this.point});
}

class GraphEdge {
  final int from;
  final int to;
  GraphEdge({required this.from, required this.to});
}

void main() => runApp(const CampusNavApp());

class CampusNavApp extends StatelessWidget {
  const CampusNavApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const CampusMapScreen(),
    );
  }
}

// FIXED: Added missing createState implementation
class CampusMapScreen extends StatefulWidget {
  const CampusMapScreen({super.key});

  @override
  State<CampusMapScreen> createState() => _CampusMapScreenState();
}

class _CampusMapScreenState extends State<CampusMapScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  StreamSubscription<Position>? _positionStream;

  // Data
  List<dynamic> _destinations = [];
  List<dynamic> _filteredDestinations = [];
  Map<int, GraphNode> _graphNodes = {};
  List<GraphEdge> _graphEdges = [];

  // State
  LatLng? _userPos;
  dynamic _selectedDestination;
  List<LatLng> _routePoints = [];
  
  bool _isNavigating = false;
  bool _showSearchResults = false;
  double _remainingDist = 0;
  int _etaMinutes = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
    _startLiveTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      String destString = await rootBundle.loadString('assets/campus_location.json');
      _destinations = json.decode(destString);
      _filteredDestinations = _destinations;

      String pathString = await rootBundle.loadString('assets/campus_path.json');
      final pathData = json.decode(pathString);
      
      Map<int, GraphNode> tempNodes = {};
      for (var n in pathData['nodes']) {
        tempNodes[n['id']] = GraphNode(id: n['id'], point: LatLng(n['lat'], n['lng']));
      }

      List<GraphEdge> tempEdges = [];
      for (var e in pathData['edges']) {
        tempEdges.add(GraphEdge(from: e['from'], to: e['to']));
      }

      setState(() {
        _graphNodes = tempNodes;
        _graphEdges = tempEdges;
      });
    } catch (e) {
      debugPrint("Load Error: $e");
    }
  }

  void _startLiveTracking() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 2),
    ).listen((pos) {
      LatLng newLoc = LatLng(pos.latitude, pos.longitude);
      setState(() { _userPos = newLoc; });

      if (_isNavigating && _routePoints.isNotEmpty) {
        _updateNavigationLogic(newLoc);
      }
    });
  }

  void _updateNavigationLogic(LatLng newLoc) {
    const Distance distanceCalc = Distance();
    
    if (_routePoints.length > 1) {
      double distToNext = distanceCalc.as(LengthUnit.Meter, newLoc, _routePoints[1]);
      if (distToNext < 7) {
        setState(() { _routePoints.removeAt(0); });
      }
    }

    double distToCurrentTarget = distanceCalc.as(LengthUnit.Meter, newLoc, _routePoints[0]);
    if (distToCurrentTarget > 30) {
      _calculateRoute(LatLng(_selectedDestination['lat'], _selectedDestination['lng']), _selectedDestination);
    }

    double total = 0;
    for (int i = 0; i < _routePoints.length - 1; i++) {
      total += distanceCalc.as(LengthUnit.Meter, _routePoints[i], _routePoints[i+1]);
    }
    setState(() {
      _remainingDist = total;
      _etaMinutes = (total / 1.4 / 60).ceil();
    });
  }

  void _calculateRoute(LatLng target, dynamic destObj) {
    if (_userPos == null) return;

    // 1. Find the nearest "Road Entry" node to your current position
    int startId = _findNearestNodeId(_userPos!);
    
    // 2. Find the nearest "Road Exit" node to the selected department
    int endId = _findNearestNodeId(target);
    
    // 3. Get the list of nodes that strictly follow your campus road edges
    List<LatLng> path = _findShortestPath(startId, endId);

    if (path.isEmpty) {
      setState(() {
        _selectedDestination = destObj;
        _routePoints = []; 
      });
      // Move camera to destination even if path fails
      _mapController.move(target, 18);
      return;
    }

    setState(() {
      _selectedDestination = destObj;
      
      // FIXED: We no longer add [_userPos!] at the beginning or [target] at the end.
      // This forces the blue line to stay locked onto your JSON road nodes ONLY.
      _routePoints = path; 
      
      _isNavigating = true;
      _showSearchResults = false;
      _searchController.clear();
    });

    // Move camera to the start of the actual road network path
    _mapController.move(path.first, 18);
  }
  void _stopNavigation() {
    setState(() {
      _isNavigating = false;
      _routePoints.clear();
      _selectedDestination = null;
    });
  }

  int _findNearestNodeId(LatLng point) {
    int closestId = -1;
    double minD = double.infinity;
    const Distance dist = Distance();
    _graphNodes.forEach((id, node) {
      double d = dist.as(LengthUnit.Meter, point, node.point);
      if (d < minD) { minD = d; closestId = id; }
    });
    return closestId;
  }

  List<LatLng> _findShortestPath(int startId, int endId) {
    if (startId == endId) return [_graphNodes[startId]!.point];
    Map<int, Map<int, double>> adj = {};
    const Distance dCalc = Distance();
    for (var id in _graphNodes.keys) { adj[id] = {}; }
    for (var e in _graphEdges) {
      if (_graphNodes.containsKey(e.from) && _graphNodes.containsKey(e.to)) {
        double d = dCalc.as(LengthUnit.Meter, _graphNodes[e.from]!.point, _graphNodes[e.to]!.point);
        adj[e.from]![e.to] = d; adj[e.to]![e.from] = d;
      }
    }
    Map<int, double> dists = {for (var id in _graphNodes.keys) id: double.infinity};
    Map<int, int?> prev = {for (var id in _graphNodes.keys) id: null};
    List<int> q = _graphNodes.keys.toList();
    dists[startId] = 0;
    while (q.isNotEmpty) {
      q.sort((a, b) => dists[a]!.compareTo(dists[b]!));
      int curr = q.removeAt(0);
      if (curr == endId) {
        List<LatLng> p = []; int? temp = endId;
        while (temp != null) { p.insert(0, _graphNodes[temp]!.point); temp = prev[temp]; }
        return p;
      }
      if (dists[curr] == double.infinity) break;
      adj[curr]!.forEach((nb, w) {
        double alt = dists[curr]! + w;
        if (alt < dists[nb]!) { dists[nb] = alt; prev[nb] = curr; }
      });
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _userPos ?? const LatLng(21.0684, 73.1315),
              initialZoom: 18,
            ),
            children: [
              TileLayer(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png"),
              
              // GOOGLE MAPS STYLE PATH
              if (_routePoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 7.0,
                      color: Colors.blue.withOpacity(0.85),
                      borderStrokeWidth: 2.5,
                      borderColor: const Color(0xFF1A5A96),
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                    ),
                  ],
                ),
                
              MarkerLayer(
                markers: [
                  if (_userPos != null)
                    Marker(
                      point: _userPos!,
                      width: 45, height: 45,
                      child: const Icon(Icons.navigation, color: Colors.blue, size: 35),
                    ),
                  if (_selectedDestination != null)
                    Marker(
                      point: LatLng(_selectedDestination['lat'], _selectedDestination['lng']), 
                      width: 45, height: 45,
                      child: const Icon(Icons.location_on, color: Colors.red, size: 45),
                    ),
                ],
              ),
            ],
          ),

          // SEARCH BAR (UI from reference)
          Positioned(
            top: 50, left: 16, right: 16,
            child: Column(
              children: [
                Material(
                  elevation: 6, borderRadius: BorderRadius.circular(30),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() {
                      _showSearchResults = v.isNotEmpty;
                      _filteredDestinations = _destinations.where((d) => 
                        d['name'].toString().toLowerCase().contains(v.toLowerCase())).toList();
                    }),
                    decoration: const InputDecoration(
                      hintText: "Search destination", prefixIcon: Icon(Icons.search),
                      border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_showSearchResults)
                  Card(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: ListView.builder(
                        shrinkWrap: true, itemCount: _filteredDestinations.length,
                        itemBuilder: (context, i) => ListTile(
                          title: Text(_filteredDestinations[i]['name']),
                          onTap: () => _calculateRoute(LatLng(_filteredDestinations[i]['lat'], _filteredDestinations[i]['lng']), _filteredDestinations[i]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // INFO BAR (UI from reference)
          if (_isNavigating)
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: Container(
                height: 100, padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                child: Row(
                  children: [
                    const Icon(Icons.directions_walk, size: 40, color: Colors.blue),
                    const SizedBox(width: 15),
                    Expanded(child: Text(_selectedDestination['name'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text("${_remainingDist.toStringAsFixed(0)} m", style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                        Text("$_etaMinutes min", style: const TextStyle(color: Colors.grey)),
                      ],
                    ),
                    const SizedBox(width: 15),
                    IconButton(onPressed: _stopNavigation, icon: const Icon(Icons.cancel, color: Colors.red, size: 35)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
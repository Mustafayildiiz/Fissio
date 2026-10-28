import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const FissioApp());
}

/// Android emülatöründe host makine 10.0.2.2 adresidir.
String get _host => (!kIsWeb && Platform.isAndroid) ? '10.0.2.2' : 'localhost';

class FissioApp extends StatelessWidget {
  const FissioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fissio',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const HealthPage(),
    );
  }
}

class HealthPage extends StatefulWidget {
  const HealthPage({super.key});

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> {
  final Map<String, String> _status = {};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<String> _ping(int port) async {
    try {
      final r = await http
          .get(Uri.parse('http://$_host:$port/health'))
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200 ? 'OK' : 'HATA (${r.statusCode})';
    } catch (_) {
      return 'Ulaşılamıyor';
    }
  }

  Future<void> _check() async {
    setState(() => _loading = true);
    final auth = await _ping(8081);
    final expense = await _ping(8082);
    if (!mounted) return;
    setState(() {
      _status['Auth Service'] = auth;
      _status['Expense Service'] = expense;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Fissio')),
      body: ListView(
        children: [
          for (final e in _status.entries)
            ListTile(
              leading: Icon(
                e.value == 'OK' ? Icons.check_circle : Icons.error,
                color: e.value == 'OK' ? Colors.green : Colors.red,
              ),
              title: Text(e.key),
              subtitle: Text(e.value),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loading ? null : _check,
        child: _loading
            ? const CircularProgressIndicator()
            : const Icon(Icons.refresh),
      ),
    );
  }
}

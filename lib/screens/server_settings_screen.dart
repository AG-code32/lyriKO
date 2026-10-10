import 'package:flutter/material.dart';

import '../services/lyriko_server_client.dart';

class ServerSettingsScreen extends StatefulWidget {
  const ServerSettingsScreen({super.key});

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  final _client = LyrikoServerClient();
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _busy = true;
  bool _hasToken = false;
  bool _showToken = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final url = await _client.getBaseUrl();
      final stored = await _client.hasStoredToken();
      if (!mounted) return;
      _urlController.text = url;
      setState(() { _hasToken = stored; _busy = false; });
    } catch (e) {
      if (mounted) setState(() { _busy = false; _result = '$e'; });
    }
  }

  Future<void> _saveAndTest() async {
    setState(() { _busy = true; _result = null; });
    try {
      await _client.saveSettings(
        url: _urlController.text,
        token: _tokenController.text.trim().isEmpty
            ? null : _tokenController.text.trim(),
      );
      _tokenController.clear();
      final songs = await _client.songs();
      if (!mounted) return;
      setState(() {
        _hasToken = true;
        _result = 'Conectado correctamente: ${songs.length} canciones.';
      });
    } catch (e) {
      if (mounted) setState(() { _result = 'No se pudo conectar: $e'; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('Servidor de Lyriko',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              const Text('La dirección del Quick Tunnel puede cambiar al reiniciar Windows. Actualízala aquí sin reinstalar la aplicación.'),
              const SizedBox(height: 24),
              TextField(
                controller: _urlController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'URL HTTPS del servidor',
                  hintText: 'https://ejemplo.trycloudflare.com',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _tokenController,
                autocorrect: false,
                obscureText: !_showToken,
                decoration: InputDecoration(
                  labelText: _hasToken
                      ? 'Nuevo token (dejar vacío para conservar el actual)'
                      : 'Token de acceso',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: _showToken ? 'Ocultar' : 'Mostrar',
                    icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => _showToken = !_showToken),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _saveAndTest,
                icon: const Icon(Icons.wifi_find),
                label: const Text('Guardar y probar conexión'),
              ),
              if (_busy) const Padding(
                padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
              if (_result != null) Padding(
                padding: const EdgeInsets.only(top: 20),
                child: SelectableText(_result!),
              ),
              const SizedBox(height: 24),
              const Text('La URL y la credencial se guardan en el almacenamiento seguro del dispositivo. Nunca pegues el token en GitHub ni lo compartas.'),
            ],
          ),
        ),
      ),
    );
  }
}

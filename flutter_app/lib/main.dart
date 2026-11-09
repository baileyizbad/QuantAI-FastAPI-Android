import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const _ink = Color(0xFF0B1220);
const _panel = Color(0xFF121D2E);
const _line = Color(0xFF25364D);
const _accent = Color(0xFF55D6A2);
const _systemPrompt = 'You are QuantAI, a precise quantitative research and Python engineering assistant. Explain mathematical assumptions and distinguish verified facts from hypotheses. Never claim to have run a backtest, accessed a broker, or placed an order unless a connected tool actually did so. Treat trading outputs as research, not financial guarantees. Identify look-ahead bias, survivorship bias, transaction costs, spread, slippage, financing, and out-of-sample validation where relevant.';
const _uuid = Uuid();

void main() => runApp(const QuantAiApp());

class ChatMessage {
  ChatMessage({required this.id, required this.role, required this.content, required this.createdAt, this.server, this.fallback = false});
  final String id;
  final String role;
  final String content;
  final DateTime createdAt;
  final String? server;
  final bool fallback;

  Map<String, Object?> toJson() => {
    'id': id, 'role': role, 'content': content,
    'createdAt': createdAt.toIso8601String(), 'server': server, 'fallback': fallback,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    role: json['role'] as String,
    content: json['content'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    server: json['server'] as String?,
    fallback: json['fallback'] as bool? ?? false,
  );
}

const _apiBaseUrl = 'http://127.0.0.1:8080';

class FastApiClient {
  const FastApiClient();

  Uri _uri(String path) => Uri.parse('$_apiBaseUrl$path');

  Map<String, String> get _headers => const {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Future<Map<String, dynamic>> health() async {
    final response = await http.get(_uri('/health'), headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) throw FastApiException('FastAPI health check failed (${response.statusCode}).');
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<ChatReply> send(List<ChatMessage> history) async {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': _systemPrompt},
      ...history.map((message) => {'role': message.role, 'content': message.content}),
    ];
    final response = await http.post(
      _uri('/v1/chat/completions'),
      headers: _headers,
      body: jsonEncode({'messages': messages, 'temperature': 0.35, 'max_tokens': 4096}),
    ).timeout(const Duration(seconds: 110));
    if (response.statusCode != 200) {
      String message = 'AI request failed (${response.statusCode}).';
      try {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        message = decoded['detail']?.toString() ?? message;
      } catch (_) {
        if (response.body.isNotEmpty) message = response.body.substring(0, response.body.length > 300 ? 300 : response.body.length);
      }
      throw FastApiException(message);
    }
    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final content = data['content'];
      if (content is! String || content.trim().isEmpty) throw FastApiException('The AI server returned an empty response.');
      return ChatReply(content, data['server']?.toString() ?? 'FastAPI', data['fallback_used'] == true);
    } on FormatException {
      throw FastApiException('FastAPI returned an invalid JSON response.');
    }
  }
}

class ChatReply {
  const ChatReply(this.content, this.server, this.fallback);
  final String content;
  final String server;
  final bool fallback;
}

class FastApiException implements Exception {
  FastApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class QuantAiApp extends StatelessWidget {
  const QuantAiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'QuantAI', debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark, scaffoldBackgroundColor: _ink,
      colorScheme: const ColorScheme.dark(primary: _accent, secondary: Color(0xFF72A7FF), surface: _panel),
      useMaterial3: true, fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(backgroundColor: _ink, surfaceTintColor: Colors.transparent),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: _panel, hintStyle: const TextStyle(color: Color(0xFF8092A9)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _accent)),
      ),
    ),
    home: const ChatHome(),
  );
}

class ChatHome extends StatefulWidget {
  const ChatHome({super.key});
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  bool _sending = false;
  bool _checking = false;
  bool _ready = false;
  String _apiStatus = 'Connecting to FastAPI';
  String _serverStatus = 'http://127.0.0.1:8080';
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('chat_history');
    if (saved != null) {
      try {
        final decoded = jsonDecode(saved) as List<dynamic>;
        _messages.addAll(decoded.map((item) => ChatMessage.fromJson(item as Map<String, dynamic>)));
      } catch (_) {
        await prefs.remove('chat_history');
      }
    }
    await prefs.remove('gateway_url');
    await prefs.remove('gateway_token');
    if (!mounted) return;
    setState(() => _ready = true);
    unawaited(_checkConnection());
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_history', jsonEncode(_messages.map((m) => m.toJson()).toList()));
  }

  FastApiClient get _client => const FastApiClient();

  Future<void> _checkConnection() async {
    if (_checking) return;
    setState(() { _checking = true; _error = null; });
    try {
      final health = await _client.health();
      if (!mounted) return;
      setState(() {
        _apiStatus = 'FastAPI online';
        final p = health['primary_configured'] == true ? 'Primary ready' : 'Primary not configured';
        final s = health['secondary_configured'] == true ? 'Secondary ready' : 'Secondary not configured';
        _serverStatus = '$p · $s';
      });
    } catch (error) {
      if (mounted) setState(() { _apiStatus = 'FastAPI offline'; _serverStatus = error.toString(); });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context, backgroundColor: _panel,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('FastAPI server', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          const SelectableText(_apiBaseUrl, style: TextStyle(color: _accent)),
          const SizedBox(height: 8),
          const Text('Fixed local endpoint. No configurable URL, app token, or app-level authorization is used.', style: TextStyle(color: Color(0xFF9AACC1), height: 1.4)),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: () { Navigator.pop(sheetContext); _checkConnection(); }, child: const Text('Check connection'))),
        ]),
      ),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    final user = ChatMessage(id: _uuid.v4(), role: 'user', content: text, createdAt: DateTime.now());
    setState(() { _messages.add(user); _sending = true; _error = null; });
    await _persist();
    _jumpToBottom();
    try {
      final reply = await _client.send(_messages.where((m) => m.role == 'user' || m.role == 'assistant').toList());
      final assistant = ChatMessage(id: _uuid.v4(), role: 'assistant', content: reply.content, createdAt: DateTime.now(), server: reply.server, fallback: reply.fallback);
      if (!mounted) return;
      setState(() => _messages.add(assistant));
      await _persist();
      _jumpToBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  Future<void> _newChat() async {
    if (_sending) return;
    setState(() { _messages.clear(); _error = null; });
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 18,
        title: Row(children: [
          Container(width: 38, height: 38, decoration: BoxDecoration(color: _accent.withValues(alpha: .13), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.auto_awesome, color: _accent)),
          const SizedBox(width: 11), const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('QuantAI', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)), Text('RESEARCH ASSISTANT', style: TextStyle(fontSize: 9, letterSpacing: 1.3, color: Color(0xFF8FA2BA))) ]),
        ]),
        actions: [IconButton(tooltip: 'New chat', onPressed: _newChat, icon: const Icon(Icons.add_comment_outlined)), IconButton(tooltip: 'Settings', onPressed: _openSettings, icon: const Icon(Icons.tune)), const SizedBox(width: 4)],
      ),
      body: SafeArea(child: Column(children: [
        _statusCard(),
        Expanded(child: _messages.isEmpty ? _welcome() : ListView.builder(
          controller: _scroll, padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
          itemCount: _messages.length + (_sending ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _messages.length) return const _TypingBubble();
            return _MessageBubble(message: _messages[index]);
          },
        )),
        if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 8), child: Container(width: double.infinity, padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF48232B), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF81404C))), child: Text(_error!, style: const TextStyle(color: Color(0xFFFFC3CB), fontSize: 12)))),
        _composer(),
      ])),
    );
  }

  Widget _statusCard() => Container(
    margin: const EdgeInsets.fromLTRB(14, 4, 14, 8), padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
    decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(14), border: Border.all(color: _line)),
    child: Row(children: [
      Icon(Icons.circle, size: 8, color: _apiStatus == 'FastAPI online' ? _accent : const Color(0xFFE3A85B)),
      const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_apiStatus, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)), Text(_serverStatus, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Color(0xFF8FA2BA)))])),
      IconButton(visualDensity: VisualDensity.compact, tooltip: 'Check servers', onPressed: _checking ? null : _checkConnection, icon: _checking ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh, size: 18)),
    ]),
  );

  Widget _welcome() => Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 76, height: 76, decoration: BoxDecoration(color: _accent.withValues(alpha: .10), borderRadius: BorderRadius.circular(24)), child: const Icon(Icons.query_stats, size: 38, color: _accent)),
    const SizedBox(height: 20), const Text('Quantitative intelligence.', textAlign: TextAlign.center, style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
    const SizedBox(height: 8), const Text('Ask about Python systems, market data, strategy research, backtesting, or risk models.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF9AACC1), height: 1.5)),
    const SizedBox(height: 22),
    _suggestion('Review my strategy architecture', Icons.account_tree_outlined),
    _suggestion('Explain a Kalman filter for market data', Icons.functions),
    _suggestion('Design a bias-resistant walk-forward test', Icons.fact_check_outlined),
  ])));

  Widget _suggestion(String text, IconData icon) => Padding(padding: const EdgeInsets.only(bottom: 9), child: InkWell(onTap: () { _input.text = text; _send(); }, borderRadius: BorderRadius.circular(13), child: Container(width: double.infinity, padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: _panel, border: Border.all(color: _line), borderRadius: BorderRadius.circular(13)), child: Row(children: [Icon(icon, color: _accent, size: 18), const SizedBox(width: 10), Expanded(child: Text(text, style: const TextStyle(fontSize: 13))), const Icon(Icons.arrow_outward, size: 15, color: Color(0xFF8195AC))]))));

  Widget _composer() => Container(
    padding: EdgeInsets.fromLTRB(12, 10, 12, MediaQuery.of(context).padding.bottom > 0 ? 8 : 12),
    decoration: const BoxDecoration(color: _ink, border: Border(top: BorderSide(color: _line))),
    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(child: TextField(controller: _input, minLines: 1, maxLines: 6, textCapitalization: TextCapitalization.sentences, onSubmitted: (_) => _send(), decoration: const InputDecoration(hintText: 'Message QuantAI…', contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 13)))),
      const SizedBox(width: 9),
      SizedBox(width: 48, height: 48, child: FilledButton(onPressed: _sending ? null : _send, style: FilledButton.styleFrom(padding: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))), child: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: _ink)) : const Icon(Icons.arrow_upward))),
    ]),
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final ChatMessage message;
  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    return Align(alignment: user ? Alignment.centerRight : Alignment.centerLeft, child: Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .88),
      margin: const EdgeInsets.only(bottom: 13), padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(color: user ? const Color(0xFF173C37) : _panel, borderRadius: BorderRadius.only(topLeft: const Radius.circular(16), topRight: const Radius.circular(16), bottomLeft: Radius.circular(user ? 16 : 4), bottomRight: Radius.circular(user ? 4 : 16)), border: Border.all(color: user ? const Color(0xFF28685B) : _line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SelectableText(message.content, style: const TextStyle(fontSize: 14, height: 1.5, color: Color(0xFFE5EDF7))),
        const SizedBox(height: 8), Row(mainAxisSize: MainAxisSize.min, children: [
          Text(DateFormat('HH:mm').format(message.createdAt), style: const TextStyle(fontSize: 9, color: Color(0xFF8295AA))),
          if (message.server != null) ...[const SizedBox(width: 8), Icon(message.fallback ? Icons.swap_horiz : Icons.dns_outlined, size: 11, color: message.fallback ? const Color(0xFFE3A85B) : _accent), const SizedBox(width: 3), Text(message.fallback ? 'SECONDARY' : message.server!.toUpperCase(), style: TextStyle(fontSize: 9, color: message.fallback ? const Color(0xFFE3A85B) : _accent, fontWeight: FontWeight.w700))],
        ]),
      ]),
    ));
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();
  @override
  Widget build(BuildContext context) => Align(alignment: Alignment.centerLeft, child: Container(margin: const EdgeInsets.only(left: 2, top: 4, bottom: 12), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13), decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(15), border: Border.all(color: _line)), child: const Row(mainAxisSize: MainAxisSize.min, children: [SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)), SizedBox(width: 10), Text('QuantAI is thinking…', style: TextStyle(color: Color(0xFF9AACC1), fontSize: 12))])));
}

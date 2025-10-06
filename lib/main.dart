import 'package:flutter/material.dart';
import 'pages/server_list_page.dart';

void main() {
  runApp(const VPNApp());
}

class VPNApp extends StatelessWidget {
  const VPNApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nokz – Provisioner',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(),
        useMaterial3: true,
        fontFamily: 'ShareTechMono',
        // Strongly prefer your local font everywhere (helps avoid Google Fonts fetches)
        textTheme: const TextTheme().apply(fontFamily: 'ShareTechMono'),
        primaryTextTheme: const TextTheme().apply(fontFamily: 'ShareTechMono'),
      ),
      home: const Scaffold(body: ServerListPage()),
      debugShowCheckedModeBanner: false,
    );
  }
}

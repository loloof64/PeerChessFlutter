/*
    Peer Chess : Play chess remotely with your friends.
    Copyright (C) 2023  Laurent Bernabe <laurent.bernabe@gmail.com>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_i18n/flutter_i18n.dart';
import 'package:flutter_i18n/loaders/decoders/json_decode_strategy.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'package:logger/logger.dart';
import 'package:firedart/firedart.dart';
import 'package:flutter/services.dart';
import 'screens/game_screen.dart';
import 'screens/new_game_screen.dart';
import 'screens/new_game_position_editor_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final String configText =
      await rootBundle.loadString('assets/secrets/firebase.json');
  final config = await json.decode(configText);

  Firestore.initialize(config['projectId']);

  windowManager.setTitle("Peer chess");
  windowManager.setMinimumSize(
    const Size(600, 400),
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Peer chess',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      localizationsDelegates: [
        FlutterI18nDelegate(
          translationLoader: FileTranslationLoader(
            basePath: 'assets/i18n',
            useCountryCode: false,
            fallbackFile: 'en',
            decodeStrategies: [JsonDecodeStrategy()],
          ),
          missingTranslationHandler: (key, locale) {
            Logger().w(
                "--- Missing Key: $key, languageCode: ${locale?.languageCode}");
          },
        ),
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate
      ],
      supportedLocales: const [
        Locale('en', ''),
        Locale('fr', ''),
        Locale('es', ''),
      ],
      onGenerateRoute: (settings) {
        if (settings.name == '/') {
          return MaterialPageRoute(builder: (context) => const GameScreen());
        } else if (settings.name == '/new_game') {
          final args = settings.arguments as NewGameScreenArguments;
          return MaterialPageRoute(
            builder: (context) => NewGameScreen(
              initialFen: args.initialFen,
              initialWhiteGameDuration: args.initialWhiteGameDuration,
              initialBlackGameDuration: args.initialBlackGameDuration,
            ),
          );
        } else if (settings.name == '/new_game_editor') {
          return MaterialPageRoute(builder: (context) {
            final args =
                settings.arguments as NewGamePositionEditorScreenArguments;
            return NewGamePositionEditorScreen(initialFen: args.initialFen);
          });
        } else {
          return MaterialPageRoute(builder: (context) => const GameScreen());
        }
      },
      home: const GameScreen(),
    );
  }
}

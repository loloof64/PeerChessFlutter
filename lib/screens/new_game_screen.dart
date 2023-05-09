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
import './new_game_position_editor_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_i18n/flutter_i18n.dart';
import 'package:simple_chess_board/simple_chess_board.dart';
import 'package:editable_chess_board/editable_chess_board.dart';
import '../components/duration_picker_dialog_box.dart';
import '../components/dialog_buttons.dart';

class NewGameParameters {
  final String startPositionFen;
  final bool playerHasWhite;
  final bool useTime;
  final ExtendedDuration whiteGameTime;
  final ExtendedDuration blackGameTime;

  NewGameParameters({
    required this.startPositionFen,
    required this.playerHasWhite,
    required this.useTime,
    required this.whiteGameTime,
    required this.blackGameTime,
  });
}

class NewGameScreenArguments {
  final String initialFen;
  final ExtendedDuration initialWhiteGameDuration;
  final ExtendedDuration initialBlackGameDuration;

  NewGameScreenArguments({
    required this.initialFen,
    required this.initialWhiteGameDuration,
    required this.initialBlackGameDuration,
  });
}

class NewGameScreen extends StatefulWidget {
  final String initialFen;
  final ExtendedDuration initialWhiteGameDuration;
  final ExtendedDuration initialBlackGameDuration;

  const NewGameScreen({
    Key? key,
    required this.initialFen,
    required this.initialWhiteGameDuration,
    required this.initialBlackGameDuration,
  }) : super(key: key);

  @override
  NewGameScreenState createState() => NewGameScreenState();
}

class NewGameScreenState extends State<NewGameScreen> {
  late PositionController _positionController;
  late String _positionFen;
  late bool _playerHasWhite;
  late BoardColor _orientation;
  bool _useTime = false;
  bool _differentTimes = false;
  late ExtendedDuration _whiteGameDuration;
  late ExtendedDuration _blackGameDuration;

  @override
  void initState() {
    _whiteGameDuration = widget.initialWhiteGameDuration;
    _blackGameDuration = widget.initialBlackGameDuration;
    _positionController = PositionController(widget.initialFen);
    _positionFen = _positionController.currentPosition;
    _playerHasWhite = _positionFen.split(' ')[1] == 'w';
    _orientation = _playerHasWhite ? BoardColor.white : BoardColor.black;
    super.initState();
  }

  Translations _getDurationPickerTranslations() {
    return Translations(
      duration: FlutterI18n.translate(context, 'duration_picker.duration'),
      select: FlutterI18n.translate(context, 'duration_picker.select'),
      hours: FlutterI18n.translate(context, 'duration_picker.hours'),
      minutes: FlutterI18n.translate(context, 'duration_picker.minutes'),
      seconds: FlutterI18n.translate(context, 'duration_picker.seconds'),
      incrementInSeconds:
          FlutterI18n.translate(context, 'duration_picker.increment_seconds'),
      secondsUnit:
          FlutterI18n.translate(context, 'duration_picker.seconds_unit'),
    );
  }

  String _getGameDurationString({
    required int timeMillis,
    required int incrementTimeSeconds,
  }) {
    final deciSeconds = ((timeMillis % 1000) / 10).floor();
    final timeSeconds = (timeMillis / 1000).floor();
    final seconds = timeSeconds % 60;
    final timeMinutes = (timeSeconds / 60).floor();
    final minutes = timeMinutes % 60;
    final hours = (timeMinutes / 60).floor();

    final lessThanOneMinute = hours == 0 && minutes == 0;
    if (lessThanOneMinute) {
      return "$seconds.$deciSeconds";
    } else {
      final minutesStr = minutes < 10 ? "0$minutes" : "$minutes";
      final secondsStr = seconds < 10 ? "0$seconds" : "$seconds";
      return "$hours:$minutesStr:$secondsStr +"
          "$incrementTimeSeconds"
          "${FlutterI18n.translate(context, 'duration_picker.seconds_unit')}";
    }
  }

  Future<void> _showEditPositionPage() async {
    final result = await Navigator.of(context).pushNamed(
      '/new_game_editor',
      arguments: NewGamePositionEditorScreenArguments(
          _positionController.currentPosition),
    ) as String?;
    if (result != null) {
      setState(() {
        _positionController.value = result;
        _positionFen = _positionController.currentPosition;
      });
    }
  }

  void _onTurnChanged(bool newTurnValue) {
    setState(() {
      _playerHasWhite = newTurnValue;
      _orientation = _playerHasWhite ? BoardColor.white : BoardColor.black;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: I18nText('new_game.title'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(children: <Widget>[
                SimpleChessBoard(
                  chessBoardColors: ChessBoardColors()
                    ..lastMoveArrowColor = Colors.blueAccent,
                  lastMoveToHighlight: null,
                  fen: _positionFen,
                  orientation: _orientation,
                  whitePlayerType: PlayerType.computer,
                  blackPlayerType: PlayerType.computer,
                  onMove: ({required move}) {},
                  onPromote: () async => null,
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      I18nText('new_game.position_editor.label_player_side'),
                      ListTile(
                        title: Text(
                          FlutterI18n.translate(
                            context,
                            'new_game.position_editor.label_white_player',
                          ),
                        ),
                        leading: Radio<bool>(
                          groupValue: _playerHasWhite,
                          value: true,
                          onChanged: (value) {
                            _onTurnChanged(value ?? true);
                          },
                        ),
                      ),
                      ListTile(
                        title: Text(
                          FlutterI18n.translate(
                            context,
                            'new_game.position_editor.label_black_player',
                          ),
                        ),
                        leading: Radio<bool>(
                          groupValue: _playerHasWhite,
                          value: false,
                          onChanged: (value) {
                            _onTurnChanged(value ?? false);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ElevatedButton(
                    onPressed: () {
                      _showEditPositionPage();
                    },
                    child: I18nText(
                      'new_game.edit_position',
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: ListTile(
                    title: Text(
                      FlutterI18n.translate(
                        context,
                        'new_game.use_clock',
                      ),
                    ),
                    leading: Checkbox(
                        value: _useTime,
                        onChanged: (newState) {
                          if (newState != null) {
                            setState(() {
                              _useTime = newState;
                            });
                          }
                        }),
                  ),
                ),
                if (_useTime)
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Flexible(
                            child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _getGameDurationString(
                                timeMillis:
                                    _whiteGameDuration.duration.inMilliseconds,
                                incrementTimeSeconds:
                                    _whiteGameDuration.incrementInSeconds,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 4.0),
                              child: ElevatedButton(
                                onPressed: () async {
                                  final newDuration = await showDurationPicker(
                                    context: context,
                                    initialDuration: _whiteGameDuration,
                                    confirmText: FlutterI18n.translate(
                                      context,
                                      'buttons.ok',
                                    ),
                                    cancelText: FlutterI18n.translate(
                                      context,
                                      'buttons.cancel',
                                    ),
                                    translations:
                                        _getDurationPickerTranslations(),
                                  );
                                  if (newDuration != null) {
                                    setState(() {
                                      _whiteGameDuration = newDuration;
                                    });
                                  }
                                },
                                child: I18nText('buttons.modify'),
                              ),
                            )
                          ],
                        )),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: ListTile(
                          title: Text(
                            FlutterI18n.translate(
                              context,
                              'new_game.use_different_clocks',
                            ),
                          ),
                          leading: Checkbox(
                              value: _differentTimes,
                              onChanged: (newState) {
                                if (newState != null) {
                                  setState(() {
                                    _differentTimes = newState;
                                  });
                                }
                              }),
                        ),
                      ),
                      if (_differentTimes)
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Flexible(
                              child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _getGameDurationString(
                                  timeMillis: _blackGameDuration
                                      .duration.inMilliseconds,
                                  incrementTimeSeconds:
                                      _blackGameDuration.incrementInSeconds,
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(left: 4.0),
                                child: ElevatedButton(
                                  onPressed: () async {
                                    final newDuration =
                                        await showDurationPicker(
                                      context: context,
                                      initialDuration: _blackGameDuration,
                                      confirmText: FlutterI18n.translate(
                                        context,
                                        'buttons.ok',
                                      ),
                                      cancelText: FlutterI18n.translate(
                                        context,
                                        'buttons.cancel',
                                      ),
                                      translations:
                                          _getDurationPickerTranslations(),
                                    );
                                    if (newDuration != null) {
                                      setState(() {
                                        _blackGameDuration = newDuration;
                                      });
                                    }
                                  },
                                  child: I18nText('buttons.modify'),
                                ),
                              )
                            ],
                          )),
                        ),
                    ],
                  ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(2.0),
                        child: DialogActionButton(
                          onPressed: () async {
                            Navigator.of(context).pop(
                              NewGameParameters(
                                startPositionFen:
                                    _positionController.currentPosition,
                                playerHasWhite: _playerHasWhite,
                                useTime: _useTime,
                                whiteGameTime: _whiteGameDuration,
                                blackGameTime: _differentTimes
                                    ? _blackGameDuration
                                    : _whiteGameDuration,
                              ),
                            );
                          },
                          textContent: I18nText('buttons.ok'),
                          backgroundColor: Colors.greenAccent,
                          textColor: Colors.white,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(2.0),
                        child: DialogActionButton(
                          onPressed: () {
                            Navigator.of(context).pop(null);
                          },
                          textContent: I18nText('buttons.cancel'),
                          backgroundColor: Colors.redAccent,
                          textColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                )
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

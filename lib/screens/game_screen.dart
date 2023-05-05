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

import 'package:firedart/firedart.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_window_close/flutter_window_close.dart';
import 'package:logger/logger.dart';
import 'package:peer_chess/logic/utils.dart';
import 'package:simple_chess_board/models/board_arrow.dart';
import 'package:simple_chess_board/simple_chess_board.dart';
import 'package:chess_vectors_flutter/chess_vectors_flutter.dart';
import 'package:chess/chess.dart' as chess;
import 'package:flutter_i18n/flutter_i18n.dart';
import '../logic/managers/game_manager.dart';
import '../logic/managers/history_manager.dart';
import '../logic/webrtc/signaling.dart';
import '../logic/history_builder.dart';
import '../components/history.dart';
import '../components/dialog_buttons.dart';
import '../screens/new_game_screen.dart';

class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  BoardColor _orientation = BoardColor.white;
  BoardArrow? _lastMoveToHighlight;
  late GameManager _gameManager;
  late HistoryManager _historyManager;
  late Signaling _signaling;
  RTCDataChannel? _dataChannel;
  late TextEditingController _roomIdController;
  bool _sessionActive = false;
  bool _readyToSendMessagesToOtherPeer = false;
  bool _waitingJoiningAnswer = false;
  bool _waitingJoiningRequest = false;

  final ScrollController _historyScrollController =
      ScrollController(initialScrollOffset: 0.0, keepScrollOffset: true);

  @override
  void initState() {
    _roomIdController = TextEditingController();
    _gameManager = GameManager();
    _historyManager = HistoryManager(
      onUpdateChildrenWidgets: _updateHistoryChildrenWidgets,
      onPositionSelected: _selectPosition,
      onSelectStartPosition: _selectStartPosition,
      isStartMoveNumber: _isStartMoveNumber,
    );

    _signaling = Signaling();

    _signaling.readyToSendMessagesStream.forEach((newState) {
      setState(() {
        _readyToSendMessagesToOtherPeer = newState;
      });
    });

    FlutterWindowClose.setWindowShouldCloseHandler(() async {
      await _signaling.hangUp();
      await _signaling.dispose();
      return true;
    });

    _listenSnapshotsInDB().then((value) => {});
    super.initState();
  }

  @override
  void dispose() {
    _roomIdController.dispose();
    _signaling.hangUp().then((value) {
      _signaling.dispose().then((value) => null);
    });
    super.dispose();
  }

  Future<void> _listenSnapshotsInDB() async {
    Firestore.instance.collection('rooms').stream.forEach((roomsList) async {
      final weHaveARoom = _signaling.ourRoomId != null;
      final weAreHosted = _signaling.hostRoomId != null;

      if (weHaveARoom) {
        final ourRoomDocument = await Firestore.instance
            .collection('rooms')
            .document(_signaling.ourRoomId!)
            .get();
        final allCalleeCandidates = await getAllDocumentsFromSubCollection(
            parentDocument: ourRoomDocument,
            collectionName: 'calleeCandidates');
        final weHaveAGuest = allCalleeCandidates.isNotEmpty;
        final weJustHaveHadAGuest = _waitingJoiningRequest && weHaveAGuest;
        if (weJustHaveHadAGuest) {
          setState(() {
            _waitingJoiningRequest = false;
          });
          for (var candidate in allCalleeCandidates) {
            _signaling.addCandidate(
              RTCIceCandidate(
                candidate['candidate'],
                candidate['sdpMid'],
                candidate['sdpMLineIndex'],
              ),
            );
          }
          await _sendAnswerToRoomGuest(roomDocument: ourRoomDocument);
        }
      } else if (weAreHosted) {
        final hostRoomDocument = await Firestore.instance
            .collection('rooms')
            .document(_signaling.hostRoomId!)
            .get();
        final weHaveAnswer = hostRoomDocument['positiveAnswerFromHost'] != null;
        final weJustHadAnAnswer = _waitingJoiningAnswer && weHaveAnswer;
        if (weJustHadAnAnswer) {
          await _handleJoiningAnswer(roomDocument: hostRoomDocument);
        }
      }
    });
  }

  Future<void> _sendAnswerToRoomGuest({required Document roomDocument}) async {
    await roomDocument.reference.set({
      'offer': roomDocument['offer'],
      'answer': roomDocument['answer'],
      'positiveAnswerFromHost': true,
    });
    await _signaling.establishConnection();
    // Removes the room popup
    if (!mounted) return;
    Navigator.of(context).pop();
    setState(() {
      _sessionActive = true;
    });
  }

  Future<void> _handleJoiningAnswer({required Document roomDocument}) async {
    setState(() {
      _waitingJoiningAnswer = false;
    });
    final allCallerCandidates = await getAllDocumentsFromSubCollection(
      parentDocument: roomDocument,
      collectionName: 'callerCandidates',
    );
    for (var candidate in allCallerCandidates) {
      _signaling.addCandidate(
        RTCIceCandidate(
          candidate['candidate'],
          candidate['sdpMid'],
          candidate['sdpMLineIndex'],
        ),
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: I18nText('game.accepted_request'),
      ),
    );
    // Removes the waiting for answer popup
    Navigator.of(context).pop();
    setState(() {
      _sessionActive = true;
    });
  }

  bool _isStartMoveNumber(int moveNumber) {
    return int.parse(_gameManager.startPosition.split(' ')[5]) == moveNumber;
  }

  void _selectStartPosition() {
    setState(() {
      _lastMoveToHighlight = null;
      _gameManager.loadStartPosition();
    });
  }

  void _selectPosition({
    required String from,
    required String to,
    required String position,
  }) {
    setState(() {
      _lastMoveToHighlight = BoardArrow(
        from: from,
        to: to,
      );
      _gameManager.loadPosition(position);
    });
  }

  /*
    Must be called after a move has just been
    added to _gameLogic
    Do not update state itself.
  */
  void _addMoveToHistory() {
    if (_historyManager.currentNode != null) {
      final whiteMove = _gameManager.whiteTurn;
      final lastMoveFan = _gameManager.getLastMoveFan();
      final relatedMove = _gameManager.getLastMove();
      final gameStart = _gameManager.isGameStart;
      final position = _gameManager.position;

      setState(() {
        _lastMoveToHighlight = BoardArrow(
          from: relatedMove.from.toString(),
          to: relatedMove.to.toString(),
        );
        _historyManager.addMove(
          isWhiteTurnNow: whiteMove,
          isGameStart: gameStart,
          lastMoveFan: lastMoveFan,
          position: position,
          lastPlayedMove: relatedMove,
        );
      });
    }
  }

  void _makeMove({
    required ShortMove move,
  }) {
    setState(() {
      final moveHasBeenMade = _gameManager.processPlayerMove(
        from: move.from,
        to: move.to,
        promotion: move.promotion.map((t) => t.name).toNullable(),
      );
      if (moveHasBeenMade) {
        _addMoveToHistory();
      }
      _gameManager.clearGameStartFlag();
    });
    if (_gameManager.isGameOver) {
      final gameResultString = _gameManager.getResultString();
      setState(() {
        _addMoveToHistory();
        _historyManager.addResultString(gameResultString);
        _gameManager.stopGame();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _gameManager.getGameEndedType(),
            ],
          ),
        ),
      );
    }
  }

  void _updateHistoryChildrenWidgets() {
    setState(() {
      if (_gameManager.gameInProgress) {
        _historyScrollController.animateTo(
          _historyScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 50),
          curve: Curves.easeIn,
        );
      } else {
        if (_historyManager.selectedNode != null) {
          var selectedNodeIndex = getHistoryNodeIndex(
              node: _historyManager.selectedNode!,
              rootNode: _historyManager.gameHistoryTree!);
          var selectedLine = selectedNodeIndex ~/ 6;
          _historyScrollController.animateTo(
            selectedLine * 40.0,
            duration: const Duration(milliseconds: 50),
            curve: Curves.easeIn,
          );
        } else {
          _historyScrollController.animateTo(0.0,
              duration: const Duration(milliseconds: 10), curve: Curves.easeIn);
        }
      }
    });
  }

  Future<PieceType?> _makePromotion() async {
    final promotion = await _showPromotionDialog(context);
    return promotion;
  }

  Future<PieceType?> _showPromotionDialog(BuildContext context) {
    const pieceSize = 60.0;
    final whiteTurn = _gameManager.position.split(' ')[1] == 'w';
    return showDialog<PieceType>(
        context: context,
        builder: (_) {
          return AlertDialog(
            title: I18nText('game.promotion_dialog_title'),
            alignment: Alignment.center,
            content: FittedBox(
              child: Row(
                children: [
                  InkWell(
                    child: whiteTurn
                        ? WhiteQueen(size: pieceSize)
                        : BlackQueen(size: pieceSize),
                    onTap: () => Navigator.of(context).pop(PieceType.queen),
                  ),
                  InkWell(
                    child: whiteTurn
                        ? WhiteRook(size: pieceSize)
                        : BlackRook(size: pieceSize),
                    onTap: () => Navigator.of(context).pop(PieceType.rook),
                  ),
                  InkWell(
                    child: whiteTurn
                        ? WhiteBishop(size: pieceSize)
                        : BlackBishop(size: pieceSize),
                    onTap: () => Navigator.of(context).pop(PieceType.bishop),
                  ),
                  InkWell(
                    child: whiteTurn
                        ? WhiteKnight(size: pieceSize)
                        : BlackKnight(size: pieceSize),
                    onTap: () => Navigator.of(context).pop(PieceType.knight),
                  ),
                ],
              ),
            ),
          );
        });
  }

  List<Widget> _buildHistoryWidgetsTree(double fontSize) {
    return _historyManager.elementsTree.map((currentElement) {
      final textComponent = Text(
        currentElement.text,
        style: TextStyle(
          fontSize: fontSize,
          fontFamily: 'FreeSerif',
          backgroundColor: currentElement.backgroundColor,
          color: currentElement.textColor,
        ),
      );

      if (currentElement is MoveLinkElement) {
        return TextButton(
          onPressed: currentElement.onPressed,
          child: textComponent,
        );
      } else {
        return textComponent;
      }
    }).toList();
  }

  Future<void> _goToNewGameOptionsPage() async {
    String editPosition = _gameManager.position;
    final editPositionEmpty = editPosition.split(' ')[0] == '8/8/8/8/8/8/8/8';
    if (editPositionEmpty) editPosition = chess.Chess.DEFAULT_POSITION;
    final gameParameters = await Navigator.of(context).pushNamed(
      '/new_game',
      arguments: NewGameScreenArguments(editPosition),
    ) as NewGameParameters?;
    if (gameParameters != null) {
      _startNewGame(
        startPosition: gameParameters.startPositionFen,
        playerHasWhite: gameParameters.playerHasWhite,
      );
    }
  }

  Future<void> _startNewGame({
    String startPosition = chess.Chess.DEFAULT_POSITION,
    bool playerHasWhite = true,
  }) async {
    setState(() {
      _historyScrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 50),
        curve: Curves.easeIn,
      );

      _orientation = playerHasWhite ? BoardColor.white : BoardColor.black;

      final parts = startPosition.split(' ');
      final whiteTurn = parts[1] == 'w';
      final moveNumber = parts[5];
      final caption = "$moveNumber${whiteTurn ? '.' : '...'}";
      _lastMoveToHighlight = null;
      _historyManager.newGame(caption);
      _gameManager.startNewGame(
        startPosition: startPosition,
        playerHasWhite: playerHasWhite,
      );
    });
  }

  void _toggleBoardOrientation() {
    setState(() {
      _orientation = _orientation == BoardColor.white
          ? BoardColor.black
          : BoardColor.white;
    });
  }

  void _stopCurrentGameConfirmationAction() {
    Navigator.of(context).pop();
    _stopCurrentGame();
  }

  void _stopCurrentGame() {
    setState(() {
      if (_historyManager.currentNode?.relatedMove != null) {
        _lastMoveToHighlight = BoardArrow(
          from: _historyManager.currentNode!.relatedMove!.from.toString(),
          to: _historyManager.currentNode!.relatedMove!.to.toString(),
        );
        _historyManager.selectCurrentNode();
      }
      _historyManager.addResultString('*');
      _gameManager.stopGame();
    });
    setState(() {
      _historyManager.updateChildrenWidgets();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [I18nText('game.stopped')],
        ),
      ),
    );
  }

  Future<void> _createRoom() async {
    if (!mounted) return;

    final success = await _signaling.createRoom();
    switch (success) {
      case CreatingRoomState.alreadyCreatedARoom:
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: I18nText('game.already_created_room')));
        return;
      case CreatingRoomState.miscError:
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: I18nText('game.misc_room_creation_error')));
        return;
      case CreatingRoomState.success:
        setState(() {
          _waitingJoiningRequest = true;
        });
        break;
    }

    if (!mounted) return;

    showDialog(
      barrierDismissible: false,
      context: context,
      builder: (BuildContext innerCtx) {
        return AlertDialog(
          title: I18nText('game.room_creation_title'),
          content:
              Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            I18nText('game.room_creation_msg'),
            I18nText('game.room_creation_msg2'),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _signaling.ourRoomId!,
                  style: const TextStyle(
                    backgroundColor: Colors.blueGrey,
                  ),
                ),
                IconButton(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _signaling.ourRoomId!),
                    );
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: I18nText("clipboard.content_copied"),
                      ),
                    );
                  },
                  icon: const Icon(
                    Icons.paste,
                  ),
                ),
              ],
            ),
          ]),
          actions: [
            DialogActionButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _signaling.hangUp();
              },
              textContent: I18nText(
                'buttons.cancel',
              ),
              textColor: Colors.white,
              backgroundColor: Colors.redAccent,
            )
          ],
        );
      },
    );
  }

  void _purposeStopGame() {
    if (!_gameManager.gameInProgress) return;
    showDialog(
        context: context,
        builder: (BuildContext innerCtx) {
          return AlertDialog(
            title: I18nText('game.stop_game_title'),
            content: I18nText('game.stop_game_msg'),
            actions: [
              DialogActionButton(
                onPressed: _stopCurrentGameConfirmationAction,
                textContent: I18nText(
                  'buttons.ok',
                ),
                backgroundColor: Colors.tealAccent,
                textColor: Colors.white,
              ),
              DialogActionButton(
                onPressed: () => Navigator.of(context).pop(),
                textContent: I18nText(
                  'buttons.cancel',
                ),
                textColor: Colors.white,
                backgroundColor: Colors.redAccent,
              )
            ],
          );
        });
  }

  void _sendMove(ShortMove move) {
    final moveData = {
      "from": move.from,
      "to": move.to,
      "promotion": move.promotion.isNone()
          ? ""
          : move.promotion.getOrElse(() => PieceType.queen).name,
    };
    final moveAsJson = jsonEncode(moveData);
    _dataChannel?.send(RTCDataChannelMessage(moveAsJson));
  }

  Future<void> _handleRoomJoiningRequest() async {
    final requestedRoomId = _roomIdController.text;

    if (!mounted) return;
    final success = await _signaling.joinRoom(
      requestedRoomId: requestedRoomId,
    );
    switch (success) {
      case JoiningRoomState.noRoomWithThisId:
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: I18nText('game.no_matching_room'),
          ),
        );
        return;
      case JoiningRoomState.alreadyInARoom:
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: I18nText('game.already_a_pending_request'),
          ),
        );
        return;
      case JoiningRoomState.alreadySomeonePairingWithHost:
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: I18nText('game.busy_room'),
          ),
        );
        return;
      case JoiningRoomState.miscError:
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: I18nText('game.misc_room_joining_error'),
          ),
        );
        return;
      case JoiningRoomState.success:
        break;
    }

    final roomDocument = await Firestore.instance
        .collection('rooms')
        .document(requestedRoomId)
        .get();
    await roomDocument.reference.set({
      'offer': roomDocument['offer'],
      'answer': roomDocument['answer'],
      'positiveAnswerFromHost': roomDocument['positiveAnswerFromHost'],
    });
    setState(() {
      _waitingJoiningAnswer = true;
    });

    if (!mounted) return;

    // showing waiting for answer dialog
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx2) {
          return AlertDialog(
            title: I18nText('game.waiting_call_answer_title'),
            content: I18nText('game.waiting_call_answer_message'),
          );
        });
  }

  Future<void> _joinRoom() async {
    setState(() {
      _roomIdController.text = "";
    });

    if (!mounted) return;

    showDialog(
        barrierDismissible: false,
        context: context,
        builder: (ctx2) {
          return AlertDialog(
            title: I18nText("game.join_room"),
            content: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                I18nText('game.enterRoomId'),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: TextField(
                        controller: _roomIdController,
                        decoration: InputDecoration(
                          hintText:
                              FlutterI18n.translate(context, "game.roomIdHint"),
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () async {
                        final data =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        if (data == null || data.text == null) return;
                        _roomIdController.text = data.text!;
                      },
                      icon: const Icon(
                        Icons.paste,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              DialogActionButton(
                onPressed: () async {
                  Navigator.of(ctx2).pop();
                  await _handleRoomJoiningRequest();
                },
                textContent: I18nText(
                  'buttons.ok',
                ),
                backgroundColor: Colors.tealAccent,
                textColor: Colors.white,
              ),
              DialogActionButton(
                onPressed: () async {
                  Navigator.of(ctx2).pop();
                },
                textContent: I18nText(
                  'buttons.cancel',
                ),
                textColor: Colors.white,
                backgroundColor: Colors.redAccent,
              )
            ],
          );
        });
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      appBar: AppBar(
        title: I18nText('game_page.title'),
        actions: [
          if (!_sessionActive)
            IconButton(
              onPressed: _createRoom,
              icon: const Icon(
                Icons.room,
              ),
            ),
          if (!_sessionActive)
            IconButton(
              onPressed: _joinRoom,
              icon: const Icon(
                Icons.door_sliding,
              ),
            ),
          if (_sessionActive && _readyToSendMessagesToOtherPeer)
            IconButton(
              onPressed: () async {
                await _signaling.sendMessage(
                    jsonEncode({'type': 'message', 'value': 'Hello !'}));
              },
              icon: const Icon(
                Icons.add_circle,
              ),
            ),
          if (_sessionActive && _readyToSendMessagesToOtherPeer)
            IconButton(
              onPressed: _toggleBoardOrientation,
              icon: const Icon(
                Icons.swap_vert_circle,
              ),
            ),
        ],
      ),
      body: Center(
        child: isLandscape
            ? Row(
                children: [
                  Flexible(
                    child: SimpleChessBoard(
                      chessBoardColors: ChessBoardColors()
                        ..lastMoveArrowColor = Colors.blueAccent,
                      engineThinking: false,
                      whitePlayerType: PlayerType.human,
                      blackPlayerType: PlayerType.human,
                      orientation: _orientation,
                      lastMoveToHighlight: _lastMoveToHighlight,
                      fen: _gameManager.position,
                      onMove: _makeMove,
                      onPromote: _makePromotion,
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(builder: (ctx2, constraints2) {
                      double fontSize =
                          constraints2.biggest.shortestSide * 0.09;
                      if (fontSize < 25) {
                        fontSize = 25;
                      }
                      return ChessHistory(
                        scrollController: _historyScrollController,
                        requestGotoFirst: _historyManager.gotoFirst,
                        requestGotoPrevious: _historyManager.gotoPrevious,
                        requestGotoNext: _historyManager.gotoNext,
                        requestGotoLast: _historyManager.gotoLast,
                        children: _buildHistoryWidgetsTree(fontSize),
                      );
                    }),
                  )
                ],
              )
            : Expanded(
                child: Column(
                  children: [
                    Flexible(
                      child: SimpleChessBoard(
                        chessBoardColors: ChessBoardColors()
                          ..lastMoveArrowColor = Colors.blueAccent,
                        engineThinking: false,
                        whitePlayerType: PlayerType.human,
                        blackPlayerType: PlayerType.human,
                        orientation: _orientation,
                        lastMoveToHighlight: _lastMoveToHighlight,
                        fen: _gameManager.position,
                        onMove: _makeMove,
                        onPromote: _makePromotion,
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(builder: (ctx2, constraints2) {
                        double fontSize =
                            constraints2.biggest.shortestSide * 0.09;
                        if (fontSize < 25) {
                          fontSize = 25;
                        }
                        return ChessHistory(
                          scrollController: _historyScrollController,
                          requestGotoFirst: _historyManager.gotoFirst,
                          requestGotoPrevious: _historyManager.gotoPrevious,
                          requestGotoNext: _historyManager.gotoNext,
                          requestGotoLast: _historyManager.gotoLast,
                          children: _buildHistoryWidgetsTree(fontSize),
                        );
                      }),
                    )
                  ],
                ),
              ),
      ),
    );
  }
}

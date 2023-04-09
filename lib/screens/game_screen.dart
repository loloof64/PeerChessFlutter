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

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_window_close/flutter_window_close.dart';
import 'package:logger/logger.dart';
import 'package:parse_server_sdk_flutter/parse_server_sdk_flutter.dart';
import 'package:simple_chess_board/models/board_arrow.dart';
import 'package:simple_chess_board/simple_chess_board.dart';
import 'package:chess_vectors_flutter/chess_vectors_flutter.dart';
import 'package:chess/chess.dart' as chess;
import 'package:flutter_i18n/flutter_i18n.dart';
import '../logic/managers/game_manager.dart';
import '../logic/managers/history_manager.dart';
import '../logic/webrtc/signalling.dart';
import '../logic/history_builder.dart';
import '../components/history.dart';
import '../components/dialog_buttons.dart';
import '../screens/new_game_screen.dart';

const ringingMessageKey = 'ringingMessage';

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
  Map<String, String> _receivedPeerData = {};
  RTCDataChannel? _dataChannel;
  late TextEditingController _roomIdController;
  late TextEditingController _ringingMessageController;
  late TextEditingController _denyRequestMessageController;
  BuildContext? _pendingCallContext;
  bool _pendingRequest = false;

  final _liveQuery = LiveQuery();

  late Subscription<ParseObject> _peerSubscription;
  final QueryBuilder<ParseObject> _queryPeer =
      QueryBuilder<ParseObject>(ParseObject('Peer'));

  late Subscription<ParseObject> _roomSubscription;
  final QueryBuilder<ParseObject> _queryRoom =
      QueryBuilder<ParseObject>(ParseObject('Room'));

  final ScrollController _historyScrollController =
      ScrollController(initialScrollOffset: 0.0, keepScrollOffset: true);

  @override
  void initState() {
    _roomIdController = TextEditingController();
    _ringingMessageController = TextEditingController();
    _denyRequestMessageController = TextEditingController();
    _gameManager = GameManager();
    _historyManager = HistoryManager(
      onUpdateChildrenWidgets: _updateHistoryChildrenWidgets,
      onPositionSelected: _selectPosition,
      onSelectStartPosition: _selectStartPosition,
      isStartMoveNumber: _isStartMoveNumber,
    );

    _signaling = Signaling();

    FlutterWindowClose.setWindowShouldCloseHandler(() async {
      await _signaling.removePeerFromDB();
      await _signaling.deleteRoom();
      return true;
    });

    _startLiveQuery();

    super.initState();
  }

  @override
  void dispose() {
    _roomIdController.dispose();
    _ringingMessageController.dispose();
    _denyRequestMessageController.dispose();
    _signaling.removePeerFromDB();
    _cancelLiveQuery();
    super.dispose();
  }

  Future<void> _handleIncomingRequestAccepted() async {
    // todo accept request
    setState(() {
      _pendingRequest = false;
    });
  }

  Future<void> _completeDenyingRequestProcess(String message) async {
    // get room object
    QueryBuilder<ParseObject> queryRoom =
        QueryBuilder<ParseObject>(ParseObject('Room'));
    final ParseResponse apiResponse = await queryRoom.query();
    if (!apiResponse.success || apiResponse.results == null) {
      Logger().e('The room does not exist in database.');
      setState(() {
        _pendingRequest = false;
      });
    }

    final roomInstance = apiResponse.results?.first as ParseObject;
    roomInstance.set('accepted', false);
    roomInstance.set('answerMessage', message);
    roomInstance.set('joiner', null);
    roomInstance.set('requestMessage', null);
    final dbAnswer = await roomInstance.save();

    if (!dbAnswer.success) {
      Logger().e(dbAnswer.error);
    }

    setState(() {
      _pendingRequest = false;
    });
  }

  Future<void> _handleIncomingRequestDenied() async {
    if (mounted) {
      setState(() {
        _denyRequestMessageController.text = '';
      });
      showDialog(
          barrierDismissible: false,
          context: context,
          builder: (ctx2) {
            return AlertDialog(
              title: I18nText('game.choose_deny_message_title'),
              content: TextField(
                controller: _denyRequestMessageController,
                maxLines: 6,
              ),
              actions: [
                DialogActionButton(
                  onPressed: () {
                    Navigator.of(ctx2).pop();
                    _completeDenyingRequestProcess(
                        _denyRequestMessageController.text);
                  },
                  textContent: I18nText(
                    'buttons.ok',
                  ),
                  backgroundColor: Colors.tealAccent,
                  textColor: Colors.white,
                ),
              ],
            );
          });
    } else {
      _completeDenyingRequestProcess('');
    }
  }

  void _startLiveQuery() async {
    _peerSubscription = await _liveQuery.client.subscribe(_queryPeer);
    _peerSubscription.on(LiveQueryEvent.delete, (value) {
      final realValue = value as ParseObject;
      final isTheInstanceWeNeedToDelete =
          realValue.objectId == _signaling.remoteId;
      if (isTheInstanceWeNeedToDelete) {
        _signaling.hangUp();
        // cancel pending call if any
        if (_pendingCallContext != null) {
          Navigator.of(_pendingCallContext!).pop();
          setState(() {
            _pendingCallContext = null;
          });
        }
      }
    });

    _roomSubscription = await _liveQuery.client.subscribe(_queryRoom);
    _roomSubscription.on(LiveQueryEvent.update, (value) async {
      final realValue = value as ParseObject;
      final isTheRoomWeBelongIn = realValue.objectId == _signaling.roomId;
      final weAreTheOwner =
          realValue.get<ParseObject>('owner')?.objectId == _signaling.selfId;
      final weAreTheJoiner =
          realValue.get<ParseObject>('joiner')?.objectId == _signaling.selfId;
      if (isTheRoomWeBelongIn) {
        if (weAreTheOwner) {
          final thereIsAJoiner = realValue.get<ParseObject>('joiner') != null;
          if (thereIsAJoiner) {
            setState(() {
              _pendingRequest = true;
            });
            final message = realValue.get<String>('requestMessage');
            await showDialog(
                barrierDismissible: false,
                context: context,
                builder: (ctx2) {
                  return AlertDialog(
                    title: I18nText('game.incoming_request_title'),
                    content: Text(message ?? ''),
                    actions: [
                      DialogActionButton(
                        onPressed: () {
                          Navigator.of(ctx2).pop();
                          _handleIncomingRequestAccepted();
                        },
                        textContent: I18nText(
                          'buttons.ok',
                        ),
                        backgroundColor: Colors.tealAccent,
                        textColor: Colors.white,
                      ),
                      DialogActionButton(
                        onPressed: () {
                          Navigator.of(ctx2).pop();
                          _handleIncomingRequestDenied();
                        },
                        textContent: I18nText(
                          'buttons.deny',
                        ),
                        textColor: Colors.white,
                        backgroundColor: Colors.redAccent,
                      )
                    ],
                  );
                });
          } // thereIsAJoiner
          else {
            final thereIsAPendingRequest = _pendingRequest;
            if (thereIsAPendingRequest) {
              // clearing accept/deny request dialog
              Navigator.of(context).pop();

              setState(() {
                _pendingRequest = false;
              });

              // notifying us
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: I18nText('game.aborted_request_by_peer')),
              );
            }
          }
        } // weAreTheOwner
        else if (weAreTheJoiner) {
          final accepted = realValue.get<bool>('accepted');
          final answerMessage = realValue.get<String>('answerMessage') ?? '';
          if (accepted == false) {
            // Cancelling waiting answer dialog
            Navigator.of(context).pop();

            // Showing dialog
            if (!mounted) return;
            await showDialog(
                barrierDismissible: false,
                context: context,
                builder: (ctx2) {
                  return AlertDialog(
                    title: I18nText('game.denied_connection_title'),
                    content: Text(answerMessage),
                    actions: [
                      DialogActionButton(
                        onPressed: () {
                          Navigator.of(ctx2).pop();
                        },
                        textContent: I18nText(
                          'buttons.ok',
                        ),
                        backgroundColor: Colors.tealAccent,
                        textColor: Colors.white,
                      ),
                    ],
                  );
                });
          }
        }
      }
    });
  }

  void _cancelLiveQuery() async {
    _liveQuery.client.unSubscribe(_peerSubscription);
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
    final success = await _signaling.createRoom();
    if (success == CreatingRoomState.alreadyCreatedARoom) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: I18nText("game.already_created_room"),
        ),
      );
      return;
    }

    if (success == CreatingRoomState.error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: I18nText("game.failed_creating_room"),
        ),
      );
      return;
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext innerCtx) {
        return AlertDialog(
          title: I18nText('game.room_creation_title'),
          content:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            I18nText('game.room_creation_msg'),
            I18nText('game.room_creation_msg2'),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _signaling.roomId!,
                  style: const TextStyle(
                    backgroundColor: Colors.blueGrey,
                  ),
                ),
                IconButton(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _signaling.roomId),
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
                await _signaling.deleteRoom();
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

  _hangUp() {
    _signaling.hangUp();
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
    final message = _ringingMessageController.text;
    final success = await _signaling.joinRoom(requestedRoomId, message);
    if (success == JoiningRoomState.noRoomWithThisId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: I18nText("game.no_matching_room"),
        ),
      );
      return;
    }
    if (success == JoiningRoomState.alreadySomeonePairingWithHost) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: I18nText("game.busy_room"),
        ),
      );
      return;
    }

    if (!mounted) return;
    showDialog(
        barrierDismissible: false,
        context: context,
        builder: (ctx2) {
          return AlertDialog(
            content: I18nText('game.waiting_response'),
            actions: [
              DialogActionButton(
                onPressed: () async {
                  Navigator.of(ctx2).pop();
                  await _signaling.removeSelfFromRoomJoiner();
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

  Future<void> _joinRoom() async {
    if (!mounted) return;

    setState(() {
      _roomIdController.text = "";
      _ringingMessageController.text = "";
    });

    showDialog(
        context: context,
        builder: (ctx2) {
          return AlertDialog(
            title: I18nText("game.join_room"),
            content: Column(
              mainAxisAlignment: MainAxisAlignment.start,
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
                TextField(
                  controller: _ringingMessageController,
                  maxLines: 6,
                  decoration: InputDecoration(
                    hintText: FlutterI18n.translate(
                        context, "game.joininingMessageHint"),
                  ),
                )
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
                onPressed: () {
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
          IconButton(
            onPressed: _createRoom,
            icon: const Icon(
              Icons.room,
            ),
          ),
          IconButton(
            onPressed: _joinRoom,
            icon: const Icon(
              Icons.door_sliding,
            ),
          ),
          IconButton(
            onPressed: _purposeStopGame,
            icon: const Icon(
              Icons.stop_circle,
            ),
          ),
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

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
import '../logic/webrtc/session.dart';
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
  bool _readyToConnect = false;
  String _remotePeerId = '';
  Session? _session;
  late TextEditingController _peerIdController;
  late TextEditingController _ringingMessageController;
  BuildContext? _pendingCallContext;

  final _liveQuery = LiveQuery();

  late Subscription<ParseObject> _peerSubscription;
  final QueryBuilder<ParseObject> _queryPeer =
      QueryBuilder<ParseObject>(ParseObject('Peer'));

  late Subscription<ParseObject> _offerCandidatesSubscription;
  final QueryBuilder<ParseObject> _queryOfferCandidates =
      QueryBuilder<ParseObject>(ParseObject('OfferCandidates'));

  final ScrollController _historyScrollController =
      ScrollController(initialScrollOffset: 0.0, keepScrollOffset: true);

  @override
  void initState() {
    _peerIdController = TextEditingController(text: _remotePeerId);
    _ringingMessageController = TextEditingController();
    _gameManager = GameManager();
    _historyManager = HistoryManager(
      onUpdateChildrenWidgets: _updateHistoryChildrenWidgets,
      onPositionSelected: _selectPosition,
      onSelectStartPosition: _selectStartPosition,
      isStartMoveNumber: _isStartMoveNumber,
    );

    _signaling = Signaling();
    _readyToConnect = true;

    FlutterWindowClose.setWindowShouldCloseHandler(() async {
      await _signaling.removePeerFromDB();
      return true;
    });

    _startLiveQuery();

    super.initState();
  }

  @override
  void dispose() {
    _peerIdController.dispose();
    _ringingMessageController.dispose();
    _signaling.removePeerFromDB();
    _cancelLiveQuery();
    super.dispose();
  }

  void _startLiveQuery() async {
    _peerSubscription = await _liveQuery.client.subscribe(_queryPeer);
    _peerSubscription.on(LiveQueryEvent.delete, (value) {
      final realValue = value as ParseObject;
      if (realValue.objectId == _signaling.remoteId) {
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

    _offerCandidatesSubscription =
        await _liveQuery.client.subscribe(_queryOfferCandidates);

    _offerCandidatesSubscription.on(LiveQueryEvent.create, (value) async {
      final realValue = value as ParseObject;

      final peerMessage = realValue.get('offerMessage');

      final target = realValue.get('target');
      final realTarget = target as ParseObject;

      if (realTarget.objectId == _signaling.selfId) {
        if (_signaling.callInProgress) {
          final dbCandidate = ParseObject('AnswerCandidates')
            ..set('owner', ParseObject('Peer')..objectId = _signaling.selfId)
            ..set('target', ParseObject('Peer')..objectId = _signaling.remoteId)
            ..set('accepted', false);
          await dbCandidate.save();
        } else {
          if (context.mounted) {
            _showAcceptDialog(peerMessage);
          }
        }
      }
    });
  }

  void _cancelLiveQuery() async {
    _liveQuery.client.unSubscribe(_offerCandidatesSubscription);
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

  void _purposeRestartGame() {
    final isEmptyPosition = _gameManager.position == emptyPosition;
    if (isEmptyPosition) {
      _goToNewGameOptionsPage();
      return;
    }

    showDialog(
      context: context,
      builder: (BuildContext innerCtx) {
        return AlertDialog(
          title: I18nText('game.restart_game_title'),
          content: I18nText('game.restart_game_msg'),
          actions: [
            DialogActionButton(
              onPressed: () {
                Navigator.of(context).pop();
                _goToNewGameOptionsPage();
              },
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

  Future<void> _copyIdToClipboard() async {
    await Clipboard.setData(
      ClipboardData(text: _signaling.selfId),
    );
  }

  Future<void> _copyTextFromClipboard() async {
    final text = await Clipboard.getData('text/plain');
    if (text != null && text.text != null) {
      setState(() {
        _peerIdController.text = text.text!;
      });
    }
  }

  Future<void> _showWaitingPeerDialog() {
    return showDialog<bool?>(
        barrierDismissible: false,
        context: context,
        builder: (BuildContext context2) {
          _pendingCallContext = context2;
          return AlertDialog(
            title: I18nText("session.dialog_waiting_peer.title"),
            content: I18nText("session.dialog_waiting_peer.message"),
            actions: [
              DialogActionButton(
                onPressed: () {
                  Navigator.of(context2).pop();
                  _signaling.cancelCallRequest();
                  setState(() {
                    _pendingCallContext = null;
                  });
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

  Future<bool?> _showAcceptDialog(String peerMessage) {
    return showDialog<bool?>(
        barrierDismissible: false,
        context: context,
        builder: (context2) {
          return AlertDialog(
            title: I18nText('session.dialog_accept.title'),
            content: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                I18nText('session.dialog_accept.message'),
                Text(
                  peerMessage,
                  style: TextStyle(
                    backgroundColor: Colors.grey[300],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
            actions: [
              DialogActionButton(
                onPressed: () {
                  Navigator.of(context2).pop();
                  // TODO register an acceptation
                },
                textContent: I18nText(
                  'buttons.ok',
                ),
                backgroundColor: Colors.tealAccent,
                textColor: Colors.white,
              ),
              DialogActionButton(
                onPressed: () {
                  Navigator.of(context2).pop();
                  // TODO register a refusal
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

  Future<void> _startSession() async {
    setState(() {
      _remotePeerId = _peerIdController.text;

      _signaling.onDataChannelMessage = (dc, RTCDataChannelMessage data) {
        setState(() {
          _receivedPeerData = jsonDecode(data.text);
        });
      };

      _signaling.onDataChannel = (channel) {
        _dataChannel = channel;
      };
/* TODO fix or remove
      _signaling.onCallStateChange = (Session session, CallState state) async {
        switch (state) {
          case CallState.callStateNew:
            setState(() {
              _session = session;
            });
            break;
          case CallState.callStateInvite:
            setState(() {
              _waitAccept = true;
              _showWaitingPeerDialog(context);
            });
            break;
          case CallState.callStateConnected:
            if (_communicating) {
              Logger().d("Blocked an incoming connection.");
              return;
            }
            if (_waitAccept) {
              _waitAccept = false;
              Navigator.of(context).pop(false);
            }
            setState(() {
              _communicating = true;
            });
            break;
          case CallState.callStateBye:
            if (_waitAccept) {
              Logger().e('peer reject');
              _waitAccept = false;
              Navigator.of(context).pop(false);
            }
            setState(() {
              _communicating = false;
              _session = null;
            });
            break;
          case CallState.callStateRinging:
            if (_communicating) {
              Logger().d("Blocked an incoming request.");
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: I18nText('session.blocked_incoming_request'),
                ),
              );
              return;
            }
            final peerMessage = _receivedPeerData[ringingMessageKey] ?? '';
            bool? accept = await _showAcceptDialog(context, peerMessage);
            if (accept!) {
              _accept();
              setState(() {
                _communicating = true;
              });
            } else {
              _reject();
            }
            break;
        }
      };
      */
    });
    final response = await _signaling.makeCall(
      remotePeerId: _remotePeerId,
      message: _ringingMessageController.text,
    );
    setState(() {});
    switch (response) {
      case MakingCallResult.remotePeerDoesNotExist:
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: I18nText('game.no_matching_peer'),
            ),
          );
        }
        break;
      case MakingCallResult.alreadyAPendingCall:
      case MakingCallResult.success:
        await _showWaitingPeerDialog();
        break;
    }
  }

  void _accept() {
    if (_session != null) {
      // TODO _signaling.accept();
    }
  }

  _reject() {
    if (_session != null) {
      //TODO _signaling.reject();
    }
  }

  Future<void> _startConnection() async {
    setState(() {
      _peerIdController.text = '';
      _ringingMessageController.text = '';
    });
    return showDialog(
        context: context,
        builder: (BuildContext context2) {
          return AlertDialog(
            title: I18nText('session.dialog_new.title'),
            content: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  height: 30.0,
                ),
                I18nText('session.dialog_new.message_2'),
                IconButton(
                  onPressed: _copyTextFromClipboard,
                  icon: const Icon(
                    Icons.paste,
                  ),
                ),
                TextField(
                  controller: _peerIdController,
                  decoration: InputDecoration(
                    label: I18nText(
                      'session.dialog_new.peerIdPlaceholder',
                    ),
                  ),
                ),
                Container(
                  height: 30.0,
                ),
                TextField(
                  controller: _ringingMessageController,
                  maxLines: 5,
                  decoration: InputDecoration(
                      label: I18nText(
                    'session.dialog_new.ringingMessagePlaceholder',
                  )),
                )
              ],
            ),
            actions: [
              DialogActionButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _startSession();
                },
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
                backgroundColor: Colors.redAccent,
                textColor: Colors.white,
              )
            ],
          );
        });
  }

  Future<void> _displayMyOwnId() async {
    showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
              title: I18nText('session.dialog_my_id.title'),
              content: Row(
                children: [
                  Text(_signaling.selfId!),
                  IconButton(
                    onPressed: _copyIdToClipboard,
                    icon: const Icon(
                      Icons.paste,
                    ),
                  ),
                ],
              ),
              actions: [
                DialogActionButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  textContent: I18nText(
                    'buttons.ok',
                  ),
                  backgroundColor: Colors.tealAccent,
                  textColor: Colors.white,
                ),
              ]);
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
          if (_readyToConnect && !_signaling.callInProgress)
            IconButton(
              onPressed: _startConnection,
              icon: const Icon(
                Icons.call,
              ),
            ),
          if (_readyToConnect)
            IconButton(
              onPressed: _displayMyOwnId,
              icon: const Icon(
                Icons.numbers,
              ),
            ),
          IconButton(
            onPressed: _purposeRestartGame,
            icon: const Icon(
              Icons.add_rounded,
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

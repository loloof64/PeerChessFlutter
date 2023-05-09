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

import 'package:chess/chess.dart' as chess;
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_i18n/flutter_i18n.dart';
import 'package:simple_chess_board/simple_chess_board.dart';
import '../utils.dart';
import '../history_builder.dart';

const emptyPosition = '8/8/8/8/8/8/8/8 w - - 0 1';

enum EndStatus {
  followGameLogic,
  drawByAgreement,
  whiteGaveUp,
  blackGaveUp,
  whiteLossOnTime,
  blackLossOnTime,
}

class GameManager {
  chess.Chess _gameLogic = chess.Chess();
  PlayerType _whitePlayerType = PlayerType.computer;
  PlayerType _blackPlayerType = PlayerType.computer;
  bool _cpuCanPlay = false;
  String _startPosition = chess.Chess.DEFAULT_POSITION;
  bool _gameStart = false;
  bool _gameInProgress = false;
  bool _engineThinking = false;
  bool _atLeastAGameStarted = false;
  EndStatus _endStatus = EndStatus.followGameLogic;

  GameManager() {
    _gameLogic.load(emptyPosition);
  }

  bool get isGameOver => _gameLogic.game_over;
  bool get isGameStart => _gameStart;
  bool get atLeastAGameStarted => _atLeastAGameStarted;
  String get position => _gameLogic.fen;
  bool get whiteTurn => _gameLogic.turn == chess.Color.WHITE;
  String get startPosition => _startPosition;
  bool get cpuCanPlay => _cpuCanPlay;
  bool get gameInProgress => _gameInProgress;
  PlayerType get whitePlayerType => _whitePlayerType;
  PlayerType get blackPlayerType => _blackPlayerType;
  bool get engineThiking => _engineThinking;

  void setGameEndStatus(EndStatus endStatus) {
    _endStatus = endStatus;
  }

  bool whiteHasCheckmated() {
    if (_gameLogic.in_checkmate) return false;
    return _gameLogic.turn == chess.Color.BLACK;
  }

  bool blackHasCheckmated() {
    if (_gameLogic.in_checkmate) return false;
    return _gameLogic.turn == chess.Color.WHITE;
  }

  bool isDrawOnBoard() {
    return _gameLogic.in_draw;
  }

  bool processComputerMove({
    required String from,
    required String to,
    required String? promotion,
  }) {
    final moveHasBeenMade = _gameLogic.move({
      'from': from,
      'to': to,
      'promotion': promotion,
    });
    _engineThinking = false;
    _cpuCanPlay = false;

    return moveHasBeenMade;
  }

  void startSession() {
    _atLeastAGameStarted = false;
    _gameLogic.load(emptyPosition);
  }

  void clearGameStartFlag() {
    _gameStart = false;
  }

  bool processPlayerMove({
    required String from,
    required String to,
    required String? promotion,
  }) {
    final moveHasBeenMade = _gameLogic.move({
      'from': from,
      'to': to,
      'promotion': promotion,
    });
    return moveHasBeenMade;
  }

  void startNewGame({
    String startPosition = chess.Chess.DEFAULT_POSITION,
    bool playerHasWhite = true,
  }) {
    _endStatus = EndStatus.followGameLogic;
    _startPosition = startPosition;
    _whitePlayerType = playerHasWhite ? PlayerType.human : PlayerType.computer;
    _blackPlayerType = playerHasWhite ? PlayerType.computer : PlayerType.human;
    _gameStart = true;
    _gameInProgress = true;
    _gameLogic = chess.Chess();
    _gameLogic.load(_startPosition);
    _atLeastAGameStarted = true;
  }

  void stopGame() {
    _whitePlayerType = PlayerType.computer;
    _blackPlayerType = PlayerType.computer;
    _gameInProgress = false;
    _engineThinking = false;
  }

  void loadStartPosition() {
    _endStatus = EndStatus.followGameLogic;
    _gameLogic = chess.Chess();
    _gameLogic.load(_startPosition);
  }

  void loadPosition(String position) {
    _endStatus = EndStatus.followGameLogic;
    _gameLogic = chess.Chess();
    _gameLogic.load(position);
  }

  void allowCpuThinking() {
    _engineThinking = true;
    _cpuCanPlay = true;
  }

  void forbidCpuThinking() {
    _engineThinking = false;
    _cpuCanPlay = false;
  }

  String getLastMoveFan() {
    final lastPlayedMove = _gameLogic.history.last.move;

    // In order to get move SAN, it must not be done on board yet !
    // So we rollback the move, then we'll make it happen again.
    _gameLogic.undo_move();
    final san = _gameLogic.move_to_san(lastPlayedMove);
    _gameLogic.make_move(lastPlayedMove);

    // Move has been played: we need to revert player turn for the SAN.
    return san.toFan(whiteMove: !whiteTurn);
  }

  Move getLastMove() {
    final lastPlayedMove = _gameLogic.history.last.move;
    final relatedMoveFromSquareIndex = CellIndexConverter(lastPlayedMove.from)
        .convertSquareIndexFromChessLib();
    final relatedMoveToSquareIndex =
        CellIndexConverter(lastPlayedMove.to).convertSquareIndexFromChessLib();
    return Move(
      from: Cell.fromSquareIndex(relatedMoveFromSquareIndex),
      to: Cell.fromSquareIndex(relatedMoveToSquareIndex),
    );
  }

  String getResultString() {
    switch (_endStatus) {
      case EndStatus.followGameLogic:
        if (_gameLogic.in_checkmate) {
          return _gameLogic.turn == chess.Color.WHITE ? '0-1' : '1-0';
        }
        if (_gameLogic.in_draw) {
          return '1/2-1/2';
        }
        return '*';
      case EndStatus.drawByAgreement:
        return '1/2-1/2';
      case EndStatus.whiteGaveUp:
        return '0-1';
      case EndStatus.blackGaveUp:
        return '1-0';
      case EndStatus.whiteLossOnTime:
        return '0-1';
      case EndStatus.blackLossOnTime:
        return '1-0';
    }
  }

  Widget getGameEndedType() {
    dynamic result;
    if (_gameLogic.in_checkmate) {
      result = (_gameLogic.turn == chess.Color.WHITE)
          ? I18nText('game_termination.black_checkmate_white')
          : I18nText('game_termination.white_checkmate_black');
    } else if (_gameLogic.in_stalemate) {
      result = I18nText('game_termination.stalemate');
    } else if (_gameLogic.in_threefold_repetition) {
      result = I18nText('game_termination.repetitions');
    } else if (_gameLogic.insufficient_material) {
      result = I18nText('game_termination.insufficient_material');
    } else if (_gameLogic.in_draw) {
      result = I18nText('game_termination.fifty_moves');
    }
    return result;
  }

  String getPgn(
      {required String youTranslation,
      required String opponentTranslation,
      required bool playerHasWhite}) {
    final date = DateTime.now();
    final formatter = DateFormat('yyyy.MM.dd');
    _gameLogic.set_header([
      'FEN',
      _startPosition,
      'White',
      playerHasWhite ? youTranslation : opponentTranslation,
      'Black',
      playerHasWhite ? opponentTranslation : youTranslation,
      'Date',
      formatter.format(date),
      'Result',
      getResultString(),
    ]);

    String pgnStr = _gameLogic.pgn({
      'max_width': 80,
      'newline_char': '\n',
    });
    pgnStr = "$pgnStr ${getResultString()}\n";

    return pgnStr;
  }
}

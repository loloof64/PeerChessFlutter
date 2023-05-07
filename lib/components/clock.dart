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

import 'package:flutter/material.dart';

class ClockWidget extends StatelessWidget {
  final int whiteTimeInDeciSeconds;
  final int blackTimeInDeciSeconds;
  final bool whiteTimeSelected;

  const ClockWidget({
    super.key,
    required this.whiteTimeInDeciSeconds,
    required this.blackTimeInDeciSeconds,
    required this.whiteTimeSelected,
  });

  String _getTimeFormat(int timeInDeciSeconds) {
    final timeMillis = timeInDeciSeconds * 100;
    final deciSeconds = timeInDeciSeconds % 10;
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
      return "$hours:$minutesStr:$secondsStr";
    }
  }

  Color _getWhiteTextColor() {
    Color result = Colors.black;
    if (whiteTimeSelected) result = Colors.white;
    return result;
  }

  Color _getWhiteBackgroundColor() {
    Color result = Colors.white;
    if (whiteTimeSelected) {
      result = whiteTimeInDeciSeconds > 600 ? Colors.green : Colors.red;
    }
    return result;
  }

  Color _getBlackTextColor() {
    Color result = Colors.white;
    return result;
  }

  Color _getBlackBackgroundColor() {
    Color result = Colors.black;
    if (!whiteTimeSelected) {
      result = blackTimeInDeciSeconds > 600 ? Colors.green : Colors.red;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final whiteTimeText = _getTimeFormat(whiteTimeInDeciSeconds);
    final blackTimeText = _getTimeFormat(blackTimeInDeciSeconds);
    return LayoutBuilder(builder: (ctx2, constraints2) {
      final fontSize = constraints2.biggest.shortestSide * 0.04;
      return Row(
        children: [
          Flexible(
            flex: 4,
            fit: FlexFit.tight,
            child: Container(),
          ),
          Flexible(
            flex: 3,
            fit: FlexFit.tight,
            child: ClockSide(
              timeText: whiteTimeText,
              textColor: _getWhiteTextColor(),
              backgroundColor: _getWhiteBackgroundColor(),
              fontSize: fontSize,
            ),
          ),
          Flexible(
            flex: 3,
            fit: FlexFit.tight,
            child: ClockSide(
              timeText: blackTimeText,
              textColor: _getBlackTextColor(),
              backgroundColor: _getBlackBackgroundColor(),
              fontSize: fontSize,
            ),
          ),
          Flexible(
            flex: 4,
            fit: FlexFit.tight,
            child: Container(),
          ),
        ],
      );
    });
  }
}

class ClockSide extends StatelessWidget {
  final String timeText;
  final Color textColor;
  final Color backgroundColor;
  final double fontSize;
  const ClockSide({
    super.key,
    required this.timeText,
    required this.textColor,
    required this.backgroundColor,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          width: 1.0,
          color: Colors.black,
        ),
        color: backgroundColor,
      ),
      padding: const EdgeInsets.all(8.0),
      child: Text(
        timeText,
        textAlign: TextAlign.right,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.bold,
          fontSize: fontSize,
        ),
      ),
    );
  }
}

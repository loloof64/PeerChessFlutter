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

import 'package:firedart/firedart.dart';

extension FanConverter on String {
  String toFan({required bool whiteMove}) {
    const piecesRefs = "NBRQK";
    String result = this;

    final thisAsIndexedArray = split('').asMap();
    var firstOccurenceIndex = -1;
    for (var index = 0; index < thisAsIndexedArray.length; index++) {
      final element = thisAsIndexedArray[index]!;
      if (piecesRefs.contains(element)) {
        firstOccurenceIndex = index;
        break;
      }
    }

    if (firstOccurenceIndex > -1) {
      final element = thisAsIndexedArray[firstOccurenceIndex];
      dynamic replacement;
      switch (element) {
        case 'N':
          replacement = whiteMove ? "\u2658" : "\u265e";
          break;
        case 'B':
          replacement = whiteMove ? "\u2657" : "\u265d";
          break;
        case 'R':
          replacement = whiteMove ? "\u2656" : "\u265c";
          break;
        case 'Q':
          replacement = whiteMove ? "\u2655" : "\u265b";
          break;
        case 'K':
          replacement = whiteMove ? "\u2654" : "\u265a";
          break;
        default:
          throw Exception("Unrecognized piece char $element into SAN $this");
      }

      final firstPart = substring(0, firstOccurenceIndex);
      final lastPart = substring(firstOccurenceIndex + 1);

      result = "$firstPart$replacement$lastPart";
    }

    return result;
  }
}

Future<List<Document>> getAllDocumentsFromCollection({
  required String collectionName,
}) async {
  var nextPageToken = '';
  var results = <Document>[];
  while (true) {
    final instances = await Firestore.instance.collection(collectionName).get(
          nextPageToken: nextPageToken,
        );
    results.addAll(instances);
    if (!instances.hasNextPage) break;
    nextPageToken = instances.nextPageToken;
  }

  return results;
}

Future<List<Document>> getAllDocumentsFromSubCollection({
  required Document parentDocument,
  required String collectionName,
}) async {
  var nextPageToken = '';
  var results = <Document>[];
  while (true) {
    final instances =
        await parentDocument.reference.collection(collectionName).get(
              nextPageToken: nextPageToken,
            );
    results.addAll(instances);
    if (!instances.hasNextPage) break;
    nextPageToken = instances.nextPageToken;
  }

  return results;
}

enum ChannelMessagesKeys {
  type,
  startPosition,
  iHaveWhite,
  moveFrom,
  moveTo,
  movePromotion,
  value,
  useTime,
  whiteGameDurationMillis,
  blackGameDurationMillis,
  whiteGameIncrementMillis,
  blackGameIncrementMillis
}

enum ChannelMessageValues {
  newGame,
  newMove,
  giveUp,
  drawOffer,
  drawAnswer,
}

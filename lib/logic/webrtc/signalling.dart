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
// Using code from https://github.com/flutter-webrtc/flutter-webrtc-demo/blob/master/lib/src/call_sample/random_string.dart

import 'dart:convert';
import 'dart:math';

import 'package:collection_ext/ranges.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:parse_server_sdk_flutter/parse_server_sdk_flutter.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

enum MakingCallResult {
  success,
  remotePeerDoesNotExist,
  alreadyAPendingCall,
}

final asciiDigits = 48.upTo(57);
final asciiLowercase = 97.upTo(122);
final asciiUppercase = 65.upTo(90);

/// Generates a random integer where [from] <= [to].
int randomBetween(int from, int to) {
  if (from > to) throw Exception('$from cannot be > $to');
  var rand = Random();
  return ((to - from) * rand.nextDouble()).toInt() + from;
}

String randomString(int length) {
  return String.fromCharCodes(List.generate(length, (index) {
    var result = 0;
    while (!asciiDigits.contains(result) &&
        !asciiLowercase.contains(result) &&
        !asciiUppercase.contains(result)) {
      result = randomBetween(48, 122);
    }
    return result;
  }));
}

enum CreatingRoomState {
  success,
  alreadyCreatedARoom,
  error,
}

enum JoiningRoomState {
  success,
  noRoomWithThisId,
  alreadySomeonePairingWithHost,
}

class Signaling {
  RTCDataChannel? _dataChannel;
  late RTCPeerConnection _myConnection;

  String? _selfId;
  String? _roomId;

  bool _signallingInProgress = false;
  String? get roomId => _roomId;
  // TODO adapt
  String? get remoteId => null;

  late Map<String, dynamic> _iceServers;

  Signaling() {
    _initializeIceServers().then((value) => _createMyConnection());
  }

  Future<void> _initializeIceServers() async {
    final String credentialsText =
        await rootBundle.loadString('assets/credentials/turn_credentials.json');
    final credentials = await json.decode(credentialsText);

    final apiKey = credentials['apiKey'] as String;
    final response = await http.get(Uri.parse(
        "https://peer-chess.metered.live/api/v1/turn/credentials?apiKey=$apiKey"));

    // Saving the response in the iceServers array
    final serversText = response.body;
    final serversJson = await json.decode(serversText);
    _iceServers = {'iceServers': serversJson};
  }

  Future<void> _createMyConnection() async {
    final stream =
        await mediaDevices.getUserMedia({"audio": false, "video": false});
    _myConnection = await createPeerConnection(_iceServers);
    _myConnection.addStream(stream);
    final peer = ParseObject('Peer');
    final response = await peer.save();
    _selfId = peer.objectId;
    if (response.error != null) {
      Logger().e(response.error);
    }
  }

  Future<void> deleteRoom() async {
    if (_roomId == null) return;
    final roomInstance = ParseObject('Room')..objectId = _roomId!;
    await roomInstance.delete();
  }

  Future<CreatingRoomState> createRoom() async {
    if (_roomId != null) return CreatingRoomState.alreadyCreatedARoom;
    final room = ParseObject('Room');
    room.set('owner', ParseObject('Peer')..objectId = _selfId);
    final response = await room.save();
    if (response.error != null) {
      Logger().e(response.error);
      return CreatingRoomState.error;
    }
    final roomId = room.objectId;
    _roomId = roomId;
    return CreatingRoomState.success;
  }

  Future<JoiningRoomState> joinRoom(
      String requestedRoomId, String message) async {
    // Checks that the room exists
    QueryBuilder<ParseObject> queryRoom =
        QueryBuilder<ParseObject>(ParseObject('Room'))
          ..whereEqualTo('objectId', requestedRoomId);
    final ParseResponse apiResponse = await queryRoom.query();
    final roomExists = apiResponse.success && apiResponse.results != null;

    if (!roomExists) {
      return JoiningRoomState.noRoomWithThisId;
    }

    // Checks that nobody is playing with the room's host
    final roomInstance = apiResponse.results?.first as ParseObject;
    if (roomInstance.get('joiner') != null) {
      return JoiningRoomState.alreadySomeonePairingWithHost;
    }

    _roomId = requestedRoomId;

    // Registers the joiner of the room in the DB
    roomInstance.set(
        'joiner', (ParseObject('Peer')..objectId = selfId).toPointer());
    roomInstance.set('message', message);
    final saveResponse = await roomInstance.save();

    if (saveResponse.error != null) {
      Logger().e(saveResponse.error);
    }

    return JoiningRoomState.success;
  }

  Future<void> removeSelfFromRoomJoiner() async {
    final roomInstance = ParseObject('Room')..objectId = _roomId;
    roomInstance.set('joiner', null);
    roomInstance.set('message', null);
    await roomInstance.save();
  }

  Future<void> removePeerFromDB() async {
    final localPeer = ParseObject('Peer')..objectId = _selfId;
    await localPeer.delete();
  }

  String? get selfId => _selfId;

  Function(RTCDataChannel dc, RTCDataChannelMessage data)? onDataChannelMessage;
  Function(RTCDataChannel dc)? onDataChannel;

  void cancelCallRequest() {
    if (_signallingInProgress == false) return;
    _signallingInProgress = false;
  }

  Future<void> acceptAnswer() async {
    if (_signallingInProgress == false) return;
    _signallingInProgress = false;
    // TODO update OfferCandidates with status set to Accepted
    _myConnection.onDataChannel = (channel) {
      _dataChannel = channel;
      _dataChannel!.onMessage = (data) {
        print(data);
      };
    };
  }

  Future<void> declineAnswer() async {
    if (_signallingInProgress == false) return;
    _signallingInProgress = false;
    // TODO update OfferCandidates with status set to Rejected
  }

  Future<void> _closeCall() async {
    await _myConnection.close();
    await _dataChannel?.close();
    _dataChannel = null;
  }

  void _addDataChannel(RTCDataChannel channel) {
    channel.onDataChannelState = (e) {};
    channel.onMessage = (RTCDataChannelMessage data) {
      onDataChannelMessage?.call(channel, data);
    };
    _dataChannel = channel;
    onDataChannel?.call(channel);
  }

  Future<void> _createDataChannel({label = 'dataTransfer'}) async {
    final dataChannelDict = RTCDataChannelInit()..maxRetransmits = 30;
    final channel =
        await _myConnection.createDataChannel(label, dataChannelDict);
    _addDataChannel(channel);
  }

  Future<void> hangUp() async {
    _closeCall();
  }
}

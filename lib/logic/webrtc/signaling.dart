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

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;

enum MakingCallResult {
  success,
  remotePeerDoesNotExist,
  alreadyAPendingCall,
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
  error,
}

class Signaling {
  RTCDataChannel? _dataChannel;
  late RTCPeerConnection _myConnection;
  late WebSocketChannel _wsChannel;

  String? _selfId;
  String? _roomId;

  String? get roomId => _roomId;

  bool get remoteDescriptionNeeded =>
      _myConnection.connectionState !=
          RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
      _myConnection.connectionState !=
          RTCPeerConnectionState.RTCPeerConnectionStateConnecting;

  late Map<String, dynamic> _iceServers;

  Signaling() {
    _initializeWebSocket().then((value) =>
        _initializeIceServers().then((value) => _createMyConnection()));
  }

  void dispose() {
    _wsChannel.sink.close();
  }

  void _processIncomingMessage(message) {
    final dataAsJson = jsonDecode(message) as Map<String, dynamic>;
    if (dataAsJson.containsKey('error')) {
      Logger().e(dataAsJson['error']);
    } else if (dataAsJson.containsKey('socketID')) {
      _selfId = dataAsJson['socketID'];
      ////////////////////
      Logger().d(_selfId);
      ////////////////////
    } else if (dataAsJson.containsKey('type')) {
      if (dataAsJson['type'] == 'disconnection') {
        final id = dataAsJson['id'];
        Logger().d('Peer $id has disconnected.');
      }
    }
  }

  Future<void> _initializeWebSocket() async {
    final String secretsText =
        await rootBundle.loadString('assets/secrets/signaling.json');
    final secrets = await json.decode(secretsText);
    final serverUrl = secrets['serverUrl'] as String;

    final uri = Uri.parse(serverUrl);

    _wsChannel = WebSocketChannel.connect(
      uri,
    );

    _wsChannel.stream.listen((element) {
      _processIncomingMessage(element);
    });
    //_wsChannel.sink.add('Hello !');
  }

  Future<void> _initializeIceServers() async {
    final String credentialsText =
        await rootBundle.loadString('assets/secrets/turn_credentials.json');
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

    // todo add peer in db
  }

  Future<void> deleteRoom() async {
    if (_roomId == null) return;
    // todo remove room in db
    _roomId = null;
  }

  Future<void> setRemoteDescriptionFromAnswer(
      RTCSessionDescription description) async {
    await _myConnection.setRemoteDescription(description);
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    await _myConnection.addCandidate(candidate);
  }

  Future<void> createRoom() async {
    // Checking that this peer is not already in a room
    final peerAlreadyInARoom = _roomId != null;

    // todo Save Room into DB and join this peer to it

    // todo Update room id

    // todo Set ICE candidates handler

    // todo Create WebRTC offer

    // todo Save offer in db

    return;
  }

  Future<void> joinRoom(String requestedRoomId) async {
    // todo Check that the room exists

    // todo Check that nobody is playing with the room's host

    // todo Set remote description with offer from host

    // todo Register the joiner of the room in the DB

    // todo Set the ICE candidates from the offer

    // todo Set ICE candidates handler

    // todo Create WebRTC offer

    // todo Save answer in db

    return;
  }

  Future<void> removeSelfFromRoomJoiner() async {
    // todo removeSelfFromRoomJoiner
  }

  Future<void> removePeerFromDB() async {
    // todo removePeerFromDB
  }

  String? get selfId => _selfId;

  Function(RTCDataChannel dc, RTCDataChannelMessage data)? onDataChannelMessage;
  Function(RTCDataChannel dc)? onDataChannel;

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

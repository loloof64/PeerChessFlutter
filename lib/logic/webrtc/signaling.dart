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

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:fauna_dart_driver/fauna_dart_driver.dart';
import 'package:faunadb_http/faunadb_http.dart' hide FaunaClient;
import 'package:faunadb_http/query.dart';

String generateId() {
  const digitsCount = 10;
  String result = '';
  var rng = Random();
  for (var i = 0; i < digitsCount; i++) {
    result += rng.nextInt(10).toString();
  }
  return result;
}

class Signaling {
  RTCDataChannel? _dataChannel;
  late RTCPeerConnection _myConnection;
  late FaunaClient _faunaClient;
  String? _selfId;
  String? _remoteId;

  String? get selfId => _selfId;
  String? get remoteId => _remoteId;

  bool get remoteDescriptionNeeded =>
      _myConnection.connectionState !=
          RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
      _myConnection.connectionState !=
          RTCPeerConnectionState.RTCPeerConnectionStateConnecting;

  late Map<String, dynamic> _iceServers;

  Signaling() {
    _initialiseFaunaListener().then((value) =>
        _initializeIceServers().then((value) => _createMyConnection()));
  }

  Future<void> _initialiseFaunaListener() async {
    final String secretsText =
        await rootBundle.loadString('assets/secrets/fauna.json');
    final secrets = await json.decode(secretsText);
    final secretValue = secrets['secret'] as String;

    _faunaClient = FaunaClient(
      secret: secretValue,
    );

    _selfId = generateId();

    await _faunaClient.query(Create(
      Collection('peer'),
      Obj(
        {
          "data": {
            "id": _selfId,
          },
        },
      ),
    ));
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
  }

  Future<void> setRemoteDescriptionFromAnswer(
      RTCSessionDescription description) async {
    await _myConnection.setRemoteDescription(description);
  }

  Future<void> addIceCandidate(RTCIceCandidate candidate) async {
    await _myConnection.addCandidate(candidate);
  }

  Future<void> removeSelfFromRoomJoiner() async {
    // todo removeSelfFromRoomJoiner
  }

  Function(RTCDataChannel dc, RTCDataChannelMessage data)? onDataChannelMessage;
  Function(RTCDataChannel dc)? onDataChannel;

  Future<void> _closeCall() async {
    await _myConnection.close();
    await _dataChannel?.close();
    _dataChannel = null;
    await _faunaClient.close();
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

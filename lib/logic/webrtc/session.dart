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

import 'dart:math';
import 'dart:convert';

import 'package:collection_ext/ranges.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:parse_server_sdk_flutter/parse_server_sdk.dart';

class Session {
  Session({required this.peerId});
  String peerId;
  RTCPeerConnection? peerConnection;
  RTCDataChannel? dataChannel;
  RTCIceCandidate? remoteCandidates;
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

enum SignalingState {
  connectionOpen,
  connectionClosed,
  connectionError,
}

enum CallState {
  callStateNew,
  callStateRinging,
  callStateInvite,
  callStateConnected,
  callStateBye,
}

const turnUsername = 'e70ea9d69e030b5e912b12b2';
const turnPassword = 'wKYehfEx0+I4Q1G';

class Signaling {
  final JsonEncoder _encoder;
  final JsonDecoder _decoder;

  RTCDataChannel? _dataChannel;
  late RTCPeerConnection _myConnection;

  late Session _session;

  final String _selfId = randomString(15);

  final Map<String, dynamic> _iceServers;

  final Map<String, dynamic> _dcConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    },
    'optional': [],
  };

  Signaling()
      : _iceServers = {
          'iceServers': [
            {
              'urls': "stun:openrelay.metered.ca:80",
            },
            {
              'urls': "turn:openrelay.metered.ca:80",
              'username': turnUsername,
              'credential': turnPassword,
            },
            {
              'urls': "turn:openrelay.metered.ca:443",
              'username': turnUsername,
              'credential': turnPassword,
            },
            {
              'urls': "turn:openrelay.metered.ca:443?transport=tcp",
              'username': turnUsername,
              'credential': turnPassword,
            },
          ]
        },
        _encoder = const JsonEncoder(),
        _decoder = const JsonDecoder();

  Future<void> createMyConnection() async {
    _myConnection = await createPeerConnection(_iceServers);
    final peer = ParseObject('Peer')..set('genId', _selfId);
    final response = await peer.save();
    if (response.error != null) {
      Logger().e(response.error);
    }

    final offerDescription = await _myConnection.createOffer();
    _myConnection.setLocalDescription(offerDescription);

    final offer = {"sdp": offerDescription.sdp, "type": offerDescription.type};
    QueryBuilder<ParseObject> queryPeer =
        QueryBuilder<ParseObject>(ParseObject('Peer'));
    queryPeer.whereContains('genId', _selfId);
    final ParseResponse apiResponse = await queryPeer.query();
    if (apiResponse.success && apiResponse.results != null) {
      final objId = (apiResponse.results!.first as ParseObject).objectId;
      final parseInstance = ParseObject('Peer')..objectId = objId;
      parseInstance.set('offer', offer);
      await parseInstance.save();
    }
  }

  Future<void> removePeerFromDB() async {
    final QueryBuilder<ParseObject> parseQuery =
        QueryBuilder<ParseObject>(ParseObject('Peer'));
    parseQuery.whereContains('genId', _selfId);

    final ParseResponse apiResponse = await parseQuery.query();

    if (apiResponse.success &&
        apiResponse.results != null &&
        apiResponse.results!.isNotEmpty) {
      final response = apiResponse.results!.first as ParseObject;
      await response.delete();
    }
  }

  String get selfId => _selfId;

  Function(SignalingState state)? onSignalingStateChange;
  Function(Session session, CallState state)? onCallStateChange;

  Function(Session session, RTCDataChannel dc, RTCDataChannelMessage data)?
      onDataChannelMessage;
  Function(Session session, RTCDataChannel dc)? onDataChannel;

  void invite({required String peerId}) async {
    await _createSession(peerId: peerId);
    _createDataChannel(_session);
    _createOffer(_session);
    onCallStateChange?.call(_session, CallState.callStateNew);
    onCallStateChange?.call(_session, CallState.callStateInvite);
  }

  void bye() {
    /* TODO correct
    _send('bye', {
      'from': _selfId,
    });
    */
    _closeSession();
  }

  void accept() {
    _createAnswer();
  }

  void reject() {
    bye();
  }

  Future<void> _createSession({
    required String peerId,
  }) async {
    /* TODO correct
    var newSession = Session(peerId: peerId);
    pc.onIceCandidate = (candidate) {
      _send('candidate', {
        'to': peerId,
        'from': _selfId,
        'candidate': {
          'sdpMLineIndex': candidate.sdpMLineIndex,
          'sdpMid': candidate.sdpMid,
          'candidate': candidate.candidate,
        },
      });
    };

    pc.onIceConnectionState = (state) {};

    pc.onDataChannel = (channel) {
      _addDataChannel(channel);
    };

    newSession.peerConnection = pc;
    _session = newSession;
    */
  }

  Future<void> _closeSession() async {
    await _session.peerConnection?.close();
    await _session.dataChannel?.close();
  }

  void _addDataChannel(RTCDataChannel channel) {
    channel.onDataChannelState = (e) {};
    channel.onMessage = (RTCDataChannelMessage data) {
      onDataChannelMessage?.call(_session, channel, data);
    };
    _session.dataChannel = channel;
    onDataChannel?.call(_session, channel);
  }

  Future<void> _createDataChannel(Session session,
      {label = 'dataTransfer'}) async {
    RTCDataChannelInit dataChannelDict = RTCDataChannelInit()
      ..maxRetransmits = 30;
    RTCDataChannel channel =
        await session.peerConnection!.createDataChannel(label, dataChannelDict);
    _addDataChannel(channel);
  }

  Future<void> _createOffer(Session session) async {
    try {
      RTCSessionDescription s =
          await session.peerConnection!.createOffer(_dcConstraints);
      /* TODO correct
      await session.peerConnection!.setLocalDescription(_fixSdp(s));
      _send('offer', {
        'to': session.pid,
        'from': _selfId,
        'description': {'sdp': s.sdp, 'type': s.type},
      });
      */
    } catch (e) {
      Logger().e(e.toString());
    }
  }

  Future<void> _createAnswer() async {
    try {
      RTCSessionDescription s =
          await _session.peerConnection!.createAnswer(_dcConstraints);
      /* TODO correct 
      _send('answer', {
        'to': _session.pid,
        'from': _selfId,
        'description': {'sdp': s.sdp, 'type': s.type},
      });
      */
    } catch (e) {
      Logger().e(e.toString());
    }
  }
}

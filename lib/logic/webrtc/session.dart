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
import './websocket.dart';

class Session {
  Session({required this.pid});
  String pid;
  RTCPeerConnection? peerConnection;
  RTCDataChannel? dataChannel;
  List<RTCIceCandidate> remoteCandidates = [];
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

class Signaling {
  final JsonEncoder _encoder;
  final JsonDecoder _decoder;

  RTCDataChannel? _dataChannel;

  SimpleWebSocket? _socket;

  late Session _session;

  final String turnUsername;
  final String turnPassword;
  final String _selfId = randomString(15);

  final Map<String, dynamic> _iceServers;

  final Map<String, dynamic> _config = {
    'mandatory': {},
    'optional': [
      {'DtlsSrtpKeyAgreement': true},
    ]
  };

  final Map<String, dynamic> _dcConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    },
    'optional': [],
  };

  Signaling({
    required this.turnUsername,
    required this.turnPassword,
  })  : _iceServers = {
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

  String get selfId => _selfId;

  Function(SignalingState state)? onSignalingStateChange;
  Function(Session session, CallState state)? onCallStateChange;

  Function(Session session, RTCDataChannel dc, RTCDataChannelMessage data)?
      onDataChannelMessage;
  Function(Session session, RTCDataChannel dc)? onDataChannel;

  void invite(String peerId) async {
    await _createSession(peerId: peerId);
    _createDataChannel(_session);
    _createOffer(_session);
    onCallStateChange?.call(_session, CallState.callStateNew);
    onCallStateChange?.call(_session, CallState.callStateInvite);
  }

  void bye() {
    _send('bye', {
      'from': _selfId,
    });
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
    var newSession = Session(pid: peerId);
    RTCPeerConnection pc = await createPeerConnection({
      ..._iceServers,
      ...{'sdpSemantics': 'unified-plan'}
    }, _config);
    pc.onIceCandidate = (candidate) async {
      // This delay is needed to allow enough time to try an ICE candidate
      // before skipping to the next one. 1 second is just an heuristic value
      // and should be thoroughly tested in your own environment.
      await Future.delayed(
          const Duration(seconds: 1),
          () => _send('candidate', {
                'to': peerId,
                'from': _selfId,
                'candidate': {
                  'sdpMLineIndex': candidate.sdpMLineIndex,
                  'sdpMid': candidate.sdpMid,
                  'candidate': candidate.candidate,
                },
              }));
    };

    pc.onIceConnectionState = (state) {};

    pc.onDataChannel = (channel) {
      _addDataChannel(channel);
    };

    newSession.peerConnection = pc;
    _session = newSession;
  }

  Future<void> _closeSession() async {
    await _session.peerConnection?.close();
    await _session.dataChannel?.close();
    _socket?.close();
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
      {label = 'fileTransfer'}) async {
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
      await session.peerConnection!.setLocalDescription(_fixSdp(s));
      _send('offer', {
        'to': session.pid,
        'from': _selfId,
        'description': {'sdp': s.sdp, 'type': s.type},
      });
    } catch (e) {
      Logger().e(e.toString());
    }
  }

  RTCSessionDescription _fixSdp(RTCSessionDescription s) {
    var sdp = s.sdp;
    s.sdp =
        sdp!.replaceAll('profile-level-id=640c1f', 'profile-level-id=42e032');
    return s;
  }

  Future<void> _createAnswer() async {
    try {
      RTCSessionDescription s =
          await _session.peerConnection!.createAnswer(_dcConstraints);
      await _session.peerConnection!.setLocalDescription(_fixSdp(s));
      _send('answer', {
        'to': _session.pid,
        'from': _selfId,
        'description': {'sdp': s.sdp, 'type': s.type},
      });
    } catch (e) {
      Logger().e(e.toString());
    }
  }

  _send(event, data) {
    var request = {};
    request["type"] = event;
    request["data"] = data;
    _socket?.send(_encoder.convert(request));
  }
}

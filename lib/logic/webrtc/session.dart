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

import 'package:collection_ext/ranges.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logger/logger.dart';
import 'package:parse_server_sdk_flutter/parse_server_sdk.dart';

enum MakingCallResult {
  success,
  remotePeerDoesNotExist,
  alreadyAPendingCall,
}

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
  RTCDataChannel? _dataChannel;
  late RTCPeerConnection _myConnection;

  late Session _session;

  String? _selfId;
  String? _remotePeerId;

  String? _callObjectId;

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
        } {
    _createMyConnection();
  }

  Future<void> _createMyConnection() async {
    _myConnection = await createPeerConnection(_iceServers);
    final peer = ParseObject('Peer');
    final response = await peer.save();
    _selfId = peer.objectId;
    if (response.error != null) {
      Logger().e(response.error);
    }
  }

  Future<void> _removeReleatedOfferCandidates() async {
    if (_remotePeerId != null) {
      QueryBuilder<ParseObject> queryBook =
          QueryBuilder<ParseObject>(ParseObject('OfferCandidates'))
            ..whereEqualTo(
                'owner', (ParseObject('Peer')..objectId = selfId).toPointer())
            ..whereEqualTo('target',
                (ParseObject('Peer')..objectId = _remotePeerId).toPointer());
      final ParseResponse apiResponse = await queryBook.query();

      if (apiResponse.success && apiResponse.results != null) {
        for (var result in apiResponse.results! as List<ParseObject>) {
          await result.delete();
        }
      }
    }
  }

  Future<void> removePeerFromDB() async {
    _removeReleatedOfferCandidates();

    final localPeer = ParseObject('Peer')..objectId = _selfId;
    await localPeer.delete();
  }

  String? get selfId => _selfId;
  String? get remoteId => _remotePeerId;
  bool get callInProgress => _remotePeerId != null;

  Function(SignalingState state)? onSignalingStateChange;
  Function(Session session, CallState state)? onCallStateChange;

  Function(Session session, RTCDataChannel dc, RTCDataChannelMessage data)?
      onDataChannelMessage;
  Function(Session session, RTCDataChannel dc)? onDataChannel;

  void cancelCallRequest() {
    //TODO check if no call is in progress
    _remotePeerId = null;
  }

  Future<MakingCallResult> makeCall({
    required String remotePeerId,
    required String message,
  }) async {
    if (_remotePeerId == null) {
      // checking that target peer exists
      QueryBuilder<ParseObject> queryRemotePeer =
          QueryBuilder<ParseObject>(ParseObject('Peer'))
            ..whereEqualTo('objectId', remotePeerId);
      final ParseResponse apiResponse = await queryRemotePeer.query();

      if (!apiResponse.success ||
          apiResponse.results == null ||
          apiResponse.results!.isEmpty) {
        return MakingCallResult.remotePeerDoesNotExist;
      }

      _remotePeerId = remotePeerId;

      // create call object
      _myConnection.onIceCandidate = (candidate) async {
        final dbCandidate = ParseObject('OfferCandidates')
          ..set('owner', ParseObject('Peer')..objectId = selfId)
          ..set('target', ParseObject('Peer')..objectId = remotePeerId)
          ..set('offerMessage', message)
          ..set('offer', candidate.toMap());
        _callObjectId = dbCandidate.objectId;
        await dbCandidate.save();
      };

      final offerDescription = await _myConnection.createOffer();
      await _myConnection.setLocalDescription(offerDescription);

      return MakingCallResult.success;
    }
    return MakingCallResult.alreadyAPendingCall;
  }

  Future<void> _closeCall() async {
    await _session.peerConnection?.close();
    await _session.dataChannel?.close();
    _removeReleatedOfferCandidates();
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

  Future<void> hangUp() async {
    _closeCall();
    _remotePeerId = null;
  }
}
